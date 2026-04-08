import 'package:flutter/material.dart';
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
// SCREEN
// ─────────────────────────────────────────

/// Shown between rounds.
/// Displays a podium for the top 3, rank-change arrows for every player,
/// and the correct answer reveal card. Navigates automatically when the
/// server pushes the next QuestionBroadcast or MatchEnd event.
class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  // Snapshot of ranks from the PREVIOUS round — used to compute ↑ / ↓ arrows.
  // Populated once on first build from the leaderboard before this round's
  // LeaderboardUpdate arrives.
  Map<String, int> _prevRanks = {};
  bool _prevRanksCaptured = false;

  @override
  void initState() {
    super.initState();
    // Capture current ranks as "previous" on mount so we have a baseline
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scores = ref.read(gameProvider).leaderboard;
      if (!_prevRanksCaptured) {
        _prevRanks = {for (final s in scores) s.userId: s.rank};
        _prevRanksCaptured = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(gameProvider);

    // If we arrive and the phase is already finished (MatchEnd arrived
    // before this screen mounted), navigate immediately.
    if (state.phase == MatchPhase.finished) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.goNamed('results');
      });
    }

    // Navigate on phase change
    ref.listen(matchPhaseProvider, (_, next) {
      if (!context.mounted) return;
      if (next == MatchPhase.inRound) context.goNamed('quiz');
      if (next == MatchPhase.finished) context.goNamed('results');
    });

    // When leaderboard updates, update prev ranks for next refresh
    ref.listen(leaderboardProvider, (prev, next) {
      if (prev != null && prev.isNotEmpty) {
        setState(() {
          _prevRanks = {for (final s in prev) s.userId: s.rank};
        });
      }
    });

    final scores = state.leaderboard;
    final top3 = scores.take(3).toList();
    final rest = scores.skip(3).toList();
    final isLastRound = state.currentRound >= state.totalRounds;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  children: [
                    _buildHeader(state),
                    if (state.lastRoundResult != null)
                      _buildAnswerReveal(state.lastRoundResult!),
                    const SizedBox(height: 16),
                    if (top3.isNotEmpty) _buildPodium(top3, state.userId),
                    if (rest.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildRestListInline(rest, state.userId),
                    ],
                  ],
                ),
              ),
            ),
            _buildNextRoundHint(isLastRound),
          ],
        ),
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────

  Widget _buildHeader(GameState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Round ${state.currentRound} of ${state.totalRounds}',
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 2),
              const Text(
                'Leaderboard',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const Spacer(),
          const Icon(Icons.emoji_events_rounded, color: _gold, size: 32)
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .scaleXY(begin: 1, end: 1.15, duration: 900.ms)
              .then()
              .scaleXY(begin: 1.15, end: 1, duration: 900.ms),
        ],
      ),
    );
  }

  // ─── Correct answer reveal card ───────────────────────────

  Widget _buildAnswerReveal(RoundResultEvent result) {
    final fastestName = result.fastestUsername.isNotEmpty
        ? result.fastestUsername
        : result.fastestUserId;
    final hasFastest = fastestName.isNotEmpty;
    final answerText = result.correctAnswerText.isNotEmpty
        ? result.correctAnswerText
        : 'Option ${String.fromCharCode(65 + result.correctIndex)}';

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A3A2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _green.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _green.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.check_rounded,
                color: _green, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Correct answer',
                  style: TextStyle(
                      color: _green,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  answerText,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          Flexible(
            child: hasFastest
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bolt_rounded, color: _gold, size: 14),
                          SizedBox(width: 2),
                          Text('Fastest',
                              style: TextStyle(
                                  color: _gold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        fastestName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  )
                : const Text(
                    'No correct\nanswers',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                        color: Colors.white30,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                  ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 500.ms).slideY(begin: -0.12, end: 0);
  }

  // ─── PODIUM (top 3) ───────────────────────────────────────

  Widget _buildPodium(List<PlayerScore> top3, String? myUserId) {
    // Podium order: 2nd (left), 1st (center, tallest), 3rd (right)
    final order = [
      if (top3.length > 1) top3[1] else null, // left — 2nd
      top3[0], // center — 1st
      if (top3.length > 2) top3[2] else null, // right — 3rd
    ];
    final heights = [100.0, 130.0, 80.0];
    final colors = [_silver, _gold, _bronze];
    final labelColors = [_silver, _gold, _bronze];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(3, (i) {
          final score = order[i];
          if (score == null) {
            return Expanded(child: SizedBox(height: heights[i]));
          }
          final isMe = score.userId == myUserId;
          final rankDelta = _rankDelta(score.userId, score.rank);
          return Expanded(
            child: _PodiumBlock(
              score: score,
              height: heights[i],
              podiumColor: colors[i],
              labelColor: labelColors[i],
              rankBadge: i == 0 ? '2' : i == 1 ? '1' : '3',
              isMe: isMe,
              rankDelta: rankDelta,
              delay: Duration(milliseconds: 100 + i * 80),
            ),
          );
        }),
      ),
    );
  }

  // ─── Rest of leaderboard (rank 4+) — inline for ScrollView ─

  Widget _buildRestListInline(List<PlayerScore> rest, String? myUserId) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: rest.asMap().entries.map((e) {
          final i = e.key;
          final score = e.value;
          final isMe = score.userId == myUserId;
          final delta = _rankDelta(score.userId, score.rank);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ListRow(
              score: score,
              isMe: isMe,
              rankDelta: delta,
              delay: Duration(milliseconds: 80 + i * 50),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ─── Rank delta helper ────────────────────────────────────

  int _rankDelta(String userId, int currentRank) {
    final prev = _prevRanks[userId];
    if (prev == null) return 0;
    return prev - currentRank; // positive = improved (rank number got smaller)
  }

  // ─── "Next round starting…" hint ──────────────────────────

  Widget _buildNextRoundHint(bool isLastRound) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Text(
        isLastRound
            ? 'Calculating final results…'
            : 'Next round starting soon…',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white38, fontSize: 13),
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fadeIn(duration: 600.ms)
        .then(delay: 800.ms)
        .fadeOut(duration: 600.ms);
  }
}

// ─────────────────────────────────────────
// PODIUM BLOCK WIDGET
// ─────────────────────────────────────────

class _PodiumBlock extends StatelessWidget {
  final PlayerScore score;
  final double height;
  final Color podiumColor;
  final Color labelColor;
  final String rankBadge;
  final bool isMe;
  final int rankDelta;
  final Duration delay;

  const _PodiumBlock({
    required this.score,
    required this.height,
    required this.podiumColor,
    required this.labelColor,
    required this.rankBadge,
    required this.isMe,
    required this.rankDelta,
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
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // Rank change arrow
        _RankArrow(delta: rankDelta),
        const SizedBox(height: 4),
        // Avatar
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _avatarBg,
                border: Border.all(
                  color: isMe ? _coral : podiumColor.withValues(alpha: 0.6),
                  width: 2.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: podiumColor.withValues(alpha: 0.3),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                score.username[0].toUpperCase(),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800),
              ),
            ),
            // Rank medal badge
            Positioned(
              bottom: -6,
              right: -2,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: podiumColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: _bg, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  rankBadge,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Name + score
        Text(
          isMe ? 'You' : score.username,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: isMe ? _coral : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          '${score.score} pts',
          style: TextStyle(
              color: labelColor, fontSize: 11, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        // Podium base
        Container(
          width: double.infinity,
          height: height,
          decoration: BoxDecoration(
            color: podiumColor.withValues(alpha: 0.18),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(10),
              topRight: Radius.circular(10),
            ),
            border: Border.all(color: podiumColor.withValues(alpha: 0.35)),
          ),
        ),
      ],
    )
        .animate()
        .fadeIn(delay: delay, duration: 400.ms)
        .slideY(begin: 0.25, end: 0, delay: delay, curve: Curves.easeOutBack);
  }
}

