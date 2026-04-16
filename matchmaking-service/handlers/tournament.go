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
	"go.mongodb.org/mongo-driver/mongo/options"

	"quiz-battle/shared/auth"
)

// TournamentHandler handles /tournament/* REST endpoints.
type TournamentHandler struct {
	db *mongo.Database
}

func NewTournamentHandler(db *mongo.Database) *TournamentHandler {
	return &TournamentHandler{db: db}
}

type tournamentDoc struct {
	ID              primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	Name            string             `bson:"name" json:"name"`
	Description     string             `bson:"description" json:"description"`
	Type            string             `bson:"type" json:"type"`
	Status          string             `bson:"status" json:"status"`
	StartsAt        time.Time          `bson:"starts_at" json:"starts_at"`
	EndsAt          time.Time          `bson:"ends_at" json:"ends_at"`
	MaxParticipants int                `bson:"max_participants" json:"max_participants"`
	EntryFee        int                `bson:"entry_fee" json:"entry_fee"`
	PremiumOnly     bool               `bson:"premium_only" json:"premium_only"`
	Prizes          map[string]int     `bson:"prizes" json:"prizes"`
	Rounds          int                `bson:"rounds" json:"rounds"`
	Difficulty      string             `bson:"difficulty" json:"difficulty"`
	Participants    []participant      `bson:"participants" json:"participants"`
	Winner          string             `bson:"winner,omitempty" json:"winner,omitempty"`
	CreatedAt       time.Time          `bson:"created_at" json:"created_at"`
}

type participant struct {
	UserID   string `bson:"user_id" json:"user_id"`
	Username string `bson:"username" json:"username"`
	Score    int    `bson:"score" json:"score"`
	Rank     int    `bson:"rank" json:"rank"`
}

func tournamentError(w http.ResponseWriter, code int, msg string) {
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"success": false, "error": msg}) //nolint:errcheck
}

// ── GET /tournament/list

func (h *TournamentHandler) List(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	cursor, err := h.db.Collection("tournaments").Find(ctx, bson.M{},
		options.Find().SetSort(bson.M{"starts_at": -1}).SetLimit(20))
	if err != nil {
		log.Printf("⚠️  tournament list: %v", err)
		tournamentError(w, http.StatusInternalServerError, "database error")
		return
	}
	defer cursor.Close(ctx)

	var tournaments []tournamentDoc
	if err := cursor.All(ctx, &tournaments); err != nil {
		tournamentError(w, http.StatusInternalServerError, "decode error")
		return
	}
	if tournaments == nil {
		tournaments = []tournamentDoc{}
	}

	json.NewEncoder(w).Encode(map[string]any{"success": true, "tournaments": tournaments}) //nolint:errcheck
}

// ── GET /tournament/detail?id=xxx

func (h *TournamentHandler) Detail(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	id := r.URL.Query().Get("id")
	if id == "" {
		tournamentError(w, http.StatusBadRequest, "id required")
		return
	}
	oid, err := primitive.ObjectIDFromHex(id)
	if err != nil {
		tournamentError(w, http.StatusBadRequest, "invalid id")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var t tournamentDoc
	if err := h.db.Collection("tournaments").FindOne(ctx, bson.M{"_id": oid}).Decode(&t); err != nil {
		tournamentError(w, http.StatusNotFound, "tournament not found")
		return
	}

	json.NewEncoder(w).Encode(map[string]any{"success": true, "tournament": t}) //nolint:errcheck
}

// ── POST /tournament/join

func (h *TournamentHandler) Join(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	tokenStr := r.Header.Get("Authorization")
	if len(tokenStr) > 7 && tokenStr[:7] == "Bearer " {
		tokenStr = tokenStr[7:]
	}
	userID, username, err := auth.ValidateToken(tokenStr)
	if err != nil {
		tournamentError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var body struct {
		TournamentID string `json:"tournament_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.TournamentID == "" {
		tournamentError(w, http.StatusBadRequest, "tournament_id required")
		return
	}

	oid, err := primitive.ObjectIDFromHex(body.TournamentID)
	if err != nil {
		tournamentError(w, http.StatusBadRequest, "invalid tournament_id")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var t tournamentDoc
	if err := h.db.Collection("tournaments").FindOne(ctx, bson.M{"_id": oid}).Decode(&t); err != nil {
		tournamentError(w, http.StatusNotFound, "tournament not found")
		return
	}

	if t.Status != "upcoming" {
		tournamentError(w, http.StatusBadRequest, "tournament is not open for registration")
		return
	}
	if len(t.Participants) >= t.MaxParticipants {
		tournamentError(w, http.StatusBadRequest, "tournament is full")
		return
	}
	for _, p := range t.Participants {
		if p.UserID == userID {
			tournamentError(w, http.StatusConflict, "already registered for this tournament")
			return
		}
	}

	// Premium check
	if t.PremiumOnly {
		count, _ := h.db.Collection("subscriptions").CountDocuments(ctx, bson.M{
			"user_id": userID, "status": "active", "expires_at": bson.M{"$gt": time.Now()},
		})
		if count == 0 {
			tournamentError(w, http.StatusForbidden, "premium subscription required")
			return
		}
	}

	// Entry fee
	if t.EntryFee > 0 {
		userOID, _ := primitive.ObjectIDFromHex(userID)
		var user struct{ Coins int `bson:"coins"` }
		h.db.Collection("users").FindOne(ctx, bson.M{"_id": userOID}).Decode(&user) //nolint:errcheck
		if user.Coins < t.EntryFee {
			tournamentError(w, http.StatusBadRequest, "not enough coins for entry fee")
			return
		}
		h.db.Collection("users").UpdateByID(ctx, userOID, bson.M{"$inc": bson.M{"coins": -t.EntryFee}}) //nolint:errcheck
	}

	_, err = h.db.Collection("tournaments").UpdateByID(ctx, oid, bson.M{
		"$push": bson.M{"participants": participant{UserID: userID, Username: username}},
	})
	if err != nil {
		tournamentError(w, http.StatusInternalServerError, "failed to join")
		return
	}

	log.Printf("🏆 Tournament join — user: %s (%s) → %s", username, userID, t.Name)

	json.NewEncoder(w).Encode(map[string]any{
		"success": true, "message": "Registered for " + t.Name,
		"participants": len(t.Participants) + 1, "max": t.MaxParticipants,
	}) //nolint:errcheck
}
