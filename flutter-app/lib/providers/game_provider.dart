import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/game_event.dart';

// ─────────────────────────────────────────
// GAME STATE
// ─────────────────────────────────────────

enum MatchPhase {
  idle,         // not in a match
  matchmaking,  // searching for players
  starting,     // room found, loading questions
  inRound,      // active question on screen
  betweenRounds,// showing round result / leaderboard
  spectating,   // forfeited — waiting for match to end
  finished,     // match over, showing results
}

class GameState {
  // Match info
  final String? roomId;
  final String? userId;
  final String? username;
  final MatchPhase phase;
  final int totalRounds;

  // Current round
  final int currentRound;
  final Question? currentQuestion;
  final int? selectedAnswerIndex;  // null = not answered yet
  final int remainingSeconds;
  final bool roundExpired;

  // Scores
  final List<PlayerScore> leaderboard;
  final List<Player> players;

  // Round result (shown between rounds)
  final RoundResultEvent? lastRoundResult;

  // Match end
  final MatchEndEvent? matchEnd;

  // Error state
  final String? error;

  const GameState({
    this.roomId,
    this.userId,
    this.username,
    this.phase = MatchPhase.idle,
    this.totalRounds = 5,
    this.currentRound = 0,
    this.currentQuestion,
    this.selectedAnswerIndex,
    this.remainingSeconds = 30,
    this.roundExpired = false,
    this.leaderboard = const [],
    this.players = const [],
    this.lastRoundResult,
    this.matchEnd,
    this.error,
  });

  // My personal score from the leaderboard
  PlayerScore? get myScore =>
      leaderboard.where((s) => s.userId == userId).firstOrNull;

  // True once player has tapped an answer
  bool get hasAnswered => selectedAnswerIndex != null;

