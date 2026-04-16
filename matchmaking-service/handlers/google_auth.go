package handlers

// google_auth.go — HTTP handler for Google Sign-In token verification.
//
// WHY REST (not gRPC)?
//   Google Sign-In is an OAuth 2.0 / OIDC flow that happens entirely outside
//   your gRPC protocol. The client receives a signed Google ID token (JWT)
//   that the backend must verify with Google's public keys. This is a one-time
//   auth exchange — not a stream — so a plain HTTP POST is the right tool.
//   Once the user is authenticated, they receive your app's own JWT and all
//   subsequent calls go over gRPC as usual.
//
// FLOW:
//   1. Flutter opens Google Sign-In SDK → Google returns an ID token
//   2. Flutter POST /auth/google  { "id_token": "eyJ..." }
//   3. Backend calls tokeninfo API to verify the token
//   4. Backend upserts user in MongoDB (create on first login, update on return)
//   5. Backend returns { token, user_id, username, email, picture_url, rating }
//   6. Flutter stores JWT, uses it as `Authorization: Bearer <jwt>` on all gRPC calls
//
// SECURITY:
//   - Token is verified server-side with Google's tokeninfo endpoint (not client-trusted)
//   - `aud` claim is checked against GOOGLE_CLIENT_ID env var
//   - All user fields come from Google's verified response, not the client body
//   - Password column stays empty for Google-only accounts (no hash stored)

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	goredis "github.com/gomodule/redigo/redis"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"

	"quiz-battle/shared/auth"
)

// ─────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────

// googleTokenInfo is the response from Google's tokeninfo validation endpoint.
// Reference: https://developers.google.com/identity/sign-in/web/backend-auth#verify-the-integrity-of-the-id-token
type googleTokenInfo struct {
	Sub           string `json:"sub"`             // unique Google user ID (stable, use as google_id)
	Email         string `json:"email"`
	EmailVerified string `json:"email_verified"`  // "true" | "false"
	Name          string `json:"name"`            // full display name
	GivenName     string `json:"given_name"`
	FamilyName    string `json:"family_name"`
	Picture       string `json:"picture"`         // profile picture URL (CDN, 96px)
	Aud           string `json:"aud"`             // must match GOOGLE_CLIENT_ID
	Iss           string `json:"iss"`             // must be accounts.google.com
	Exp           string `json:"exp"`             // unix epoch, already validated by Google
	ErrorDesc     string `json:"error_description"` // non-empty on invalid token
}

// googleAuthResponse is the JSON body returned to Flutter.
type googleAuthResponse struct {
	Success    bool   `json:"success"`
	Token      string `json:"token"`       // your app's JWT (not Google's token)
	UserID     string `json:"user_id"`
	Username   string `json:"username"`
	Email      string `json:"email"`
	PictureURL string `json:"picture_url"`
	Rating     int    `json:"rating"`
	IsNewUser  bool   `json:"is_new_user"` // true on first-ever login
	Message    string `json:"message"`
}

// ─────────────────────────────────────────
// GOOGLE USER — MongoDB document fields
// ─────────────────────────────────────────
// Extends the existing User struct with Google-specific fields.
// We use a separate projection struct to avoid touching the email/password auth path.

type googleUserDoc struct {
	ID           primitive.ObjectID `bson:"_id,omitempty"`
	Username     string             `bson:"username"`
	GoogleID     string             `bson:"google_id"`
	Email        string             `bson:"email"`
	PictureURL   string             `bson:"picture_url"`
	Rating       int                `bson:"rating"`
	CreatedAt    time.Time          `bson:"created_at"`
	UpdatedAt    time.Time          `bson:"updated_at"`
	ReferralCode string             `bson:"referral_code"`
}

// ─────────────────────────────────────────
// HANDLER
// ─────────────────────────────────────────

// GoogleAuthHandler handles POST /auth/google.
// It is attached to the matchmaking service's HTTP server (port 8080),
// alongside the gRPC-Web proxy.
type GoogleAuthHandler struct {
	users          *mongo.Collection
	mongoDB        *mongo.Database
	redisPool      *goredis.Pool
	googleClientID string // GOOGLE_CLIENT_ID env var — used to verify `aud` claim
}

