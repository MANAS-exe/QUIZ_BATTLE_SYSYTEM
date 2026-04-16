package handlers

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"

	"quiz-battle/shared/auth"
)

// UserStatsHandler serves:
//   GET  /user/stats — returns all persistent user stats from MongoDB
//   POST /user/stats — pushes local stats to MongoDB (called after every match/claim/streak update)
type UserStatsHandler struct {
	db *mongo.Database
}

func NewUserStatsHandler(db *mongo.Database) *UserStatsHandler {
	return &UserStatsHandler{db: db}
}

// userStats is the full set of persistent fields synced between Flutter and MongoDB.
type userStats struct {
	Rating              int      `bson:"rating" json:"rating"`
	MatchesPlayed       int      `bson:"matches_played" json:"matches_played"`
	MatchesWon          int      `bson:"matches_won" json:"matches_won"`
	Coins               int      `bson:"coins" json:"coins"`
	BonusGamesRemaining int      `bson:"bonus_games_remaining" json:"bonus_games_remaining"`
	CurrentStreak       int      `bson:"current_streak" json:"current_streak"`
	LongestStreak       int      `bson:"longest_streak" json:"longest_streak"`
	MaxQuestionStreak   int      `bson:"max_question_streak" json:"max_question_streak"`
	LoginHistory        []string `bson:"login_history" json:"login_history"`
	PremiumTrialExpiry  string   `bson:"premium_trial_expiry" json:"premium_trial_expiry"`
	DailyRewardClaimed  string   `bson:"daily_reward_claimed" json:"daily_reward_claimed"`

	// Last match details (Profile → LAST MATCH tab)
	LMWon             bool   `bson:"lm_won" json:"lm_won"`
	LMRank            int    `bson:"lm_rank" json:"lm_rank"`
	LMScore           int    `bson:"lm_score" json:"lm_score"`
	LMAnswersCorrect  int    `bson:"lm_answers_correct" json:"lm_answers_correct"`
	LMTotalRounds     int    `bson:"lm_total_rounds" json:"lm_total_rounds"`
	LMAvgResponseMs   int    `bson:"lm_avg_response_ms" json:"lm_avg_response_ms"`
	LMDurationSeconds int    `bson:"lm_duration_seconds" json:"lm_duration_seconds"`
	LMMaxStreak       int    `bson:"lm_max_streak" json:"lm_max_streak"`
	LMWinnerUsername  string `bson:"lm_winner_username" json:"lm_winner_username"`
}

func (h *UserStatsHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// Extract user ID from JWT
	tokenStr := r.Header.Get("Authorization")
	if len(tokenStr) > 7 && tokenStr[:7] == "Bearer " {
		tokenStr = tokenStr[7:]
	}
	userID, _, err := auth.ValidateToken(tokenStr)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	oid, err := primitive.ObjectIDFromHex(userID)
	if err != nil {
		http.Error(w, "invalid user id", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodGet:
		h.handleGet(w, r, oid, userID)
	case http.MethodPost:
		h.handlePost(w, r, oid, userID)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// GET /user/stats — returns all persistent stats from MongoDB.
func (h *UserStatsHandler) handleGet(w http.ResponseWriter, r *http.Request, oid primitive.ObjectID, userID string) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var stats userStats
	err := h.db.Collection("users").FindOne(ctx, bson.M{"_id": oid}).Decode(&stats)
	if err != nil {
		log.Printf("⚠️  GET /user/stats: user %s not found: %v", userID, err)
		json.NewEncoder(w).Encode(userStats{Rating: 1000})
		return
	}

	json.NewEncoder(w).Encode(stats) //nolint:errcheck
}

// POST /user/stats — pushes local stats to MongoDB. Uses $max for counters
// (takes the higher of local vs server) to prevent overwriting with stale data.
func (h *UserStatsHandler) handlePost(w http.ResponseWriter, r *http.Request, oid primitive.ObjectID, userID string) {
	var body userStats
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	// $max for counters that only go up (played, won, coins, streaks, last-match bests).
	// $set for values that can decrease (bonus_games_remaining) or are latest-wins.
	update := bson.M{
		"$max": bson.M{
			"matches_played":      body.MatchesPlayed,
			"matches_won":         body.MatchesWon,
			"coins":               body.Coins,
			"current_streak":      body.CurrentStreak,
			"longest_streak":      body.LongestStreak,
			"max_question_streak": body.MaxQuestionStreak,
			"lm_rank":             body.LMRank,
			"lm_score":            body.LMScore,
			"lm_answers_correct":  body.LMAnswersCorrect,
			"lm_total_rounds":     body.LMTotalRounds,
			"lm_avg_response_ms":  body.LMAvgResponseMs,
			"lm_duration_seconds": body.LMDurationSeconds,
			"lm_max_streak":       body.LMMaxStreak,
		},
		"$set": bson.M{
			// bonus_games_remaining can decrease (games consumed) — must use $set
			"bonus_games_remaining": body.BonusGamesRemaining,
			"login_history":         body.LoginHistory,
			"premium_trial_expiry":  body.PremiumTrialExpiry,
			"daily_reward_claimed":  body.DailyRewardClaimed,
			"lm_won":                body.LMWon,
			"lm_winner_username":    body.LMWinnerUsername,
		},
	}

	_, err := h.db.Collection("users").UpdateByID(ctx, oid, update)
	if err != nil {
		log.Printf("⚠️  POST /user/stats: user %s: %v", userID, err)
		http.Error(w, "failed to sync stats", http.StatusInternalServerError)
		return
	}

	log.Printf("📊 Stats synced for user %s (played=%d won=%d coins=%d streak=%d)",
		userID, body.MatchesPlayed, body.MatchesWon, body.Coins, body.CurrentStreak)

	json.NewEncoder(w).Encode(map[string]any{"success": true}) //nolint:errcheck
}
