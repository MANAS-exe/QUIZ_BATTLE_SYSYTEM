package handlers

import (
	"context"
	"encoding/json"
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
	mu          sync.Mutex
	subs        []chan *quiz.GameEvent
	connected   map[string]bool // tracks stream subscriptions (includes spectators)
	active      map[string]bool // tracks who is actively playing (not forfeited)
	startOnce   sync.Once
	totalRounds int
}

func (r *gameRoom) addSub(ch chan *quiz.GameEvent, userID string) {
	r.mu.Lock()
	r.subs = append(r.subs, ch)
	if r.connected == nil {
		r.connected = make(map[string]bool)
	}
	if r.active == nil {
		r.active = make(map[string]bool)
	}
	r.connected[userID] = true
	r.active[userID] = true
	r.mu.Unlock()
}

func (r *gameRoom) removeSub(ch chan *quiz.GameEvent, userID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	updated := r.subs[:0]
	for _, s := range r.subs {
		if s != ch {
			updated = append(updated, s)
		}
	}
	r.subs = updated
	delete(r.connected, userID)
	delete(r.active, userID)
}

// markForfeited removes a player from active but keeps their stream subscription.
func (r *gameRoom) markForfeited(userID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.active, userID)
	log.Printf("👋 Player %s forfeited (still spectating)", userID)
}

// activeCount returns the number of players still actively playing.
func (r *gameRoom) activeCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.active)
}

// lastActiveUserID returns the userID of the sole remaining active player.
func (r *gameRoom) lastActiveUserID() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	for uid := range r.active {
		return uid
	}
	return ""
}