func NewGoogleAuthHandler(mongoDB *mongo.Database) *GoogleAuthHandler {
	clientID := os.Getenv("GOOGLE_CLIENT_ID")
	if clientID == "" {
		log.Println("⚠️  GOOGLE_CLIENT_ID not set — skipping `aud` verification (dev mode)")
	}
	return &GoogleAuthHandler{
		users:          mongoDB.Collection("users"),
		mongoDB:        mongoDB,
		googleClientID: clientID,
	}
}

// SetRedisPool attaches a Redis pool for populating observability keys on login.
func (h *GoogleAuthHandler) SetRedisPool(pool *goredis.Pool) {
	h.redisPool = pool
}

// ServeHTTP handles POST /auth/google
// Expected body: { "id_token": "<google id token>" }
func (h *GoogleAuthHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Only accept POST
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// CORS headers — Flutter app needs these in development
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	w.Header().Set("Content-Type", "application/json")

	// Parse request body
	var body struct {
		IDToken string `json:"id_token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if body.IDToken == "" {
		writeError(w, http.StatusBadRequest, "id_token is required")
		return
	}

	// Verify token with Google
	info, err := verifyGoogleToken(r.Context(), body.IDToken)
	if err != nil {
		log.Printf("⚠️  Google token verification failed: %v", err)
		writeError(w, http.StatusUnauthorized, "invalid Google token")
		return
	}

	// Validate aud claim if client ID is configured
	if h.googleClientID != "" && info.Aud != h.googleClientID {
		log.Printf("⚠️  Google token aud mismatch: got %q want %q", info.Aud, h.googleClientID)
		writeError(w, http.StatusUnauthorized, "token audience mismatch")
		return
	}

	// Validate email is verified
	if info.EmailVerified != "true" {
		writeError(w, http.StatusUnauthorized, "Google account email not verified")
		return
	}

	// Upsert user — create on first login, update picture/email on return visits
	userDoc, isNew, err := h.upsertGoogleUser(r.Context(), info)
	if err != nil {
		log.Printf("❌ upsertGoogleUser: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to upsert user")
		return
	}

	// Issue your app's JWT (same format as email/password auth)
	userID := userDoc.ID.Hex()
	token, err := auth.GenerateToken(userID, userDoc.Username)
	if err != nil {
		log.Printf("❌ GenerateToken: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to generate token")
		return
	}

	log.Printf("✅ Google login — user: %s (%s) email: %s new: %v",
		userDoc.Username, userID, userDoc.Email, isNew)

	// Fire-and-forget: populate Redis observability keys
	go PopulateUserRedisKeys(h.redisPool, h.mongoDB, userID)

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(googleAuthResponse{ //nolint:errcheck
		Success:    true,
		Token:      token,
		UserID:     userID,
		Username:   userDoc.Username,
		Email:      userDoc.Email,
		PictureURL: userDoc.PictureURL,
		Rating:     userDoc.Rating,
		IsNewUser:  isNew,
		Message:    "Login successful",
	})
}

// ─────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────

// verifyGoogleToken calls Google's tokeninfo endpoint to validate the ID token.
// This is the server-side verification path recommended by Google for backends
// that cannot use the Google API client library.
//
// Alternative: use google.golang.org/api/idtoken package for offline verification
// (faster, no network call, but requires fetching public keys periodically).
func verifyGoogleToken(ctx context.Context, idToken string) (*googleTokenInfo, error) {
	url := "https://oauth2.googleapis.com/tokeninfo?id_token=" + idToken

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("tokeninfo request: %w", err)
	}
	defer resp.Body.Close() //nolint:errcheck

	var info googleTokenInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, fmt.Errorf("decode tokeninfo: %w", err)
	}
	if info.ErrorDesc != "" {
		return nil, fmt.Errorf("google says: %s", info.ErrorDesc)
	}
	if info.Sub == "" {
		return nil, fmt.Errorf("tokeninfo returned empty sub")
	}
	if info.Iss != "accounts.google.com" && info.Iss != "https://accounts.google.com" {
		return nil, fmt.Errorf("unexpected issuer: %s", info.Iss)
	}

	return &info, nil
}

// upsertGoogleUser finds a user by google_id; creates a new one if absent.
// On every login, picture_url and email are refreshed from Google's token
// (profile picture CDN URLs change periodically).
//
// Username strategy:
//   - New user: derive from given_name + first letter of family_name, lowercased
//     e.g. "John Doe" → "johnd"
//   - If that name is taken, append a short suffix from the google sub.
//   - Returning user: username never changes (stability > freshness).
func (h *GoogleAuthHandler) upsertGoogleUser(ctx context.Context, info *googleTokenInfo) (*googleUserDoc, bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	// Try find by google_id first
	var existing googleUserDoc
	err := h.users.FindOne(ctx, bson.M{"google_id": info.Sub}).Decode(&existing)
	if err == nil {
		// Returning user — refresh mutable fields
		_, updateErr := h.users.UpdateOne(ctx,
			bson.M{"_id": existing.ID},
			bson.M{"$set": bson.M{
				"email":       info.Email,
				"picture_url": info.Picture,
				"updated_at":  time.Now(),
			}},
		)
		if updateErr != nil {
			log.Printf("⚠️  refresh google user %s: %v", existing.Username, updateErr)
		}
		existing.Email = info.Email
		existing.PictureURL = info.Picture
		return &existing, false, nil
	}
	if err != mongo.ErrNoDocuments {
		return nil, false, fmt.Errorf("findOne by google_id: %w", err)
	}

	// Also check if an email/password account already exists for this email
	// (user may have registered earlier without Google). If so, link accounts.
	var emailUser googleUserDoc
	emailErr := h.users.FindOne(ctx, bson.M{"email": info.Email}).Decode(&emailUser)
	if emailErr == nil {
		// Link Google ID to existing account
		if _, linkErr := h.users.UpdateOne(ctx, bson.M{"_id": emailUser.ID}, bson.M{"$set": bson.M{
			"google_id":   info.Sub,
			"picture_url": info.Picture,
			"updated_at":  time.Now(),
		}}); linkErr != nil {
			return nil, false, fmt.Errorf("link google to existing email account: %w", linkErr)
		}
		emailUser.PictureURL = info.Picture
		return &emailUser, false, nil
	}

	// New user — derive username from Google name
	username := deriveUsername(info.GivenName, info.FamilyName, info.Sub)

	// Ensure username is unique (append suffix if collision)
	username, err = h.ensureUniqueUsername(ctx, username, info.Sub)
	if err != nil {
		return nil, false, fmt.Errorf("ensure unique username: %w", err)
	}

	// Generate a referral code at creation time so the user can immediately share.
	// Non-fatal: the code will be lazily generated on the first GET /referral/code.
	referralCode, codeErr := generateUniqueCode(ctx, h.users)
	if codeErr != nil {
		log.Printf("⚠️  google: failed to generate referral code for new user %s: %v", username, codeErr)
		referralCode = ""
	}

	newUser := googleUserDoc{
		Username:     username,
		GoogleID:     info.Sub,
		Email:        info.Email,
		PictureURL:   info.Picture,
		Rating:       1000,
		CreatedAt:    time.Now(),
		UpdatedAt:    time.Now(),
		ReferralCode: referralCode,
	}

	result, err := h.users.InsertOne(ctx, newUser)
	if err != nil {
		return nil, false, fmt.Errorf("insert user: %w", err)
	}
	newUser.ID = result.InsertedID.(primitive.ObjectID)
	return &newUser, true, nil
}

// deriveUsername creates a clean username from Google's display name.
// e.g. "John Doe" → "johnd"  |  "Alice" → "alice"
func deriveUsername(givenName, familyName, sub string) string {
	base := strings.ToLower(strings.ReplaceAll(givenName, " ", ""))
	if len(base) == 0 {
		base = "user"
	}
	if len(familyName) > 0 {
		base += strings.ToLower(string(familyName[0]))
	}
	// Keep to max 15 chars
	if len(base) > 15 {
		base = base[:15]
	}
	return base
}

// ensureUniqueUsername checks if the proposed username is taken; if so,
// appends a short numeric suffix derived from the Google sub.
func (h *GoogleAuthHandler) ensureUniqueUsername(ctx context.Context, username, sub string) (string, error) {
	candidate := username
	for i := 0; i < 10; i++ {
		count, err := h.users.CountDocuments(ctx, bson.M{"username": candidate},
			options.Count().SetLimit(1))
		if err != nil {
			return "", err
		}
		if count == 0 {
			return candidate, nil
		}
		// Collision — append last 4 digits of sub as suffix
		suffix := sub
		if len(suffix) > 4 {
			suffix = suffix[len(suffix)-4:]
		}
		candidate = fmt.Sprintf("%s%s", username, suffix)
		if i > 0 {
			candidate = fmt.Sprintf("%s%d", username, i)
		}
	}
	return candidate, nil
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{ //nolint:errcheck
		"success": false,
		"message": msg,
	})
}
