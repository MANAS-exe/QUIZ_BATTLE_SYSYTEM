import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/auth_service.dart' show AuthState, AuthNotifier, DailyReward, authProvider, kFreeQuotaPerDay;
import '../theme/colors.dart';
import 'global_leaderboard_screen.dart' show globalLeaderboardProvider;

// ─────────────────────────────────────────
// HOME SCREEN
// ─────────────────────────────────────────
//
// PURPOSE:
//   The primary landing screen after login. It surfaces everything a player
//   needs at a glance — who they are, how many games they have left today,
//   their streak, and the most important action: Play.
//
// WHY this exists (instead of going straight to matchmaking):
//   A "jump straight to queue" UX works for die-hard players, but research on
//   mobile games shows that 60–70% of daily-active users open the app to check
//   their stats or progress, not necessarily to play immediately. The home screen
//   gives them a reason to engage every day even on non-play days (streak, quota).
//
// SECTIONS:
//   1. Profile card     — avatar (Google or initials), username, rating, tier badge
//   2. Daily quota pill — shows X / 5 remaining (or ∞ for premium)
//   3. Play CTA         — full-width; disabled + upsell if free quota exhausted
//   4. Quick stats      — streak, matches played, win rate
//   5. Premium card     — shown to free users only; tap to upgrade (togglePremium for demo)
//   6. Bottom nav       — Home · Play · Leaderboard · Profile (persistent shell)
//
// REAL-WORLD EXAMPLE:
//   A user opens the app in the morning. They see they've played 3/5 games today,
//   their win streak is 7 days, and their rating is 1 240. They tap Play → routed
//   to matchmaking. After 2 more games (now 5/5), the Play button dims and shows
//   "Upgrade for unlimited". The next day the counter resets automatically.
//
// STATE:
//   All state comes from [authProvider] (Riverpod StateNotifierProvider).
//   No local state — the screen is a pure projection of AuthState.

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Show the daily reward popup after the first frame so the dialog has a
    // valid BuildContext and the widget tree is fully mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reward = ref.read(authProvider).pendingReward;
      if (reward != null) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _DailyRewardDialog(reward: reward),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    // Block the device back button / swipe-back gesture on the home screen.
    // Home is the root authenticated screen — popping it would land on /login,
    // which immediately redirects back to /home, causing a crash loop.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: appBg,
        body: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _TopBar(auth: auth),
                      const SizedBox(height: 24),
                      _ProfileCard(auth: auth),
                      const SizedBox(height: 20),
                      _DailyQuotaCard(auth: auth),
                      const SizedBox(height: 20),
                      _PlayButton(auth: auth),
                      const SizedBox(height: 20),
                      _QuickStats(auth: auth),
                      const SizedBox(height: 20),
                      if (!auth.isEffectivelyPremium) ...[
                        _PremiumUpsellCard(auth: auth),
                        const SizedBox(height: 20),
                      ],
                      // Tournament card — premium feature teaser
                      GestureDetector(
                        onTap: () => context.pushNamed('tournaments'),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [const Color(0xFF1A1A2E), appCoral.withValues(alpha: 0.1)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: appCoral.withValues(alpha: 0.25)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 44, height: 44,
                                decoration: BoxDecoration(
                                  color: appCoral.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.emoji_events_rounded, color: appCoral, size: 24),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Tournaments',
                                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 2),
                                    Text(auth.isEffectivelyPremium
                                        ? 'Weekly & special events available'
                                        : 'Go Premium to compete',
                                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded, color: Colors.white24, size: 22),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _StreakCard(auth: auth),
                      const SizedBox(height: 20),
                      if (auth.referralCode != null) ...[
                        _ReferralShareCard(auth: auth),
                        const SizedBox(height: 20),
                      ],
                      _LeaderboardPreview(auth: auth),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _BottomNav(currentIndex: 0),
      ),
    );
  }
}

// ─────────────────────────────────────────
// TOP BAR
// ─────────────────────────────────────────
//
// Shows a greeting on the left and a settings / logout icon on the right.
// "Good morning, Alice" is friendlier than a blank header — personalisation
// increases session-start retention by reducing "who am I here?" friction.

