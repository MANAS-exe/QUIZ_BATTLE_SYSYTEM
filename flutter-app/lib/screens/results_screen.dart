import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/game_event.dart';
import '../providers/game_provider.dart';

// ─────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────

const _coral = Color(0xFFC96442);
const _bg = Color(0xFF0D0D1A);
const _surface = Color(0xFF1A1A2E);
const _gold = Color(0xFFFFB830);
const _silver = Color(0xFFB0BEC5);
const _bronze = Color(0xFFCD7F32);
const _green = Color(0xFF2ECC71);
const _red = Color(0xFFE74C3C);

// ─────────────────────────────────────────
// XP CALCULATION
// ─────────────────────────────────────────

/// XP = (correct answers × 10) + speed bonus
/// Speed bonus: up to 5 pts per correct answer for fast responses (<3000 ms)
int _calcXP(PlayerScore s) {
  final base = s.answersCorrect * 10;
  if (s.answersCorrect == 0) return base;
  final speedBonus = ((1 - (s.avgResponseMs / 10000).clamp(0.0, 1.0)) *
          5 *
          s.answersCorrect)
      .round();
  return base + speedBonus;
}

// ─────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────

/// Final match results screen. Shown after MatchEnd event arrives.
/// Features: trophy animation, personal stats card, final standings,
/// rematch and share buttons.
class ResultsScreen extends ConsumerWidget {
  const ResultsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(gameProvider);
    final matchEnd = state.matchEnd;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: matchEnd == null
            ? _buildLoading()
            : _buildResults(context, ref, state, matchEnd),
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
    WidgetRef ref,
    GameState state,
    MatchEndEvent matchEnd,
  ) {
    final isWinner = matchEnd.winnerUserId == state.userId;
    final myScore = state.leaderboard
        .where((s) => s.userId == state.userId)
        .firstOrNull;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 32),
                _buildTrophyHero(isWinner),
                const SizedBox(height: 20),
                _buildWinnerBanner(matchEnd),
                const SizedBox(height: 20),
                if (myScore != null) ...[
                  _buildPersonalStats(
                      myScore, matchEnd.totalRounds, isWinner),
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
        _buildActions(context, ref, state, matchEnd, myScore),
      ],
    );
  }

  // ─── Trophy hero ──────────────────────────────────────────

  Widget _buildTrophyHero(bool isWinner) {
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            // Glow ring behind trophy
            if (isWinner)
              Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: _gold.withValues(alpha: 0.3),
                        blurRadius: 40,
                        spreadRadius: 10),
                  ],
                ),
              )
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .scaleXY(begin: 0.9, end: 1.1, duration: 1200.ms),
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isWinner
                    ? _gold.withValues(alpha: 0.15)
                    : _surface,
                border: Border.all(
                  color: isWinner
                      ? _gold.withValues(alpha: 0.5)
                      : Colors.white12,
                  width: 2.5,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                isWinner ? '🏆' : '🎯',
                style: const TextStyle(fontSize: 52),
              ),
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
        const SizedBox(height: 18),
        Text(
          isWinner ? 'You Won! 🎉' : 'Match Over',
          style: TextStyle(
              color: isWinner ? _gold : Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800),
        )
            .animate()
            .fadeIn(delay: 400.ms, duration: 400.ms)
            .slideY(begin: 0.2, end: 0, delay: 400.ms),
      ],
    );
  }

  // ─── Winner banner ────────────────────────────────────────

  Widget _buildWinnerBanner(MatchEndEvent matchEnd) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _gold.withValues(alpha: 0.08),
              _gold.withValues(alpha: 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _gold.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.emoji_events_rounded,
                color: _gold, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Winner',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                  ),
                  Text(
                    matchEnd.winnerUsername,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: _gold,
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
      PlayerScore my, int totalRounds, bool isWinner) {
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
    WidgetRef ref,
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
          const SizedBox(width: 12),
          // Rematch button
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.replay_rounded, size: 18),
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
                  '${score.answersCorrect} correct · '
                  '${(score.avgResponseMs / 1000).toStringAsFixed(1)}s avg',
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
