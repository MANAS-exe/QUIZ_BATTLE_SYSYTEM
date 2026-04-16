import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/auth_service.dart';
import '../theme/colors.dart';

// ─────────────────────────────────────────
// PROFILE SCREEN
// ─────────────────────────────────────────

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: appBg,
      body: NestedScrollView(
        headerSliverBuilder: (_, __) => [
          SliverAppBar(
            pinned: true,
            expandedHeight: 260,
            backgroundColor: appBg,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white70, size: 20),
              onPressed: () => context.pop(),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.lock_reset_rounded, color: Colors.white70, size: 22),
                tooltip: 'Change Password',
                onPressed: () => _showChangePasswordDialog(context, ref),
              ),
              IconButton(
                icon: const Icon(Icons.logout_rounded, color: Colors.white70, size: 22),
                tooltip: 'Logout',
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: const Color(0xFF1A1A2E),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: const Text('Logout', style: TextStyle(color: Colors.white)),
                      content: const Text('Are you sure you want to logout?',
                          style: TextStyle(color: Colors.white70)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: Text('Logout', style: TextStyle(color: appCoral)),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true && context.mounted) {
                    await ref.read(authProvider.notifier).logout();
                    if (context.mounted) context.go('/login');
                  }
                },
              ),
              const SizedBox(width: 4),
            ],
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.pin,
              background: _ProfileHeader(auth: auth),
            ),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Container(
                color: appBg,
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: appCoral,
                  indicatorWeight: 2.5,
                  indicatorSize: TabBarIndicatorSize.label,
                  labelColor: appCoral,
                  unselectedLabelColor: Colors.white38,
                  labelStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1),
                  tabs: const [
                    Tab(text: 'PROFILE'),
                    Tab(text: 'LAST MATCH'),
                    Tab(text: 'BADGES'),
                    Tab(text: 'STREAK'),
                    Tab(text: 'REFERRAL'),
                  ],
                ),
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            _ProfileTab(auth: auth),
            _LastMatchTab(auth: auth),
            _BadgesTab(auth: auth),
            _StreakTab(auth: auth),
            _ReferralTab(auth: auth),
          ],
        ),
      ),
    );
  }

  Future<void> _showChangePasswordDialog(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Change Password', style: TextStyle(color: Colors.white)),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: ctrl,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'New Password',
                    labelStyle: const TextStyle(color: Colors.white54),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: appCoral),
                    ),
                    errorText: error,
                  ),
                  validator: (v) => (v == null || v.length < 4)
                      ? 'Minimum 4 characters'
                      : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                final err = await ref
                    .read(authProvider.notifier)
                    .changePassword(ctrl.text.trim());
                if (err == null) {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Password updated successfully'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } else {
                  setState(() => error = err);
                }
              },
              child: Text('Update', style: TextStyle(color: appCoral)),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
  }
}

