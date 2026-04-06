package redis

import (
	"fmt"

	"github.com/gomodule/redigo/redis"
)

// updateScoreScript atomically:
//   1. Increments the player's score in the sorted set.
//   2. Returns their new 0-based rank (ZREVRANK — highest score = rank 0).
//
// KEYS[1] = leaderboard key  (room:{id}:leaderboard)
// ARGV[1] = points to add    (integer)
// ARGV[2] = userID           (member)
//
// Why Lua: ZINCRBY + ZREVRANK are two separate commands. Without atomicity,
// a concurrent update between them would return a stale rank. Lua scripts
// execute as a single Redis transaction — no interleaving possible.
var updateScoreScript = redis.NewScript(1, `
local key    = KEYS[1]
local points = tonumber(ARGV[1])
local member = ARGV[2]

redis.call('ZINCRBY', key, points, member)

-- ZREVRANK: rank 0 = highest score (leaderboard order)
local rank = redis.call('ZREVRANK', key, member)
return rank
`)

// LeaderboardEntry holds a single player's position data.
type LeaderboardEntry struct {
	UserID string
	Score  float64
	Rank   int // 1-based for display
}

func leaderboardKey(roomID string) string {
	return fmt.Sprintf("room:%s:leaderboard", roomID)
}

// UpdateScore increments userID's score by points and returns their new
// 1-based rank (rank 1 = highest score). The operation is atomic via Lua.
func UpdateScore(pool *redis.Pool, roomID, userID string, points int) (rank int, err error) {
	conn := pool.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return 0, fmt.Errorf("redis connection error: %w", err)
	}

	// Do runs the script using EVALSHA, falling back to EVAL on cache miss.
	reply, err := redis.Int(updateScoreScript.Do(conn, leaderboardKey(roomID), points, userID))
	if err != nil {
		return 0, fmt.Errorf("UpdateScore lua %s/%s: %w", roomID, userID, err)
	}

	// Redis ZREVRANK is 0-based; return 1-based rank to callers.
	return reply + 1, nil
}

// GetLeaderboard returns the top 10 players for roomID, ordered by score
// descending (rank 1 = highest). Uses ZREVRANGE WITHSCORES.
func GetLeaderboard(pool *redis.Pool, roomID string) ([]LeaderboardEntry, error) {
	conn := pool.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return nil, fmt.Errorf("redis connection error: %w", err)
	}

	// ZREVRANGE key 0 9 WITHSCORES → [member, score, member, score, ...]
	values, err := redis.Values(conn.Do("ZREVRANGE", leaderboardKey(roomID), 0, 9, "WITHSCORES"))
	if err != nil {
		return nil, fmt.Errorf("ZREVRANGE %s: %w", roomID, err)
	}

	entries := make([]LeaderboardEntry, 0, len(values)/2)
	for i := 0; i < len(values); i += 2 {
		userID, err := redis.String(values[i], nil)
		if err != nil {
			return nil, fmt.Errorf("parse member at index %d: %w", i, err)
		}
		score, err := redis.Float64(values[i+1], nil)
		if err != nil {
			return nil, fmt.Errorf("parse score at index %d: %w", i+1, err)
		}
		entries = append(entries, LeaderboardEntry{
			UserID: userID,
			Score:  score,
			Rank:   len(entries) + 1, // 1-based, already in descending order
		})
	}

	return entries, nil
}
