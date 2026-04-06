package redis

import (
	"errors"
	"fmt"

	"github.com/gomodule/redigo/redis"
)

const (
	lockTTLSeconds = 10
	lockKeyPrefix  = "room:lock:"
)

// ErrLockNotAcquired is returned when another instance already holds the lock.
var ErrLockNotAcquired = errors.New("lock not acquired: another instance holds it")

// AcquireLock tries to set room:lock:{roomID} using SET NX EX (atomic).
// Returns ErrLockNotAcquired if the lock is already held.
func AcquireLock(pool *redis.Pool, roomID string) error {
	conn := pool.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return fmt.Errorf("redis connection error: %w", err)
	}

	key := lockKeyPrefix + roomID

	// SET key "1" NX EX <ttl>
	// Returns "OK" on success, nil bulk string when NX condition fails.
	reply, err := redis.String(conn.Do("SET", key, "1", "NX", "EX", lockTTLSeconds))
	if err != nil {
		// redigo returns ErrNil when the SET NX was rejected (key exists).
		if errors.Is(err, redis.ErrNil) {
			return ErrLockNotAcquired
		}
		return fmt.Errorf("SET NX EX %s: %w", key, err)
	}
	if reply != "OK" {
		return ErrLockNotAcquired
	}
	return nil
}

// ReleaseLock deletes room:lock:{roomID}.
// Only the goroutine that created the room should call this.
func ReleaseLock(pool *redis.Pool, roomID string) error {
	conn := pool.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return fmt.Errorf("redis connection error: %w", err)
	}

	key := lockKeyPrefix + roomID

	_, err := conn.Do("DEL", key)
	if err != nil {
		return fmt.Errorf("DEL %s: %w", key, err)
	}
	return nil
}
