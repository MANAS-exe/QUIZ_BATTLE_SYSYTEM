import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/game_event.dart';
import '../providers/game_provider.dart';
import '../services/game_service.dart';

// ─────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────

const _coral = Color(0xFFC96442);
const _bg = Color(0xFF0D0D1A);
const _matchmakingTimeout = 30; // seconds before auto-cancel

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
    _userId = 'player-${DateTime.now().millisecondsSinceEpoch % 100000}';
    _setupAnimations();
  }

  void _onStartPressed() {
    setState(() => _searching = true);
    _startCountdown();
    _joinMatchmaking();
  }

  void _joinMatchmaking() {
    ref.read(gameProvider.notifier).setUser(_userId, 'Player');
    ref.read(gameServiceProvider).joinMatchmaking(_userId, 1000);
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
    ref.read(gameServiceProvider).leaveMatchmaking(_userId);
    ref.read(gameProvider.notifier).cancelMatchmaking();
    if (mounted) context.pop();
  }

  void _onMatchFound(MatchmakingUpdate update) {
    _countdownTimer?.cancel();
    ref.read(gameProvider.notifier).setUser(_userId, 'You');
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
                ),
              ),
            ),
            _buildCancelButton(),
          ],
        ),
      ),
    );
  }

  // ── Lobby (pre-matchmaking) ───────────────────────────────

  Widget _buildLobby() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),

        // Icon
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _coral.withValues(alpha: 0.15),
            border: Border.all(color: _coral.withValues(alpha: 0.3), width: 2),
          ),
          child: const Icon(
            Icons.sports_esports_rounded,
            color: _coral,
            size: 48,
          ),
        ),

        const SizedBox(height: 32),

        const Text(
          'Ready to battle?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),

        const SizedBox(height: 12),

        Text(
          'Press Start when you\'re ready to\nfind an opponent',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),

        const SizedBox(height: 12),

        // Show userId so the user knows which player they are
        Text(
          _userId,
          style: TextStyle(
            color: _coral.withValues(alpha: 0.7),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),

        const Spacer(),

        // Start button
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _onStartPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: _coral,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                'Start Matchmaking',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.2, end: 0),
      ],
    );
  }

  // ── Top bar ───────────────────────────────────────────────

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54),
            onPressed: _onCancel,
          ),
          const Expanded(
            child: Text(
              'Quiz Battle',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          // Spacer to balance the close button
          const SizedBox(width: 48),
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
  }) {
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
                text: '$playersFound',
                style: const TextStyle(
                  color: _coral,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: '/$total players found',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        )
            .animate()
            .fadeIn(duration: 300.ms)
            .slideY(begin: 0.2, end: 0),

        const SizedBox(height: 32),

        // ── Found player chips ──
        if (foundPlayers.isNotEmpty)
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