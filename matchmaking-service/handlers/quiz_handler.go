package handlers

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	goredis "github.com/gomodule/redigo/redis"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	quiz "github.com/yourorg/quiz-battle/proto/quiz"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"

	"quiz-battle/matchmaking/rabbitmq"
	rdb "quiz-battle/matchmaking/redis"
)

// ─────────────────────────────────────────
// ROOM HUB — fan-out broadcasting per room
// ─────────────────────────────────────────

// gameRoom holds all active subscriber channels for one room plus
// a sync.Once so the game loop starts exactly once.
type gameRoom struct {
	mu        sync.Mutex
	subs      []chan *quiz.GameEvent
	startOnce sync.Once
	totalRounds int
}

func (r *gameRoom) addSub(ch chan *quiz.GameEvent) {
	r.mu.Lock()
	r.subs = append(r.subs, ch)
	r.mu.Unlock()
}

func (r *gameRoom) removeSub(ch chan *quiz.GameEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	updated := r.subs[:0]
	for _, s := range r.subs {
		if s != ch {
			updated = append(updated, s)
		}
	}
	r.subs = updated
}

func (r *gameRoom) broadcast(event *quiz.GameEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, ch := range r.subs {
		select {
		case ch <- event:
		default: // drop for slow consumers — they'll catch up via TimerSync
		}
	}
}

func (r *gameRoom) closeAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, ch := range r.subs {
		close(ch)
	}
	r.subs = nil
}

// roomHub manages per-room gameRoom instances.
type roomHub struct {
	mu    sync.Mutex
	rooms map[string]*gameRoom
}

func newRoomHub() *roomHub {
	return &roomHub{rooms: make(map[string]*gameRoom)}
}

func (h *roomHub) getOrCreate(roomID string, totalRounds int) *gameRoom {
	h.mu.Lock()
	defer h.mu.Unlock()
	r, ok := h.rooms[roomID]
	if !ok {
		r = &gameRoom{totalRounds: totalRounds}
		h.rooms[roomID] = r
	}
	return r
}

func (h *roomHub) delete(roomID string) {
	h.mu.Lock()
	delete(h.rooms, roomID)
	h.mu.Unlock()
}

// ─────────────────────────────────────────
// QUIZ SERVICE HANDLER
// ─────────────────────────────────────────

// QuizServiceHandler implements quiz.QuizServiceServer.
type QuizServiceHandler struct {
	quiz.UnimplementedQuizServiceServer

	redisPool *goredis.Pool
	mongoDB   *mongo.Database
	publisher *rabbitmq.Publisher
	quizSvc   *QuizService
	hub       *roomHub
}

func NewQuizServiceHandler(
	redisPool *goredis.Pool,
	mongoDB *mongo.Database,
	publisher *rabbitmq.Publisher,
) *QuizServiceHandler {
	return &QuizServiceHandler{
		redisPool: redisPool,
		mongoDB:   mongoDB,
		publisher: publisher,
		quizSvc:   NewQuizService(redisPool, mongoDB, publisher),
		hub:       newRoomHub(),
	}
}

// Register wires this handler into the gRPC server.
func (h *QuizServiceHandler) Register(s *grpc.Server) {
	quiz.RegisterQuizServiceServer(s, h)
	log.Println("✅ QuizService registered")
}

// ─────────────────────────────────────────
// GetRoomQuestions
// ─────────────────────────────────────────
// Returns the list of questions for a room (without correct answers).

func (h *QuizServiceHandler) GetRoomQuestions(ctx context.Context, req *quiz.RoomRequest) (*quiz.QuestionsResponse, error) {
	if req.RoomId == "" {
		return nil, status.Error(codes.InvalidArgument, "room_id is required")
	}

	conn := h.redisPool.Get()
	defer conn.Close()

	// Fetch question IDs from the Redis list (non-destructive LRANGE)
	questionsKey := fmt.Sprintf("room:%s:questions", req.RoomId)
	ids, err := goredis.Strings(conn.Do("LRANGE", questionsKey, 0, -1))
	if err != nil {
		return nil, status.Errorf(codes.Internal, "redis LRANGE: %v", err)
	}

	if len(ids) == 0 {
		return nil, status.Error(codes.NotFound, "no questions found for room — call SelectQuestionsForRoom first")
	}

	// Fetch questions from MongoDB in order
	protoQuestions := make([]*quiz.Question, 0, len(ids))
	for _, id := range ids {
		oid, err := primitive.ObjectIDFromHex(id)
		if err != nil {
			continue
		}

		var q Question
		fetchCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = h.mongoDB.Collection("questions").FindOne(fetchCtx, bson.M{"_id": oid}).Decode(&q)
		cancel()
		if err != nil {
			log.Printf("⚠️  GetRoomQuestions: skip missing question %s: %v", id, err)
			continue
		}

		protoQuestions = append(protoQuestions, &quiz.Question{
			QuestionId:  id,
			Text:        q.Text,
			Options:     q.Options,
			Difficulty:  difficultyFromString(q.Difficulty),
			Topic:       q.Topic,
			TimeLimitMs: 30_000,
		})
	}

	return &quiz.QuestionsResponse{
		RoomId:      req.RoomId,
		Questions:   protoQuestions,
		TotalRounds: int32(len(protoQuestions)),
	}, nil
}

