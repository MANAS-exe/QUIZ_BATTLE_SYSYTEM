package handlers

// change_password.go — HTTP handler for authenticated password changes.
//
// POST /user/change-password
//   Headers: Authorization: Bearer <jwt>
//   Body:    { "new_password": "..." }
//   Returns: { "success": true|false, "message": "..." }
//
// The endpoint requires a valid JWT so the user must be logged in.
// No old password is required — possession of a valid token is proof of identity.
// Use this for the in-app "Change Password" flow.

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"golang.org/x/crypto/bcrypt"

	"quiz-battle/shared/auth"
)

type ChangePasswordHandler struct {
	mongoDB *mongo.Database
}

func NewChangePasswordHandler(mongoDB *mongo.Database) *ChangePasswordHandler {
	return &ChangePasswordHandler{mongoDB: mongoDB}
}

type changePasswordRequest struct {
	NewPassword string `json:"new_password"`
}

type changePasswordResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
}

func (h *ChangePasswordHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// ── Authenticate via JWT ─────────────────────────────────────
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		writeChangePasswordResp(w, http.StatusUnauthorized, false, "missing Authorization header")
		return
	}
	token := strings.TrimPrefix(authHeader, "Bearer ")

	userID, _, err := auth.ValidateToken(token)
	if err != nil {
		writeChangePasswordResp(w, http.StatusUnauthorized, false, "invalid or expired token")
		return
	}

	// ── Parse body ───────────────────────────────────────────────
	var req changePasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeChangePasswordResp(w, http.StatusBadRequest, false, "invalid request body")
		return
	}
	if len(req.NewPassword) < 4 {
		writeChangePasswordResp(w, http.StatusBadRequest, false, "password must be at least 4 characters")
		return
	}

	// ── Hash and update ──────────────────────────────────────────
	hash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		log.Printf("change-password: bcrypt error for user %s: %v", userID, err)
		writeChangePasswordResp(w, http.StatusInternalServerError, false, "internal error")
		return
	}

	oid, err := primitive.ObjectIDFromHex(userID)
	if err != nil {
		writeChangePasswordResp(w, http.StatusBadRequest, false, "invalid user id")
		return
	}

	ctx := r.Context()
	res, err := h.mongoDB.Collection("users").UpdateOne(ctx,
		bson.M{"_id": oid},
		bson.M{"$set": bson.M{"password_hash": string(hash)}},
	)
	if err != nil {
		log.Printf("change-password: db error for user %s: %v", userID, err)
		writeChangePasswordResp(w, http.StatusInternalServerError, false, "database error")
		return
	}
	if res.MatchedCount == 0 {
		writeChangePasswordResp(w, http.StatusNotFound, false, "user not found")
		return
	}

	log.Printf("✅ Password changed for user %s", userID)
	writeChangePasswordResp(w, http.StatusOK, true, "Password updated successfully")
}

func writeChangePasswordResp(w http.ResponseWriter, status int, success bool, msg string) {
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(changePasswordResponse{Success: success, Message: msg}) //nolint:errcheck
}