// ─────────────────────────────────────────
// LIST ROW (rank 4+)
// ─────────────────────────────────────────

class _ListRow extends StatelessWidget {
  final PlayerScore score;
  final bool isMe;
  final int rankDelta;
  final Duration delay;

  const _ListRow({
    required this.score,
    required this.isMe,
    required this.rankDelta,
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
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
          // Rank number
          SizedBox(
            width: 26,
            child: Text(
              '#${score.rank}',
              style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          // Avatar
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: _avatarBg),
            alignment: Alignment.center,
            child: Text(
              score.username[0].toUpperCase(),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          // Name + streak
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
                            fontSize: 13,
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
                  '${score.answersCorrect} correct',
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          // Rank delta arrow
          _RankArrow(delta: rankDelta),
          const SizedBox(width: 10),
          // Score
          Text(
            '${score.score}',
            style: TextStyle(
                color: isMe ? _coral : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 3),
          const Text('pts',
              style: TextStyle(color: Colors.white38, fontSize: 10)),
        ],
      ),
    )
        .animate()
        .fadeIn(delay: delay, duration: 300.ms)
        .slideX(begin: 0.06, end: 0, delay: delay);
  }
}

// ─────────────────────────────────────────
// RANK ARROW WIDGET
// ─────────────────────────────────────────

/// Shows ↑ (green) if rank improved, ↓ (red) if rank dropped, — if unchanged.
/// delta > 0 means rank number went DOWN (player moved UP the leaderboard).
class _RankArrow extends StatelessWidget {
  final int delta;

  const _RankArrow({required this.delta});

  @override
  Widget build(BuildContext context) {
    if (delta == 0) {
      return const Text('—',
          style: TextStyle(color: Colors.white24, fontSize: 12));
    }

    final isUp = delta > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
          color: isUp ? _green : _red,
          size: 14,
        ),
        Text(
          '${delta.abs()}',
          style: TextStyle(
              color: isUp ? _green : _red,
              fontSize: 11,
              fontWeight: FontWeight.w700),
        ),
      ],
    )
        .animate()
        .fadeIn(duration: 350.ms)
        .slideY(begin: isUp ? 0.3 : -0.3, end: 0);
  }
}