// ─────────────────────────────────────────
// SubmitAnswer
// ─────────────────────────────────────────
// Publishes an answer.submitted event to RabbitMQ. The consumer
// processes it, validates against MongoDB, and updates the leaderboard.

func (h *QuizServiceHandler) SubmitAnswer(ctx context.Context, req *quiz.AnswerRequest) (*quiz.AnswerAck, error) {
	if req.RoomId == "" || req.UserId == "" || req.QuestionId == "" {
		return nil, status.Error(codes.InvalidArgument, "room_id, user_id, and question_id are required")
	}

	// Fetch the round start time stored by RunRound for response-time calculation.
	var roundStartedAtMs int64
	rdConn := h.redisPool.Get()
	if startedAt, err := goredis.Int64(rdConn.Do("GET",
		fmt.Sprintf("room:%s:round:%d:started_at", req.RoomId, req.RoundNumber),
	)); err == nil {
		roundStartedAtMs = startedAt
	}
	rdConn.Close()

	event := rabbitmq.AnswerSubmittedEvent{
		RoomID:           req.RoomId,
		UserID:           req.UserId,
		RoundNumber:      int(req.RoundNumber),
		QuestionID:       req.QuestionId,
		AnswerIndex:      int(req.AnswerIndex),
		SubmittedAtMs:    req.SubmittedAtMs,
		RoundStartedAtMs: roundStartedAtMs,
	}

	if err := h.publisher.PublishAnswerSubmitted(event); err != nil {
		log.Printf("⚠️  SubmitAnswer publish failed room=%s user=%s: %v", req.RoomId, req.UserId, err)
		return nil, status.Errorf(codes.Internal, "failed to record answer: %v", err)
	}

	log.Printf("📩 Answer submitted — room: %s user: %s round: %d idx: %d",
		req.RoomId, req.UserId, req.RoundNumber, req.AnswerIndex)

	return &quiz.AnswerAck{
		Received: true,
		Message:  "Answer recorded",
	}, nil
}

// ─────────────────────────────────────────
// StreamGameEvents
// ─────────────────────────────────────────
// Long-lived server stream. Events are broadcast to all subscribers in the room.
// The first player to connect starts the game loop goroutine.

func (h *QuizServiceHandler) StreamGameEvents(req *quiz.StreamRequest, stream grpc.ServerStreamingServer[quiz.GameEvent]) error {
	if req.RoomId == "" || req.UserId == "" {
		return status.Error(codes.InvalidArgument, "room_id and user_id are required")
	}

	roomID := req.RoomId

	// Determine total rounds from Redis question list length
	conn := h.redisPool.Get()
	totalRounds, _ := goredis.Int(conn.Do("LLEN", fmt.Sprintf("room:%s:questions", roomID)))
	conn.Close()

	if totalRounds == 0 {
		return status.Error(codes.FailedPrecondition, "room has no questions — call SelectQuestionsForRoom first")
	}

	room := h.hub.getOrCreate(roomID, totalRounds)

	// Subscribe with a buffered channel (buffer = 2× totalRounds to absorb bursts)
	ch := make(chan *quiz.GameEvent, totalRounds*2+50)
	room.addSub(ch)
	defer room.removeSub(ch)

	log.Printf("📺 Player %s subscribed to room %s game stream", req.UserId, roomID)

	// The first subscriber triggers the game loop (subsequent ones just receive)
	room.startOnce.Do(func() {
		go h.runGameLoop(roomID, room)
	})

	ctx := stream.Context()
	for {
		select {
		case <-ctx.Done():
			log.Printf("📴 Player %s disconnected from room %s", req.UserId, roomID)
			return nil

		case event, ok := <-ch:
			if !ok {
				// Channel closed — game ended
				return nil
			}
			if err := stream.Send(event); err != nil {
				return err
			}
		}
	}
}

