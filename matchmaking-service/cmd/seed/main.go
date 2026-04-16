// seed creates/resets test users in MongoDB with pre-hashed passwords.
// Run: go run ./cmd/seed [MONGO_URI]
//
// All test users have password: speakx123
// Uses upsert — if a user already exists their password is reset to speakx123
// WITHOUT touching their rating or other fields.
// This is intentional: run the seed whenever a dev user's password is unknown.
//
// Bot accounts:  alice, bob, charlie, diana, evan, fiona  (rating spread)
// Dev accounts:  manas, manas1, manas2, manas3, manas4
// Test accounts: e2e_alice, e2e_bob, demo_alice, demo_bob,
//                audit_user1, audit2, audit3, grpctest
package main

import (
	"context"
	"log"
	"os"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/bcrypt"
)

func main() {
	mongoURI := "mongodb://localhost:27017"
	if len(os.Args) > 1 {
		mongoURI = os.Args[1]
	}
	if v := os.Getenv("MONGO_URI"); v != "" {
		mongoURI = v
	}

	client, err := mongo.Connect(context.Background(), options.Client().ApplyURI(mongoURI))
	if err != nil {
		log.Fatalf("❌ MongoDB connect: %v", err)
	}
	defer client.Disconnect(context.Background()) //nolint:errcheck

	if err := client.Ping(context.Background(), nil); err != nil {
		log.Fatalf("❌ MongoDB ping: %v", err)
	}
	log.Printf("✅ Connected to MongoDB at %s", mongoURI)

	col := client.Database("quizdb").Collection("users")

	testUsers := []struct {
		username string
		rating   int // only used when creating a NEW user; existing users keep their rating
	}{
		// Bot accounts — span a wide rating range for matchmaking testing
		{"alice", 1200},
		{"bob", 1050},
		{"charlie", 1380},
		{"diana", 975},
		{"evan", 1520},
		{"fiona", 890},
		// Dev accounts
		{"manas", 1100},
		{"manas1", 53140},
		{"manas2", 53952},
		{"manas3", 47004},
		{"manas4", 1100},
		// Test / demo / audit accounts
		{"e2e_alice", 1000},
		{"e2e_bob", 1000},
		{"demo_alice", 1000},
		{"demo_bob", 1000},
		{"audit_user1", 1000},
		{"audit2", 1000},
		{"audit3", 1000},
		{"grpctest", 1000},
	}

	// Hash once — reuse for all test users (password: speakx123).
	hash, err := bcrypt.GenerateFromPassword([]byte("speakx123"), bcrypt.DefaultCost)
	if err != nil {
		log.Fatalf("❌ bcrypt: %v", err)
	}

	created, updated, failed := 0, 0, 0
	for _, u := range testUsers {
		// Upsert: create if not exists, reset password_hash if already exists.
		// This is intentional — re-running seed resets passwords to speakx123.
		filter := bson.M{"username": u.username}
		update := bson.M{
			// Only reset password_hash for existing users — never overwrite rating.
			"$set": bson.M{
				"password_hash": string(hash),
			},
			// rating and created_at are set ONLY when the document is first created.
			"$setOnInsert": bson.M{
				"rating":     u.rating,
				"created_at": time.Now(),
			},
		}
		opts := options.UpdateOptions{}
		upsert := true
		opts.Upsert = &upsert
		res, err := col.UpdateOne(context.Background(), filter, update, &opts)
		if err != nil {
			log.Printf("⚠️  Upsert %s: %v", u.username, err)
			failed++
			continue
		}
		if res.UpsertedCount > 0 {
			log.Printf("✅ Created user: %-10s rating: %d", u.username, u.rating)
			created++
		} else {
			log.Printf("🔄 Reset password: %-10s (already existed)", u.username)
			updated++
		}
	}

	log.Printf("\n── Seed summary ──────────────")
	log.Printf("  Created : %d", created)
	log.Printf("  Reset   : %d (password reset to speakx123)", updated)
	log.Printf("  Failed  : %d", failed)
	log.Printf("  Password: speakx123  (all test users)")

	// Verify counts
	total, _ := col.CountDocuments(context.Background(), bson.M{})
	log.Printf("  Total users in DB: %d", total)
}