class _TopBar extends StatelessWidget {
  final AuthState auth;
  const _TopBar({required this.auth});

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final name = auth.username?.split(' ').first ?? 'Player';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _greeting(),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  fontStyle: FontStyle.italic,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        // Coin capsule — always shown when logged in
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: appGold.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: appGold.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.monetization_on_rounded, color: appGold, size: 16),
              const SizedBox(width: 4),
              Text(
                '${auth.coins}',
                style: TextStyle(
                  color: appGold,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Login streak pill — shown when streak > 0
        if (auth.currentStreak > 0) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B35).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: const Color(0xFFFF6B35).withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.local_fire_department_rounded,
                    color: Color(0xFFFF6B35), size: 16),
                const SizedBox(width: 4),
                Text(
                  '${auth.currentStreak}',
                  style: const TextStyle(
                    color: Color(0xFFFF6B35),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
        // Notification bell placeholder
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: appSurface,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: const Icon(Icons.notifications_none_rounded,
              color: Colors.white54, size: 20),
        ),
      ],
    ).animate().fadeIn(duration: 400.ms);
  }
}

// ─────────────────────────────────────────
// PROFILE CARD
// ─────────────────────────────────────────
//
// Shows: Google profile picture (or initial letter fallback), username,
// tier label, rating, W/L record, premium badge.
//
// WHY show W/L here:
//   Players care about their win-loss record more than any other stat — it's the
//   single number that summarises skill. Showing it prominently on the home card
//   gives them a reason to come back and improve it.
//
// AVATAR STRATEGY:
//   If pictureUrl is set (Google Sign-In), we use CachedNetworkImage with a
//   CircleAvatar fallback while loading. If null (email/password account), we
//   render the first letter of the username on a coral background.
//   CachedNetworkImage handles CDN cache automatically — Google's profile picture
//   URLs change periodically but the cache key is the URL, so old URLs just expire.

class _ProfileCard extends StatelessWidget {
  final AuthState auth;
  const _ProfileCard({required this.auth});

  @override
  Widget build(BuildContext context) {
    final username = auth.username ?? 'Player';
    final wins = auth.matchesWon;
    final losses = auth.matchesPlayed - wins;
    final tier = _tierLabel(auth.rating);
    final tierColor = _tierColor(auth.rating);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            appCoral.withValues(alpha: 0.18),
            appSurface,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: appCoral.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          // ── Avatar ──────────────────────────────────────────────
          _Avatar(pictureUrl: auth.pictureUrl, username: username),
          const SizedBox(width: 16),

          // ── Info ─────────────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        username,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (auth.isPremium) ...[
                      const SizedBox(width: 6),
                      _PremiumBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                // Tier + Rating
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: tierColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: tierColor.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        tier,
                        style: TextStyle(
                          color: tierColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.star_rounded, color: appGold, size: 14),
                    const SizedBox(width: 3),
                    Text(
                      '${auth.rating}',
                      style: const TextStyle(
                        color: appGold,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // W/L record
                Row(
                  children: [
                    _RecordChip(
                      label: 'W',
                      value: '$wins',
                      color: appGreen,
                    ),
                    const SizedBox(width: 6),
                    _RecordChip(
                      label: 'L',
                      value: '$losses',
                      color: appRed,
                    ),
                    const SizedBox(width: 6),
                    _RecordChip(
                      label: 'WR',
                      value: auth.matchesPlayed > 0
                          ? '${(auth.winRate * 100).round()}%'
                          : '—',
                      color: appCoral,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 100.ms, duration: 400.ms);
  }
}

// ─────────────────────────────────────────
// AVATAR WIDGET
// ─────────────────────────────────────────
//
// Smart avatar: uses CachedNetworkImage when a Google profile picture URL
// is present, otherwise falls back to a letter avatar.
//
// WHY CachedNetworkImage:
//   Google's profile picture CDN serves images at up to 512px but we only
//   display 64px. The package automatically caches the downloaded bytes in
//   memory and on disk, so subsequent app opens don't re-download.
//   If the URL changes (Google rotates CDN URLs), the old cache entry simply
//   becomes unreachable and a new one is populated transparently.

class _Avatar extends StatelessWidget {
  final String? pictureUrl;
  final String username;
  const _Avatar({required this.pictureUrl, required this.username});

  @override
  Widget build(BuildContext context) {
    final initial =
        username.isNotEmpty ? username[0].toUpperCase() : '?';

    final border = BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: appCoral, width: 2.5),
      boxShadow: [
        BoxShadow(
          color: appCoral.withValues(alpha: 0.3),
          blurRadius: 16,
          spreadRadius: 1,
        ),
      ],
    );

    if (pictureUrl != null && pictureUrl!.isNotEmpty) {
      return Container(
        width: 64,
        height: 64,
        decoration: border,
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: pictureUrl!,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            placeholder: (_, __) => _initialAvatar(initial),
            errorWidget: (_, __, ___) => _initialAvatar(initial),
          ),
        ),
      );
    }

    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: appCoral.withValues(alpha: 0.2),
        border: Border.all(color: appCoral, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: appCoral.withValues(alpha: 0.3),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
            color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900),
      ),
    );
  }

  Widget _initialAvatar(String initial) => Container(
        color: appCoral.withValues(alpha: 0.2),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: const TextStyle(
              color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900),
        ),
      );
}

