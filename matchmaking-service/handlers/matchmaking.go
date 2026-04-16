package handlers

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"sync"
	"time"

	"github.com/gomodule/redigo/redis"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	quiz "github.com/yourorg/quiz-battle/proto/quiz"
	"quiz-battle/matchmaking/rabbitmq"
	rdb "quiz-battle/matchmaking/redis"
	"quiz-battle/shared/middleware"
	"quiz-battle/shared/models"
)

const (
	matchmakingPoolKey = "matchmaking:pool"
	minPlayersToStart  = 2                // require at least 2 players
	maxPlayersPerRoom  = 10
	matchmakingTimeout = 30 * time.Second
	lobbyWait          = 10 * time.Second // always wait this long before creating a room
)

// MatchmakingHandler implements quiz.MatchmakingServiceServer.
type MatchmakingHandler struct {
	quiz.UnimplementedMatchmakingServiceServer

	pool      *redis.Pool
	publisher *rabbitmq.Publisher
	mongoDB   *mongo.Database

	// mu guards playerChans — one buffered channel per waiting player
	mu          sync.Mutex
	playerChans map[string]chan *quiz.MatchEvent
}

func NewMatchmakingHandler(pool *redis.Pool, publisher *rabbitmq.Publisher) *MatchmakingHandler {
	return &MatchmakingHandler{
		pool:        pool,
		publisher:   publisher,
		playerChans: make(map[string]chan *quiz.MatchEvent),
	}
}

// SetMongoDB attaches a MongoDB database handle used for feature-gating queries.
func (h *MatchmakingHandler) SetMongoDB(db *mongo.Database) {
	h.mongoDB = db
}

// Register wires this handler into the gRPC server using the generated descriptor.
func (h *MatchmakingHandler) Register(s *grpc.Server) {
	quiz.RegisterMatchmakingServiceServer(s, h)
	log.Println("✅ MatchmakingService registered")
}

// ─────────────────────────────────────────────────────────────
// JoinMatchmaking
// ─────────────────────────────────────────────────────────────

func (h *MatchmakingHandler) JoinMatchmaking(ctx context.Context, req *quiz.JoinRequest) (*quiz.JoinResponse, error) {
	// Use authenticated userId from JWT context instead of trusting the request
	authUID := middleware.UserIDFromContext(ctx)
	if authUID != "" {
		req.UserId = authUID
	}
	if req.UserId == "" || req.Username == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id and username are required")
	}

	// ── Feature gating: enforce free-tier daily quiz limit ────
	if h.mongoDB != nil {
		if err := h.enforceQuotaAndIncrement(ctx, req.UserId); err != nil {
			return nil, err
		}
	}

	// NOTE: Do NOT delete playerChans here — the SubscribeToMatch stream
	// may already be registered for this session. Deleting it would cause
	// "No subscription" when tryCreateRoom tries to deliver MatchFound.
	// Stale channels from previous sessions are cleaned up by SubscribeToMatch
	// itself (it overwrites the map entry at line 276).

	conn := h.pool.Get()
	defer conn.Close()

	// Add player to sorted set — score = rating
	if _, err := conn.Do("ZADD", matchmakingPoolKey, req.Rating, req.UserId); err != nil {
		return nil, status.Errorf(codes.Internal, "redis ZADD: %v", err)
	}

	// Store player details for room-creation lookup
	playerKey := fmt.Sprintf("player:%s", req.UserId)
	if _, err := conn.Do("HSET", playerKey,
		"user_id", req.UserId,
		"username", req.Username,
		"rating", req.Rating,
		"joined_at", time.Now().UnixMilli(),
	); err != nil {
		return nil, status.Errorf(codes.Internal, "redis HSET: %v", err)
	}
	conn.Do("EXPIRE", playerKey, int(matchmakingTimeout.Seconds())) //nolint:errcheck

	poolSize, err := redis.Int(conn.Do("ZCARD", matchmakingPoolKey))
	if err != nil {
		return nil, status.Errorf(codes.Internal, "redis ZCARD: %v", err)
	}

	log.Printf("👤 Player %s joined matchmaking pool (pool size: %d)", req.Username, poolSize)

	// Always wait lobbyWait before attempting room creation to give
	// all players time to join. Only schedule once (when first player joins).
	if poolSize == 1 {
		go func() {
			time.Sleep(lobbyWait)
			h.tryCreateRoom()
		}()
	} else if poolSize >= minPlayersToStart {
		// Additional players joined — schedule another attempt after lobbyWait
		// in case even more players want to join.
		go func() {
			time.Sleep(lobbyWait)
			h.tryCreateRoom()
		}()
	}

	// Broadcast WaitingUpdate with player list to all waiting subscribers
	go h.broadcastWaitingUpdate()

	return &quiz.JoinResponse{
		Success:       true,
		Message:       "Added to matchmaking pool",
		QueuePosition: fmt.Sprintf("%d players waiting", poolSize),
	}, nil
}

