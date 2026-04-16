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

  // Streak tracking
  final int currentAnswerStreak; // consecutive correct answers this match
  final int maxAnswerStreak;     // best streak this match

  // Win streak: consecutive rounds where THIS player was fastest AND correct
  final int currentWinStreak;
  final int maxWinStreak;

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
    this.currentAnswerStreak = 0,
    this.maxAnswerStreak = 0,
    this.currentWinStreak = 0,
    this.maxWinStreak = 0,
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
    int? currentAnswerStreak,
    int? maxAnswerStreak,
    int? currentWinStreak,
    int? maxWinStreak,
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
      currentAnswerStreak: currentAnswerStreak ?? this.currentAnswerStreak,
      maxAnswerStreak: maxAnswerStreak ?? this.maxAnswerStreak,
      currentWinStreak: currentWinStreak ?? this.currentWinStreak,
      maxWinStreak: maxWinStreak ?? this.maxWinStreak,
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
  DateTime? _matchStartedAt;

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
        debugPrint('[GameProvider] Stream ERROR: $e (phase: ${state.phase})');
        // If spectating, stream error means match ended — show results
        if (state.phase == MatchPhase.spectating && state.leaderboard.isNotEmpty) {
          _buildSyntheticMatchEnd();
          return;
        }
        state = state.copyWith(
          error: 'Stream error: $e',
          phase: MatchPhase.idle,
        );
      },
      onDone: () {
        debugPrint('[GameProvider] Stream DONE — current phase: ${state.phase}');
        if (state.phase != MatchPhase.finished) {
          _buildSyntheticMatchEnd();
        }
      },
    );
  }

  // ── Event handlers (one per GameEvent subtype) ─────────────

  void _buildSyntheticMatchEnd() {
    debugPrint('[GameProvider] Building synthetic MatchEnd from leaderboard');
    if (state.leaderboard.isNotEmpty) {
      final sorted = [...state.leaderboard]..sort((a, b) => b.score.compareTo(a.score));
      final winner = sorted.first;
      final duration = _matchStartedAt != null
          ? DateTime.now().difference(_matchStartedAt!).inSeconds
          : 0;
      state = state.copyWith(
        phase: MatchPhase.finished,
        matchEnd: MatchEndEvent(
          roomId: state.roomId ?? '',
          winnerUserId: winner.userId,
          winnerUsername: winner.username,
          totalRounds: state.totalRounds,
          durationSeconds: duration,
          finalScores: state.leaderboard,
        ),
      );
    } else {
      state = state.copyWith(error: 'Connection lost');
    }
  }

  void _handleEvent(GameEvent event) {
    debugPrint('[GameProvider] Event: ${event.runtimeType}');

    // While spectating, process limited events (no questions/timer/answers)
    if (state.phase == MatchPhase.spectating) {
      debugPrint('[GameProvider] SPECTATING event: ${event.runtimeType}');
      if (event is MatchEndEvent) {
        debugPrint('[GameProvider] SPECTATING: MatchEnd received!');
        _onMatchEnd(event);
      } else if (event is LeaderboardUpdateEvent) {
        _onLeaderboard(event);
      } else if (event is RoundResultEvent) {
        debugPrint('[GameProvider] SPECTATING: RoundResult round=${event.roundNumber}/${state.totalRounds}');
        state = state.copyWith(
          currentRound: event.roundNumber,
          leaderboard: event.scores,
        );
        // Last round → match is over, build results instantly
        if (event.roundNumber >= state.totalRounds) {
          debugPrint('[GameProvider] SPECTATING: Last round! Building synthetic MatchEnd');
          _buildSyntheticMatchEnd();
        }
        return;
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
    // Reconnect catch-up guard: the server re-sends currentQuestion to late-joiners.
    // If we're already showing this exact round/question (e.g. after a brief disconnect),
    // ignore it — don't clear the user's selected answer or restart the countdown.
    if (state.phase == MatchPhase.inRound &&
        state.currentRound == e.roundNumber &&
        state.currentQuestion?.questionId == e.question.questionId) {
      debugPrint('[GameProvider] _onQuestion: catch-up duplicate for round ${e.roundNumber}, skipping');
      return;
    }

    _countdownTimer?.cancel();
    _matchStartedAt ??= DateTime.now(); // track match start (first question)
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

    // Update answer streak: if player's answer matches correct, increment; else reset
    final wasCorrect = state.selectedAnswerIndex == e.correctIndex;
    final newStreak = wasCorrect ? state.currentAnswerStreak + 1 : 0;
    final newMax = newStreak > state.maxAnswerStreak ? newStreak : state.maxAnswerStreak;

    // Update win streak: correct AND fastest this round
    final wasWinner = wasCorrect && e.fastestUserId == state.userId;
    final newWinStreak = wasWinner ? state.currentWinStreak + 1 : 0;
    final newMaxWin = newWinStreak > state.maxWinStreak ? newWinStreak : state.maxWinStreak;

    state = state.copyWith(
      phase: MatchPhase.betweenRounds,
      lastRoundResult: e,
      leaderboard: e.scores,
      currentAnswerStreak: newStreak,
      maxAnswerStreak: newMax,
      currentWinStreak: newWinStreak,
      maxWinStreak: newMaxWin,
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

  /// Immediately build results and finish — used when player forfeits.
  void forfeitToResults() {
    _eventSub?.cancel();
    _countdownTimer?.cancel();
    _buildSyntheticMatchEnd();
  }

  // ── Cleanup ────────────────────────────────────────────────

  void reset() {
    _eventSub?.cancel();
    _countdownTimer?.cancel();
    _matchStartedAt = null;
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