// ─────────────────────────────────────────
// RECORD CHIP
// ─────────────────────────────────────────

class _RecordChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _RecordChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(
                  color: color.withValues(alpha: 0.6),
                  fontSize: 10,
                  fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// PREMIUM BADGE
// ─────────────────────────────────────────

class _PremiumBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFB830), Color(0xFFFF8C00)],
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt_rounded, color: Colors.white, size: 11),
          SizedBox(width: 2),
          Text(
            'PRO',
            style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// DAILY QUOTA CARD
// ─────────────────────────────────────────
//
// Shows the player's daily game allowance as a horizontal progress bar.
//
// REAL-WORLD EXAMPLE:
//   Free user who played 3 games today sees:
//     "3 / 5 games played today  ██████░░░░  2 remaining"
//   Premium user sees:
//     "Unlimited games  ∞"
//
// WHY quota:
//   Freemium games use daily quotas to create urgency and scarcity. When the
//   bar is nearly full, the player feels pressure to make the last game count.
//   When it's empty, the upsell card becomes highly visible — this is the
//   optimal moment to prompt an upgrade because the user is engaged and wants
//   to play more.
//
// RESET:
//   The quota resets at midnight (date-based, not 24h rolling).
//   AuthNotifier._loadLocalStats() compares the saved date with today and
//   resets the counter to 0 if they differ. This means a player who played at
//   11 PM can play again at 12:01 AM — feels fair and keeps daily sessions short.

class _DailyQuotaCard extends StatelessWidget {
  final AuthState auth;
  const _DailyQuotaCard({required this.auth});

  @override
  Widget build(BuildContext context) {
    if (auth.isEffectivelyPremium) {
      return _buildPremiumQuota();
    }

    final used = auth.dailyQuizUsed;
    final total = kFreeQuotaPerDay;
    final remaining = auth.dailyQuizRemaining;
    final progress = (used / total).clamp(0.0, 1.0);
    final isExhausted = auth.isQuotaExhausted;
    final bonusGames = auth.bonusGamesRemaining;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isExhausted
              ? appRed.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isExhausted
                    ? Icons.lock_rounded
                    : Icons.today_rounded,
                color: isExhausted ? appRed : appCoral,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Daily Games',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                isExhausted
                    ? 'Limit reached'
                    : '$remaining remaining',
                style: TextStyle(
                  color: isExhausted
                      ? appRed
                      : Colors.white.withValues(alpha: 0.45),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(
                isExhausted ? appRed : appCoral,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$used / $total games played today'
            '${bonusGames > 0 ? '  ·  +$bonusGames bonus' : ''}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 11,
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 200.ms, duration: 400.ms);
  }

  Widget _buildPremiumQuota() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            appGold.withValues(alpha: 0.15),
            appGold.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: appGold.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.all_inclusive_rounded, color: appGold, size: 22),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Unlimited daily games',
              style: TextStyle(
                  color: appGold,
                  fontSize: 14,
                  fontWeight: FontWeight.w700),
            ),
          ),
          _PremiumBadge(),
        ],
      ),
    ).animate().fadeIn(delay: 200.ms, duration: 400.ms);
  }
}