// buildWaitingUpdateEvent fetches the current pool and returns a WaitingUpdate event.
func (h *MatchmakingHandler) buildWaitingUpdateEvent() *quiz.MatchEvent {
	conn := h.pool.Get()
	defer conn.Close()

	userIDs, err := redis.Strings(conn.Do("ZRANGE", matchmakingPoolKey, 0, -1))
	if err != nil {
		log.Printf("⚠️  buildWaitingUpdateEvent ZRANGE: %v", err)
		return nil
	}

	var players []*quiz.Player
	for _, uid := range userIDs {
		vals, err := redis.Strings(conn.Do("HMGET", fmt.Sprintf("player:%s", uid), "username", "rating"))
		if err != nil || len(vals) < 2 || vals[0] == "" {
			continue
		}
		rating := 0
		if vals[1] != "" {
			rating, _ = strconv.Atoi(vals[1])
		}
		players = append(players, &quiz.Player{
			UserId:   uid,
			Username: vals[0],
			Rating:   int32(rating),
		})
	}

	return &quiz.MatchEvent{
		Event: &quiz.MatchEvent_WaitingUpdate{
			WaitingUpdate: &quiz.WaitingUpdate{
				PlayersInPool: int32(len(players)),
				Players:       players,
			},
		},
	}
}

// broadcastWaitingUpdate sends a WaitingUpdate event to all subscribed players.
func (h *MatchmakingHandler) broadcastWaitingUpdate() {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("⚠️  broadcastWaitingUpdate recovered from panic: %v", r)
		}
	}()

	event := h.buildWaitingUpdateEvent()
	if event == nil {
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	for _, ch := range h.playerChans {
		select {
		case ch <- event:
		default:
		}
	}
}

// sendWaitingUpdateTo sends the current pool state to a single player's channel.
func (h *MatchmakingHandler) sendWaitingUpdateTo(ch chan *quiz.MatchEvent) {
	event := h.buildWaitingUpdateEvent()
	if event == nil {
		return
	}
	select {
	case ch <- event:
	default:
	}
}

// ─────────────────────────────────────────────────────────────
// LeaveMatchmaking
// ─────────────────────────────────────────────────────────────

func (h *MatchmakingHandler) LeaveMatchmaking(ctx context.Context, req *quiz.LeaveRequest) (*quiz.LeaveResponse, error) {
	if authUID := middleware.UserIDFromContext(ctx); authUID != "" {
		req.UserId = authUID
	}
	if req.UserId == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}

	conn := h.pool.Get()
	defer conn.Close()

	removed, err := redis.Int(conn.Do("ZREM", matchmakingPoolKey, req.UserId))
	if err != nil {
		return nil, status.Errorf(codes.Internal, "redis ZREM: %v", err)
	}
	conn.Do("DEL", fmt.Sprintf("player:%s", req.UserId)) //nolint:errcheck

	// Remove the channel from the map — do NOT close it.
	// A concurrent broadcastWaitingUpdate goroutine may still hold a reference
	// and panic on send-to-closed. The SubscribeToMatch defer handles cleanup.
	h.mu.Lock()
	delete(h.playerChans, req.UserId)
	h.mu.Unlock()

	if removed == 0 {
		return &quiz.LeaveResponse{Success: true, Message: "Not in pool"}, nil
	}

	log.Printf("👋 Player %s left matchmaking pool", req.UserId)
	return &quiz.LeaveResponse{Success: true, Message: "Removed from matchmaking pool"}, nil
}

// ─────────────────────────────────────────────────────────────
// SubscribeToMatch
// ─────────────────────────────────────────────────────────────
// Long-lived stream. The server pushes a MatchFound event once a room is ready.

