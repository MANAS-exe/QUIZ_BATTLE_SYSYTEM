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
	"go.mongodb.org/mongo-driver/mongo/options"

	"quiz-battle/quiz/rabbitmq"
	rdb "quiz-battle/quiz/redis"
	"quiz-battle/shared/middleware"
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

	// Late-joiner catch-up: the game loop stores the current question event
	// so late subscribers can be sent the active round immediately.
	currentQuestion *quiz.GameEvent // latest QuestionBroadcast event
	currentRound    int
	roundDeadlineMs int64 // absolute unix ms when current round ends
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
	// NOTE: do NOT remove from active here — stream disconnect != forfeit.
	// Players are only removed from active via markForfeited().
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

// setCurrentQuestion stores the latest question event for late-joiner catch-up.
func (r *gameRoom) setCurrentQuestion(event *quiz.GameEvent, round int, deadlineMs int64) {
	r.mu.Lock()
	r.currentQuestion = event
	r.currentRound = round
	r.roundDeadlineMs = deadlineMs
	r.mu.Unlock()
}

// getCurrentQuestion returns the current question event for late-joiner catch-up.
func (r *gameRoom) getCurrentQuestion() (*quiz.GameEvent, int, int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.currentQuestion, r.currentRound, r.roundDeadlineMs
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
	if authUID := middleware.UserIDFromContext(ctx); authUID != "" {
		req.UserId = authUID
	}
	if req.RoomId == "" || req.UserId == "" {
		return nil, status.Error(codes.InvalidArgument, "room_id and user_id are required")
	}

	// answer_index = -1 signals a forfeit — mark player as inactive
	if req.AnswerIndex == -1 {
		room := h.hub.getOrCreate(req.RoomId, 0)
		room.markForfeited(req.UserId)
		log.Printf("🚪 Forfeit: user=%s room=%s activeCount=%d", req.UserId, req.RoomId, room.activeCount())
		return &quiz.AnswerAck{Received: true, Message: "Forfeited"}, nil
	}

	if req.QuestionId == "" {
		return nil, status.Error(codes.InvalidArgument, "question_id is required")
	}

	// Record in a SEPARATE "submitted" hash so the round timer can detect
	// "all players answered" immediately. The scoring consumer uses the
	// "answers" hash for idempotency — we must NOT write there or it skips scoring.
	rdConn := h.redisPool.Get()
	defer rdConn.Close()
	submittedKey := fmt.Sprintf("room:%s:submitted:%d", req.RoomId, req.RoundNumber)
	setRes, setErr := rdConn.Do("HSETNX", submittedKey, req.UserId, req.AnswerIndex)
	rdConn.Do("EXPIRE", submittedKey, 30*60) //nolint:errcheck
	log.Printf("📝 Recorded submission — user=%s key=%s round=%d setResult=%v setErr=%v", req.UserId, submittedKey, req.RoundNumber, setRes, setErr)

	// Fetch the round start time for response-time calculation.
	var roundStartedAtMs int64
	startedAtKey := fmt.Sprintf("room:%s:round:%d:started_at", req.RoomId, req.RoundNumber)
	if startedAt, err := goredis.Int64(rdConn.Do("GET", startedAtKey)); err == nil {
		roundStartedAtMs = startedAt
	} else {
		log.Printf("⚠️  Could not read round start time: key=%s err=%v", startedAtKey, err)
	}

	// Use SERVER receive time instead of client's SubmittedAtMs to avoid
	// clock skew between emulators/devices. The server clock is the single
	// source of truth for both roundStartedAtMs and submittedAtMs.
	serverNowMs := time.Now().UnixMilli()

	log.Printf("🔍 SubmitAnswer timing — user=%s round=%d clientSubmitted=%d serverNow=%d roundStart=%d serverDiff=%dms",
		req.UserId, req.RoundNumber, req.SubmittedAtMs, serverNowMs, roundStartedAtMs, serverNowMs-roundStartedAtMs)

	event := rabbitmq.AnswerSubmittedEvent{
		RoomID:           req.RoomId,
		UserID:           req.UserId,
		RoundNumber:      int(req.RoundNumber),
		QuestionID:       req.QuestionId,
		AnswerIndex:      int(req.AnswerIndex),
		SubmittedAtMs:    serverNowMs, // server timestamp — no clock skew
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
	if authUID := middleware.UserIDFromContext(stream.Context()); authUID != "" {
		req.UserId = authUID
	}
	if req.RoomId == "" || req.UserId == "" {
		return status.Error(codes.InvalidArgument, "room_id and user_id are required")
	}

	roomID := req.RoomId

	// Check if the game loop is already running for this room
	h.hub.mu.Lock()
	existingRoom, roomExists := h.hub.rooms[roomID]
	h.hub.mu.Unlock()

	var room *gameRoom
	if roomExists {
		// Room exists — game already in progress, just subscribe
		room = existingRoom
	} else {
		// First connection — check questions exist
		conn := h.redisPool.Get()
		totalRounds, _ := goredis.Int(conn.Do("LLEN", fmt.Sprintf("room:%s:questions", roomID)))
		conn.Close()

		if totalRounds == 0 {
			return status.Error(codes.FailedPrecondition, "room has no questions — call SelectQuestionsForRoom first")
		}
		room = h.hub.getOrCreate(roomID, totalRounds)
	}

	// Buffer must handle worst case: ~35 events/round (question + 30 timersync + result + leaderboard + matchend)
	ch := make(chan *quiz.GameEvent, room.totalRounds*40+50)
	room.addSub(ch, req.UserId)
	defer room.removeSub(ch, req.UserId)

	log.Printf("📺 Player %s subscribed to room %s game stream", req.UserId, roomID)

	// Notify all OTHER subscribers that this player joined.
	// Look up the player's username from the room:{id}:players hash.
	username := h.lookupUsername(roomID, req.UserId)
	room.broadcast(&quiz.GameEvent{
		Event: &quiz.GameEvent_PlayerJoined{
			PlayerJoined: &quiz.PlayerJoined{
				Player: &quiz.Player{
					UserId:   req.UserId,
					Username: username,
					Status:   quiz.PlayerStatus_CONNECTED,
				},
				RoundNumber: int32(room.totalRounds), // current rounds count
				State:       quiz.MatchState_IN_PROGRESS,
			},
		},
	})

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

	matchStartedAt := time.Now()
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
			// Intercept QuestionBroadcast to store for late-joiner catch-up
			if q := event.GetQuestion(); q != nil {
				room.setCurrentQuestion(event, round, q.DeadlineMs)
			}
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

		// Wait for scoring consumer to finish processing answers via RabbitMQ
		time.Sleep(2 * time.Second)

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

		// If auto-winner was set mid-round, end now
		if autoWinnerID != "" {
			time.Sleep(2 * time.Second)
			break
		}

		// Last round — shorter pause before results
		if round == room.totalRounds {
			time.Sleep(3 * time.Second)
		} else {
			// Pause to show leaderboard + correct answer before next round
			time.Sleep(5 * time.Second)
		}
	}

	// All rounds done (or early end) — broadcast MatchEnd
	matchDuration := int32(time.Since(matchStartedAt).Seconds())
	matchEnd, err := h.buildMatchEndEvent(roomID, room.totalRounds, autoWinnerID, matchDuration)
	if err != nil {
		log.Printf("⚠️  buildMatchEnd room=%s: %v", roomID, err)
		return
	}
	room.broadcast(matchEnd)

	// Update player ratings in MongoDB based on XP earned
	h.updatePlayerRatings(matchEnd)

	// Save this match, then trim to keep only the last 3 per player.
	// Keeping 3 serves both profile display (last 3 matches) and question
	// deduplication (questions from recent matches are excluded from future draws).
	h.saveMatchHistory(matchEnd, playedQuestionIDs, matchStartedAt)
	h.trimMatchHistory(matchEnd, 3)

	// Give clients time to receive MatchEnd before closeAll() in defer
	time.Sleep(3 * time.Second)
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

// findFastestCorrectAnswer checks per-round response times to find who answered
// correctly the fastest THIS round (not cumulative avg). Returns empty if no one
// was correct. If tied on time, returns empty userID (tie).
func (h *QuizServiceHandler) findFastestCorrectAnswer(roomID string, roundNum int, correctIndex int) (userID, username string) {
	conn := h.redisPool.Get()
	defer conn.Close()

	// Get all answers for this round: {userId: answerIndex, ...}
	answersKey := fmt.Sprintf("room:%s:answers:%d", roomID, roundNum)
	answers, err := goredis.StringMap(conn.Do("HGETALL", answersKey))
	if err != nil || len(answers) == 0 {
		return "", ""
	}

	// Get per-round response times: {userId: responseMs, ...}
	roundTimeKey := fmt.Sprintf("room:%s:round_time:%d", roomID, roundNum)
	roundTimes, _ := goredis.Int64Map(conn.Do("HGETALL", roundTimeKey))

	// Collect correct users with their per-round response time
	type entry struct {
		uid  string
		time int64
	}
	var correctUsers []entry
	for uid, ansStr := range answers {
		var idx int
		fmt.Sscanf(ansStr, "%d", &idx)
		if idx == correctIndex {
			t := roundTimes[uid]
			correctUsers = append(correctUsers, entry{uid, t})
		}
	}

	if len(correctUsers) == 0 {
		return "", ""
	}

	if len(correctUsers) == 1 {
		uid := correctUsers[0].uid
		return uid, h.getUsernameFromRedis(conn, roomID, uid)
	}

	// Find fastest — if two have same time (within 100ms tolerance), it's a tie
	best := correctUsers[0]
	for _, e := range correctUsers[1:] {
		if e.time > 0 && (best.time == 0 || e.time < best.time) {
			best = e
		}
	}

	// Check for tie: is anyone within 100ms of the best?
	tieCount := 0
	for _, e := range correctUsers {
		if e.uid != best.uid && e.time > 0 {
			diff := e.time - best.time
			if diff < 0 {
				diff = -diff
			}
			if diff <= 100 { // within 100ms = tie
				tieCount++
			}
		}
	}
	if tieCount > 0 {
		return "", "" // tie — no single fastest player
	}

	name := h.getUsernameFromRedis(conn, roomID, best.uid)
	return best.uid, name
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

	// Fallback: if leaderboard is empty (e.g. all players forfeited before answering),
	// load all players from the room's player registry with 0 score.
	if len(entries) == 0 {
		entries = h.loadPlayersAsZeroScores(roomID)
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
			Rank:           int32(i + 1),
			AnswersCorrect: int32(correctCounts[e.UserID]),
			AvgResponseMs:  int32(avgResponseMs[e.UserID]),
		}
	}
	return scores, nil
}

