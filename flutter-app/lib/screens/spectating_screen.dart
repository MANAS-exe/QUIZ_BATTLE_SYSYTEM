import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/game_provider.dart';

const _coral = Color(0xFFC96442);
const _bg = Color(0xFF0D0D1A);
const _surface = Color(0xFF1A1A2E);

class SpectatingScreen extends ConsumerWidget {
  const SpectatingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(gameProvider);

    // Navigate to results when match finishes
    ref.listen(matchPhaseProvider, (_, next) {
      if (!context.mounted) return;
      if (next == MatchPhase.finished) context.goNamed('results');
    });

    // If already finished on mount (MatchEnd arrived before screen)
    if (state.phase == MatchPhase.finished) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.goNamed('results');
      });
    }

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Animated hourglass
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _coral.withValues(alpha: 0.12),
                    border: Border.all(
                        color: _coral.withValues(alpha: 0.3), width: 2),
                  ),
                  child: const Icon(
                    Icons.sports_esports_rounded,
                    color: _coral,
                    size: 48,
                  ),
                )
                    .animate(onPlay: (c) => c.repeat(reverse: true))
                    .scaleXY(begin: 1.0, end: 1.08, duration: 1200.ms)
                    .then()
                    .scaleXY(begin: 1.08, end: 1.0, duration: 1200.ms),

                const SizedBox(height: 32),

                const Text(
                  'Match in Progress',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ).animate().fadeIn(duration: 500.ms),

                const SizedBox(height: 12),

                Text(
                  'You left the match.\nWaiting for the game to finish...',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ).animate().fadeIn(delay: 200.ms, duration: 400.ms),

                const SizedBox(height: 32),

                // Live score preview
                if (state.leaderboard.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              'Live Scores',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              'Round ${state.currentRound}/${state.totalRounds}',
                              style: TextStyle(
                                color: _coral.withValues(alpha: 0.7),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ...state.leaderboard.take(5).map((s) {
                          final isMe = s.userId == state.userId;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 22,
                                  child: Text(
                                    '#${s.rank}',
                                    style: TextStyle(
                                      color: isMe
                                          ? _coral
                                          : Colors.white38,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isMe ? 'You' : s.username,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isMe
                                          ? _coral
                                          : Colors.white70,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${s.score} pts',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ).animate().fadeIn(delay: 400.ms, duration: 400.ms),
                ],

                const SizedBox(height: 40),

                // Pulsing dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(3, (i) {
                    return Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _coral.withValues(alpha: 0.6),
                      ),
                    )
                        .animate(
                            onPlay: (c) => c.repeat(reverse: true),
                            delay: Duration(milliseconds: i * 300))
                        .fadeIn(duration: 600.ms)
                        .then()
                        .fadeOut(duration: 600.ms);
                  }),
                ),

                const SizedBox(height: 40),

                // Leave button
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      ref.read(gameProvider.notifier).reset();
                      context.goNamed('matchmaking');
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white54,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'Leave',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ).animate().fadeIn(delay: 600.ms, duration: 400.ms),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
