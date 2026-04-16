package handlers

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"

	"quiz-battle/shared/auth"
)

// Config holds Razorpay credentials loaded from environment variables.
type Config struct {
	RazorpayKeyID         string
	RazorpayKeySecret     string
	RazorpayWebhookSecret string
}

// PaymentHandler handles payment-related HTTP endpoints.
type PaymentHandler struct {
	db  *mongo.Database
	cfg *Config
}

func NewPaymentHandler(db *mongo.Database, cfg *Config) *PaymentHandler {
	return &PaymentHandler{db: db, cfg: cfg}
}

// ─────────────────────────────────────────────────────────────
// MongoDB document types
// ─────────────────────────────────────────────────────────────

// Subscription document stored in the `subscriptions` collection.
type Subscription struct {
	ID               primitive.ObjectID `bson:"_id,omitempty"    json:"id,omitempty"`
	UserID           string             `bson:"user_id"          json:"user_id"`
	Plan             string             `bson:"plan"             json:"plan"`             // free | monthly | yearly
	StartedAt        time.Time          `bson:"started_at"       json:"started_at"`
	ExpiresAt        *time.Time         `bson:"expires_at"       json:"expires_at"`
	RazorpayOrderID  string             `bson:"razorpay_order_id" json:"razorpay_order_id"`
	RazorpayPaymentID string            `bson:"razorpay_payment_id" json:"razorpay_payment_id"`
	Status           string             `bson:"status"           json:"status"` // active | expired | cancelled
}

// Payment document stored in the `payments` collection.
type Payment struct {
	ID                 primitive.ObjectID `bson:"_id,omitempty"          json:"id,omitempty"`
	PaymentID          string             `bson:"payment_id"             json:"payment_id"`
	UserID             string             `bson:"user_id"                json:"user_id"`
	OrderID            string             `bson:"order_id"               json:"order_id"`
	Plan               string             `bson:"plan"                   json:"plan"`
	Amount             int64              `bson:"amount"                 json:"amount"`
	Currency           string             `bson:"currency"               json:"currency"`
	Status             string             `bson:"status"                 json:"status"`
	RazorpayPaymentID  string             `bson:"razorpay_payment_id"    json:"razorpay_payment_id"`
	RazorpaySignature  string             `bson:"razorpay_signature"     json:"razorpay_signature"`
	CreatedAt          time.Time          `bson:"created_at"             json:"created_at"`
	WebhookReceivedAt  *time.Time         `bson:"webhook_received_at"    json:"webhook_received_at,omitempty"`
}

// ─────────────────────────────────────────────────────────────
// Razorpay API types
// ─────────────────────────────────────────────────────────────

type razorpayOrderRequest struct {
	Amount   int64  `json:"amount"`
	Currency string `json:"currency"`
	Receipt  string `json:"receipt"`
}

type razorpayOrderResponse struct {
	ID       string `json:"id"`
	Amount   int64  `json:"amount"`
	Currency string `json:"currency"`
	Receipt  string `json:"receipt"`
	Status   string `json:"status"`
}

// ─────────────────────────────────────────────────────────────
// JSON helpers
// ─────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("writeJSON encode error: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{"success": false, "message": message})
}

// ─────────────────────────────────────────────────────────────
// JWT extraction helper
// ─────────────────────────────────────────────────────────────

func extractBearerToken(r *http.Request) (string, error) {
	header := r.Header.Get("Authorization")
	if header == "" {
		return "", fmt.Errorf("missing Authorization header")
	}
	parts := strings.SplitN(header, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
		return "", fmt.Errorf("invalid Authorization header format")
	}
	return parts[1], nil
}

// ─────────────────────────────────────────────────────────────
// POST /payment/create-order
// ─────────────────────────────────────────────────────────────

