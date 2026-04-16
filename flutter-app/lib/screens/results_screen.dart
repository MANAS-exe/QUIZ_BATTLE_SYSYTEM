import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/game_event.dart';
import '../providers/game_provider.dart';
import '../services/auth_service.dart';
import '../theme/colors.dart';

// ─────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────

const _coral   = appCoral;
const _bg      = appBg;
const _surface = appSurface;
const _gold    = appGold;
const _silver  = appSilver;
const _bronze  = appBronze;
const _green   = appGreen;
const _red     = appRed;

// ─────────────────────────────────────────
// XP CALCULATION
// ─────────────────────────────────────────

/// XP = the player's actual match score from the backend leaderboard.
int _calcXP(PlayerScore s) => s.score;

// ─────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────

/// Final match results screen. Shown after MatchEnd event arrives.
/// Features: trophy animation, personal stats card, final standings,
/// rematch and share buttons.
class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({super.key});

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  bool _statsSaved = false;

  void _saveStatsIfNeeded() {
    if (_statsSaved) return;
    final gs = ref.read(gameProvider);
    final me = gs.matchEnd;
    if (me == null) return;
    _statsSaved = true;

    // When nobody answered correctly, there is no real winner — don't record
    // a win even if the server assigned one (it always assigns rank 1 to someone).
    final totalCorrect =
        me.finalScores.fold(0, (sum, s) => sum + s.answersCorrect);
    final isNoCorrectAnswers =
        totalCorrect == 0 && me.finalScores.isNotEmpty;
    final won = !isNoCorrectAnswers && me.winnerUserId == gs.userId;

    final myScore =
        gs.leaderboard.where((s) => s.userId == gs.userId).firstOrNull;
    ref.read(authProvider.notifier).recordMatchResult(
          won: won,
          newRating: ref.read(authProvider).rating + (myScore?.score ?? 0),
          matchMaxStreak: gs.maxAnswerStreak,
          lastMatch: LastMatchData(
            won: won,
            rank: myScore?.rank ?? gs.leaderboard.length,
            score: myScore?.score ?? 0,
            answersCorrect: myScore?.answersCorrect ?? 0,
            totalRounds: me.totalRounds,
            avgResponseMs: myScore?.avgResponseMs ?? 0,
            durationSeconds: me.durationSeconds,
            maxStreak: gs.maxAnswerStreak,
            winnerUsername: isNoCorrectAnswers ? '' : me.winnerUsername,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(gameProvider);
    final matchEnd = state.matchEnd;

    // Save stats as soon as the match result is available
    if (matchEnd != null && !_statsSaved) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _saveStatsIfNeeded();
      });
    }

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: matchEnd == null
            ? _buildLoading()
            : _buildResults(context, state, matchEnd),
      ),
    );
  }

  // ─── Loading ──────────────────────────────────────────────

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _coral),
          SizedBox(height: 16),
          Text('Loading results…',
              style: TextStyle(color: Colors.white54, fontSize: 14)),
        ],
      ),
    );
  }

  // ─── Main layout ──────────────────────────────────────────

  Widget _buildResults(
    BuildContext context,
    GameState state,
    MatchEndEvent matchEnd,
  ) {
    final isWinner = matchEnd.winnerUserId == state.userId;
    final myScore = state.leaderboard
        .where((s) => s.userId == state.userId)
        .firstOrNull;

    final totalCorrect = matchEnd.finalScores.fold(0, (sum, s) => sum + s.answersCorrect);
    final isNoCorrectAnswers = totalCorrect == 0 && matchEnd.finalScores.isNotEmpty;
    final isTie = !isNoCorrectAnswers &&
        matchEnd.finalScores.length > 1 &&
        matchEnd.finalScores[0].score == matchEnd.finalScores[1].score;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 32),
                _buildTrophyHero(isWinner, isTie: isTie, isNoCorrect: isNoCorrectAnswers),
                const SizedBox(height: 20),
                _buildWinnerBanner(matchEnd, isTie: isTie, isNoCorrect: isNoCorrectAnswers),
                const SizedBox(height: 20),
                if (myScore != null) ...[
                  _buildPersonalStats(
                      myScore, matchEnd.totalRounds, isWinner, state.maxAnswerStreak),
                  const SizedBox(height: 20),
                ],
                _buildMatchSummary(matchEnd),
                const SizedBox(height: 20),
                _buildFinalStandings(state, matchEnd),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        _buildActions(context, state, matchEnd, myScore),
      ],
    );
  }

  // ─── Trophy hero ──────────────────────────────────────────

  Widget _buildTrophyHero(bool isWinner, {bool isTie = false, bool isNoCorrect = false}) {
    final heroColor = isNoCorrect
        ? Colors.white38
        : isTie
            ? _silver
            : isWinner
                ? _gold
                : _coral;
    final icon = isNoCorrect
        ? Icons.block_rounded
        : isTie
            ? Icons.handshake_rounded
            : isWinner
                ? Icons.emoji_events_rounded
                : Icons.flag_rounded;
    final headline = isNoCorrect
        ? 'No Answers'
        : isTie
            ? "It's a Tie!"
            : isWinner
                ? 'Victory!'
                : 'Match Over';
    final subtitle = isNoCorrect
        ? 'Nobody answered correctly this match'
        : isTie
            ? 'Equal scores — well played by all!'
            : isWinner
                ? null
                : 'Better luck next time';

    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: heroColor.withValues(alpha: 0.25),
                      blurRadius: 40,
                      spreadRadius: 8),
                ],
              ),
            )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .scaleXY(begin: 0.9, end: 1.08, duration: 1400.ms),
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    heroColor.withValues(alpha: 0.2),
                    heroColor.withValues(alpha: 0.05),
                  ],
                ),
                border: Border.all(
                  color: heroColor.withValues(alpha: 0.5),
                  width: 2.5,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: heroColor, size: 52),
            )
                .animate()
                .fadeIn(duration: 600.ms)
                .scale(
                    begin: const Offset(0.5, 0.5),
                    end: const Offset(1, 1),
                    curve: Curves.elasticOut,
                    duration: 800.ms),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          headline,
          style: TextStyle(
              color: isNoCorrect
                  ? Colors.white38
                  : isTie
                      ? _silver
                      : isWinner
                          ? _gold
                          : Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800),
        )
            .animate()
            .fadeIn(delay: 400.ms, duration: 400.ms)
            .slideY(begin: 0.2, end: 0, delay: 400.ms),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 14,
                fontWeight: FontWeight.w500),
          ).animate().fadeIn(delay: 500.ms, duration: 300.ms),
        ],
      ],
    );
  }

  // ─── Winner banner ────────────────────────────────────────

  Widget _buildWinnerBanner(MatchEndEvent matchEnd, {bool isTie = false, bool isNoCorrect = false}) {
    final Color bannerColor;
    final IconData bannerIcon;
    final String bannerLabel;
    final String bannerValue;

    if (isNoCorrect) {
      bannerColor = Colors.white24;
      bannerIcon = Icons.block_rounded;
      bannerLabel = 'Result';
      bannerValue = 'No correct answers';
    } else if (isTie) {
      bannerColor = _silver;
      bannerIcon = Icons.handshake_rounded;
      bannerLabel = 'Result';
      bannerValue = "It's a Tie!";
    } else {
      bannerColor = _gold;
      bannerIcon = Icons.emoji_events_rounded;
      bannerLabel = 'Winner';
      bannerValue = matchEnd.winnerUsername;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              bannerColor.withValues(alpha: 0.08),
              bannerColor.withValues(alpha: 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: bannerColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(bannerIcon, color: bannerColor, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bannerLabel,
                    style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                  ),
                  Text(
                    bannerValue,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: bannerColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 500.ms, duration: 400.ms);
  }

  // ─── Personal stats card ──────────────────────────────────

  Widget _buildPersonalStats(
      PlayerScore my, int totalRounds, bool isWinner, int maxStreak) {
    final wrongAnswers = totalRounds - my.answersCorrect;
    final accuracy = totalRounds > 0
        ? (my.answersCorrect / totalRounds * 100).round()
        : 0;
    final xp = _calcXP(my);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: isWinner
                  ? _coral.withValues(alpha: 0.3)
                  : Colors.white10),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, 6)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Your performance',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                // XP earned badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _coral.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        Border.all(color: _coral.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.bolt_rounded,
                          color: _coral, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        '+$xp XP',
                        style: const TextStyle(
                            color: _coral,
                            fontSize: 12,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Accuracy bar
            _AccuracyBar(accuracy: accuracy),
            const SizedBox(height: 16),
            // Stat grid
            Row(
              children: [
                _StatCell(
                  icon: Icons.check_circle_rounded,
                  iconColor: _green,
                  label: 'Correct',
                  value: '${my.answersCorrect}',
                ),
                _StatCell(
                  icon: Icons.cancel_rounded,
                  iconColor: _red,
                  label: 'Wrong',
                  value: '$wrongAnswers',
                ),
                _StatCell(
                  icon: Icons.speed_rounded,
                  iconColor: _gold,
                  label: 'Avg time',
                  value: '${(my.avgResponseMs / 1000).toStringAsFixed(1)}s',
                ),
                _StatCell(
                  icon: Icons.leaderboard_rounded,
                  iconColor: _coral,
                  label: 'Rank',
                  value: '#${my.rank}',
                ),
                _StatCell(
                  icon: Icons.local_fire_department_rounded,
                  iconColor: _red,
                  label: 'Best Streak',
                  value: '$maxStreak',
                ),
              ],
            ),
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(delay: 600.ms, duration: 400.ms)
        .slideY(begin: 0.1, end: 0, delay: 600.ms);
  }

  // ─── Match summary chips ──────────────────────────────────

  Widget _buildMatchSummary(MatchEndEvent matchEnd) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          _SummaryChip(
              icon: Icons.quiz_rounded,
              label: '${matchEnd.totalRounds} rounds'),
          _SummaryChip(
              icon: Icons.timer_rounded,
              label: _fmtDuration(matchEnd.durationSeconds)),
          _SummaryChip(
              icon: Icons.people_rounded,
              label: '${matchEnd.finalScores.length} players'),
        ],
      ),
    ).animate().fadeIn(delay: 700.ms, duration: 400.ms);
  }

  // ─── Final standings ──────────────────────────────────────

  Widget _buildFinalStandings(GameState state, MatchEndEvent matchEnd) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Final standings',
            style: TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          ...matchEnd.finalScores.asMap().entries.map((e) {
            final i = e.key;
            final score = e.value;
            final isMe = score.userId == state.userId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _StandingRow(
                score: score,
                isMe: isMe,
                delay: Duration(milliseconds: 750 + i * 60),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── Action buttons ───────────────────────────────────────

  Widget _buildActions(
    BuildContext context,
    GameState state,
    MatchEndEvent matchEnd,
    PlayerScore? myScore,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      decoration: const BoxDecoration(
        color: _bg,
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          // Share button
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.share_rounded, size: 18),
              label: const Text('Share'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
              onPressed: () => _shareResult(state, matchEnd, myScore),
            ),
          ),
          const SizedBox(width: 8),
          // Home button
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.home_rounded, size: 18),
              label: const Text('Home'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
              onPressed: () {
                ref.read(gameProvider.notifier).reset();
                context.goNamed('home');
              },
            ),
          ),
          const SizedBox(width: 8),
          // Rematch button
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.sports_esports_rounded, size: 18),
              label: const Text('Play Again'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _coral,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700),
                elevation: 0,
              ),
              onPressed: () {
                ref.read(gameProvider.notifier).reset();
                context.goNamed('matchmaking');
              },
            ),
          ),
        ],
      ),
    )
        .animate()
        .fadeIn(delay: 900.ms, duration: 400.ms)
        .slideY(begin: 0.3, end: 0, delay: 900.ms);
  }

  // ─── Share helper ─────────────────────────────────────────

  void _shareResult(
      GameState state, MatchEndEvent matchEnd, PlayerScore? my) {
    final rank = my?.rank ?? '?';
    final correct = my?.answersCorrect ?? 0;
    final xp = my != null ? _calcXP(my) : 0;
    final text =
        'I finished #$rank in Quiz Battle!\n'
        '$correct/${matchEnd.totalRounds} correct answers · +$xp XP\n'
        'Winner: ${matchEnd.winnerUsername}\n'
        '#QuizBattle';
    Clipboard.setData(ClipboardData(text: text));
    // In a real app: use share_plus package → Share.share(text)
  }

  String _fmtDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }
}