// ─────────────────────────────────────────
// HEADER
// ─────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  final AuthState auth;
  const _ProfileHeader({required this.auth});

  @override
  Widget build(BuildContext context) {
    final username = auth.username ?? 'Player';
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    final winRate = auth.matchesPlayed > 0
        ? (auth.matchesWon / auth.matchesPlayed * 100).round()
        : 0;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D0D1A), Color(0xFF1A0B08), Color(0xFF2B1208)],
        ),
      ),
      child: Stack(
        children: [
          // Decorative background rings
          Positioned(
            top: -50,
            right: -50,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: appCoral.withValues(alpha: 0.06),
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            left: -30,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: appCoral.withValues(alpha: 0.04),
              ),
            ),
          ),
          // Content
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 56, 20, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Avatar
                  _buildAvatar(auth.pictureUrl, initial)
                      .animate()
                      .fadeIn(duration: 400.ms)
                      .scale(
                          begin: const Offset(0.7, 0.7),
                          end: const Offset(1, 1),
                          curve: Curves.elasticOut,
                          duration: 700.ms),

                  const SizedBox(width: 18),

                  // Name + info column
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Name + online dot
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                username,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFF2ECC71),
                                boxShadow: [
                                  BoxShadow(
                                    color: Color(0x662ECC71),
                                    blurRadius: 6,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        // Rating
                        Row(
                          children: [
                            const Icon(Icons.star_rounded,
                                color: appGold, size: 15),
                            const SizedBox(width: 4),
                            Text(
                              '${auth.rating} Rating',
                              style: const TextStyle(
                                color: appGold,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Chips row
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _MiniChip(
                              icon: Icons.sports_esports_rounded,
                              label: '${auth.matchesPlayed} played',
                            ),
                            _MiniChip(
                              icon: Icons.emoji_events_rounded,
                              label: '$winRate% win rate',
                              color: appGold,
                            ),
                          ],
                        ),
                      ],
                    ).animate().fadeIn(delay: 150.ms, duration: 400.ms),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(String? pictureUrl, String initial) {
    final decoration = BoxDecoration(
      shape: BoxShape.circle,
      color: appCoral.withValues(alpha: 0.18),
      border: Border.all(color: appCoral, width: 2.5),
      boxShadow: [
        BoxShadow(
          color: appCoral.withValues(alpha: 0.35),
          blurRadius: 24,
          spreadRadius: 2,
        ),
      ],
    );

    if (pictureUrl != null && pictureUrl.isNotEmpty) {
      return Container(
        width: 88,
        height: 88,
        decoration: decoration,
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: pictureUrl,
            width: 88,
            height: 88,
            fit: BoxFit.cover,
            placeholder: (_, __) => _initialCircle(initial),
            errorWidget: (_, __, ___) => _initialCircle(initial),
          ),
        ),
      );
    }
    return Container(
      width: 88,
      height: 88,
      decoration: decoration,
      alignment: Alignment.center,
      child: _initialCircle(initial),
    );
  }

  Widget _initialCircle(String initial) => Center(
        child: Text(
          initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 36,
            fontWeight: FontWeight.w900,
          ),
        ),
      );
}

// ─────────────────────────────────────────
// TAB 1 — PROFILE
// ─────────────────────────────────────────

class _ProfileTab extends StatelessWidget {
  final AuthState auth;
  const _ProfileTab({required this.auth});

  @override
  Widget build(BuildContext context) {
    final losses = auth.matchesPlayed - auth.matchesWon;
    final winRate = auth.matchesPlayed > 0
        ? (auth.matchesWon / auth.matchesPlayed * 100).round()
        : 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        // ── Rating card ───────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                appCoral.withValues(alpha: 0.22),
                appCoral.withValues(alpha: 0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: appCoral.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              const Icon(Icons.star_rounded, color: appGold, size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${auth.rating}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Text(
                      'Current Rating',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Level badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: appGold.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: appGold.withValues(alpha: 0.4)),
                ),
                child: Text(
                  _levelLabel(auth.rating),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    color: appGold,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.1, end: 0),

        const SizedBox(height: 20),

        // ── Match stats ───────────────────────────────────────────
        _SectionLabel('Match Stats'),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
                child: _StatCard(
                    icon: Icons.sports_esports_rounded,
                    iconColor: appCoral,
                    value: '${auth.matchesPlayed}',
                    label: 'Played',
                    delay: 100.ms)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    icon: Icons.emoji_events_rounded,
                    iconColor: appGreen,
                    value: '${auth.matchesWon}',
                    label: 'Won',
                    delay: 150.ms)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    icon: Icons.close_rounded,
                    iconColor: appRed,
                    value: '$losses',
                    label: 'Lost',
                    delay: 200.ms)),
          ],
        ),

        const SizedBox(height: 12),

        // Win rate bar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: appSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Win Rate',
                      style:
                          TextStyle(color: Colors.white60, fontSize: 12)),
                  Text('$winRate%',
                      style: TextStyle(
                          color: winRate >= 60
                              ? appGreen
                              : winRate >= 40
                                  ? appGold
                                  : appRed,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: winRate / 100.0,
                  backgroundColor: Colors.white10,
                  color: winRate >= 60
                      ? appGreen
                      : winRate >= 40
                          ? appGold
                          : appRed,
                  minHeight: 7,
                ),
              ),
            ],
          ),
        ).animate().fadeIn(delay: 250.ms, duration: 350.ms),

        const SizedBox(height: 20),

        // ── Streak stats ──────────────────────────────────────────
        _SectionLabel('Streaks'),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
                child: _StatCard(
                    icon: Icons.local_fire_department_rounded,
                    iconColor: appRed,
                    value: '${auth.currentStreak}',
                    label: 'Daily Streak',
                    delay: 300.ms)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    icon: Icons.whatshot_rounded,
                    iconColor: appGold,
                    value: '${auth.maxStreak}',
                    label: 'Max Day Streak',
                    delay: 350.ms)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    icon: Icons.bolt_rounded,
                    iconColor: appCoral,
                    value: '${auth.maxQuestionStreak}',
                    label: 'Best Answer Streak',
                    delay: 400.ms)),
          ],
        ),
      ],
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
}