// lookupUsername fetches a single player's username from room:{id}:players.
// Returns an empty string if the lookup fails (non-fatal).
func (h *QuizServiceHandler) lookupUsername(roomID, userID string) string {
	conn := h.redisPool.Get()
	defer conn.Close()
	raw, err := goredis.Bytes(conn.Do("HGET", fmt.Sprintf("room:%s:players", roomID), userID))
	if err != nil {
		return ""
	}
	var p struct {
		Username string `json:"username"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return ""
	}
	return p.Username
}

// loadPlayersAsZeroScores reads room:{id}:players and returns every player
// with 0 score — used when the leaderboard is empty (all forfeited).
func (h *QuizServiceHandler) loadPlayersAsZeroScores(roomID string) []rdb.LeaderboardEntry {
	conn := h.redisPool.Get()
	defer conn.Close()

	playersKey := fmt.Sprintf("room:%s:players", roomID)
	raw, err := goredis.StringMap(conn.Do("HGETALL", playersKey))
	if err != nil || len(raw) == 0 {
		return nil
	}

	entries := make([]rdb.LeaderboardEntry, 0, len(raw))
	for userID, jsonStr := range raw {
		var p struct {
			Username string `json:"username"`
		}
		if jsonErr := json.Unmarshal([]byte(jsonStr), &p); jsonErr == nil {
			entries = append(entries, rdb.LeaderboardEntry{
				UserID: userID,
				Score:  0,
				Rank:   0, // filled in by caller
			})
		}
	}
	return entries
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
func (h *QuizServiceHandler) buildMatchEndEvent(roomID string, totalRounds int, autoWinnerID string, durationSeconds int32) (*quiz.GameEvent, error) {
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
				RoomId:          roomID,
				WinnerUserId:    winnerUserID,
				WinnerUsername:  winnerUsername,
				TotalRounds:     int32(totalRounds),
				DurationSeconds: durationSeconds,
				FinalScores:     scores,
			},
		},
	}, nil
}

// updatePlayerRatings bumps each player's rating in MongoDB by their match score
// and persists match stats (played, won, coins, streaks) so they survive app reinstall.
func (h *QuizServiceHandler) updatePlayerRatings(matchEndEvent *quiz.GameEvent) {
	me := matchEndEvent.GetMatchEnd()
	if me == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	winnerID := me.WinnerUserId

	users := h.mongoDB.Collection("users")
	for _, ps := range me.FinalScores {
		oid, err := primitive.ObjectIDFromHex(ps.UserId)
		if err != nil {
			log.Printf("⚠️  updateRatings: invalid userId %s: %v", ps.UserId, err)
			continue
		}

		// Always increment matches_played; conditionally increment matches_won
		inc := bson.M{
			"matches_played": 1,
		}
		if ps.Score > 0 {
			inc["rating"] = int(ps.Score)
		}
		if ps.UserId == winnerID {
			inc["matches_won"] = 1
		}

		result, err := users.UpdateByID(ctx, oid, bson.M{"$inc": inc})
		if err != nil {
			log.Printf("⚠️  updateRatings: user %s: %v", ps.UserId, err)
			continue
		}
		if result.ModifiedCount > 0 {
			won := ""
			if ps.UserId == winnerID {
				won = " (winner)"
			}
			log.Printf("📈 Stats updated — user: %s (+%d rating, +1 played%s)", ps.Username, ps.Score, won)
		}
	}
}

// trimMatchHistory keeps only the most recent `keep` match_history documents
// for each player in the match. Older records beyond that are deleted.
// This lets the profile show the last N matches while also bounding the
// question-deduplication window to recent matches only.
func (h *QuizServiceHandler) trimMatchHistory(matchEndEvent *quiz.GameEvent, keep int) {
	me := matchEndEvent.GetMatchEnd()
	if me == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	col := h.mongoDB.Collection("match_history")

	for _, ps := range me.FinalScores {
		// Find the IDs of this player's most recent `keep` records (newest first).
		opts := options.Find().
			SetSort(bson.D{{Key: "createdAt", Value: -1}}).
			SetSkip(int64(keep)).
			SetProjection(bson.M{"_id": 1})

		cursor, err := col.Find(ctx, bson.M{"players.userId": ps.UserId}, opts)
		if err != nil {
			log.Printf("⚠️  trimMatchHistory find %s: %v", ps.UserId, err)
			continue
		}

		var toDelete []interface{}
		for cursor.Next(ctx) {
			toDelete = append(toDelete, cursor.Current.Lookup("_id").ObjectID())
		}
		cursor.Close(ctx) //nolint:errcheck

		if len(toDelete) == 0 {
			continue
		}

		res, err := col.DeleteMany(ctx, bson.M{"_id": bson.M{"$in": toDelete}})
		if err != nil {
			log.Printf("⚠️  trimMatchHistory delete %s: %v", ps.UserId, err)
			continue
		}
		if res.DeletedCount > 0 {
			log.Printf("🗑️  Trimmed %d old match_history entries for user %s", res.DeletedCount, ps.UserId)
		}
	}
}

func (h *QuizServiceHandler) saveMatchHistory(matchEndEvent *quiz.GameEvent, questionIDs []string, matchStartedAt time.Time) {
	me := matchEndEvent.GetMatchEnd()
	if me == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Full player stats — pulled directly from the MatchEnd proto which already
	// has username, score, rank, answersCorrect, avgResponseMs populated by
	// buildMatchEndEvent → buildPlayerScores → GetPlayerMeta.
	type playerEntry struct {
		UserID         string `bson:"userId"`
		Username       string `bson:"username"`
		FinalScore     int32  `bson:"finalScore"`
		Rank           int32  `bson:"rank"`
		AnswersCorrect int32  `bson:"answersCorrect"`
		AvgResponseMs  int32  `bson:"avgResponseTimeMs"`
	}
	players := make([]playerEntry, len(me.FinalScores))
	for i, ps := range me.FinalScores {
		players[i] = playerEntry{
			UserID:         ps.UserId,
			Username:       ps.Username,
			FinalScore:     ps.Score,
			Rank:           ps.Rank,
			AnswersCorrect: ps.AnswersCorrect,
			AvgResponseMs:  ps.AvgResponseMs,
		}
	}

	// Use actual rounds played (len of question IDs consumed), not configured total.
	// Use matchStartedAt for createdAt and exact ms duration — not the rounded int32.
	doc := bson.M{
		"roomId":      me.RoomId,
		"players":     players,
		"questionIds": questionIDs,
		"rounds":      len(questionIDs),
		"winner":      me.WinnerUserId,
		"createdAt":   matchStartedAt,
		"durationMs":  time.Since(matchStartedAt).Milliseconds(),
	}

	_, err := h.mongoDB.Collection("match_history").InsertOne(ctx, doc)
	if err != nil {
		log.Printf("⚠️  saveMatchHistory: %v", err)
		return
	}
	log.Printf("📝 Match history saved — room: %s, winner: %s, %d rounds, %d players",
		me.RoomId, me.WinnerUserId, me.TotalRounds, len(players))
}
