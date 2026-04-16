import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/game_event.dart';
import '../providers/game_provider.dart';
import '../services/auth_service.dart';
import '../services/game_service.dart';
import '../theme/colors.dart';

// ─────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────

const _coral   = appCoral;
const _bg      = appBg;
const _matchmakingTimeout = 20; // seconds — gives server lobbyWait (10s) + buffer

// ─────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────

// Real gRPC SubscribeToMatch stream — backed by the Go server.
// userId is passed as the family parameter to avoid race with _joinMatchmaking.
final matchmakingStreamProvider =
    StreamProvider.family<MatchmakingUpdate, String>((ref, userId) {
  final gameService = ref.watch(gameServiceProvider);
  return gameService.subscribeToMatch(userId);
});

// Tracks countdown seconds remaining
final waitTimerProvider = StateProvider<int>((ref) => _matchmakingTimeout);

// ─────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────

class MatchmakingScreen extends ConsumerStatefulWidget {
  const MatchmakingScreen({super.key});

  @override
  ConsumerState<MatchmakingScreen> createState() => _MatchmakingScreenState();
}

class _MatchmakingScreenState extends ConsumerState<MatchmakingScreen>
    with TickerProviderStateMixin {

  // userId fixed for the lifetime of this screen — same value used for
  // both subscribeToMatch (provider) and joinMatchmaking (RPC call).
  late final String _userId;

  // Whether the user has pressed "Start" to begin matchmaking
  bool _searching = false;

  // Pulsing outer ring controller
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;
  late final Animation<double> _pulseOpacity;

  // Rotating ring controller (subtle spin)
  late final AnimationController _spinController;

  // Countdown timer
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider);
    _userId = auth.userId ?? 'player-${DateTime.now().millisecondsSinceEpoch % 100000}';
    _setupAnimations();
  }

  void _onStartPressed() {
    // Invalidate any cached stream from a previous session (Play Again)
    ref.invalidate(matchmakingStreamProvider(_userId));
    setState(() => _searching = true);
    _startCountdown();
    // Delay joinMatchmaking by one frame so the stream provider rebuilds first,
    // ensuring SubscribeToMatch is established on the server BEFORE JoinMatchmaking
    // fires. Without this delay, the JoinMatchmaking broadcast arrives before the
    // player's subscription channel is registered, so they never see themselves.
    WidgetsBinding.instance.addPostFrameCallback((_) => _joinMatchmaking());
  }

  Future<void> _joinMatchmaking() async {
    final auth = ref.read(authProvider);
    final username = auth.username ?? 'Player';
    ref.read(gameProvider.notifier).setUser(_userId, username);
    try {
      await ref.read(gameServiceProvider).joinMatchmaking(_userId, username, auth.rating.toDouble());
    } catch (e) {
      if (!mounted) return;
      // Cancel the search UI and show the error to the user
      _countdownTimer?.cancel();
      setState(() => _searching = false);
      final msg = e.toString().contains('Daily free limit')
          ? 'Daily limit reached (5/5 games). Come back tomorrow or upgrade to Premium!'
          : 'Could not join matchmaking. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: const Color(0xFFE74C3C),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _setupAnimations() {
    // Pulse: scale 1.0 → 1.35 → 1.0, repeating
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _pulseScale = Tween<double>(begin: 1.0, end: 1.35).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _pulseOpacity = Tween<double>(begin: 0.6, end: 0.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
    );

    // Subtle spin on the dashed ring
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  void _startCountdown() {
    // Cancel any existing timer first (prevents double-tick on re-entry)
    _countdownTimer?.cancel();

    // Reset timer
    ref.read(waitTimerProvider.notifier).state = _matchmakingTimeout;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = ref.read(waitTimerProvider);
      if (current <= 1) {
        _countdownTimer?.cancel();
        _onCancel(); // auto-cancel when ETA expires
      } else {
        ref.read(waitTimerProvider.notifier).state = current - 1;
      }
    });
  }

  void _onCancel() {
    _countdownTimer?.cancel();
    if (_searching) {
      ref.read(gameServiceProvider).leaveMatchmaking(_userId);
      ref.read(gameProvider.notifier).cancelMatchmaking();
      // Go back to lobby view (not pop — matchmaking is the root after login)
      setState(() => _searching = false);
    }
  }

  void _onMatchFound(MatchmakingUpdate update) {
    _countdownTimer?.cancel();
    final auth = ref.read(authProvider);
    ref.read(authProvider.notifier).consumeDailyQuiz();
    ref.read(gameProvider.notifier).setUser(_userId, auth.username ?? 'You');
    ref.read(gameProvider.notifier).onMatchFound(
      roomId: update.roomId!,
      players: update.players,
      totalRounds: update.totalRounds,
    );
    if (mounted) context.goNamed('quiz');
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _spinController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_searching) {
      return Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context),
              Expanded(child: _buildLobby()),
            ],
          ),
        ),
      );
    }

    final streamState = ref.watch(matchmakingStreamProvider(_userId));
    final waitSeconds = ref.watch(waitTimerProvider);

    // React to stream events
    ref.listen(matchmakingStreamProvider(_userId), (_, next) {
      next.whenData((update) {
        if (update.matchFound) _onMatchFound(update);
      });
    });

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),
            Expanded(
              child: streamState.when(
                loading: () => _buildSearching(playersFound: 0, total: 4, waitSeconds: waitSeconds),
                error: (e, _) => _buildError(e.toString()),
                data: (update) => _buildSearching(
                  playersFound: update.playersFound,
                  total: update.totalNeeded,
                  waitSeconds: waitSeconds,
                  foundPlayers: update.players,
                  waitingPlayers: update.waitingPlayers,
                ),
              ),
            ),
            _buildCancelButton(),
          ],
        ),
      ),
    );
  }

  String _levelLabel(int rating) {
    if (rating >= 250000) return 'GRANDMASTER';
    if (rating >= 200000) return 'MASTER';
    if (rating >= 150000) return 'EXPERT';
    if (rating >= 100000) return 'ADVANCED';
    if (rating >= 50000)  return 'INTERMEDIATE';
    return 'BEGINNER';
  }

  // ── Lobby (pre-matchmaking) ───────────────────────────────

  Widget _buildLobby() {
    final auth = ref.watch(authProvider);
    final username = auth.username ?? _userId;
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    final winRate = auth.matchesPlayed > 0
        ? (auth.matchesWon / auth.matchesPlayed * 100).round()
        : 0;

    return SingleChildScrollView(
      child: Column(
        children: [
          // ── Profile banner (like reference) ───────────────────
          Stack(
            clipBehavior: Clip.none,
            children: [
              // Banner background
              Container(
                height: 160,
                width: double.infinity,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF2B1208), Color(0xFF1A0B06), Color(0xFF0D0D1A)],
                  ),
                ),
                child: Stack(
                  children: [
                    // Decorative circle top-right
                    Positioned(
                      top: -30, right: -30,
                      child: Container(
                        width: 160, height: 160,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _coral.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -20, left: 20,
                      child: Container(
                        width: 90, height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _coral.withValues(alpha: 0.05),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Avatar — overlapping the banner bottom edge
              Positioned(
                bottom: -44,
                left: 24,
                child: _buildLobbyAvatar(auth.pictureUrl, initial)
                    .animate()
                    .scale(
                        begin: const Offset(0.7, 0.7),
                        end: const Offset(1, 1),
                        curve: Curves.elasticOut,
                        duration: 700.ms),
              ),

              // View profile button top-right of banner
              Positioned(
                top: 12, right: 16,
                child: GestureDetector(
                  onTap: () => context.pushNamed('profile'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_rounded, color: Colors.white70, size: 14),
                        SizedBox(width: 5),
                        Text('View Profile',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            )),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ).animate().fadeIn(duration: 400.ms),

          // ── Name + info row (below banner) ─────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 54, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Name + online dot
                Row(
                  children: [
                    Text(
                      username,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 10, height: 10,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF2ECC71),
                        boxShadow: [
                          BoxShadow(color: Color(0x552ECC71), blurRadius: 6, spreadRadius: 1),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Rating + win-rate chips
                Wrap(
                  spacing: 8, runSpacing: 6,
                  children: [
                    _Chip(icon: Icons.star_rounded, label: '${auth.rating}', color: const Color(0xFFFFB830)),
                    _Chip(icon: Icons.military_tech_rounded, label: _levelLabel(auth.rating), color: const Color(0xFFFFB830)),
                    if (auth.currentStreak > 0)
                      _Chip(icon: Icons.local_fire_department_rounded, label: '${auth.currentStreak}d streak', color: const Color(0xFFE74C3C)),
                  ],
                ),
              ],
            ).animate().fadeIn(delay: 200.ms, duration: 400.ms),
          ),

          const SizedBox(height: 20),

          // ── Stats grid (3 tabs style) ──────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  // Top row
                  IntrinsicHeight(
                    child: Row(
                      children: [
                        _StatTile(icon: Icons.sports_esports_rounded, color: _coral,
                            value: '${auth.matchesPlayed}', label: 'Played'),
                        _VertDivider(),
                        _StatTile(icon: Icons.emoji_events_rounded, color: const Color(0xFF2ECC71),
                            value: '${auth.matchesWon}', label: 'Won'),
                        _VertDivider(),
                        _StatTile(icon: Icons.close_rounded, color: const Color(0xFFE74C3C),
                            value: '${auth.matchesPlayed - auth.matchesWon}', label: 'Lost'),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Colors.white10),
                  // Bottom row
                  IntrinsicHeight(
                    child: Row(
                      children: [
                        _StatTile(icon: Icons.whatshot_rounded, color: const Color(0xFFFFB830),
                            value: '${auth.maxStreak}', label: 'Max Streak'),
                        _VertDivider(),
                        _StatTile(icon: Icons.bolt_rounded, color: _coral,
                            value: '${auth.maxQuestionStreak}', label: 'Best Q Streak'),
                        _VertDivider(),
                        _StatTile(icon: Icons.bar_chart_rounded, color: const Color(0xFFFFB830),
                            value: '$winRate%', label: 'Win Rate'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ).animate().fadeIn(delay: 300.ms, duration: 400.ms).slideY(begin: 0.1, end: 0),

          const SizedBox(height: 16),

          // ── Daily quota card ──────────────────────────────────
          _buildDailyQuotaCard(auth),

          const SizedBox(height: 16),

          // ── Start button ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _onStartPressed,
                icon: const Icon(Icons.sports_esports_rounded, size: 20),
                label: const Text(
                  'Start Matchmaking',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _coral,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
              ),
            ),
          ).animate().fadeIn(delay: 400.ms, duration: 400.ms).slideY(begin: 0.2, end: 0),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Daily quota card ─────────────────────────────────────

  /// Returns the local time when midnight UTC occurs (i.e. when quota resets).
  String _quotaResetTime() {
    final now = DateTime.now();
    // Next midnight UTC in local time
    final nextMidnightUtc = DateTime.utc(now.toUtc().year, now.toUtc().month, now.toUtc().day + 1);
    final local = nextMidnightUtc.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildDailyQuotaCard(AuthState auth) {
    if (auth.isPremium) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFFB830).withValues(alpha: 0.3)),
          ),
          child: const Row(
            children: [
              Icon(Icons.all_inclusive_rounded, color: Color(0xFFFFB830), size: 18),
              SizedBox(width: 10),
              Text('Unlimited matches today',
                  style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
              Spacer(),
              Text('PREMIUM', style: TextStyle(color: Color(0xFFFFB830), fontSize: 11, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ).animate().fadeIn(delay: 350.ms, duration: 400.ms);
    }

    final used = auth.dailyQuizUsed;
    final bonus = auth.bonusGamesRemaining;
    final freeLeft = (kFreeQuotaPerDay - used).clamp(0, kFreeQuotaPerDay);
    final totalLeft = freeLeft + bonus;
    final exhausted = totalLeft <= 0;
    final progress = used / kFreeQuotaPerDay;

    final barColor = exhausted
        ? const Color(0xFFE74C3C)
        : freeLeft <= 1
            ? const Color(0xFFFFB830)
            : const Color(0xFF2ECC71);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: exhausted
                ? const Color(0xFFE74C3C).withValues(alpha: 0.4)
                : Colors.white10,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  exhausted ? Icons.block_rounded : Icons.sports_esports_rounded,
                  color: barColor,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Today\'s Matches',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                // Free games counter
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '$used',
                        style: TextStyle(
                          color: exhausted ? const Color(0xFFE74C3C) : Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      TextSpan(
                        text: '/$kFreeQuotaPerDay',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (bonus > 0)
                        TextSpan(
                          text: ' +$bonus bonus',
                          style: const TextStyle(
                            color: Color(0xFFFFB830),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
              ),
            ),
            if (exhausted) ...[
              const SizedBox(height: 8),
              Text(
                bonus > 0
                    ? '$bonus bonus game${bonus == 1 ? '' : 's'} remaining'
                    : 'Limit reached — resets at ${_quotaResetTime()} or upgrade to Premium',
                style: TextStyle(
                  color: bonus > 0
                      ? const Color(0xFFFFB830)
                      : const Color(0xFFE74C3C).withValues(alpha: 0.8),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    ).animate().fadeIn(delay: 350.ms, duration: 400.ms);
  }

  // ── Lobby avatar (Google photo or initial letter) ─────────

  Widget _buildLobbyAvatar(String? pictureUrl, String initial) {
    final outerDecoration = BoxDecoration(
      shape: BoxShape.circle,
      color: _coral.withValues(alpha: 0.18),
      border: Border.all(color: _bg, width: 4),
      boxShadow: [
        BoxShadow(color: _coral.withValues(alpha: 0.4), blurRadius: 20, spreadRadius: 2),
      ],
    );

    if (pictureUrl != null && pictureUrl.isNotEmpty) {
      return Container(
        width: 88, height: 88,
        decoration: outerDecoration,
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: pictureUrl,
            width: 88, height: 88,
            fit: BoxFit.cover,
            placeholder: (_, __) => _initialAvatar(initial),
            errorWidget: (_, __, ___) => _initialAvatar(initial),
          ),
        ),
      );
    }
    return Container(
      width: 88, height: 88,
      decoration: outerDecoration,
      child: _initialAvatar(initial),
    );
  }

  Widget _initialAvatar(String initial) => Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _coral.withValues(alpha: 0.25),
          border: Border.all(color: _coral, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w900,
          ),
        ),
      );

  // ── Top bar ───────────────────────────────────────────────

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white70, size: 20),
            onPressed: () {
              if (_searching) _onCancel();
              context.goNamed('home');
            },
          ),
          const Text(
            'Quiz Battle',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF1A1A2E),
              border: Border.all(color: Colors.white12),
            ),
            child: const Icon(Icons.notifications_none_rounded,
                color: Colors.white38, size: 18),
          ),
        ],
      ),
    );
  }

  // ── Main searching UI ─────────────────────────────────────

  Widget _buildSearching({
    required int playersFound,
    required int total,
    required int waitSeconds,
    List<Player> foundPlayers = const [],
    List<Player> waitingPlayers = const [],
  }) {
    final displayCount = waitingPlayers.isNotEmpty ? waitingPlayers.length : playersFound;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),

        // ── Pulse animation ──
        _buildPulseRadar(),

        const SizedBox(height: 40),

        // ── "Finding opponents..." text ──
        Text(
          'Finding opponents',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        )
            .animate(onPlay: (c) => c.repeat())
            .shimmer(duration: 2400.ms, color: _coral.withValues(alpha: 0.4)),

        const SizedBox(height: 8),

        // ── Player count ──
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: '$displayCount',
                style: const TextStyle(
                  color: _coral,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: ' player${displayCount == 1 ? '' : 's'} in lobby',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ── Waiting player avatars ──
        if (waitingPlayers.isNotEmpty)
          _buildWaitingPlayers(waitingPlayers),

        // ── Found player chips (on match found) ──
        if (foundPlayers.isNotEmpty && waitingPlayers.isEmpty)
          _buildPlayerChips(foundPlayers),

        const Spacer(),

        // ── ETA countdown ──
        _buildEta(waitSeconds),

        const SizedBox(height: 32),
      ],
    );
  }

  // ── Pulsing radar ─────────────────────────────────────────

  Widget _buildPulseRadar() {
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer pulse ring 1
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, __) => Transform.scale(
              scale: _pulseScale.value * 1.2,
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _coral.withValues(alpha: _pulseOpacity.value * 0.5),
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),

          // Middle pulse ring 2
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, __) => Transform.scale(
              scale: _pulseScale.value,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _coral.withValues(alpha: _pulseOpacity.value * 0.7),
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),

          // Spinning dashed ring
          AnimatedBuilder(
            animation: _spinController,
            builder: (_, child) => Transform.rotate(
              angle: _spinController.value * 6.28,
              child: child,
            ),
            child: Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _coral.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
            ),
          ),

          // Center icon
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _coral,
              boxShadow: [
                BoxShadow(
                  color: _coral.withValues(alpha: 0.4),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(
              Icons.search_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  // ── Found player chips ────────────────────────────────────

  Widget _buildPlayerChips(List<Player> players) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: players.asMap().entries.map((e) {
          final i = e.key;
          final p = e.value;
          return _PlayerChip(player: p, delay: Duration(milliseconds: i * 120));
        }).toList(),
      ),
    );
  }

  // ── Waiting players (floating avatars) ─────────────────────

  Widget _buildWaitingPlayers(List<Player> players) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 14,
        children: players.asMap().entries.map((e) {
          final i = e.key;
          final p = e.value;
          final isMe = p.userId == _userId;
          return _WaitingPlayerBubble(
            player: p,
            isMe: isMe,
            delay: Duration(milliseconds: i * 100),
          );
        }).toList(),
      ),
    );
  }

  // ── ETA ───────────────────────────────────────────────────

  Widget _buildEta(int waitSeconds) {
    return Text(
      'Estimated wait: ~${waitSeconds}s remaining',
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.4),
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  // ── Cancel button ─────────────────────────────────────────

  Widget _buildCancelButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: _onCancel,
          style: ElevatedButton.styleFrom(
            backgroundColor: _coral,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: const Text(
            'Cancel',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.3, end: 0);
  }

  // ── Error state ───────────────────────────────────────────

  Widget _buildError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off_rounded, color: Colors.white38, size: 48),
            const SizedBox(height: 16),
            Text(
              'Connection failed',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(color: Colors.white38, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// LOBBY HELPER WIDGETS
// ─────────────────────────────────────────

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Chip({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  const _StatTile({required this.icon, required this.color, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _VertDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, color: Colors.white10);
}

// ─────────────────────────────────────────
// PLAYER CHIP WIDGET
// ─────────────────────────────────────────

class _PlayerChip extends StatelessWidget {
  final Player player;
  final Duration delay;

  const _PlayerChip({required this.player, required this.delay});

  // Generate a consistent color from the username initial
  Color get _avatarColor {
    const colors = [
      Color(0xFF0F3460),
      Color(0xFF533483),
      Color(0xFF2D6A4F),
      Color(0xFF7B2D8B),
      Color(0xFF1A4A80),
    ];
    return colors[player.username.codeUnitAt(0) % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Avatar circle
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _avatarColor,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.2),
              width: 2,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            player.username[0].toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          player.username,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    )
        .animate()
        .fadeIn(delay: delay, duration: 350.ms)
        .scale(begin: const Offset(0.6, 0.6), end: const Offset(1, 1), delay: delay);
  }
}

// ─────────────────────────────────────────
// WAITING PLAYER BUBBLE
// ─────────────────────────────────────────

class _WaitingPlayerBubble extends StatelessWidget {
  final Player player;
  final bool isMe;
  final Duration delay;

  const _WaitingPlayerBubble({required this.player, this.isMe = false, required this.delay});

  Color get _avatarColor {
    const colors = [
      Color(0xFF0F3460),
      Color(0xFF533483),
      Color(0xFF2D6A4F),
      Color(0xFF7B2D8B),
      Color(0xFF1A4A80),
    ];
    return colors[player.username.codeUnitAt(0) % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Floating avatar with glow
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _avatarColor,
            border: Border.all(
              color: isMe ? _coral : _coral.withValues(alpha: 0.5),
              width: isMe ? 2.5 : 2,
            ),
            boxShadow: [
              BoxShadow(
                color: _avatarColor.withValues(alpha: 0.4),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            player.username.isNotEmpty
                ? player.username[0].toUpperCase()
                : '?',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Username
        Text(
          isMe ? 'You' : player.username,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isMe ? _coral : Colors.white.withValues(alpha: 0.75),
            fontSize: 11,
            fontWeight: isMe ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
        // Rating
        Text(
          '${player.rating}',
          style: TextStyle(
            color: _coral.withValues(alpha: 0.7),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    )
        .animate()
        .fadeIn(delay: delay, duration: 400.ms)
        .scale(
            begin: const Offset(0.5, 0.5),
            end: const Offset(1, 1),
            delay: delay,
            curve: Curves.elasticOut,
            duration: 600.ms)
        .then(delay: 200.ms)
        .shimmer(duration: 1800.ms, color: _coral.withValues(alpha: 0.15));
  }
}