// ─────────────────────────────────────────
// TAB 2 — LAST MATCH (history)
// ─────────────────────────────────────────

class _LastMatchTab extends StatelessWidget {
  final AuthState auth;
  const _LastMatchTab({required this.auth});

  @override
  Widget build(BuildContext context) {
    final history = auth.matchHistory;
    // Premium users see up to 3 past matches; free users see only the latest.
    final limit = auth.isEffectivelyPremium ? 3 : 1;
    final matches = history.take(limit).toList();

    if (matches.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sports_esports_outlined,
                color: Colors.white12, size: 64),
            const SizedBox(height: 16),
            const Text(
              'No matches played yet',
              style: TextStyle(color: Colors.white38, fontSize: 15),
            ),
            const SizedBox(height: 6),
            const Text(
              'Play your first match to see stats here',
              style: TextStyle(color: Colors.white24, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      itemCount: matches.length + (history.length > limit ? 1 : 0),
      itemBuilder: (_, i) {
        // Upgrade upsell row at the bottom for free users with more history
        if (i == matches.length) {
          return _UpgradeBanner(hiddenCount: history.length - limit);
        }
        final lm = matches[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (matches.length > 1) ...[
              _SectionLabel(i == 0 ? 'MOST RECENT' : 'MATCH ${i + 1}'),
              const SizedBox(height: 8),
            ],
            _MatchHistoryCard(lm: lm, index: i),
            if (i < matches.length - 1) const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

// ── Single match card ──────────────────────────────────────────────────────

class _MatchHistoryCard extends StatelessWidget {
  final LastMatchData lm;
  final int index;
  const _MatchHistoryCard({required this.lm, required this.index});

  @override
  Widget build(BuildContext context) {
    final accuracy = lm.totalRounds > 0
        ? (lm.answersCorrect / lm.totalRounds * 100).round()
        : 0;
    final acColor =
        accuracy >= 80 ? appGreen : accuracy >= 50 ? appGold : appRed;
    final delay = Duration(milliseconds: 60 * index);

    // Determine result state
    final isNoWinner = lm.winnerUsername.isEmpty;
    final resultColor = isNoWinner
        ? Colors.white38
        : lm.won
            ? appGold
            : appCoral;
    final resultIcon = isNoWinner
        ? Icons.block_rounded
        : lm.won
            ? Icons.emoji_events_rounded
            : Icons.flag_rounded;
    final resultTitle =
        isNoWinner ? 'No winner' : (lm.won ? 'Victory' : 'Defeat');
    final resultSubtitle = isNoWinner
        ? 'Nobody answered correctly'
        : lm.won
            ? 'You won this match!'
            : 'Winner: ${lm.winnerUsername}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Win / Loss / No-winner banner ──────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                resultColor.withValues(alpha: 0.18),
                resultColor.withValues(alpha: 0.06),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: resultColor.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Icon(resultIcon, color: resultColor, size: 40),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resultTitle,
                    style: TextStyle(
                      color: resultColor,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    resultSubtitle,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _rankColor(lm.rank).withValues(alpha: 0.15),
                  border: Border.all(
                      color: _rankColor(lm.rank).withValues(alpha: 0.5),
                      width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  '#${lm.rank}',
                  style: TextStyle(
                    color: _rankColor(lm.rank),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ).animate().fadeIn(delay: delay, duration: 350.ms),

        const SizedBox(height: 16),

        // ── Key stats grid ─────────────────────────────────────────
        Row(
          children: [
            Expanded(
                child: _StatCard(
                    icon: Icons.bolt_rounded,
                    iconColor: appGold,
                    value: '${lm.score}',
                    label: 'Score',
                    delay: delay + 60.ms)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    icon: Icons.check_circle_rounded,
                    iconColor: appGreen,
                    value: '${lm.answersCorrect}/${lm.totalRounds}',
                    label: 'Correct',
                    delay: delay + 100.ms)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    icon: Icons.local_fire_department_rounded,
                    iconColor: appRed,
                    value: '${lm.maxStreak}',
                    label: 'Best Streak',
                    delay: delay + 140.ms)),
          ],
        ),

        const SizedBox(height: 12),

        // Accuracy bar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: appSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Accuracy',
                      style:
                          TextStyle(color: Colors.white60, fontSize: 12)),
                  Text('$accuracy%',
                      style: TextStyle(
                          color: acColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: accuracy / 100.0,
                  backgroundColor: Colors.white10,
                  color: acColor,
                  minHeight: 7,
                ),
              ),
            ],
          ),
        ).animate().fadeIn(delay: delay + 180.ms),

        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
                child: _StatCard(
                    icon: Icons.speed_rounded,
                    iconColor: appGold,
                    value:
                        '${(lm.avgResponseMs / 1000).toStringAsFixed(1)}s',
                    label: 'Avg Response',
                    delay: delay + 220.ms)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    icon: Icons.timer_rounded,
                    iconColor: Colors.white54,
                    value: _fmtDuration(lm.durationSeconds),
                    label: 'Duration',
                    delay: delay + 260.ms)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    icon: Icons.quiz_rounded,
                    iconColor: appCoral,
                    value: '${lm.totalRounds}',
                    label: 'Rounds',
                    delay: delay + 300.ms)),
          ],
        ),
      ],
    );
  }

  Color _rankColor(int rank) {
    if (rank == 1) return appGold;
    if (rank == 2) return appSilver;
    if (rank == 3) return appBronze;
    return Colors.white38;
  }

  String _fmtDuration(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return m > 0 ? '${m}m ${sec}s' : '${s}s';
  }
}

