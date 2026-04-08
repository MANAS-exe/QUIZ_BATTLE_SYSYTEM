import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/game_event.dart';
import '../providers/game_provider.dart';
import '../services/auth_service.dart';
import '../services/game_service.dart';

// ─────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────

const _coral = Color(0xFFC96442);
const _bg = Color(0xFF0D0D1A);
const _surface = Color(0xFF1A1A2E);
const _gold = Color(0xFFFFB830);
const _green = Color(0xFF2ECC71);
const _red = Color(0xFFE74C3C);

// ─────────────────────────────────────────
// OPTION STATE ENUM
// ─────────────────────────────────────────

enum _OptionState {
  idle,       // untouched, round active
  selected,   // optimistically tapped — waiting for result
  correct,    // this index was the right answer (green)
  wrong,      // selected but incorrect (red)
}

// ─────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────

class QuizScreen extends ConsumerStatefulWidget {
  const QuizScreen({super.key});

  @override
  ConsumerState<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends ConsumerState<QuizScreen>
    with TickerProviderStateMixin {
  // Slide-in animation for each new question card
  late final AnimationController _questionCtrl;

  // Shake animation when time runs out
  late final AnimationController _shakeCtrl;

  // Tracks which questionId the current animation is for (avoids re-triggering)
  String? _animatedQuestionId;

  @override
  void initState() {
    super.initState();
    _questionCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    )..forward();

    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    // Subscribe to the game event stream as soon as the screen mounts.
    // Uses a post-frame callback so ref.read is safe here.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startStream());
  }

  void _startStream() {
    final gameState = ref.read(gameProvider);
    final roomId = gameState.roomId;
    final userId = gameState.userId;
    if (roomId == null || userId == null) {
      debugPrint('[QuizScreen] Missing roomId or userId — cannot start stream');
      return;
    }

    final stream = ref
        .read(gameServiceProvider)
        .streamGameEvents(roomId, userId);

    ref.read(gameProvider.notifier).subscribeToGameEvents(stream);
  }