func (h *PaymentHandler) CreateOrder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// 1. Parse JWT
	tokenStr, err := extractBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	userID, username, err := auth.ValidateToken(tokenStr)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid token: "+err.Error())
		return
	}

	// 2. Parse request body
	var body struct {
		Plan       string `json:"plan"`        // "monthly" | "yearly"
		CouponCode string `json:"coupon_code"` // optional referral discount code
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if body.Plan != "monthly" && body.Plan != "yearly" {
		writeError(w, http.StatusBadRequest, "plan must be 'monthly' or 'yearly'")
		return
	}

	// 3. Check for existing active subscription
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	subsColl := h.db.Collection("subscriptions")
	var existingSub Subscription
	err = subsColl.FindOne(ctx, bson.M{
		"user_id": userID,
		"status":  "active",
		"expires_at": bson.M{"$gt": time.Now()},
	}).Decode(&existingSub)
	if err == nil {
		writeError(w, http.StatusConflict, "user already has an active subscription")
		return
	}
	if err != mongo.ErrNoDocuments {
		log.Printf("CreateOrder: subscription lookup error for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// 4. Calculate amount (in paise)
	var amount int64
	switch body.Plan {
	case "monthly":
		amount = 49900 // ₹499
	case "yearly":
		amount = 399900 // ₹3999
	}

	originalAmount := amount
	discountApplied := false

	// Optional referral coupon — buyer enters a friend's referral code to get a discount.
	// Valid if: the code exists in the users collection AND does not belong to the buyer.
	if body.CouponCode != "" {
		couponCode := strings.ToUpper(strings.TrimSpace(body.CouponCode))
		usersColl := h.db.Collection("users")
		var codeOwner struct {
			ID primitive.ObjectID `bson:"_id"`
		}
		err := usersColl.FindOne(ctx,
			bson.M{"referral_code": couponCode},
			options.FindOne().SetProjection(bson.M{"_id": 1}),
		).Decode(&codeOwner)
		if err == nil && codeOwner.ID.Hex() != userID {
			// Code belongs to someone else — valid discount
			discountApplied = true
			switch body.Plan {
			case "monthly":
				amount = 39900 // ₹399 (₹100 off)
			case "yearly":
				amount = 349900 // ₹3499 (₹500 off)
			}
		} else if err == nil && codeOwner.ID.Hex() == userID {
			// Self-referral — reject
			writeError(w, http.StatusBadRequest, "you cannot use your own referral code")
			return
		} else if err != mongo.ErrNoDocuments {
			log.Printf("CreateOrder: coupon lookup error for code %s: %v", couponCode, err)
		}
		// If code not found (ErrNoDocuments), silently ignore — no discount applied
	}

	// 5. Generate a receipt ID
	receipt := fmt.Sprintf("rcpt_%s_%d", userID[:8], time.Now().UnixMilli())

	// 6. Create Razorpay order via REST API
	rzpOrder, err := h.createRazorpayOrder(amount, receipt)
	if err != nil {
		log.Printf("CreateOrder: Razorpay API error for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "failed to create payment order: "+err.Error())
		return
	}

	// 7. Save pending payment record to MongoDB
	paymentsColl := h.db.Collection("payments")
	paymentDoc := Payment{
		PaymentID: fmt.Sprintf("pay_%s_%d", userID[:8], time.Now().UnixNano()),
		UserID:    userID,
		OrderID:   rzpOrder.ID,
		Plan:      body.Plan,
		Amount:    amount,
		Currency:  "INR",
		Status:    "pending",
		CreatedAt: time.Now(),
	}
	if _, err := paymentsColl.InsertOne(ctx, paymentDoc); err != nil {
		log.Printf("CreateOrder: failed to save payment for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// 8. Return order details to Flutter
	writeJSON(w, http.StatusOK, map[string]any{
		"success":          true,
		"order_id":         rzpOrder.ID,
		"amount":           rzpOrder.Amount,
		"currency":         rzpOrder.Currency,
		"key_id":           h.cfg.RazorpayKeyID,
		"user_id":          userID,
		"username":         username,
		"plan":             body.Plan,
		"discount_applied": discountApplied,
		"original_amount":  originalAmount,
	})
}

// createRazorpayOrder makes a POST to the Razorpay Orders API.
func (h *PaymentHandler) createRazorpayOrder(amount int64, receipt string) (*razorpayOrderResponse, error) {
	reqBody, err := json.Marshal(razorpayOrderRequest{
		Amount:   amount,
		Currency: "INR",
		Receipt:  receipt,
	})
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, "https://api.razorpay.com/v1/orders", bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(h.cfg.RazorpayKeyID, h.cfg.RazorpayKeySecret)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HTTP request: %w", err)
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Razorpay API returned %d: %s", resp.StatusCode, string(respBytes))
	}

	var order razorpayOrderResponse
	if err := json.Unmarshal(respBytes, &order); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w", err)
	}
	return &order, nil
}

// ─────────────────────────────────────────────────────────────
// GET /payment/validate-coupon?code=XXXXXX
// Checks whether a referral code is valid for the requesting user without
// creating an order. Returns { valid, message }.
// ─────────────────────────────────────────────────────────────

func (h *PaymentHandler) ValidateCoupon(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	tokenStr, err := extractBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	userID, _, err := auth.ValidateToken(tokenStr)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid token")
		return
	}

	code := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("code")))
	if len(code) != 6 {
		writeJSON(w, http.StatusOK, map[string]any{
			"valid":   false,
			"message": "Referral code must be exactly 6 characters",
		})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	usersColl := h.db.Collection("users")
	var codeOwner struct {
		ID primitive.ObjectID `bson:"_id"`
	}
	err = usersColl.FindOne(ctx,
		bson.M{"referral_code": code},
		options.FindOne().SetProjection(bson.M{"_id": 1}),
	).Decode(&codeOwner)

	if err == mongo.ErrNoDocuments {
		writeJSON(w, http.StatusOK, map[string]any{
			"valid":   false,
			"message": "Referral code not found",
		})
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	if codeOwner.ID.Hex() == userID {
		writeJSON(w, http.StatusOK, map[string]any{
			"valid":   false,
			"message": "You can't use your own referral code",
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"valid":   true,
		"message": "Referral code applied! Save ₹100 on Monthly · ₹500 on Yearly",
	})
}

// ─────────────────────────────────────────────────────────────
// POST /payment/verify
// Called by Flutter after Razorpay checkout succeeds.
// Verifies client-side HMAC signature, captures payment, creates subscription.
// ─────────────────────────────────────────────────────────────

func (h *PaymentHandler) VerifyPayment(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	tokenStr, err := extractBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	userID, _, err := auth.ValidateToken(tokenStr)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid token: "+err.Error())
		return
	}

	var body struct {
		PaymentID string `json:"payment_id"`
		OrderID   string `json:"order_id"`
		Signature string `json:"signature"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if body.PaymentID == "" || body.OrderID == "" || body.Signature == "" {
		writeError(w, http.StatusBadRequest, "payment_id, order_id and signature are required")
		return
	}

	// Verify: HMAC-SHA256(key_secret, order_id + "|" + payment_id) must equal signature
	mac := hmac.New(sha256.New, []byte(h.cfg.RazorpayKeySecret))
	mac.Write([]byte(body.OrderID + "|" + body.PaymentID))
	expected := hex.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(expected), []byte(body.Signature)) {
		log.Printf("VerifyPayment: signature mismatch for user %s order %s", userID, body.OrderID)
		writeError(w, http.StatusUnauthorized, "invalid payment signature")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	paymentsColl := h.db.Collection("payments")

	// Idempotency: already captured?
	var existing Payment
	err = paymentsColl.FindOne(ctx, bson.M{
		"razorpay_payment_id": body.PaymentID,
		"status":              "captured",
	}).Decode(&existing)
	if err == nil {
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "plan": "premium", "message": "already processed"})
		return
	}
	if err != mongo.ErrNoDocuments {
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// Find pending payment by order_id
	var paymentDoc Payment
	if err = paymentsColl.FindOne(ctx, bson.M{"order_id": body.OrderID}).Decode(&paymentDoc); err != nil {
		log.Printf("VerifyPayment: order not found order_id=%s: %v", body.OrderID, err)
		writeError(w, http.StatusNotFound, "payment order not found")
		return
	}

	now := time.Now()

	// Mark payment as captured
	if _, err = paymentsColl.UpdateOne(ctx,
		bson.M{"order_id": body.OrderID},
		bson.M{"$set": bson.M{
			"razorpay_payment_id": body.PaymentID,
			"razorpay_signature":  body.Signature,
			"status":              "captured",
		}},
	); err != nil {
		log.Printf("VerifyPayment: failed to update payment %s: %v", body.PaymentID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// Calculate subscription expiry
	var expiresAt time.Time
	switch paymentDoc.Plan {
	case "yearly":
		expiresAt = now.AddDate(1, 0, 0)
	default:
		expiresAt = now.AddDate(0, 1, 0)
	}

	// Upsert subscription
	subsColl := h.db.Collection("subscriptions")
	if _, err = subsColl.UpdateOne(ctx,
		bson.M{"user_id": userID},
		bson.M{"$set": bson.M{
			"user_id":             userID,
			"plan":                "premium",
			"started_at":          now,
			"expires_at":          expiresAt,
			"razorpay_order_id":   body.OrderID,
			"razorpay_payment_id": body.PaymentID,
			"status":              "active",
		}},
		options.Update().SetUpsert(true),
	); err != nil {
		log.Printf("VerifyPayment: failed to upsert subscription for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// Update users.premium = true (non-fatal)
	usersColl := h.db.Collection("users")
	userOID, _ := primitive.ObjectIDFromHex(userID)
	if _, err = usersColl.UpdateOne(ctx,
		bson.M{"_id": userOID},
		bson.M{"$set": bson.M{"premium": true}},
	); err != nil {
		log.Printf("VerifyPayment: warning — could not set premium flag for user %s: %v", userID, err)
	}

	log.Printf("VerifyPayment: success — user=%s plan=%s expires=%s", userID, paymentDoc.Plan, expiresAt.Format(time.RFC3339))

	writeJSON(w, http.StatusOK, map[string]any{
		"success":    true,
		"plan":       "premium",
		"expires_at": expiresAt.Format(time.RFC3339),
		"message":    "payment verified and subscription activated",
	})
}

// ─────────────────────────────────────────────────────────────
// GET /payment/status
// ─────────────────────────────────────────────────────────────

func (h *PaymentHandler) GetStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	tokenStr, err := extractBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	userID, _, err := auth.ValidateToken(tokenStr)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid token: "+err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	subsColl := h.db.Collection("subscriptions")

	// Find most recent active subscription
	opts := options.FindOne().SetSort(bson.D{{Key: "started_at", Value: -1}})
	var sub Subscription
	err = subsColl.FindOne(ctx, bson.M{
		"user_id": userID,
		"status":  "active",
	}, opts).Decode(&sub)

	now := time.Now()
	if err == mongo.ErrNoDocuments {
		writeJSON(w, http.StatusOK, map[string]any{
			"success":    true,
			"plan":       "free",
			"expires_at": nil,
			"is_active":  false,
		})
		return
	}
	if err != nil {
		log.Printf("GetStatus: DB error for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// Check if subscription is actually still valid
	isActive := sub.ExpiresAt != nil && sub.ExpiresAt.After(now)
	var expiresAt *string
	if sub.ExpiresAt != nil {
		s := sub.ExpiresAt.Format(time.RFC3339)
		expiresAt = &s
	}

	plan := "free"
	if isActive {
		plan = "premium"
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"success":    true,
		"plan":       plan,
		"expires_at": expiresAt,
		"is_active":  isActive,
	})
}

// ─────────────────────────────────────────────────────────────
// GET /payment/history
// ─────────────────────────────────────────────────────────────

func (h *PaymentHandler) GetHistory(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	tokenStr, err := extractBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	userID, _, err := auth.ValidateToken(tokenStr)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid token: "+err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	paymentsColl := h.db.Collection("payments")
	opts := options.Find().SetSort(bson.D{{Key: "created_at", Value: -1}})
	cursor, err := paymentsColl.Find(ctx, bson.M{"user_id": userID}, opts)
	if err != nil {
		log.Printf("GetHistory: DB error for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	defer cursor.Close(ctx)

	var payments []Payment
	if err := cursor.All(ctx, &payments); err != nil {
		log.Printf("GetHistory: cursor decode error for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	if payments == nil {
		payments = []Payment{}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"success":  true,
		"payments": payments,
	})
}