// ── Upgrade banner (shown to free users with hidden matches) ───────────────

class _UpgradeBanner extends StatelessWidget {
  final int hiddenCount;
  const _UpgradeBanner({required this.hiddenCount});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            appCoral.withValues(alpha: 0.18),
            appCoral.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: appCoral.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_rounded, color: appCoral, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$hiddenCount more match${hiddenCount > 1 ? 'es' : ''} hidden',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Upgrade to Premium to see your full match history',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 200.ms, duration: 350.ms);
  }
}

// ─────────────────────────────────────────
// TAB 3 — BADGES
// ─────────────────────────────────────────

class _BadgesTab extends StatelessWidget {
  final AuthState auth;
  const _BadgesTab({required this.auth});

  @override
  Widget build(BuildContext context) {
    final badges = _buildBadges(auth);

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 0.8,
      ),
      itemCount: badges.length,
      itemBuilder: (_, i) => _BadgeTile(badge: badges[i],
          delay: Duration(milliseconds: 60 + i * 50)),
    );
  }

  List<_Badge> _buildBadges(AuthState auth) => [
        _Badge(
          icon: Icons.sports_esports_rounded,
          label: 'First Battle',
          description: 'Play your first match',
          unlocked: auth.matchesPlayed >= 1,
          color: appCoral,
        ),
        _Badge(
          icon: Icons.emoji_events_rounded,
          label: 'First Win',
          description: 'Win your first match',
          unlocked: auth.matchesWon >= 1,
          color: appGold,
        ),
        _Badge(
          icon: Icons.local_fire_department_rounded,
          label: 'On Fire',
          description: '3-day login streak',
          unlocked: auth.currentStreak >= 3,
          color: appRed,
        ),
        _Badge(
          icon: Icons.bolt_rounded,
          label: 'Quick Thinker',
          description: '3 correct in a row',
          unlocked: auth.maxQuestionStreak >= 3,
          color: appGold,
        ),
        _Badge(
          icon: Icons.whatshot_rounded,
          label: 'Unstoppable',
          description: '5 correct in a row',
          unlocked: auth.maxQuestionStreak >= 5,
          color: appRed,
        ),
        _Badge(
          icon: Icons.star_rounded,
          label: 'Veteran',
          description: 'Play 10 matches',
          unlocked: auth.matchesPlayed >= 10,
          color: appGold,
        ),
        _Badge(
          icon: Icons.military_tech_rounded,
          label: 'Champion',
          description: 'Win 5 matches',
          unlocked: auth.matchesWon >= 5,
          color: appGold,
        ),
        _Badge(
          icon: Icons.diamond_rounded,
          label: 'Legend',
          description: 'Reach 2000 rating',
          unlocked: auth.rating >= 2000,
          color: Colors.cyanAccent,
        ),
        _Badge(
          icon: Icons.calendar_today_rounded,
          label: 'Dedicated',
          description: '7-day login streak',
          unlocked: auth.maxStreak >= 7,
          color: appGreen,
        ),
        _Badge(
          icon: Icons.local_fire_department_rounded,
          label: 'Week Warrior',
          description: '7-day streak reward',
          unlocked: auth.maxStreak >= 7,
          color: const Color(0xFFFF6B35),
        ),
        _Badge(
          icon: Icons.whatshot_rounded,
          label: 'Fortnight Fighter',
          description: '14-day streak reward',
          unlocked: auth.maxStreak >= 14,
          color: appCoral,
        ),
        _Badge(
          icon: Icons.auto_awesome_rounded,
          label: 'Monthly Master',
          description: '30-day streak reward',
          unlocked: auth.maxStreak >= 30,
          color: appGold,
        ),
      ];
}

