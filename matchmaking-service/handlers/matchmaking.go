package handlers

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/gomodule/redigo/redis"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"quiz-battle/matchmaking/models"
	"quiz-battle/matchmaking/rabbitmq"
)

const (
	matchmakingPoolKey = "matchmaking:pool"  // Redis sorted set — score = player rating
	minPlayersToStart  = 2
	maxPlayersPerRoom  = 10
	matchmakingTimeout = 30 * time.Second
)

// MatchmakingHandler implements the MatchmakingService gRPC interface.
type MatchmakingHandler struct {
	pool      *redis.Pool
	publisher *rabbitmq.Publisher
}

func NewMatchmakingHandler(pool *redis.Pool, publisher *rabbitmq.Publisher) *MatchmakingHandler {
	return &MatchmakingHandler{
		pool:      pool,
		publisher: publisher,
	}
}

// Register wires this handler into the gRPC server.
// TODO: replace the grpc.ServiceDesc stub below with the generated
// proto registration once quiz_grpc.pb.go is imported:
//   quizpb.RegisterMatchmakingServiceServer(s, h)
func (h *MatchmakingHandler) Register(s *grpc.Server) {
	// TODO: quizpb.RegisterMatchmakingServiceServer(s, h)
	log.Println("MatchmakingHandler registered (proto registration pending)")
}

// ─────────────────────────────────────────────────────────────
// JoinMatchmaking
// ─────────────────────────────────────────────────────────────
// Called when a player taps "Start Battle" in Flutter.
// Adds the player to the Redis sorted set (score = rating).
// If enough players are in the pool, triggers room creation.
func (h *MatchmakingHandler) JoinMatchmaking(ctx context.Context, req *JoinRequest) (*JoinResponse, error) {
	if req.UserId == "" || req.Username == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id and username are required")
	}

	conn := h.pool.Get()
	defer conn.Close()

	// TODO: Check if player is already in the pool (prevent duplicate joins)
	// existing, _ := redis.Int(conn.Do("ZSCORE", matchmakingPoolKey, req.UserId))
	// if existing > 0 { return nil, status.Error(codes.AlreadyExists, "already in matchmaking") }

	// Add player to sorted set with rating as score
	// ZADD matchmaking:pool <rating> <userId>
	_, err := conn.Do("ZADD", matchmakingPoolKey, req.Rating, req.UserId)
	if err != nil {
		log.Printf("❌ Redis ZADD failed for user %s: %v", req.UserId, err)
		return nil, status.Error(codes.Internal, "failed to join matchmaking pool")
	}

	// Store player details as a Redis hash for quick lookup
	playerKey := fmt.Sprintf("player:%s", req.UserId)
	_, err = conn.Do("HSET", playerKey,
		"user_id",  req.UserId,
		"username", req.Username,
		"rating",   req.Rating,
		"joined_at", time.Now().UnixMilli(),
	)
	if err != nil {
		log.Printf("❌ Redis HSET failed for player %s: %v", req.UserId, err)
		return nil, status.Error(codes.Internal, "failed to store player details")
	}
	// TTL on player key — auto-cleanup if they disconnect without calling Leave
	conn.Do("EXPIRE", playerKey, int(matchmakingTimeout.Seconds()))

	// Check pool size
	poolSize, err := redis.Int(conn.Do("ZCARD", matchmakingPoolKey))
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to check pool size")
	}

	log.Printf("👤 Player %s joined matchmaking pool (pool size: %d)", req.Username, poolSize)

	// TODO: If pool size >= minPlayersToStart, trigger room creation
	// This should:
	//   1. Acquire a distributed lock (room:lock:<id>) to prevent race conditions
	//   2. Pop up to maxPlayersPerRoom players from the sorted set
	//   3. Create room state in Redis (room:<id>:state, room:<id>:players)
	//   4. Publish match.created event to RabbitMQ
	//   5. Release the lock
	// if poolSize >= minPlayersToStart {
	//     go h.tryCreateRoom(conn)
	// }

	return &JoinResponse{
		Success:       true,
		Message:       "Added to matchmaking pool",
		QueuePosition: fmt.Sprintf("%d players waiting", poolSize),
	}, nil
}

// ─────────────────────────────────────────────────────────────
// LeaveMatchmaking
// ─────────────────────────────────────────────────────────────
// Called when a player cancels matchmaking (taps the X button).
// Removes them from the Redis sorted set.
func (h *MatchmakingHandler) LeaveMatchmaking(ctx context.Context, req *LeaveRequest) (*LeaveResponse, error) {
	if req.UserId == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}

	conn := h.pool.Get()
	defer conn.Close()

	// Remove from sorted set
	// ZREM matchmaking:pool <userId>
	removed, err := redis.Int(conn.Do("ZREM", matchmakingPoolKey, req.UserId))
	if err != nil {
		log.Printf("❌ Redis ZREM failed for user %s: %v", req.UserId, err)
		return nil, status.Error(codes.Internal, "failed to leave matchmaking pool")
	}

	// Clean up player hash
	conn.Do("DEL", fmt.Sprintf("player:%s", req.UserId))

	if removed == 0 {
		// Player wasn't in the pool — still return success (idempotent)
		log.Printf("⚠️  Player %s was not in the matchmaking pool", req.UserId)
		return &LeaveResponse{Success: true, Message: "Not in pool"}, nil
	}

	log.Printf("👋 Player %s left matchmaking pool", req.UserId)

	// TODO: If player was already assigned to a room, handle room cleanup
	// Check room:<id>:players and remove them, potentially cancelling the room

	return &LeaveResponse{
		Success: true,
		Message: "Removed from matchmaking pool",
	}, nil
}