// ─────────────────────────────────────────
// PLAY BUTTON
// ─────────────────────────────────────────
//
// The primary CTA. Full width, large, coral-coloured.
//
// DISABLED STATE (quota exhausted, free user):
//   The button dims and its label changes to "Upgrade to Play More".
//   Tapping it scrolls down to the premium upsell card instead of routing to
//   matchmaking. This avoids showing an error alert — the upgrade path is
//   right there in the same screen.
//
// ENABLED STATE:
//   Taps go to /matchmaking. consumeDailyQuiz() is NOT called here because the
//   match might not start if no opponent is found. It's called in matchmaking_screen
//   once a match is actually created (MatchmakingUpdate.matchFound received).

class _PlayButton extends ConsumerWidget {
  final AuthState auth;
  const _PlayButton({required this.auth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exhausted = auth.isQuotaExhausted;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: exhausted
            ? null
            : () => context.goNamed('matchmaking'),
        style: ElevatedButton.styleFrom(
          backgroundColor: appCoral,
          disabledBackgroundColor: appSurface,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: exhausted
                ? BorderSide(color: appRed.withValues(alpha: 0.3))
                : BorderSide.none,
          ),
          elevation: exhausted ? 0 : 4,
          shadowColor: appCoral.withValues(alpha: 0.4),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              exhausted
                  ? Icons.lock_rounded
                  : Icons.play_arrow_rounded,
              color: exhausted
                  ? Colors.white.withValues(alpha: 0.3)
                  : Colors.white,
              size: 24,
            ),
            const SizedBox(width: 10),
            Text(
              exhausted ? 'Upgrade to Play More' : 'Play Now',
              style: TextStyle(
                color: exhausted
                    ? Colors.white.withValues(alpha: 0.3)
                    : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 250.ms, duration: 400.ms).slideY(
          begin: 0.2,
          end: 0,
          delay: 250.ms,
          duration: 400.ms,
          curve: Curves.easeOut,
        );
  }
}

// ─────────────────────────────────────────
// QUICK STATS
// ─────────────────────────────────────────
//
// Three small tiles: current login streak, total matches played, accuracy.
//
// WHY three tiles:
//   - Streak: creates daily return motivation ("don't break the chain")
//   - Matches: gives a sense of progress / investment
//   - Accuracy: the metric most players want to improve after rating
//
// Accuracy = answersCorrect / (totalRounds × matchesPlayed) would require
// tracking totalCorrect separately. For simplicity we derive it from
// (matchesWon / matchesPlayed) as a proxy. A future enhancement would add
// totalAnswersCorrect and totalAnswers fields to AuthState.

class _QuickStats extends StatelessWidget {
  final AuthState auth;
  const _QuickStats({required this.auth});

  @override
  Widget build(BuildContext context) {
    final accuracy = auth.matchesPlayed > 0
        ? '${(auth.winRate * 100).round()}%'
        : '—';

    return Row(
      children: [
        Expanded(
          child: _StatTile(
            icon: Icons.local_fire_department_rounded,
            iconColor: const Color(0xFFFF6B35),
            label: 'Streak',
            value: '${auth.currentStreak}d',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            icon: Icons.sports_esports_rounded,
            iconColor: appCoral,
            label: 'Played',
            value: '${auth.matchesPlayed}',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            icon: Icons.track_changes_rounded,
            iconColor: appGold,
            label: 'Win Rate',
            value: accuracy,
          ),
        ),
      ],
    ).animate().fadeIn(delay: 300.ms, duration: 400.ms);
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  const _StatTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
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
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// PREMIUM UPSELL CARD
// ─────────────────────────────────────────
//
// Shown only to free users. Displays the value proposition of premium
// and provides a one-tap upgrade path.
//
// REAL-WORLD EXAMPLE:
//   A user at 4/5 games sees this card below the stats. It shows:
//     "⚡ Go Premium — Unlimited games · No ads · Priority matchmaking"
//   When their 5th game ends and the Play button is locked, they already
//   know what to do — they scroll down and tap "Upgrade".
//
// DEMO MODE:
//   In the real app, this would open a payment flow (in-app purchase, Stripe,
//   etc.). For this demo, tapping calls authProvider.notifier.togglePremium(),
//   which flips the flag in SharedPreferences and immediately unlocks the quota.

class _PremiumUpsellCard extends ConsumerWidget {
  final AuthState auth;
  const _PremiumUpsellCard({required this.auth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => context.pushNamed('premium'),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF2A1A00),
              appGold.withValues(alpha: 0.12),
            ],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: appGold.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFB830), Color(0xFFFF8C00)],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.bolt_rounded,
                  color: Colors.white, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Go Premium',
                    style: TextStyle(
                      color: appGold,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Unlimited games · No wait · Priority queue',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward_ios_rounded,
                color: appGold, size: 16),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 350.ms, duration: 400.ms);
  }
}