class _Badge {
  final IconData icon;
  final String label;
  final String description;
  final bool unlocked;
  final Color color;

  const _Badge({
    required this.icon,
    required this.label,
    required this.description,
    required this.unlocked,
    required this.color,
  });
}

class _BadgeTile extends StatelessWidget {
  final _Badge badge;
  final Duration delay;

  const _BadgeTile({required this.badge, required this.delay});

  @override
  Widget build(BuildContext context) {
    final color = badge.unlocked ? badge.color : Colors.white12;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: badge.unlocked
              ? badge.color.withValues(alpha: 0.4)
              : Colors.white10,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: badge.unlocked ? 0.15 : 0.05),
              border: Border.all(
                  color: color.withValues(alpha: badge.unlocked ? 0.4 : 0.15)),
            ),
            alignment: Alignment.center,
            child: Icon(badge.icon,
                color: color, size: 26),
          ),
          const SizedBox(height: 8),
          Text(
            badge.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: badge.unlocked ? Colors.white : Colors.white30,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            badge.unlocked ? '✓ Unlocked' : badge.description,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: badge.unlocked
                  ? badge.color.withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.2),
              fontSize: 9,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    )
        .animate()
        .fadeIn(delay: delay, duration: 300.ms)
        .scale(
            begin: const Offset(0.85, 0.85),
            end: const Offset(1, 1),
            delay: delay,
            duration: 300.ms);
  }
}

// ─────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      );
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;
  final Duration delay;

  const _StatCard({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
    required this.delay,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Icon(icon, color: iconColor, size: 22),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    ).animate().fadeIn(delay: delay, duration: 300.ms).slideY(
        begin: 0.1, end: 0, delay: delay, duration: 300.ms);
  }
}

// ─────────────────────────────────────────
// TAB 4 — STREAK CALENDAR
// ─────────────────────────────────────────

class _StreakTab extends StatelessWidget {
  final AuthState auth;
  const _StreakTab({required this.auth});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        _StreakSummaryCard(auth: auth),
        const SizedBox(height: 20),
        _CoinsCard(coins: auth.coins, bonusGames: auth.bonusGamesRemaining),
        const SizedBox(height: 20),
        _LoginCalendar(loginHistory: auth.loginHistory),
      ],
    );
  }
}

// ── Streak summary ─────────────────────────────────────────────────────────

class _StreakSummaryCard extends StatelessWidget {
  final AuthState auth;
  const _StreakSummaryCard({required this.auth});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFFF6B35).withValues(alpha: 0.18),
            appSurface,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFF6B35).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFF6B35).withValues(alpha: 0.15),
            ),
            child: const Icon(
              Icons.local_fire_department_rounded,
              color: Color(0xFFFF6B35),
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${auth.currentStreak}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'day streak',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Best: ${auth.maxStreak} days',
                  style: TextStyle(
                    color: const Color(0xFFFF6B35).withValues(alpha: 0.8),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.1, end: 0);
  }
}