  @override
  void dispose() {
    _questionCtrl.dispose();
    _shakeCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final gameState = ref.watch(gameProvider);
    final question = gameState.currentQuestion;

    // Re-run slide animation whenever a new question arrives
    if (question != null && question.questionId != _animatedQuestionId) {
      _animatedQuestionId = question.questionId;
      _questionCtrl.forward(from: 0);
    }

    // Shake timer when it hits 5 seconds
    ref.listen(timerProvider, (prev, next) {
      if (next == 5 && prev != null && prev > 5) {
        _shakeCtrl.forward(from: 0);
      }
    });

    // Navigate on phase change
    ref.listen(matchPhaseProvider, (_, next) {
      if (!mounted) return;
      if (next == MatchPhase.betweenRounds) context.goNamed('leaderboard');
      if (next == MatchPhase.finished) context.goNamed('results');
    });

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: question == null
            ? _buildLoading()
            : Stack(
                children: [
                  _buildRound(gameState, question),
                  _buildMiniLeaderboard(gameState),
                ],
              ),
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
          Text('Loading round…',
              style: TextStyle(color: Colors.white54, fontSize: 14)),
        ],
      ),
    );
  }

  // ─── Main round layout ────────────────────────────────────

  Widget _buildRound(GameState state, Question question) {
    return Column(
      children: [
        _buildTopBar(state),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Spacer so mini leaderboard overlay doesn't cover the timer
                const SizedBox(height: 8),
                _buildTimerRow(state),
                const SizedBox(height: 22),
                _buildQuestionCard(question),
                const SizedBox(height: 20),
                _buildOptions(question, state),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─── Top bar ──────────────────────────────────────────────

  void _exitGame() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Leave Match?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text('You will forfeit this match.',
            style: TextStyle(color: Colors.white54)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Stay', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Notify server so it stops counting this player for early-exit
              final gs = ref.read(gameProvider);
              ref.read(gameServiceProvider).submitAnswer(
                roomId: gs.roomId!,
                userId: gs.userId!,
                roundNumber: gs.currentRound,
                questionId: '',
                answerIndex: -1, // forfeit signal
              ).catchError((_) => false);
              ref.read(gameProvider.notifier).forfeitMatch();
              context.goNamed('spectating');
            },
            child: const Text('Leave', style: TextStyle(color: _coral)),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(GameState state) {
    final auth = ref.watch(authProvider);
    final username = auth.username ?? 'You';

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
      child: Row(
        children: [
          // Exit button
          GestureDetector(
            onTap: _exitGame,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _surface,
                border: Border.all(color: Colors.white12),
              ),
              child: const Icon(Icons.close, color: Colors.white38, size: 16),
            ),
          ),
          const SizedBox(width: 8),
          // Profile avatar + name + rating
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _coral.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _coral.withValues(alpha: 0.3),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    username.isNotEmpty ? username[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: _coral,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  username,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${auth.rating}',
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // Difficulty badge
          if (state.currentQuestion != null)
            _DifficultyBadge(state.currentQuestion!.difficulty),
          const Spacer(),
          // Round counter
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white12),
            ),
            child: Text(
              'Round ${state.currentRound}/${state.totalRounds}',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Timer row (CustomPainter arc + seconds) ──────────────

  Widget _buildTimerRow(GameState state) {
    final remaining = state.remainingSeconds;
    final fraction = (remaining / 30.0).clamp(0.0, 1.0);
    final timerColor = state.roundExpired
        ? Colors.white24
        : remaining <= 5
            ? _red
            : _coral;

    return Center(
      child: AnimatedBuilder(
        animation: _shakeCtrl,
        builder: (_, child) {
          final shakeOffset =
              remaining <= 5 && !state.roundExpired
                  ? math.sin(_shakeCtrl.value * math.pi * 6) * 4
                  : 0.0;
          return Transform.translate(
            offset: Offset(shakeOffset, 0),
            child: child,
          );
        },
        child: SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // CustomPainter arc ring
              CustomPaint(
                size: const Size(88, 88),
                painter: _TimerArcPainter(
                  progress: fraction,
                  arcColor: timerColor,
                  trackColor: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              // Number in center
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: TextStyle(
                  color: timerColor,
                  fontSize: remaining <= 5 ? 26 : 22,
                  fontWeight: FontWeight.w800,
                ),
                child: Text('$remaining'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Question card ────────────────────────────────────────

  Widget _buildQuestionCard(Question question) {
    return AnimatedBuilder(
      animation: _questionCtrl,
      builder: (_, child) {
        final t = CurvedAnimation(
            parent: _questionCtrl, curve: Curves.easeOutCubic);
        return Opacity(
          opacity: t.value,
          child: Transform.translate(
            offset: Offset(0, 24 * (1 - t.value)),
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Topic pill
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _coral.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    question.topic.toUpperCase(),
                    style: const TextStyle(
                        color: _coral,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              question.text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Answer options ───────────────────────────────────────

  Widget _buildOptions(Question question, GameState state) {
    // Determine post-round state for each option
    final result = state.lastRoundResult;
    final revealActive =
        result != null && state.phase == MatchPhase.betweenRounds;

    return Column(
      children: List.generate(question.options.length, (i) {
        _OptionState optState;
        if (revealActive) {
          if (i == result.correctIndex) {
            optState = _OptionState.correct;
          } else if (i == state.selectedAnswerIndex) {
            optState = _OptionState.wrong;
          } else {
            optState = _OptionState.idle;
          }
        } else if (i == state.selectedAnswerIndex) {
          optState = _OptionState.selected;
        } else {
          optState = _OptionState.idle;
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _OptionTile(
            index: i,
            text: question.options[i],
            optionState: optState,
            locked: state.hasAnswered || state.roundExpired || revealActive,
            delay: Duration(milliseconds: 80 + i * 70),
            onTap: () {
                    final gs = ref.read(gameProvider);
                    if (gs.hasAnswered || gs.roundExpired) return;
                    ref.read(gameProvider.notifier).submitAnswer(i);
                    // Fire-and-forget gRPC call — UI is already locked optimistically
                    ref.read(gameServiceProvider).submitAnswer(
                      roomId: gs.roomId!,
                      userId: gs.userId!,
                      roundNumber: gs.currentRound,
                      questionId: gs.currentQuestion!.questionId,
                      answerIndex: i,
                    ).catchError((e) {
                      debugPrint('[QuizScreen] submitAnswer gRPC error: $e');
                      return false;
                    });
                  },
          ),
        );
      }),
    );
  }

  // ─── Mini leaderboard overlay (top-right corner) ──────────

  Widget _buildMiniLeaderboard(GameState state) {
    final top3 = state.leaderboard.take(3).toList();
    if (top3.isEmpty) return const SizedBox.shrink();

    return Positioned(
      top: 60,
      right: 16,
      child: Container(
        width: 130,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🏆 TOP',
              style: TextStyle(
                  color: _gold,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1),
            ),
            const SizedBox(height: 6),
            ...top3.asMap().entries.map((e) {
              final i = e.key;
              final s = e.value;
              final isMe = s.userId == state.userId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  children: [
                    Text(
                      '${i + 1}.',
                      style: TextStyle(
                          color: i == 0
                              ? _gold
                              : i == 1
                                  ? Colors.white54
                                  : const Color(0xFFCD7F32),
                          fontSize: 11,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        isMe ? 'You' : s.username,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: isMe ? _coral : Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${s.score}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      )
          .animate()
          .fadeIn(delay: 600.ms, duration: 400.ms)
          .slideX(begin: 0.3, end: 0, delay: 600.ms),
    );
  }
}

// ─────────────────────────────────────────
// CUSTOM PAINTER — TIMER ARC
// ─────────────────────────────────────────

/// Draws a circular arc that shrinks clockwise from full (progress=1) to
/// empty (progress=0). Uses CustomPainter instead of CircularProgressIndicator
/// so we get precise strokeCap, gradient, and glow control.
class _TimerArcPainter extends CustomPainter {
  final double progress;
  final Color arcColor;
  final Color trackColor;

  _TimerArcPainter({
    required this.progress,
    required this.arcColor,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 7;

    // ── Background track ──────────────────────────────────────
    final trackPaint = Paint()
      ..color = trackColor
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress <= 0) return;

    // ── Glow layer (blurred, wider stroke) ────────────────────
    final glowPaint = Paint()
      ..color = arcColor.withValues(alpha: 0.25)
      ..strokeWidth = 12
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final sweepAngle = progress * 2 * math.pi;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, glowPaint);

    // ── Foreground arc ────────────────────────────────────────
    final arcPaint = Paint()
      ..color = arcColor
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, arcPaint);
  }

  @override
  bool shouldRepaint(_TimerArcPainter old) =>
      old.progress != progress || old.arcColor != arcColor;
}

// ─────────────────────────────────────────
// DIFFICULTY BADGE
// ─────────────────────────────────────────

class _DifficultyBadge extends StatelessWidget {
  final Difficulty difficulty;

  const _DifficultyBadge(this.difficulty);

  Color get _color {
    switch (difficulty) {
      case Difficulty.easy:
        return _green;
      case Difficulty.medium:
        return _gold;
      case Difficulty.hard:
        return _red;
      case Difficulty.unspecified:
        return Colors.white38;
    }
  }

  String get _label {
    switch (difficulty) {
      case Difficulty.easy:
        return 'EASY';
      case Difficulty.medium:
        return 'MEDIUM';
      case Difficulty.hard:
        return 'HARD';
      case Difficulty.unspecified:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (difficulty == Difficulty.unspecified) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _color.withValues(alpha: 0.4)),
      ),
      child: Text(
        _label,
        style: TextStyle(
            color: _color,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0),
      ),
    );
  }
}

// ─────────────────────────────────────────
// OPTION TILE
// ─────────────────────────────────────────

class _OptionTile extends StatelessWidget {
  final int index;
  final String text;
  final _OptionState optionState;
  final bool locked;
  final Duration delay;
  final VoidCallback onTap;

  static const _labels = ['A', 'B', 'C', 'D'];

  const _OptionTile({
    required this.index,
    required this.text,
    required this.optionState,
    required this.locked,
    required this.delay,
    required this.onTap,
  });

  Color get _borderColor {
    switch (optionState) {
      case _OptionState.correct:
        return _green;
      case _OptionState.wrong:
        return _red;
      case _OptionState.selected:
        return _coral;
      default:
        return Colors.white12;
    }
  }

  Color get _bgColor {
    switch (optionState) {
      case _OptionState.correct:
        return _green.withValues(alpha: 0.18);
      case _OptionState.wrong:
        return _red.withValues(alpha: 0.18);
      case _OptionState.selected:
        return _coral.withValues(alpha: 0.18);
      default:
        return _surface;
    }
  }

  Color get _labelBg {
    switch (optionState) {
      case _OptionState.correct:
        return _green;
      case _OptionState.wrong:
        return _red;
      case _OptionState.selected:
        return _coral;
      default:
        return Colors.white12;
    }
  }

  Widget get _trailingIcon {
    switch (optionState) {
      case _OptionState.correct:
        return const Icon(Icons.check_circle_rounded, color: _green, size: 20);
      case _OptionState.wrong:
        return const Icon(Icons.cancel_rounded, color: _red, size: 20);
      case _OptionState.selected:
        return const Icon(Icons.radio_button_checked_rounded,
            color: _coral, size: 20);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: locked ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _borderColor, width: 1.5),
          boxShadow: optionState == _OptionState.correct
              ? [
                  BoxShadow(
                      color: _green.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4))
                ]
              : optionState == _OptionState.wrong
                  ? [
                      BoxShadow(
                          color: _red.withValues(alpha: 0.25),
                          blurRadius: 12,
                          offset: const Offset(0, 4))
                    ]
                  : null,
        ),
        child: Row(
          children: [
            // Letter label
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _labelBg,
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Text(
                _labels[index],
                style: TextStyle(
                    color: optionState != _OptionState.idle
                        ? Colors.white
                        : Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                    color: optionState != _OptionState.idle
                        ? Colors.white
                        : Colors.white70,
                    fontSize: 15,
                    fontWeight: optionState != _OptionState.idle
                        ? FontWeight.w600
                        : FontWeight.w400),
              ),
            ),
            const SizedBox(width: 8),
            _trailingIcon,
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(delay: delay, duration: 300.ms)
        .slideX(begin: 0.08, end: 0, delay: delay);
  }
}
