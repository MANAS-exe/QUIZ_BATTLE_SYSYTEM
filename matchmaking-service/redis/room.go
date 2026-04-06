package redis

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/gomodule/redigo/redis"
	"github.com/google/uuid"

	"quiz-battle/matchmaking/models"
)

const (
	roomTTLSeconds  = 30 * 60 // 30 minutes
	totalRounds     = 10
)

// CreateRoom acquires a distributed lock, persists room state and player data
// into Redis, then releases the lock. Returns the created Room on success.
func CreateRoom(pool *redis.Pool, players []models.Player) (*models.Room, error) {
	roomID := uuid.New().String()

	// ── 1. Acquire distributed lock ───────────────────────────
	if err := AcquireLock(pool, roomID); err != nil {
		return nil, fmt.Errorf("acquire lock for room %s: %w", roomID, err)
	}
	// Always release the lock, even on error paths below.
	defer func() {
		if err := ReleaseLock(pool, roomID); err != nil {
			log.Printf("⚠️  Failed to release lock for room %s: %v", roomID, err)
		}
	}()

	now := time.Now()
	room := &models.Room{
		ID:           roomID,
		State:        models.RoomStateWaiting,
		Players:      players,
		TotalRounds:  totalRounds,
		CurrentRound: 0,
		CreatedAt:    now,
		StartsAt:     now.Add(10 * time.Second), // 10-second lobby countdown
	}

	conn := pool.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return nil, fmt.Errorf("redis connection error: %w", err)
	}

	// ── 2. Store each player in room:{id}:players hash ────────
	// Key layout: field = userID, value = JSON-encoded Player
	playersKey := fmt.Sprintf("room:%s:players", roomID)
	for _, p := range players {
		encoded, err := json.Marshal(p)
		if err != nil {
			return nil, fmt.Errorf("marshal player %s: %w", p.UserID, err)
		}
		if err := conn.Send("HSET", playersKey, p.UserID, encoded); err != nil {
			return nil, fmt.Errorf("pipeline HSET players: %w", err)
		}
	}

	// ── 3. Store room state in room:{id}:state hash ───────────
	stateKey := fmt.Sprintf("room:%s:state", roomID)
	stateJSON, err := json.Marshal(room)
	if err != nil {
		return nil, fmt.Errorf("marshal room state: %w", err)
	}
	if err := conn.Send("SET", stateKey, stateJSON); err != nil {
		return nil, fmt.Errorf("pipeline SET state: %w", err)
	}

	// ── 4. Set 30-minute TTL on both keys ─────────────────────
	if err := conn.Send("EXPIRE", playersKey, roomTTLSeconds); err != nil {
		return nil, fmt.Errorf("pipeline EXPIRE players: %w", err)
	}
	if err := conn.Send("EXPIRE", stateKey, roomTTLSeconds); err != nil {
		return nil, fmt.Errorf("pipeline EXPIRE state: %w", err)
	}

	// Flush all four commands in one round-trip.
	if err := conn.Flush(); err != nil {
		return nil, fmt.Errorf("pipeline flush: %w", err)
	}

	// Drain replies — HSET returns the number of new fields added (one per player),
	// SET returns "OK", each EXPIRE returns 1.
	replyCount := len(players) + 3 // HSET×N + SET + EXPIRE×2
	for i := 0; i < replyCount; i++ {
		if _, err := conn.Receive(); err != nil {
			return nil, fmt.Errorf("pipeline receive [%d]: %w", i, err)
		}
	}

	log.Printf("🏠 Room %s created — %d players, state key: %s", roomID, len(players), stateKey)

	// ── 5. Lock released via deferred ReleaseLock above ───────
	return room, nil
}