func (h *MatchmakingHandler) SubscribeToMatch(req *quiz.SubscribeRequest, stream grpc.ServerStreamingServer[quiz.MatchEvent]) error {
	if authUID := middleware.UserIDFromContext(stream.Context()); authUID != "" {
		req.UserId = authUID
	}
	if req.UserId == "" {
		return status.Error(codes.InvalidArgument, "user_id is required")
	}

	// Buffered channel — receives WaitingUpdate and MatchFound events
	ch := make(chan *quiz.MatchEvent, 4)

	h.mu.Lock()
	h.playerChans[req.UserId] = ch
	h.mu.Unlock()

	defer func() {
		h.mu.Lock()
		if h.playerChans[req.UserId] == ch {
			delete(h.playerChans, req.UserId)
		}
		h.mu.Unlock()
	}()

	log.Printf("📡 Player %s subscribed to match events", req.UserId)

	// Send the current pool state to this player after a short delay.
	// This handles the case where JoinMatchmaking broadcast fired before
	// this subscription was registered (common race: join fires before subscribe).
	go func() {
		time.Sleep(500 * time.Millisecond) // give JoinMatchmaking time to complete
		h.sendWaitingUpdateTo(ch)
	}()

	ctx := stream.Context()
	timeout := time.After(matchmakingTimeout)
	// Periodic ticker: re-broadcast pool state every 3s as a safety net.
	// Ensures clients catch up even if they miss an event.
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Printf("📴 Player %s disconnected", req.UserId)
			return nil

		case event, ok := <-ch:
			if !ok {
				// Channel closed by LeaveMatchmaking
				return nil
			}
			if err := stream.Send(event); err != nil {
				return err
			}
			// If this was MatchFound, close the stream — Flutter opens StreamGameEvents next
			if event.GetMatchFound() != nil {
				return nil
			}
			// WaitingUpdate — keep looping for more events

		case <-ticker.C:
			// Periodic refresh — re-send current pool state
			h.sendWaitingUpdateTo(ch)

		case <-timeout:
			return stream.Send(&quiz.MatchEvent{
				Event: &quiz.MatchEvent_MatchCancelled{
					MatchCancelled: &quiz.MatchCancelled{Reason: "timeout"},
				},
			})
		}
	}
}

// ─────────────────────────────────────────────────────────────
// tryCreateRoom — called in a goroutine when pool is large enough
// ─────────────────────────────────────────────────────────────

func (h *MatchmakingHandler) tryCreateRoom() {
	// Global lock prevents multiple goroutines from racing on ZPOPMIN
	ownerToken, lockErr := rdb.AcquireLock(h.pool, "matchmaking_create")
	if lockErr != nil {
		log.Printf("⚠️  tryCreateRoom: could not acquire lock, another goroutine is creating: %v", lockErr)
		return
	}
	defer rdb.ReleaseLock(h.pool, "matchmaking_create", ownerToken) //nolint:errcheck

	conn := h.pool.Get()
	defer conn.Close()

	// ZPOPMIN pops members with the lowest scores (lowest rating) first.
	rawPairs, err := redis.Strings(conn.Do("ZPOPMIN", matchmakingPoolKey, maxPlayersPerRoom))
	if err != nil || len(rawPairs) < minPlayersToStart*2 {
		// Not enough players — re-add whatever we popped
		for i := 0; i+1 < len(rawPairs); i += 2 {
			conn.Do("ZADD", matchmakingPoolKey, rawPairs[i+1], rawPairs[i]) //nolint:errcheck
		}
		log.Printf("⚠️  tryCreateRoom: not enough players (err: %v)", err)
		return
	}

	// rawPairs alternates [member, score, member, score, …]
	var players []models.Player
	for i := 0; i+1 < len(rawPairs); i += 2 {
		userID := rawPairs[i]

		vals, err := redis.Strings(conn.Do("HMGET",
			fmt.Sprintf("player:%s", userID),
			"username", "rating",
		))
		if err != nil || len(vals) < 2 || vals[0] == "" {
			log.Printf("⚠️  Missing player details for %s", userID)
			continue
		}

		rating := 0
		if vals[1] != "" {
			rating, _ = strconv.Atoi(vals[1])
		}

		players = append(players, models.Player{
			UserID:   userID,
			Username: vals[0],
			Rating:   rating,
		})
	}

	if len(players) < minPlayersToStart {
		log.Println("⚠️  tryCreateRoom: too few valid players after lookup")
		return
	}

	room, err := rdb.CreateRoom(h.pool, players)
	if err != nil {
		log.Printf("❌ CreateRoom failed: %v", err)
		return
	}

	// Publish match.created — quiz-service consumes this to select questions
	if err := h.publisher.PublishMatchCreated(room); err != nil {
		log.Printf("⚠️  PublishMatchCreated: %v", err)
	}

	// Build the proto MatchFound event to deliver to each waiting subscriber
	protoPlayers := make([]*quiz.Player, len(players))
	for i, p := range players {
		protoPlayers[i] = &quiz.Player{
			UserId:   p.UserID,
			Username: p.Username,
			Rating:   int32(p.Rating),
		}
	}

	matchFound := &quiz.MatchEvent{
		Event: &quiz.MatchEvent_MatchFound{
			MatchFound: &quiz.MatchFound{
				RoomId:      room.ID,
				Players:     protoPlayers,
				TotalRounds: int32(room.TotalRounds),
			},
		},
	}

	// Deliver MatchFound to every player's subscription channel
	h.mu.Lock()
	defer h.mu.Unlock()

	for _, p := range players {
		ch, ok := h.playerChans[p.UserID]
		if !ok {
			log.Printf("⚠️  No subscription for player %s — they may have disconnected", p.UserID)
			continue
		}
		select {
		case ch <- matchFound:
		default:
			log.Printf("⚠️  Could not deliver MatchFound to player %s (channel full)", p.UserID)
		}
	}

	log.Printf("🏠 Room %s created with %d players", room.ID, len(players))
}

