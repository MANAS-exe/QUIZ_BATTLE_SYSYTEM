package handlers

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"sync"
	"time"

	"github.com/gomodule/redigo/redis"
	"go.mongodb.org/mongo-driver/mongo"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	quiz "github.com/yourorg/quiz-battle/proto/quiz"
	"quiz-battle/matchmaking/models"
	"quiz-battle/matchmaking/rabbitmq"
	rdb "quiz-battle/matchmaking/redis"
)

const (
	matchmakingPoolKey = "matchmaking:pool"
	minPlayersToStart  = 1               // 1 = solo play allowed
	maxPlayersPerRoom  = 10
	matchmakingTimeout = 30 * time.Second
	lobbyWait          = 8 * time.Second // wait this long for more players before starting solo
)

// MatchmakingHandler implements quiz.MatchmakingServiceServer.
type MatchmakingHandler struct {
	quiz.UnimplementedMatchmakingServiceServer

	pool      *redis.Pool
	mongoDB   *mongo.Database
	publisher *rabbitmq.Publisher

	// mu guards playerChans — one buffered channel per waiting player
	mu          sync.Mutex
	playerChans map[string]chan *quiz.MatchEvent
}

func NewMatchmakingHandler(pool *redis.Pool, mongoDB *mongo.Database, publisher *rabbitmq.Publisher) *MatchmakingHandler {
	return &MatchmakingHandler{
		pool:        pool,
		mongoDB:     mongoDB,
		publisher:   publisher,
		playerChans: make(map[string]chan *quiz.MatchEvent),
	}
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
	if req.UserId == "" || req.Username == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id and username are required")
	}

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

	if poolSize >= minPlayersToStart {
		// If only 1 player, wait lobbyWait for more players before creating a solo room.
		// If 2+ players are already waiting, create the room immediately.
		if poolSize == 1 {
			go func() {
				time.Sleep(lobbyWait)
				h.tryCreateRoom()
			}()
		} else {
			go h.tryCreateRoom()
		}
	}

	return &quiz.JoinResponse{
		Success:       true,
		Message:       "Added to matchmaking pool",
		QueuePosition: fmt.Sprintf("%d players waiting", poolSize),
	}, nil
}

// ─────────────────────────────────────────────────────────────
// LeaveMatchmaking
// ─────────────────────────────────────────────────────────────

func (h *MatchmakingHandler) LeaveMatchmaking(ctx context.Context, req *quiz.LeaveRequest) (*quiz.LeaveResponse, error) {
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

	// Cancel any waiting SubscribeToMatch channel for this player
	h.mu.Lock()
	if ch, ok := h.playerChans[req.UserId]; ok {
		close(ch)
		delete(h.playerChans, req.UserId)
	}
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
	if req.UserId == "" {
		return status.Error(codes.InvalidArgument, "user_id is required")
	}

	// Create a buffered channel so tryCreateRoom never blocks on delivery
	ch := make(chan *quiz.MatchEvent, 1)

	h.mu.Lock()
	h.playerChans[req.UserId] = ch
	h.mu.Unlock()

	defer func() {
		h.mu.Lock()
		// Only delete if it's still our channel (LeaveMatchmaking may have closed it)
		if h.playerChans[req.UserId] == ch {
			delete(h.playerChans, req.UserId)
		}
		h.mu.Unlock()
	}()

	log.Printf("📡 Player %s subscribed to match events", req.UserId)

	ctx := stream.Context()
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
		// Stream can close after MatchFound — Flutter opens StreamGameEvents next
		return nil

	case <-time.After(matchmakingTimeout):
		return stream.Send(&quiz.MatchEvent{
			Event: &quiz.MatchEvent_MatchCancelled{
				MatchCancelled: &quiz.MatchCancelled{Reason: "timeout"},
			},
		})
	}
}

// ─────────────────────────────────────────────────────────────
// tryCreateRoom — called in a goroutine when pool is large enough
// ─────────────────────────────────────────────────────────────

func (h *MatchmakingHandler) tryCreateRoom() {
	conn := h.pool.Get()
	defer conn.Close()

	// ZPOPMIN pops members with the lowest scores (lowest rating) first.
	// For production, switch to ZPOPMAX or a rating-band strategy.
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

	// Select and cache questions in Redis for this room so GetRoomQuestions
	// and StreamGameEvents can find them immediately.
	playerIDs := make([]string, len(players))
	for i, p := range players {
		playerIDs[i] = p.UserID
	}
	if _, err := SelectQuestionsForRoom(h.pool, h.mongoDB, room.ID, playerIDs, room.TotalRounds); err != nil {
		log.Printf("❌ SelectQuestionsForRoom failed for room %s: %v", room.ID, err)
		return
	}
	log.Printf("📚 Questions selected for room %s", room.ID)

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