func (r *gameRoom) broadcast(event *quiz.GameEvent) {
	// Critical events (RoundResult, MatchEnd) must never be dropped.
	// TimerSync can be dropped safely — clients have their own countdown.
	critical := event.GetRoundResult() != nil || event.GetMatchEnd() != nil || event.GetQuestion() != nil || event.GetLeaderboard() != nil

	r.mu.Lock()
	defer r.mu.Unlock()
	for _, ch := range r.subs {
		if critical {
			// Blocking send with timeout — ensure delivery
			select {
			case ch <- event:
			case <-time.After(3 * time.Second):
				log.Printf("⚠️  Critical event dropped for slow subscriber (channel full)")
			}
		} else {
			select {
			case ch <- event:
			default: // drop TimerSync for slow consumers
			}
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
	if req.RoomId == "" || req.UserId == "" {
		return nil, status.Error(codes.InvalidArgument, "room_id and user_id are required")
	}

	// answer_index = -1 signals a forfeit — mark player as inactive
	if req.AnswerIndex == -1 {
		room := h.hub.getOrCreate(req.RoomId, 0)
		room.markForfeited(req.UserId)
		return &quiz.AnswerAck{Received: true, Message: "Forfeited"}, nil
	}

	if req.QuestionId == "" {
		return nil, status.Error(codes.InvalidArgument, "question_id is required")
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

	// Buffer must handle worst case: ~35 events/round (question + 30 timersync + result + leaderboard + matchend)
	ch := make(chan *quiz.GameEvent, totalRounds*40)
	room.addSub(ch, req.UserId)
	defer room.removeSub(ch, req.UserId)

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

	var autoWinnerID string       // set if match ends early due to disconnections
	var playedQuestionIDs []string // track question IDs for match_history

	for round := 1; round <= room.totalRounds; round++ {
		// ── Check before each round: end match if <= 1 active player
		active := room.activeCount()
		if active == 0 {
			log.Printf("🏁 Room %s: no active players — ending match", roomID)
			break
		}
		if active == 1 {
			autoWinnerID = room.lastActiveUserID()
			log.Printf("🏆 Room %s: only 1 active player — %s wins by default", roomID, autoWinnerID)
			break
		}

		log.Printf("🎯 Room %s: starting round %d/%d (%d active players)", roomID, round, room.totalRounds, active)

		broadcastFn := func(event *quiz.GameEvent) {
			room.broadcast(event)
		}

		roundInfo, err := h.quizSvc.RunRound(ctx, roomID, round, broadcastFn, room.activeCount)
		if err != nil {
			log.Printf("❌ RunRound failed room=%s round=%d: %v", roomID, round, err)
			return
		}
		playedQuestionIDs = append(playedQuestionIDs, roundInfo.QuestionID)

		// Check again after round — players may have forfeited mid-round
		if room.activeCount() == 0 {
			log.Printf("🏁 Room %s: no active players after round %d — ending match", roomID, round)
			break
		}
		if room.activeCount() == 1 {
			autoWinnerID = room.lastActiveUserID()
			log.Printf("🏆 Room %s: 1 active player after round %d — %s wins by default", roomID, round, autoWinnerID)
			// Still broadcast this round's result before ending
		}

		// Small delay so scoring consumer can finish before we read leaderboard
		time.Sleep(1 * time.Second)

		// ── Broadcast RoundResult with correct answer ──
		roundResult, err := h.buildRoundResultEvent(roomID, round, roundInfo)
		if err != nil {
			log.Printf("⚠️  buildRoundResult room=%s round=%d: %v", roomID, round, err)
		} else {
			room.broadcast(roundResult)
		}

		// After each round: fetch and broadcast the updated leaderboard
		scores, err := h.buildLeaderboardEvent(roomID, round)
		if err != nil {
			log.Printf("⚠️  buildLeaderboard room=%s round=%d: %v", roomID, round, err)
		} else {
			room.broadcast(scores)
		}

		// If auto-winner was set mid-round, end now (don't wait 5s for next round)
		if autoWinnerID != "" {
			time.Sleep(2 * time.Second) // brief pause to show last result
			break
		}

		// Pause to show leaderboard + correct answer before next round
		time.Sleep(5 * time.Second)
	}

	// All rounds done (or early end) — broadcast MatchEnd
	matchEnd, err := h.buildMatchEndEvent(roomID, room.totalRounds, autoWinnerID)
	if err != nil {
		log.Printf("⚠️  buildMatchEnd room=%s: %v", roomID, err)
		return
	}
	room.broadcast(matchEnd)

	// Update player ratings in MongoDB based on XP earned
	h.updatePlayerRatings(matchEnd)

	// Save played questions to match_history so they're excluded next time
	h.saveMatchHistory(matchEnd, playedQuestionIDs)

	// Give clients time to receive MatchEnd before closeAll() in defer
	time.Sleep(2 * time.Second)
}

func (h *QuizServiceHandler) buildRoundResultEvent(roomID string, roundNum int, info *RoundInfo) (*quiz.GameEvent, error) {
	scores, err := h.buildPlayerScores(roomID)
	if err != nil {
		return nil, err
	}

	// Find fastest CORRECT answerer for this round
	fastestUserID, fastestUsername := h.findFastestCorrectAnswer(roomID, roundNum, info.CorrectIndex)

	return &quiz.GameEvent{
		Event: &quiz.GameEvent_RoundResult{
			RoundResult: &quiz.RoundResult{
				RoundNumber:       int32(roundNum),
				QuestionId:        info.QuestionID,
				CorrectIndex:      int32(info.CorrectIndex),
				Scores:            scores,
				FastestUserId:     fastestUserID,
				CorrectAnswerText: info.CorrectAnswerText,
				FastestUsername:    fastestUsername,
			},
		},
	}, nil
}

// findFastestCorrectAnswer checks the answers hash for this round and finds who
// answered correctly. It then cross-references with response times to find the fastest.
// Returns empty strings if no one answered correctly.
func (h *QuizServiceHandler) findFastestCorrectAnswer(roomID string, roundNum int, correctIndex int) (userID, username string) {
	conn := h.redisPool.Get()
	defer conn.Close()

	// Get all answers for this round: {userId: answerIndex, ...}
	answersKey := fmt.Sprintf("room:%s:answers:%d", roomID, roundNum)
	answers, err := goredis.StringMap(conn.Do("HGETALL", answersKey))
	if err != nil || len(answers) == 0 {
		return "", ""
	}

	// Get response times: {userId: totalMs, ...}
	sumKey := fmt.Sprintf("room:%s:response_sum", roomID)
	countKey := fmt.Sprintf("room:%s:response_count", roomID)

	// Collect userIDs who answered correctly
	var correctUsers []string
	for uid, ansStr := range answers {
		var idx int
		fmt.Sscanf(ansStr, "%d", &idx)
		if idx == correctIndex {
			correctUsers = append(correctUsers, uid)
		}
	}

	if len(correctUsers) == 0 {
		return "", "" // no one got it right
	}

	// If only one correct, that's the fastest
	if len(correctUsers) == 1 {
		uid := correctUsers[0]
		name := h.getUsernameFromRedis(conn, roomID, uid)
		return uid, name
	}

	// Multiple correct — find the one with lowest avg response time
	// (response_sum / response_count gives avg, lower = faster)
	bestUID := correctUsers[0]
	bestAvg := int64(999999999)
	for _, uid := range correctUsers {
		sum, _ := goredis.Int64(conn.Do("HGET", sumKey, uid))
		cnt, _ := goredis.Int64(conn.Do("HGET", countKey, uid))
		if cnt > 0 {
			avg := sum / cnt
			if avg < bestAvg {
				bestAvg = avg
				bestUID = uid
			}
		}
	}

	name := h.getUsernameFromRedis(conn, roomID, bestUID)
	return bestUID, name
}

func (h *QuizServiceHandler) getUsernameFromRedis(conn goredis.Conn, roomID, userID string) string {
	playersKey := fmt.Sprintf("room:%s:players", roomID)
	raw, err := goredis.Bytes(conn.Do("HGET", playersKey, userID))
	if err != nil || len(raw) == 0 {
		return userID
	}
	var p struct {
		Username string `json:"username"`
	}
	if jsonErr := json.Unmarshal(raw, &p); jsonErr == nil && p.Username != "" {
		return p.Username
	}
	return userID
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

// buildMatchEndEvent constructs the MatchEnd event. If autoWinnerID is non-empty,
// that player wins regardless of score (last player standing).
func (h *QuizServiceHandler) buildMatchEndEvent(roomID string, totalRounds int, autoWinnerID string) (*quiz.GameEvent, error) {
	scores, err := h.buildPlayerScores(roomID)
	if err != nil {
		return nil, err
	}

	var winnerUserID, winnerUsername string

	if autoWinnerID != "" {
		// Last player standing wins by default
		winnerUserID = autoWinnerID
		for _, s := range scores {
			if s.UserId == autoWinnerID {
				winnerUsername = s.Username
				break
			}
		}
		if winnerUsername == "" {
			winnerUsername = autoWinnerID
		}
	} else if len(scores) > 0 {
		// Normal end — highest score wins
		winnerUserID = scores[0].UserId
		winnerUsername = scores[0].Username
	}

	return &quiz.GameEvent{
		Event: &quiz.GameEvent_MatchEnd{
			MatchEnd: &quiz.MatchEnd{
				RoomId:         roomID,
				WinnerUserId:   winnerUserID,
				WinnerUsername: winnerUsername,
				TotalRounds:    int32(totalRounds),
				FinalScores:    scores,
			},
		},
	}, nil
}

// updatePlayerRatings bumps each player's rating in MongoDB by their match score.
// XP = score earned during the match (base points + speed bonus).
func (h *QuizServiceHandler) updatePlayerRatings(matchEndEvent *quiz.GameEvent) {
	me := matchEndEvent.GetMatchEnd()
	if me == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	users := h.mongoDB.Collection("users")
	for _, ps := range me.FinalScores {
		if ps.Score <= 0 {
			continue
		}
		oid, err := primitive.ObjectIDFromHex(ps.UserId)
		if err != nil {
			// userId might not be a valid ObjectID (legacy)
			log.Printf("⚠️  updateRatings: invalid userId %s: %v", ps.UserId, err)
			continue
		}
		result, err := users.UpdateByID(ctx, oid, bson.M{
			"$inc": bson.M{"rating": int(ps.Score)},
		})
		if err != nil {
			log.Printf("⚠️  updateRatings: user %s: %v", ps.UserId, err)
			continue
		}
		if result.ModifiedCount > 0 {
			log.Printf("📈 Rating updated — user: %s (+%d)", ps.Username, ps.Score)
		}
	}
}

// saveMatchHistory writes played question IDs to match_history so they're
// excluded from future matches for these players.
func (h *QuizServiceHandler) saveMatchHistory(matchEndEvent *quiz.GameEvent, questionIDs []string) {
	me := matchEndEvent.GetMatchEnd()
	if me == nil || len(questionIDs) == 0 {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Build players array matching the schema fetchSeenQuestionIDs expects
	type playerRef struct {
		UserID string `bson:"userId"`
	}
	players := make([]playerRef, len(me.FinalScores))
	for i, ps := range me.FinalScores {
		players[i] = playerRef{UserID: ps.UserId}
	}

	doc := bson.M{
		"players":     players,
		"questionIds": questionIDs,
		"roomId":      me.RoomId,
		"createdAt":   time.Now(),
	}

	_, err := h.mongoDB.Collection("match_history").InsertOne(ctx, doc)
	if err != nil {
		log.Printf("⚠️  saveMatchHistory: %v", err)
		return
	}
	log.Printf("📝 Match history saved — %d questions for %d players", len(questionIDs), len(players))
}