// ─────────────────────────────────────────
// GAME LOOP
// ─────────────────────────────────────────

// runGameLoop orchestrates all rounds for a room, broadcasting events to every
// connected player. Called exactly once per room via sync.Once.
func (h *QuizServiceHandler) runGameLoop(roomID string, room *gameRoom) {
	defer func() {
		room.closeAll()
		h.hub.delete(roomID)
		log.Printf("🏁 Game loop finished for room %s", roomID)
	}()

	// Brief lobby wait so all players can subscribe before round 1 starts
	log.Printf("⏳ Room %s: waiting 5s for players to subscribe…", roomID)
	time.Sleep(5 * time.Second)

	ctx := context.Background()

	for round := 1; round <= room.totalRounds; round++ {
		log.Printf("🎯 Room %s: starting round %d/%d", roomID, round, room.totalRounds)

		broadcastFn := func(event *quiz.GameEvent) {
			room.broadcast(event)
		}

		if err := h.quizSvc.RunRound(ctx, roomID, round, broadcastFn); err != nil {
			log.Printf("❌ RunRound failed room=%s round=%d: %v", roomID, round, err)
			return
		}

		// After each round: fetch and broadcast the updated leaderboard
		scores, err := h.buildLeaderboardEvent(roomID, round)
		if err != nil {
			log.Printf("⚠️  buildLeaderboard room=%s round=%d: %v", roomID, round, err)
		} else {
			room.broadcast(scores)
		}

		// Brief between-round pause (show leaderboard to players)
		if round < room.totalRounds {
			time.Sleep(5 * time.Second)
		}
	}

	// All rounds done — broadcast MatchEnd
	matchEnd, err := h.buildMatchEndEvent(roomID, room.totalRounds)
	if err != nil {
		log.Printf("⚠️  buildMatchEnd room=%s: %v", roomID, err)
		return
	}
	room.broadcast(matchEnd)
}

// ─────────────────────────────────────────
// LEADERBOARD HELPERS
// ─────────────────────────────────────────

func (h *QuizServiceHandler) buildPlayerScores(roomID string) ([]*quiz.PlayerScore, error) {
	entries, err := rdb.GetLeaderboard(h.redisPool, roomID)
	if err != nil {
		return nil, err
	}

	userIDs := make([]string, len(entries))
	for i, e := range entries {
		userIDs[i] = e.UserID
	}

	usernames, correctCounts, avgResponseMs, err := rdb.GetPlayerMeta(h.redisPool, roomID, userIDs)
	if err != nil {
		log.Printf("⚠️  GetPlayerMeta room=%s: %v — metadata will be empty", roomID, err)
		usernames = map[string]string{}
		correctCounts = map[string]int{}
		avgResponseMs = map[string]int{}
	}

	scores := make([]*quiz.PlayerScore, len(entries))
	for i, e := range entries {
		scores[i] = &quiz.PlayerScore{
			UserId:         e.UserID,
			Username:       usernames[e.UserID],
			Score:          int32(e.Score),
			Rank:           int32(e.Rank),
			AnswersCorrect: int32(correctCounts[e.UserID]),
			AvgResponseMs:  int32(avgResponseMs[e.UserID]),
		}
	}
	return scores, nil
}

func (h *QuizServiceHandler) buildLeaderboardEvent(roomID string, roundNum int) (*quiz.GameEvent, error) {
	scores, err := h.buildPlayerScores(roomID)
	if err != nil {
		return nil, err
	}

	return &quiz.GameEvent{
		Event: &quiz.GameEvent_Leaderboard{
			Leaderboard: &quiz.LeaderboardUpdate{
				RoomId:      roomID,
				RoundNumber: int32(roundNum),
				Scores:      scores,
			},
		},
	}, nil
}

func (h *QuizServiceHandler) buildMatchEndEvent(roomID string, totalRounds int) (*quiz.GameEvent, error) {
	scores, err := h.buildPlayerScores(roomID)
	if err != nil {
		return nil, err
	}

	var winnerUserID, winnerUsername string
	if len(scores) > 0 {
		winnerUserID = scores[0].UserId
		winnerUsername = scores[0].Username
	}

	return &quiz.GameEvent{
		Event: &quiz.GameEvent_MatchEnd{
			MatchEnd: &quiz.MatchEnd{
				RoomId:          roomID,
				WinnerUserId:    winnerUserID,
				WinnerUsername:  winnerUsername,
				TotalRounds:     int32(totalRounds),
				FinalScores:     scores,
			},
		},
	}, nil
}
