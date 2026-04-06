package redis

import (
	"fmt"

	"github.com/gomodule/redigo/redis"
)

const matchmakingPoolKey = "matchmaking:pool"

// AddToPool adds a player to the matchmaking sorted set with their rating as score.
func AddToPool(pool *redis.Pool, userID string, rating float64) error {
	conn := pool.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return fmt.Errorf("redis connection error: %w", err)
	}

	_, err := conn.Do("ZADD", matchmakingPoolKey, rating, userID)
	if err != nil {
		return fmt.Errorf("ZADD %s: %w", matchmakingPoolKey, err)
	}
	return nil
}

// GetMatchablePlayers returns all players in the pool if there are >= minSize entries,
// removing them atomically via a pipeline. Returns nil if the pool is too small.
func GetMatchablePlayers(pool *redis.Pool, minSize int) ([]string, error) {
	conn := pool.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return nil, fmt.Errorf("redis connection error: %w", err)
	}

	// Check current pool size before committing to a removal.
	count, err := redis.Int(conn.Do("ZCARD", matchmakingPoolKey))
	if err != nil {
		return nil, fmt.Errorf("ZCARD %s: %w", matchmakingPoolKey, err)
	}
	if count < minSize {
		return nil, nil
	}

	// Fetch all members, then delete the key — both sent in one pipeline flush
	// so no other caller can interleave between the read and the delete.
	if err := conn.Send("ZRANGE", matchmakingPoolKey, 0, -1); err != nil {
		return nil, fmt.Errorf("pipeline ZRANGE: %w", err)
	}
	if err := conn.Send("DEL", matchmakingPoolKey); err != nil {
		return nil, fmt.Errorf("pipeline DEL: %w", err)
	}
	if err := conn.Flush(); err != nil {
		return nil, fmt.Errorf("pipeline flush: %w", err)
	}

	players, err := redis.Strings(conn.Receive())
	if err != nil {
		return nil, fmt.Errorf("receive ZRANGE: %w", err)
	}
	// Consume the DEL reply; ignore the count value.
	if _, err := conn.Receive(); err != nil {
		return nil, fmt.Errorf("receive DEL: %w", err)
	}

	return players, nil
}