// ── Coins card ─────────────────────────────────────────────────────────────

class _CoinsCard extends StatelessWidget {
  final int coins;
  final int bonusGames;
  const _CoinsCard({required this.coins, required this.bonusGames});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: appGold.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.monetization_on_rounded, color: appGold, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$coins coins',
                  style: const TextStyle(
                    color: appGold,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  'Earned from daily login rewards',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (bonusGames > 0) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: appCoral.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: appCoral.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.sports_esports_rounded,
                      color: appCoral, size: 16),
                  const SizedBox(height: 2),
                  Text(
                    '+$bonusGames',
                    style: const TextStyle(
                      color: appCoral,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'bonus',
                    style: TextStyle(
                      color: appCoral.withValues(alpha: 0.7),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn(delay: 100.ms, duration: 350.ms);
  }
}

// ── 30-day login calendar ──────────────────────────────────────────────────

class _LoginCalendar extends StatelessWidget {
  final List<String> loginHistory;
  const _LoginCalendar({required this.loginHistory});

  @override
  Widget build(BuildContext context) {
    final historySet = loginHistory.toSet();
    final today = DateTime.now();
    final todayStr = today.toIso8601String().substring(0, 10);

    // Build list of the last 30 days, oldest first
    final days = List.generate(30, (i) {
      final d = today.subtract(Duration(days: 29 - i));
      return d.toIso8601String().substring(0, 10);
    });

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month_rounded,
                  color: Colors.white54, size: 16),
              const SizedBox(width: 8),
              const Text(
                'LAST 30 DAYS',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 7-column grid
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
              childAspectRatio: 1,
            ),
            itemCount: days.length,
            itemBuilder: (_, i) {
              final dateStr = days[i];
              final isToday = dateStr == todayStr;
              final loggedIn = historySet.contains(dateStr);
              return _CalendarCell(
                isToday: isToday,
                loggedIn: loggedIn,
                dayNumber: int.parse(dateStr.substring(8)),
              );
            },
          ),

          const SizedBox(height: 12),

          // Legend
          Row(
            children: [
              _LegendDot(color: appGreen, label: 'Logged in'),
              const SizedBox(width: 16),
              _LegendDot(
                  color: Colors.white24, label: 'Missed', filled: false),
              const SizedBox(width: 16),
              _LegendDot(color: appGold, label: 'Today', border: true),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(delay: 200.ms, duration: 350.ms);
  }
}

class _CalendarCell extends StatelessWidget {
  final bool isToday;
  final bool loggedIn;
  final int dayNumber;
  const _CalendarCell({
    required this.isToday,
    required this.loggedIn,
    required this.dayNumber,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color border;
    Color textColor;

    if (loggedIn) {
      bg = appGreen.withValues(alpha: 0.25);
      border = isToday ? appGold : appGreen.withValues(alpha: 0.5);
      textColor = Colors.white;
    } else {
      bg = Colors.transparent;
      border = isToday ? appGold : Colors.white10;
      textColor = isToday ? appGold : Colors.white24;
    }

    return Container(
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: isToday ? 1.5 : 1),
      ),
      alignment: Alignment.center,
      child: Text(
        '$dayNumber',
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool filled;
  final bool border;

  const _LegendDot({
    required this.color,
    required this.label,
    this.filled = true,
    this.border = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color.withValues(alpha: 0.4) : Colors.transparent,
            border: Border.all(
                color: border ? color : color.withValues(alpha: 0.5)),
          ),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4), fontSize: 10)),
      ],
    );
  }
}

// ─────────────────────────────────────────
// TAB 5 — REFERRAL
// ─────────────────────────────────────────
//
// Shows the user's own referral code, referral stats, pending rewards,
// an optional "Apply a code" section (for accounts ≤7 days old that haven't
// been referred), and how to share.

class _ReferralTab extends ConsumerStatefulWidget {
  final AuthState auth;
  const _ReferralTab({required this.auth});

  @override
  ConsumerState<_ReferralTab> createState() => _ReferralTabState();
}

class _ReferralTabState extends ConsumerState<_ReferralTab> {
  final _applyCtrl = TextEditingController();
  bool _applyLoading = false;
  bool _claimLoading = false;
  String? _applyError;
  String? _applySuccess;