// ─────────────────────────────────────────
// STREAK CARD
// ─────────────────────────────────────────
//
// Displays the user's daily login streak with a fire icon and motivational text.
// Streak is incremented at login time via _updateLoginStreak() in AuthNotifier.
//
// WHY daily streak:
//   Streaks are the most powerful retention mechanic in mobile games (Duolingo,
//   Wordle, etc.). A player at 14-day streak will log in just to preserve it.
//   Showing it prominently on the home screen reminds them every session.

class _StreakCard extends StatelessWidget {
  final AuthState auth;
  const _StreakCard({required this.auth});

  @override
  Widget build(BuildContext context) {
    final streak = auth.currentStreak;
    final maxStreak = auth.maxStreak;
    final message = _streakMessage(streak);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Row(
        children: [
          // Fire icon with glow
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B35).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.local_fire_department_rounded,
              color: Color(0xFFFF6B35),
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$streak',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      streak == 1 ? 'day streak' : 'day streak',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFFFF6B35),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (maxStreak > 0)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Best',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 10,
                  ),
                ),
                Text(
                  '$maxStreak',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
        ],
      ),
    ).animate().fadeIn(delay: 400.ms, duration: 400.ms);
  }

  String _streakMessage(int streak) {
    if (streak == 0) return 'Play a game to start your streak!';
    if (streak < 3) return 'Just getting started — keep it up!';
    if (streak < 7) return 'You\'re on a roll! Don\'t stop now.';
    if (streak < 14) return 'One week strong! 🔥';
    if (streak < 30) return 'Two-week warrior! Incredible.';
    return 'UNSTOPPABLE. Legendary streak!';
  }
}

// ─────────────────────────────────────────
// LEADERBOARD PREVIEW
// ─────────────────────────────────────────
//
// Shows top 3 players for free users, top 5 for premium.
// Tapping "See All" navigates to the full global leaderboard.
// Data is fetched from GET /leaderboard via globalLeaderboardProvider.