// ─────────────────────────────────────────
// ACCURACY BAR
// ─────────────────────────────────────────

class _AccuracyBar extends StatelessWidget {
  final int accuracy; // 0–100

  const _AccuracyBar({required this.accuracy});

  Color get _color {
    if (accuracy >= 80) return _green;
    if (accuracy >= 50) return _gold;
    return _red;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Accuracy',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            Text(
              '$accuracy%',
              style: TextStyle(
                  color: _color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: accuracy / 100.0,
            backgroundColor: Colors.white12,
            color: _color,
            minHeight: 6,
          ),
        )
            .animate()
            .custom(
              delay: 700.ms,
              duration: 800.ms,
              curve: Curves.easeOutCubic,
              builder: (context, value, child) => ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (accuracy / 100.0) * value,
                  backgroundColor: Colors.white12,
                  color: _color,
                  minHeight: 6,
                ),
              ),
            ),
      ],
    );
  }
}

// ─────────────────────────────────────────
// STAT CELL
// ─────────────────────────────────────────

class _StatCell extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  const _StatCell({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
                color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// SUMMARY CHIP
// ─────────────────────────────────────────

class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SummaryChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white38, size: 14),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// STANDING ROW
// ─────────────────────────────────────────

class _StandingRow extends StatelessWidget {
  final PlayerScore score;
  final bool isMe;
  final Duration delay;

  static const _podiumColors = [_gold, _silver, _bronze];

  const _StandingRow({
    required this.score,
    required this.isMe,
    required this.delay,
  });

  Color get _avatarBg {
    const colors = [
      Color(0xFF0F3460),
      Color(0xFF533483),
      Color(0xFF2D6A4F),
      Color(0xFF7B2D8B),
      Color(0xFF1A4A80),
    ];
    return colors[score.username.codeUnitAt(0) % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final rankColor = score.rank <= 3
        ? _podiumColors[score.rank - 1]
        : Colors.white38;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isMe ? _coral.withValues(alpha: 0.1) : _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isMe ? _coral.withValues(alpha: 0.35) : Colors.white10,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          // Rank
          SizedBox(
            width: 28,
            child: Text(
              '#${score.rank}',
              style: TextStyle(
                  color: rankColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          // Avatar
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: _avatarBg),
            alignment: Alignment.center,
            child: Text(
              score.username.isNotEmpty ? score.username[0].toUpperCase() : '?',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          // Name + stats
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        isMe ? 'You' : score.username,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: isMe ? _coral : Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: _coral,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('You',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ],
                ),
                Text(
                  score.answersCorrect == 0
                      ? 'No correct answers'
                      : '${score.answersCorrect} correct · ${(score.avgResponseMs / 1000).toStringAsFixed(1)}s',
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          // Score
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${score.score}',
                style: TextStyle(
                    color: isMe ? _coral : Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800),
              ),
              const Text('pts',
                  style: TextStyle(
                      color: Colors.white38, fontSize: 10)),
            ],
          ),
        ],
      ),
    )
        .animate()
        .fadeIn(delay: delay, duration: 300.ms)
        .slideX(begin: 0.06, end: 0, delay: delay);
  }
}
