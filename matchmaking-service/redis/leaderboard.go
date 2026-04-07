package redis

import (
	"encoding/json"
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

// TrackResponseTime accumulates a player's response time for avg calculation.
// Stores running sum and count in room:{id}:response_sum / room:{id}:response_count hashes.
func TrackResponseTime(pool *redis.Pool, roomID, userID string, responseMs int64) error {
	conn := pool.Get()
	defer conn.Close()

	sumKey := fmt.Sprintf("room:%s:response_sum", roomID)
	cntKey := fmt.Sprintf("room:%s:response_count", roomID)
	if _, err := conn.Do("HINCRBYFLOAT", sumKey, userID, responseMs); err != nil {
		return fmt.Errorf("HINCRBYFLOAT %s: %w", sumKey, err)
	}
	if _, err := conn.Do("HINCRBY", cntKey, userID, 1); err != nil {
		return fmt.Errorf("HINCRBY %s: %w", cntKey, err)
	}
	conn.Do("EXPIRE", sumKey, 30*60) //nolint:errcheck
	conn.Do("EXPIRE", cntKey, 30*60) //nolint:errcheck
	return nil
}

// IncrCorrectAnswers atomically increments the correct-answer counter for a
// player inside a room. Called by the answer consumer whenever isCorrect==true.
func IncrCorrectAnswers(pool *redis.Pool, roomID, userID string) error {
	conn := pool.Get()
	defer conn.Close()
	key := fmt.Sprintf("room:%s:correct_counts", roomID)
	if _, err := conn.Do("HINCRBY", key, userID, 1); err != nil {
		return fmt.Errorf("HINCRBY %s/%s: %w", key, userID, err)
	}
	// Align TTL with room lifetime
	conn.Do("EXPIRE", key, 30*60) //nolint:errcheck
	return nil
}

// playerJSON is the minimal subset of models.Player we need from the room hash.
type playerJSON struct {
	Username string `json:"username"`
}

// GetPlayerMeta fetches (username, correctAnswers, avgResponseMs) for each userID.
// Sources:
//   - room:{roomID}:players          — username (30-min TTL)
//   - room:{roomID}:correct_counts   — per-player correct-answer count
//   - room:{roomID}:response_sum     — total response ms per player
//   - room:{roomID}:response_count   — answer count per player (for avg)
//
// Returns maps keyed by userID; missing values default to ("", 0, 0).
func GetPlayerMeta(pool *redis.Pool, roomID string, userIDs []string) (
	usernames map[string]string, correctCounts map[string]int, avgResponseMs map[string]int, err error,
) {
	conn := pool.Get()
	defer conn.Close()

	usernames = make(map[string]string, len(userIDs))
	correctCounts = make(map[string]int, len(userIDs))
	avgResponseMs = make(map[string]int, len(userIDs))

	// Pipeline:
	//   HGET room:{id}:players {uid}  — one per user  (JSON blob with username)
	//   HGETALL room:{id}:correct_counts
	//   HGETALL room:{id}:response_sum
	//   HGETALL room:{id}:response_count
	playersKey := fmt.Sprintf("room:%s:players", roomID)
	for _, uid := range userIDs {
		if pErr := conn.Send("HGET", playersKey, uid); pErr != nil {
			return nil, nil, nil, fmt.Errorf("HGET players pipeline: %w", pErr)
		}
	}
	if pErr := conn.Send("HGETALL", fmt.Sprintf("room:%s:correct_counts", roomID)); pErr != nil {
		return nil, nil, nil, fmt.Errorf("HGETALL correct_counts pipeline: %w", pErr)
	}
	if pErr := conn.Send("HGETALL", fmt.Sprintf("room:%s:response_sum", roomID)); pErr != nil {
		return nil, nil, nil, fmt.Errorf("HGETALL response_sum pipeline: %w", pErr)
	}
	if pErr := conn.Send("HGETALL", fmt.Sprintf("room:%s:response_count", roomID)); pErr != nil {
		return nil, nil, nil, fmt.Errorf("HGETALL response_count pipeline: %w", pErr)
	}
	if flushErr := conn.Flush(); flushErr != nil {
		return nil, nil, nil, fmt.Errorf("pipeline flush: %w", flushErr)
	}

	// Read JSON player blobs → usernames
	for _, uid := range userIDs {
		raw, _ := redis.Bytes(conn.Receive())
		if len(raw) > 0 {
			var p playerJSON
			if jsonErr := json.Unmarshal(raw, &p); jsonErr == nil {
				usernames[uid] = p.Username
			}
		}
	}

	// Read correct counts
	correctPairs, _ := redis.StringMap(conn.Receive())
	for uid, countStr := range correctPairs {
		var n int
		fmt.Sscanf(countStr, "%d", &n)
		correctCounts[uid] = n
	}

	// Read response sums and counts, compute avg
	sumPairs, _ := redis.StringMap(conn.Receive())
	cntPairs, _ := redis.StringMap(conn.Receive())
	for uid, sumStr := range sumPairs {
		var sum float64
		fmt.Sscanf(sumStr, "%f", &sum)
		var cnt float64
		fmt.Sscanf(cntPairs[uid], "%f", &cnt)
		if cnt > 0 {
			avgResponseMs[uid] = int(sum / cnt)
		}
	}

	return usernames, correctCounts, avgResponseMs, nil
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