  GameState copyWith({
    String? roomId,
    String? userId,
    String? username,
    MatchPhase? phase,
    int? totalRounds,
    int? currentRound,
    Question? currentQuestion,
    int? selectedAnswerIndex,
    int? remainingSeconds,
    bool? roundExpired,
    List<PlayerScore>? leaderboard,
    List<Player>? players,
    RoundResultEvent? lastRoundResult,
    MatchEndEvent? matchEnd,
    String? error,
    bool clearQuestion = false,
    bool clearAnswer = false,
    bool clearError = false,
    bool clearRoundResult = false,
  }) {
    return GameState(
      roomId: roomId ?? this.roomId,
      userId: userId ?? this.userId,
      username: username ?? this.username,
      phase: phase ?? this.phase,
      totalRounds: totalRounds ?? this.totalRounds,
      currentRound: currentRound ?? this.currentRound,
      currentQuestion: clearQuestion ? null : (currentQuestion ?? this.currentQuestion),
      selectedAnswerIndex: clearAnswer ? null : (selectedAnswerIndex ?? this.selectedAnswerIndex),
      remainingSeconds: remainingSeconds ?? this.remainingSeconds,
      roundExpired: roundExpired ?? this.roundExpired,
      leaderboard: leaderboard ?? this.leaderboard,
      players: players ?? this.players,
      lastRoundResult: clearRoundResult ? null : (lastRoundResult ?? this.lastRoundResult),
      matchEnd: matchEnd ?? this.matchEnd,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

// ─────────────────────────────────────────
// NOTIFIER
// ─────────────────────────────────────────

class GameNotifier extends StateNotifier<GameState> {
  GameNotifier() : super(const GameState());

  StreamSubscription<GameEvent>? _eventSub;
  Timer? _countdownTimer;

  // ── Session setup ──────────────────────────────────────────

  void setUser(String userId, String username) {
    state = state.copyWith(userId: userId, username: username);
  }

  void startMatchmaking() {
    state = state.copyWith(phase: MatchPhase.matchmaking, clearError: true);
  }

  void cancelMatchmaking() {
    state = state.copyWith(phase: MatchPhase.idle);
  }

  // ── gRPC stream subscription ───────────────────────────────

  // Call this once when the gRPC StreamGameEvents stream is established.
  // Pass the stream of mapped GameEvent objects from your gRPC layer.
  void subscribeToGameEvents(Stream<GameEvent> eventStream) {
    _eventSub?.cancel();
    _eventSub = eventStream.listen(
      _handleEvent,
      onError: (e) {
        debugPrint('[GameProvider] Stream ERROR: $e');
        state = state.copyWith(
          error: 'Stream error: $e',
          phase: MatchPhase.idle,
        );
      },
      onDone: () {
        debugPrint('[GameProvider] Stream DONE — current phase: ${state.phase}');
        if (state.phase != MatchPhase.finished) {
          debugPrint('[GameProvider] Stream closed before MatchEnd! Treating as finished.');
          // Stream closed by server (game ended) — if we have scores, show results
          if (state.leaderboard.isNotEmpty) {
            final sorted = [...state.leaderboard]..sort((a, b) => b.score.compareTo(a.score));
            final winner = sorted.first;
            state = state.copyWith(
              phase: MatchPhase.finished,
              matchEnd: MatchEndEvent(
                roomId: state.roomId ?? '',
                winnerUserId: winner.userId,
                winnerUsername: winner.username,
                totalRounds: state.totalRounds,
                durationSeconds: 0,
                finalScores: state.leaderboard,
              ),
              leaderboard: state.leaderboard,
            );
          } else {
            state = state.copyWith(error: 'Connection lost');
          }
        }
      },
    );
  }

  // ── Event handlers (one per GameEvent subtype) ─────────────

  void _handleEvent(GameEvent event) {
    debugPrint('[GameProvider] Event: ${event.runtimeType}');

    // While spectating, only process leaderboard updates and match end
    if (state.phase == MatchPhase.spectating) {
      if (event is MatchEndEvent) {
        _onMatchEnd(event);
      } else if (event is LeaderboardUpdateEvent) {
        _onLeaderboard(event);
      }
      return;
    }

    switch (event) {
      case QuestionBroadcastEvent():
        _onQuestion(event);
      case LeaderboardUpdateEvent():
        _onLeaderboard(event);
      case RoundResultEvent():
        _onRoundResult(event);
      case MatchEndEvent():
        _onMatchEnd(event);
      case PlayerJoinedEvent():
        _onPlayerJoined(event);
      case TimerSyncEvent():
        _onTimerSync(event);
      case ReconnectingEvent():
        state = state.copyWith(
          error: 'Reconnecting… attempt ${event.attempt}/${event.maxAttempts}',
        );
      case ReconnectedEvent():
        state = state.copyWith(
          leaderboard: event.leaderboard,
          clearError: true,
        );
      case ReconnectFailedEvent():
        state = state.copyWith(
          error: event.reason,
          phase: MatchPhase.idle,
        );
    }
  }

  void _onQuestion(QuestionBroadcastEvent e) {
    _countdownTimer?.cancel();
    final totalSecs = (e.question.timeLimitMs / 1000).round();
    state = state.copyWith(
      phase: MatchPhase.inRound,
      currentRound: e.roundNumber,
      currentQuestion: e.question,
      remainingSeconds: totalSecs,
      roundExpired: false,
      clearAnswer: true,
      clearRoundResult: true,
    );
    // Client-side countdown — corrected by TimerSyncEvent when server sends one
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final remaining = state.remainingSeconds - 1;
      if (remaining <= 0) {
        t.cancel();
        state = state.copyWith(remainingSeconds: 0, roundExpired: true);
      } else {
        state = state.copyWith(remainingSeconds: remaining);
      }
    });
  }

  void _onLeaderboard(LeaderboardUpdateEvent e) {
    state = state.copyWith(leaderboard: e.scores);
  }

  void _onRoundResult(RoundResultEvent e) {
    _countdownTimer?.cancel();
    debugPrint('[GameProvider] RoundResult received — round ${e.roundNumber}, correctIndex=${e.correctIndex}');
    state = state.copyWith(
      phase: MatchPhase.betweenRounds,
      lastRoundResult: e,
      leaderboard: e.scores,
    );
  }

  void _onMatchEnd(MatchEndEvent e) {
    _countdownTimer?.cancel();
    debugPrint('[GameProvider] MatchEnd received — winner=${e.winnerUsername}, scores=${e.finalScores.length}');
    state = state.copyWith(
      phase: MatchPhase.finished,
      matchEnd: e,
      leaderboard: e.finalScores,
    );
    _eventSub?.cancel();
  }

  void _onPlayerJoined(PlayerJoinedEvent e) {
    final updated = [...state.players];
    final idx = updated.indexWhere((p) => p.userId == e.player.userId);
    if (idx >= 0) {
      updated[idx] = e.player;
    } else {
      updated.add(e.player);
    }
    state = state.copyWith(players: updated);
  }

  void _onTimerSync(TimerSyncEvent e) {
    final secs = e.remainingSeconds;
    state = state.copyWith(
      remainingSeconds: secs,
      roundExpired: secs == 0,
    );
  }

  // ── Player actions ─────────────────────────────────────────

  // Called when the player taps an answer option
  void submitAnswer(int answerIndex) {
    if (state.hasAnswered || state.roundExpired) return;
    state = state.copyWith(selectedAnswerIndex: answerIndex);
    // The actual gRPC SubmitAnswer call happens in the quiz screen widget
    // after calling this — this just locks the UI immediately (optimistic)
  }

  // ── Room setup (called when MatchFound arrives from matchmaking stream) ──

  void onMatchFound({
    required String roomId,
    required List<Player> players,
    required int totalRounds,
  }) {
    state = state.copyWith(
      roomId: roomId,
      players: players,
      totalRounds: totalRounds,
      phase: MatchPhase.starting,
    );
  }

  // ── Forfeit (spectate until match ends) ─────────────────────

  void forfeitMatch() {
    _countdownTimer?.cancel();
    // Keep _eventSub alive so we still receive MatchEnd from the server
    state = state.copyWith(phase: MatchPhase.spectating);
  }

  // ── Cleanup ────────────────────────────────────────────────

  void reset() {
    _eventSub?.cancel();
    _countdownTimer?.cancel();
    state = const GameState();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────
// PROVIDER
// ─────────────────────────────────────────

// The single global provider for all game state.
// Access anywhere with: ref.watch(gameProvider)
// Mutate with:          ref.read(gameProvider.notifier).someMethod()
final gameProvider = StateNotifierProvider<GameNotifier, GameState>(
  (ref) => GameNotifier(),
);

// Convenience derived providers — use these in widgets to avoid
// rebuilding the whole tree when only one field changes.

final currentQuestionProvider = Provider<Question?>(
  (ref) => ref.watch(gameProvider).currentQuestion,
);

final leaderboardProvider = Provider<List<PlayerScore>>(
  (ref) => ref.watch(gameProvider).leaderboard,
);

final timerProvider = Provider<int>(
  (ref) => ref.watch(gameProvider).remainingSeconds,
);

final matchPhaseProvider = Provider<MatchPhase>(
  (ref) => ref.watch(gameProvider).phase,
);

final myScoreProvider = Provider<PlayerScore?>(
  (ref) => ref.watch(gameProvider).myScore,
);