// ─────────────────────────────────────────────────────────────
// enforceQuotaAndIncrement — free-tier daily quiz limit
// ─────────────────────────────────────────────────────────────

// enforceQuotaAndIncrement checks whether the user is allowed to join a match.
// Free users are limited to 1 quiz per day. Premium users (active subscription)
// have unlimited access. If allowed, it increments daily_quiz_used atomically.
func (h *MatchmakingHandler) enforceQuotaAndIncrement(ctx context.Context, userID string) error {
	dbCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	// 1. Check for an active premium subscription
	subsColl := h.mongoDB.Collection("subscriptions")
	subsCount, err := subsColl.CountDocuments(dbCtx, bson.M{
		"user_id":    userID,
		"status":     "active",
		"expires_at": bson.M{"$gt": time.Now()},
	})
	if err != nil {
		log.Printf("enforceQuota: subscription lookup error for user %s: %v", userID, err)
		// Fail open — don't block the user if the DB is unavailable
		return nil
	}
	if subsCount > 0 {
		// Premium user — no limit. Mirror status to Redis for observability.
		conn := h.pool.Get()
		conn.Do("SET", fmt.Sprintf("user:%s:daily_quota", userID), "unlimited", "EX", 86400) //nolint:errcheck
		conn.Do("SET", fmt.Sprintf("user:%s:plan", userID), "premium", "EX", 86400)          //nolint:errcheck
		conn.Close()
		return nil
	}

	// 2. Look up the user's daily quota fields + bonus games
	oid, oidErr := primitive.ObjectIDFromHex(userID)
	if oidErr != nil {
		log.Printf("enforceQuota: invalid ObjectID %s: %v", userID, oidErr)
		return nil // fail open
	}
	usersColl := h.mongoDB.Collection("users")
	var userDoc struct {
		DailyQuizUsed       int    `bson:"daily_quiz_used"`
		LastQuizDate        string `bson:"last_quiz_date"` // stored as "YYYY-MM-DD"
		BonusGamesRemaining int    `bson:"bonus_games_remaining"`
	}
	err = usersColl.FindOne(dbCtx, bson.M{"_id": oid}).Decode(&userDoc)
	if err != nil && err != mongo.ErrNoDocuments {
		log.Printf("enforceQuota: user lookup error for %s: %v", userID, err)
		return nil // fail open
	}

	today := time.Now().UTC().Format("2006-01-02")

	// If last_quiz_date is a different day, the free counter resets
	usedToday := 0
	if userDoc.LastQuizDate == today {
		usedToday = userDoc.DailyQuizUsed
	}

	freeExhausted := usedToday >= 5
	hasBonus := userDoc.BonusGamesRemaining > 0

	// Block only when free quota is gone AND no bonus games remain
	if freeExhausted && !hasBonus {
		return status.Error(codes.ResourceExhausted,
			"Daily free limit reached. Upgrade to Premium for unlimited games.")
	}

	// 3. Consume the right resource atomically
	if freeExhausted && hasBonus {
		// Free quota exhausted — consume a bonus game instead
		_, err = usersColl.UpdateOne(dbCtx,
			bson.M{"_id": oid},
			bson.M{"$inc": bson.M{"bonus_games_remaining": -1}},
		)
		if err != nil {
			log.Printf("enforceQuota: failed to decrement bonus_games for user %s: %v", userID, err)
		}
		log.Printf("enforceQuota: bonus game consumed — user %s (bonus left: %d)", userID, userDoc.BonusGamesRemaining-1)
	} else {
		// Using a free game — increment daily counter
		_, err = usersColl.UpdateOne(dbCtx,
			bson.M{"_id": oid},
			bson.M{"$set": bson.M{
				"last_quiz_date":  today,
				"daily_quiz_used": usedToday + 1,
			}},
		)
		if err != nil {
			log.Printf("enforceQuota: failed to increment daily_quiz_used for user %s: %v", userID, err)
			// Fail open — don't block the user
		}
	}

	// 4. Mirror remaining quota to Redis for observability
	freeRemaining := 5 - (usedToday + 1)
	if freeRemaining < 0 {
		freeRemaining = 0
	}
	conn := h.pool.Get()
	defer conn.Close()
	quotaKey := fmt.Sprintf("user:%s:daily_quota", userID)
	conn.Do("SET", quotaKey, freeRemaining, "EX", 86400) //nolint:errcheck

	return nil
}