  @override
  void initState() {
    super.initState();
    // Sync on every tab open — catches rewards from users who applied our code
    // since the last login (referrer would otherwise see stale data).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(authProvider.notifier).refreshReferralData();
      }
    });
  }

  @override
  void dispose() {
    _applyCtrl.dispose();
    super.dispose();
  }

  Future<void> _onCopy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Code $code copied to clipboard!'),
        backgroundColor: appSurface,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _onClaim() async {
    setState(() { _claimLoading = true; });
    final err = await ref.read(authProvider.notifier).claimReferralRewards();
    if (!mounted) return;
    setState(() { _claimLoading = false; });
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: appRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rewards claimed! Check your coins and bonus games.'),
          backgroundColor: Color(0xFF2ECC71),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _onApply() async {
    final code = _applyCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _applyError = 'Enter a referral code first');
      return;
    }
    setState(() { _applyLoading = true; _applyError = null; _applySuccess = null; });
    final err =
        await ref.read(authProvider.notifier).applyReferralCode(code);
    if (!mounted) return;
    if (err != null) {
      setState(() { _applyLoading = false; _applyError = err; });
    } else {
      setState(() {
        _applyLoading = false;
        _applySuccess =
            'Code applied! Your rewards are waiting — tap Claim to collect.';
        _applyCtrl.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch auth so the tab rebuilds when claimReferralRewards() updates state.
    final auth = ref.watch(authProvider);
    final code = auth.referralCode;

    return RefreshIndicator(
      color: appCoral,
      backgroundColor: appSurface,
      onRefresh: () => ref.read(authProvider.notifier).refreshReferralData(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
        // ── Your referral code ─────────────────────────────────────
        _SectionLabel('YOUR REFERRAL CODE'),
        const SizedBox(height: 12),
        _ReferralCodeCard(
          code: code,
          onCopy: code != null ? () => _onCopy(code) : null,
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.1, end: 0),

        const SizedBox(height: 8),

        // Share instructions
        Text(
          'Share this code with friends. When they register and enter your code,'
          ' you both earn rewards.',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4), fontSize: 12, height: 1.5),
        ).animate().fadeIn(delay: 100.ms, duration: 350.ms),

        const SizedBox(height: 24),

        // ── Stats ──────────────────────────────────────────────────
        _SectionLabel('REFERRAL STATS'),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.group_add_rounded,
                iconColor: appCoral,
                value: '${auth.referralCount}',
                label: 'Friends Invited',
                delay: 150.ms,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.monetization_on_rounded,
                iconColor: appGold,
                value: '${auth.totalReferralCoins}',
                label: 'Coins Earned',
                delay: 200.ms,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.people_rounded,
                iconColor: Colors.white54,
                value: '${10 - auth.referralCount.clamp(0, 10)}',
                label: 'Slots Left',
                delay: 250.ms,
              ),
            ),
          ],
        ),

        const SizedBox(height: 24),

        // ── Pending rewards ────────────────────────────────────────
        if (auth.hasPendingReferralReward) ...[
          _SectionLabel('PENDING REWARDS'),
          const SizedBox(height: 12),
          _PendingRewardCard(
            loading: _claimLoading,
            onClaim: _onClaim,
          ).animate().fadeIn(delay: 200.ms, duration: 350.ms),
          const SizedBox(height: 24),
        ],

        // ── Apply a referral code ──────────────────────────────────
        // Only show this section if the user has NOT yet been referred.
        // Already-referred users have no need for this input.
        if (!auth.hasPendingReferralReward ||
            auth.referralCode == null) ...[
          _SectionLabel('HAVE A REFERRAL CODE?'),
          const SizedBox(height: 12),
          _ApplyCodeSection(
            controller: _applyCtrl,
            loading: _applyLoading,
            error: _applyError,
            success: _applySuccess,
            onApply: _onApply,
          ).animate().fadeIn(delay: 300.ms, duration: 350.ms),
          const SizedBox(height: 24),
        ],

        // ── How it works ───────────────────────────────────────────
        _SectionLabel('HOW IT WORKS'),
        const SizedBox(height: 12),
        _HowItWorksCard()
            .animate()
            .fadeIn(delay: 350.ms, duration: 350.ms),
      ],
    ),
    );
  }
}