class _LeaderboardPreview extends ConsumerWidget {
  final AuthState auth;
  const _LeaderboardPreview({required this.auth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leaderboardAsync = ref.watch(globalLeaderboardProvider);
    // Free: top 3 only. Effectively premium: full list (no cap).
    final limit = auth.isEffectivelyPremium ? null : 3;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        children: [
          // Header row
          Row(
            children: [
              const Icon(Icons.emoji_events_rounded, color: appGold, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Top Players',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (!auth.isEffectivelyPremium) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: appGold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: appGold.withValues(alpha: 0.3)),
                  ),
                  child: const Text(
                    'TOP 3',
                    style: TextStyle(color: appGold, fontSize: 9, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
              const Spacer(),
              GestureDetector(
                onTap: () => context.pushNamed('global-leaderboard'),
                child: const Text(
                  'See All',
                  style: TextStyle(
                    color: appCoral,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          leaderboardAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator(color: appCoral, strokeWidth: 2)),
            ),
            error: (_, __) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Could not load — server may be offline',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
            data: (entries) {
              final preview =
                  limit != null ? entries.take(limit).toList() : entries;
              return Column(
                children: preview.asMap().entries.map((e) {
                  final entry = e.value;
                  final isMe = entry.userId == auth.userId;
                  final medalColors = [appGold, appSilver, appBronze];
                  final medalColor = e.key < 3 ? medalColors[e.key] : Colors.white24;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 22,
                          child: Text(
                            '#${entry.rank}',
                            style: TextStyle(
                              color: medalColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: appCoral.withValues(alpha: 0.2),
                            border: Border.all(
                              color: isMe ? appCoral : Colors.white12,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            entry.username.isNotEmpty
                                ? entry.username[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            isMe ? '${entry.username} (You)' : entry.username,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isMe ? appCoral : Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            const Icon(Icons.star_rounded, color: appGold, size: 12),
                            const SizedBox(width: 3),
                            Text(
                              '${entry.rating}',
                              style: TextStyle(
                                color: isMe ? appCoral : Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
          if (!auth.isEffectivelyPremium) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => context.pushNamed('premium'),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: appGold.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: appGold.withValues(alpha: 0.25)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_open_rounded, color: appGold, size: 14),
                    SizedBox(width: 6),
                    Text(
                      'Upgrade to see full rankings',
                      style: TextStyle(
                        color: appGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn(delay: 450.ms, duration: 400.ms);
  }
}

// ─────────────────────────────────────────
// BOTTOM NAVIGATION
// ─────────────────────────────────────────
//
// Four tabs: Home · Play · Leaderboard · Profile
//
// WHY four tabs (not two or five):
//   Home (current state) + Play (primary action) + Leaderboard (social proof) +
//   Profile (personal stats) covers all core user needs without overwhelming.
//   Five tabs would push items too close on small phones; two would hide too much.
//
// IMPLEMENTATION NOTE:
//   This is a standalone bottom nav (not a ShellRoute) for simplicity.
//   A full app would use StatefulShellRoute in GoRouter to preserve scroll
//   position and tab state across navigations, but that requires refactoring
//   all routes into a shell — a future enhancement.

class _BottomNav extends ConsumerWidget {
  final int currentIndex;
  const _BottomNav({required this.currentIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: appSurface,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              _NavItem(
                icon: Icons.home_rounded,
                label: 'Home',
                selected: currentIndex == 0,
                onTap: () {}, // already here
              ),
              _NavItem(
                icon: Icons.play_circle_filled_rounded,
                label: 'Play',
                selected: currentIndex == 1,
                onTap: () {
                  final auth = ref.read(authProvider);
                  if (auth.isQuotaExhausted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text(
                            'Daily limit reached. Upgrade to Premium!'),
                        backgroundColor: appCoral,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    );
                    return;
                  }
                  context.goNamed('matchmaking');
                },
              ),
              _NavItem(
                icon: Icons.leaderboard_rounded,
                label: 'Leaderboard',
                selected: currentIndex == 2,
                // In-game leaderboard requires an active room.
                // Global leaderboard is a future screen; for now route to profile.
                onTap: () => context.pushNamed('global-leaderboard'),
              ),
              _NavItem(
                icon: Icons.person_rounded,
                label: 'Profile',
                selected: currentIndex == 3,
                onTap: () => context.pushNamed('profile'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? appCoral : Colors.white38;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight:
                      selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// HELPERS — Tier / Level system
// ─────────────────────────────────────────
//
// Rating tiers (same thresholds as profile_screen.dart):
//   BEGINNER       0 – 49 999
//   INTERMEDIATE   50 000 – 99 999
//   ADVANCED       100 000 – 149 999
//   EXPERT         150 000 – 199 999
//   MASTER         200 000 – 249 999
//   GRANDMASTER    250 000+
//
// Range of 50 000 per tier gives players long-term progression goals.
// The colour escalates from grey → teal → blue → purple → gold → coral.

String _tierLabel(int rating) {
  if (rating >= 250000) return 'GRANDMASTER';
  if (rating >= 200000) return 'MASTER';
  if (rating >= 150000) return 'EXPERT';
  if (rating >= 100000) return 'ADVANCED';
  if (rating >= 50000) return 'INTERMEDIATE';
  return 'BEGINNER';
}

Color _tierColor(int rating) {
  if (rating >= 250000) return appCoral;
  if (rating >= 200000) return appGold;
  if (rating >= 150000) return const Color(0xFFB04FDB);  // purple
  if (rating >= 100000) return const Color(0xFF4F8FDB);  // blue
  if (rating >= 50000) return const Color(0xFF4FDBBD);   // teal
  return Colors.white54;
}

// ─────────────────────────────────────────
// DAILY REWARD DIALOG
// ─────────────────────────────────────────
//
// Shown automatically via showDialog in HomeScreen.initState when the user
// has a pending unclaimed daily reward. Cannot be dismissed by tapping outside.
//
// "Skip" closes the dialog WITHOUT claiming — the popup will reappear the next
// time the user opens the home screen during the same day.
// "Claim" calls claimDailyReward() and closes.

class _DailyRewardDialog extends ConsumerWidget {
  final DailyReward reward;
  const _DailyRewardDialog({required this.reward});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streak = ref.watch(authProvider).currentStreak;
    final isMilestone = streak == 7 || streak == 14 || streak == 30;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isMilestone
                ? [const Color(0xFF2A1A00), appGold.withValues(alpha: 0.18)]
                : [const Color(0xFF1A0B08), appCoral.withValues(alpha: 0.14)],
          ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: isMilestone
                ? appGold.withValues(alpha: 0.5)
                : appCoral.withValues(alpha: 0.4),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: (isMilestone ? appGold : appCoral).withValues(alpha: 0.25),
              blurRadius: 40,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isMilestone ? appGold : const Color(0xFFFF6B35))
                    .withValues(alpha: 0.15),
              ),
              child: Icon(
                isMilestone
                    ? Icons.emoji_events_rounded
                    : Icons.local_fire_department_rounded,
                color: isMilestone ? appGold : const Color(0xFFFF6B35),
                size: 44,
              ),
            )
                .animate(onPlay: (c) => c.repeat())
                .scale(
                  begin: const Offset(1.0, 1.0),
                  end: const Offset(1.08, 1.08),
                  duration: 900.ms,
                  curve: Curves.easeInOut,
                )
                .then()
                .scale(
                  begin: const Offset(1.08, 1.08),
                  end: const Offset(1.0, 1.0),
                  duration: 900.ms,
                  curve: Curves.easeInOut,
                ),

            const SizedBox(height: 20),

            // Streak day label
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: (isMilestone ? appGold : appCoral).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color:
                      (isMilestone ? appGold : appCoral).withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                'Day $streak Streak',
                style: TextStyle(
                  color: isMilestone ? appGold : appCoral,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Title
            Text(
              reward.title,
              style: TextStyle(
                color: isMilestone ? appGold : Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 8),

            // Subtitle
            Text(
              reward.subtitle,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 20),

            // Reward breakdown chips
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (reward.coins > 0)
                  _RewardChip(
                    icon: Icons.monetization_on_rounded,
                    label: '+${reward.coins} coins',
                    color: appGold,
                  ),
                if (reward.bonusGames > 0)
                  _RewardChip(
                    icon: Icons.sports_esports_rounded,
                    label: '+${reward.bonusGames} games',
                    color: appCoral,
                  ),
                if (reward.premiumTrialDays > 0)
                  _RewardChip(
                    icon: Icons.bolt_rounded,
                    label: '${reward.premiumTrialDays}d Premium',
                    color: const Color(0xFFFFB830),
                  ),
                if (reward.badgeId != null)
                  _RewardChip(
                    icon: Icons.military_tech_rounded,
                    label: 'New badge!',
                    color: const Color(0xFFB04FDB),
                  ),
              ],
            ),

            const SizedBox(height: 28),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Later',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: () {
                      ref.read(authProvider.notifier).claimDailyReward();
                      Navigator.of(context).pop();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isMilestone ? appGold : appCoral,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'Claim Reward',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 300.ms).scale(
          begin: const Offset(0.85, 0.85),
          end: const Offset(1.0, 1.0),
          curve: Curves.easeOutBack,
          duration: 400.ms,
        );
  }
}

// ─────────────────────────────────────────
// REFERRAL SHARE CARD
// ─────────────────────────────────────────
//
// Compact card shown below the streak card when the user has a referral code.
// Tapping opens the Profile → REFERRAL tab for full details and sharing.
// Shows the code with a one-tap copy button — zero friction to share.

class _ReferralShareCard extends ConsumerWidget {
  final AuthState auth;
  const _ReferralShareCard({required this.auth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code = auth.referralCode!;
    return GestureDetector(
      onTap: () => context.goNamed('profile'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              appCoral.withValues(alpha: 0.14),
              appCoral.withValues(alpha: 0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: appCoral.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: appCoral.withValues(alpha: 0.14),
              ),
              child: const Icon(Icons.card_giftcard_rounded,
                  color: appCoral, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Invite friends, earn coins',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Your code: $code',
                    style: TextStyle(
                      color: appCoral.withValues(alpha: 0.85),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            // Copy button
            GestureDetector(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Code $code copied!'),
                    backgroundColor: appSurface,
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: appCoral.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: appCoral.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy_rounded, color: appCoral, size: 14),
                    SizedBox(width: 4),
                    Text('Copy',
                        style: TextStyle(
                            color: appCoral,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 200.ms, duration: 350.ms).slideY(
        begin: 0.1, end: 0, delay: 200.ms, duration: 350.ms);
  }
}

class _RewardChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _RewardChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
