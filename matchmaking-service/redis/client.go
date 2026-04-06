package redis

import (
	"fmt"
	"log"
	"time"

	"github.com/gomodule/redigo/redis"
)

// NewPool creates a Redis connection pool.
// A pool reuses connections instead of opening a new TCP connection
// on every Redis call — critical for low-latency leaderboard updates.
func NewPool(addr string) *redis.Pool {
	return &redis.Pool{
		MaxIdle:     10,             // max idle connections sitting in the pool
		MaxActive:   100,            // max total connections (idle + in-use)
		IdleTimeout: 240 * time.Second, // close idle connections after 4 min
		Wait:        true,           // block callers when pool is exhausted (don't error)

		Dial: func() (redis.Conn, error) {
			conn, err := redis.Dial(
				"tcp",
				addr,
				redis.DialConnectTimeout(5*time.Second),
				redis.DialReadTimeout(3*time.Second),
				redis.DialWriteTimeout(3*time.Second),
			)
			if err != nil {
				return nil, fmt.Errorf("redis dial %s: %w", addr, err)
			}
			return conn, nil
		},

		// TestOnBorrow checks the connection is still alive before handing
		// it to a caller. Runs only if the connection has been idle > 1 min.
		TestOnBorrow: func(c redis.Conn, t time.Time) error {
			if time.Since(t) < time.Minute {
				return nil
			}
			_, err := c.Do("PING")
			if err != nil {
				log.Printf("⚠️  Redis health check failed: %v", err)
			}
			return err
		},
	}
}