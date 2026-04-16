package handlers

import (
	"context"
	"fmt"
	"log"
	"time"

	goredis "github.com/gomodule/redigo/redis"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
)

// PopulateUserRedisKeys mirrors user state into Redis for observability and
// demo purposes (e.g. Redis CLI commands like GET user:{id}:plan).
// Called after every successful login (Google, email/password, register).
// Errors are non-fatal — we log and continue.
func PopulateUserRedisKeys(pool *goredis.Pool, mongoDB *mongo.Database, userID string) {
	if pool == nil || mongoDB == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn := pool.Get()
	defer conn.Close()

	// Convert hex string to ObjectID for users collection queries.
	// The subscriptions collection stores user_id as a string, so no conversion needed there.
	oid, oidErr := primitive.ObjectIDFromHex(userID)

	// ── Plan ──────────────────────────────────────────────────
	subsColl := mongoDB.Collection("subscriptions")
	plan := "free"
	count, err := subsColl.CountDocuments(ctx, bson.M{
		"user_id":    userID,
		"status":     "active",
		"expires_at": bson.M{"$gt": time.Now()},
	})
	if err == nil && count > 0 {
		plan = "premium"
	}
	planKey := fmt.Sprintf("user:%s:plan", userID)
	conn.Do("SET", planKey, plan, "EX", 86400) //nolint:errcheck

	if oidErr != nil {
		log.Printf("⚠️  PopulateUserRedisKeys: invalid ObjectID %s: %v", userID, oidErr)
		return
	}

	// Single query to fetch all fields at once
	usersColl := mongoDB.Collection("users")
	var doc struct {
		DailyQuizUsed int    `bson:"daily_quiz_used"`
		LastQuizDate  string `bson:"last_quiz_date"`
		CurrentStreak int    `bson:"current_streak"`
		LongestStreak int    `bson:"longest_streak"`
		LastLoginDate string `bson:"last_login_date"`
		ReferralCode  string `bson:"referral_code"`
	}
	today := time.Now().UTC().Format("2006-01-02")
	if err := usersColl.FindOne(ctx, bson.M{"_id": oid}).Decode(&doc); err != nil {
		log.Printf("⚠️  PopulateUserRedisKeys: user %s not found: %v", userID, err)
		return
	}

	// ── Daily quota ──────────────────────────────────────────
	used := 0
	if doc.LastQuizDate == today {
		used = doc.DailyQuizUsed
	}
	remaining := 5 - used
	if remaining < 0 {
		remaining = 0
	}
	val := fmt.Sprintf("%d", remaining)
	if plan == "premium" {
		val = "unlimited"
	}
	conn.Do("SET", fmt.Sprintf("user:%s:daily_quota", userID), val, "EX", 86400) //nolint:errcheck

	// ── Streak ───────────────────────────────────────────────
	current := doc.CurrentStreak
	longest := doc.LongestStreak
	lastLogin := doc.LastLoginDate
	if lastLogin == "" {
		lastLogin = today
	}
	if current == 0 {
		current = 1
	}
	conn.Do("HSET", fmt.Sprintf("user:%s:streak", userID), //nolint:errcheck
		"current", current,
		"longest", longest,
		"last_login", lastLogin,
	)

	// ── Referral code ────────────────────────────────────────
	if doc.ReferralCode != "" {
		conn.Do("SET", fmt.Sprintf("referral:code:%s", doc.ReferralCode), userID) //nolint:errcheck
	}

	log.Printf("📊 Redis keys populated for user %s (plan=%s)", userID, plan)
}