// ─────────────────────────────────────────────────────────────
// SubscribeToMatch
// ─────────────────────────────────────────────────────────────
// Long-lived gRPC server stream. Flutter keeps this open after
// calling JoinMatchmaking. Server pushes a MatchFound event
// when a room is ready for this player.
func (h *MatchmakingHandler) SubscribeToMatch(req *SubscribeRequest, stream MatchmakingService_SubscribeToMatchServer) error {
	if req.UserId == "" {
		return status.Error(codes.InvalidArgument, "user_id is required")
	}

	log.Printf("📡 Player %s subscribed to match events", req.UserId)

	// TODO: Implement real subscription using Redis Pub/Sub or a channel map
	// The flow should be:
	//   1. Register this stream in an in-memory map keyed by userId
	//   2. When tryCreateRoom() assigns this player to a room,
	//      it looks up the stream and calls stream.Send(&MatchEvent{...})
	//   3. Keep the stream alive with a heartbeat / context cancellation
	//
	// Skeleton:
	// ctx := stream.Context()
	// for {
	//     select {
	//     case <-ctx.Done():
	//         log.Printf("Player %s disconnected from match stream", req.UserId)
	//         return nil
	//     case event := <-h.getPlayerChannel(req.UserId):
	//         if err := stream.Send(event); err != nil {
	//             return err
	//         }
	//     }
	// }

	// Placeholder — keeps stream open for 30s then times out
	select {
	case <-stream.Context().Done():
		log.Printf("📴 Player %s disconnected from match stream", req.UserId)
		return nil
	case <-time.After(matchmakingTimeout):
		// Send timeout event so Flutter can show "No match found, try again"
		_ = stream.Send(&MatchEvent{
			Event: &MatchEvent_MatchCancelled{
				MatchCancelled: &MatchCancelled{Reason: "timeout"},
			},
		})
		return nil
	}
}

// ─────────────────────────────────────────────────────────────
// tryCreateRoom (private — called when pool is big enough)
// ─────────────────────────────────────────────────────────────
func (h *MatchmakingHandler) tryCreateRoom(conn redis.Conn) {
	// TODO: Implement full room creation with distributed lock
	//
	// Step 1 — acquire lock
	// lockKey := fmt.Sprintf("room:lock:%s", roomId)
	// ok, _ := redis.String(conn.Do("SET", lockKey, "1", "NX", "PX", 10000))
	// if ok != "OK" { return } // another instance got the lock
	//
	// Step 2 — pop players from pool
	// players, _ := redis.Strings(conn.Do("ZPOPMIN", matchmakingPoolKey, maxPlayersPerRoom))
	//
	// Step 3 — create room in Redis
	// roomId := generateRoomId()
	// conn.Do("HSET", "room:"+roomId+":state", "status", "waiting", "created_at", time.Now().UnixMilli())
	// conn.Do("EXPIRE", "room:"+roomId+":state", 1800)
	//
	// Step 4 — publish match.created to RabbitMQ
	// room := &models.Room{ID: roomId, Players: players}
	// h.publisher.PublishMatchCreated(room)
	//
	// Step 5 — release lock
	// conn.Do("DEL", lockKey)

	log.Println("TODO: tryCreateRoom not yet implemented")
}

// ─────────────────────────────────────────────────────────────
// Temporary local types (replace with generated proto types)
// ─────────────────────────────────────────────────────────────
// TODO: Delete these once quiz_grpc.pb.go is imported and replace
// all usages with the quizpb.* equivalents.

type JoinRequest struct {
	UserId   string
	Username string
	Rating   int32
}
type JoinResponse struct {
	Success       bool
	Message       string
	QueuePosition string
}
type LeaveRequest struct{ UserId string }
type LeaveResponse struct {
	Success bool
	Message string
}
type SubscribeRequest struct{ UserId string }
type MatchEvent struct {
	Event interface{}
}
type MatchEvent_MatchCancelled struct {
	MatchCancelled *MatchCancelled
}
type MatchCancelled struct{ Reason string }
type MatchmakingService_SubscribeToMatchServer interface {
	Send(*MatchEvent) error
	Context() context.Context
}

// Ensure models is imported (used in tryCreateRoom TODO)
var _ = models.Room{}