// ── Referral code card ─────────────────────────────────────────────────────

class _ReferralCodeCard extends StatelessWidget {
  final String? code;
  final VoidCallback? onCopy;
  const _ReferralCodeCard({required this.code, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            appCoral.withValues(alpha: 0.22),
            appCoral.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: appCoral.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.card_giftcard_rounded, color: appCoral, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: code != null
                ? Text(
                    code!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                    ),
                  )
                : Text(
                    'Loading...',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 18),
                  ),
          ),
          if (onCopy != null)
            IconButton(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded, color: appCoral, size: 22),
              tooltip: 'Copy code',
            ),
        ],
      ),
    );
  }
}

// ── Pending reward card ────────────────────────────────────────────────────

class _PendingRewardCard extends StatelessWidget {
  final bool loading;
  final VoidCallback onClaim;
  const _PendingRewardCard({required this.loading, required this.onClaim});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            appGold.withValues(alpha: 0.18),
            appGold.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: appGold.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: appGold.withValues(alpha: 0.15),
            ),
            child: const Icon(Icons.redeem_rounded, color: appGold, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Rewards ready to claim!',
                  style: TextStyle(
                    color: appGold,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Coins + bonus games are waiting for you.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: loading ? null : onClaim,
            style: ElevatedButton.styleFrom(
              backgroundColor: appGold,
              foregroundColor: Colors.black,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.black, strokeWidth: 2),
                  )
                : const Text('Claim',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

// ── Apply code section ─────────────────────────────────────────────────────

class _ApplyCodeSection extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final String? error;
  final String? success;
  final VoidCallback onApply;

  const _ApplyCodeSection({
    required this.controller,
    required this.loading,
    required this.error,
    required this.success,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'If a friend gave you their code, enter it here to earn bonus rewards.',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
                height: 1.5),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 6,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4,
                  ),
                  decoration: InputDecoration(
                    hintText: 'XXXXXX',
                    hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.2),
                        letterSpacing: 4),
                    counterText: '',
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: appCoral, width: 1.5),
                    ),
                  ),
                  onSubmitted: (_) => onApply(),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: loading ? null : onApply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: appCoral,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Text('Apply',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!,
                style: const TextStyle(color: appRed, fontSize: 12))
                .animate()
                .shakeX(hz: 3, amount: 4),
          ],
          if (success != null) ...[
            const SizedBox(height: 8),
            Text(success!,
                style: const TextStyle(
                    color: Color(0xFF2ECC71), fontSize: 12))
                .animate()
                .fadeIn(duration: 200.ms),
          ],
        ],
      ),
    );
  }
}

// ── How it works card ──────────────────────────────────────────────────────

class _HowItWorksCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const steps = [
      _HowStep(
        icon: Icons.share_rounded,
        title: 'Share your code',
        subtitle: 'Send your 6-letter code to a friend who doesn\'t have the app yet.',
      ),
      _HowStep(
        icon: Icons.person_add_rounded,
        title: 'Friend registers',
        subtitle: 'They enter your code during registration (within 7 days of signing up).',
      ),
      _HowStep(
        icon: Icons.redeem_rounded,
        title: 'Both earn rewards',
        subtitle: 'You get +200 coins & +2 bonus games. They get +100 coins & +1 bonus game.',
      ),
      _HowStep(
        icon: Icons.info_outline_rounded,
        title: 'Limits',
        subtitle: 'Max 10 successful referrals per account. Each user can apply one code.',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: steps
            .map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: appCoral.withValues(alpha: 0.12),
                        ),
                        alignment: Alignment.center,
                        child: Icon(s.icon, color: appCoral, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.title,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(s.subtitle,
                                style: TextStyle(
                                    color:
                                        Colors.white.withValues(alpha: 0.45),
                                    fontSize: 11,
                                    height: 1.4)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _HowStep {
  final IconData icon;
  final String title;
  final String subtitle;
  const _HowStep(
      {required this.icon, required this.title, required this.subtitle});
}

// ─────────────────────────────────────────

class _MiniChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MiniChip({
    required this.icon,
    required this.label,
    this.color = appCoral,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 11),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
