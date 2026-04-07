import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grpc/grpc.dart';

import '../models/game_event.dart' as app;
import '../proto/quiz.pb.dart' as pb;
import '../proto/quiz.pbgrpc.dart' as pbgrpc;

// ─────────────────────────────────────────
// CHANNEL
// ─────────────────────────────────────────

// Native (iOS / Android / macOS) — direct gRPC on port 50051
ClientChannel _buildChannel() {
  return ClientChannel(
    'localhost',
    port: 50051,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
}

// ─────────────────────────────────────────
// SERVICE CLASS
// ─────────────────────────────────────────

class GameService {
  late final ClientChannel _channel;
  late final pbgrpc.MatchmakingServiceClient _matchmakingClient;
  late final pbgrpc.QuizServiceClient _quizClient;

  GameService() {
    _channel = _buildChannel();
    _matchmakingClient = pbgrpc.MatchmakingServiceClient(_channel);
    _quizClient = pbgrpc.QuizServiceClient(_channel);
  }

  // ── 1. Join Matchmaking ──────────────────────────────────────

  Future<bool> joinMatchmaking(String userId, double rating) async {
    try {
      final req = pb.JoinRequest()
        ..userId = userId
        ..username = userId  // use userId as display name until real auth
        ..rating = rating.toInt();
      final res = await _matchmakingClient.joinMatchmaking(req);
      return res.success;
    } on GrpcError catch (e) {
      debugPrint('[GameService] joinMatchmaking error: ${e.codeName} — ${e.message}');
      rethrow;
    }
  }

  // ── 2. Subscribe to Match ────────────────────────────────────

  /// Long-lived stream that receives MatchFound / MatchCancelled.
  /// Yields [MatchmakingUpdate] objects the UI can react to.
  Stream<MatchmakingUpdate> subscribeToMatch(String userId) async* {
    final req = pb.SubscribeRequest()..userId = userId;
    try {
      await for (final event in _matchmakingClient.subscribeToMatch(req)) {
        if (event.hasMatchFound()) {
          final mf = event.matchFound;
          yield MatchmakingUpdate(
            matchFound: true,
            roomId: mf.roomId,
            totalRounds: mf.totalRounds,
            players: mf.players.map(_mapPlayer).toList(),
          );
        } else if (event.hasWaitingUpdate()) {
          yield MatchmakingUpdate(
            playersFound: event.waitingUpdate.playersInPool,
            totalNeeded: 4,
          );
        } else if (event.hasMatchCancelled()) {
          yield MatchmakingUpdate(cancelled: true);
        }
      }
    } on GrpcError catch (e) {
      debugPrint('[GameService] subscribeToMatch error: ${e.codeName} — ${e.message}');
      rethrow;
    }
  }

  // ── 3. Stream Game Events ────────────────────────────────────

  Stream<app.GameEvent> streamGameEvents(String roomId, String userId) {
    final req = pb.StreamRequest()
      ..roomId = roomId
      ..userId = userId;

    return _quizClient
        .streamGameEvents(req)
        .map(_mapProtoEvent)
        .where((e) => e != null)
        .cast<app.GameEvent>()
        .handleError((e) {
      debugPrint('[GameService] streamGameEvents error: $e');
      throw e;
    });
  }

  // ── 4. Submit Answer ─────────────────────────────────────────

  Future<bool> submitAnswer({
    required String roomId,
    required String userId,
    required int roundNumber,
    required String questionId,
    required int answerIndex,
  }) async {
    try {
      final req = pb.AnswerRequest()
        ..roomId = roomId
        ..userId = userId
        ..roundNumber = roundNumber
        ..questionId = questionId
        ..answerIndex = answerIndex
        ..submittedAtMs = Int64(DateTime.now().millisecondsSinceEpoch);
      final ack = await _quizClient.submitAnswer(req);
      return ack.received;
    } on GrpcError catch (e) {
      debugPrint('[GameService] submitAnswer error: ${e.codeName} — ${e.message}');
      rethrow;
    }
  }

  // ── 5. Leave Matchmaking ─────────────────────────────────────

  Future<void> leaveMatchmaking(String userId) async {
    try {
      final req = pb.LeaveRequest()..userId = userId;
      await _matchmakingClient.leaveMatchmaking(req);
    } on GrpcError catch (e) {
      debugPrint('[GameService] leaveMatchmaking error: ${e.codeName}');
    }
  }

  // ── 6. Get Leaderboard ───────────────────────────────────────

  Future<List<app.PlayerScore>> getLeaderboard(String roomId) async {
    // Leaderboard is pushed via stream events — stub fallback only
    return [];
  }

  // ── Cleanup ──────────────────────────────────────────────────

  Future<void> dispose() async {
    await _channel.shutdown();
  }

  // ─────────────────────────────────────────
  // PROTO → DART MAPPERS
  // ─────────────────────────────────────────

  app.GameEvent? _mapProtoEvent(pb.GameEvent proto) {
    if (proto.hasQuestion()) {
      final q = proto.question;
      return app.QuestionBroadcastEvent(
        roundNumber: q.roundNumber,
        deadlineMs: q.deadlineMs.toInt(),
        question: app.Question(
          questionId: q.question.questionId,
          text: q.question.text,
          options: q.question.options.toList(),
          difficulty: _mapDifficulty(q.question.difficulty),
          topic: q.question.topic,
          timeLimitMs: q.question.timeLimitMs,
        ),
      );
    }
    if (proto.hasLeaderboard()) {
      final lb = proto.leaderboard;
      return app.LeaderboardUpdateEvent(
        roomId: lb.roomId,
        roundNumber: lb.roundNumber,
        scores: lb.scores.map(_mapScore).toList(),
      );
    }
    if (proto.hasTimerSync()) {
      final ts = proto.timerSync;
      return app.TimerSyncEvent(
        roundNumber: ts.roundNumber,
        serverTimeMs: ts.serverTimeMs.toInt(),
        deadlineMs: ts.deadlineMs.toInt(),
      );
    }
    if (proto.hasRoundResult()) {
      final rr = proto.roundResult;
      return app.RoundResultEvent(
        roundNumber: rr.roundNumber,
        questionId: rr.questionId,
        correctIndex: rr.correctIndex,
        fastestUserId: rr.fastestUserId,
        scores: rr.scores.map(_mapScore).toList(),
      );
    }
    if (proto.hasMatchEnd()) {
      final me = proto.matchEnd;
      return app.MatchEndEvent(
        roomId: me.roomId,
        winnerUserId: me.winnerUserId,
        winnerUsername: me.winnerUsername,
        totalRounds: me.totalRounds,
        durationSeconds: me.durationSeconds,
        finalScores: me.finalScores.map(_mapScore).toList(),
      );
    }
    if (proto.hasPlayerJoined()) {
      final pj = proto.playerJoined;
      return app.PlayerJoinedEvent(
        roundNumber: pj.roundNumber,
        player: _mapPlayer(pj.player),
      );
    }
    // Unknown event type — log and return null so the stream keeps running.
    debugPrint('[GameService] Unknown GameEvent type received: $proto');
    return null;
  }

  app.PlayerScore _mapScore(pb.PlayerScore s) => app.PlayerScore(
        userId: s.userId,
        username: s.username,
        score: s.score,
        rank: s.rank,
        answersCorrect: s.answersCorrect,
        avgResponseMs: s.avgResponseMs,
        isConnected: s.isConnected,
      );

  app.Player _mapPlayer(pb.Player p) => app.Player(
        userId: p.userId,
        username: p.username,
        rating: p.rating,
      );

  app.Difficulty _mapDifficulty(pb.Difficulty d) {
    switch (d) {
      case pb.Difficulty.EASY:
        return app.Difficulty.easy;
      case pb.Difficulty.MEDIUM:
        return app.Difficulty.medium;
      case pb.Difficulty.HARD:
        return app.Difficulty.hard;
      default:
        return app.Difficulty.unspecified;
    }
  }
}

// ─────────────────────────────────────────
// MATCHMAKING UPDATE MODEL
// ─────────────────────────────────────────

class MatchmakingUpdate {
  final int playersFound;
  final int totalNeeded;
  final bool matchFound;
  final bool cancelled;
  final String? roomId;
  final int totalRounds;
  final List<app.Player> players;

  const MatchmakingUpdate({
    this.playersFound = 1,
    this.totalNeeded = 4,
    this.matchFound = false,
    this.cancelled = false,
    this.roomId,
    this.totalRounds = 5,
    this.players = const [],
  });
}

// ─────────────────────────────────────────
// RIVERPOD PROVIDERS
// ─────────────────────────────────────────

final gameServiceProvider = Provider<GameService>((ref) {
  final service = GameService();
  ref.onDispose(service.dispose);
  return service;
});

final gameEventStreamProvider =
    StreamProvider.family<app.GameEvent, (String, String)>(
  (ref, args) {
    final (roomId, userId) = args;
    final service = ref.watch(gameServiceProvider);
    return service.streamGameEvents(roomId, userId);
  },
);
