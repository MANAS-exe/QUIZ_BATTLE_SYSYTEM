package handlers

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// PaymentPublisher is the interface for publishing payment events to RabbitMQ.
type PaymentPublisher interface {
	PublishPaymentSuccess(event map[string]any) error
}

// WebhookHandler handles Razorpay webhook callbacks.
type WebhookHandler struct {
	db        *mongo.Database
	cfg       *Config
	publisher PaymentPublisher
}

func NewWebhookHandler(db *mongo.Database, cfg *Config) *WebhookHandler {
	return &WebhookHandler{db: db, cfg: cfg}
}

// SetPublisher attaches a RabbitMQ publisher for payment success events.
func (h *WebhookHandler) SetPublisher(p PaymentPublisher) {
	h.publisher = p
}

// ─────────────────────────────────────────────────────────────
// Razorpay webhook payload types
// ─────────────────────────────────────────────────────────────

type webhookPayload struct {
	Event  string         `json:"event"`
	Entity string         `json:"entity"`
	Payload webhookInner  `json:"payload"`
}

type webhookInner struct {
	Payment webhookPaymentWrapper `json:"payment"`
}

type webhookPaymentWrapper struct {
	Entity webhookPaymentEntity `json:"entity"`
}

type webhookPaymentEntity struct {
	ID          string            `json:"id"`
	OrderID     string            `json:"order_id"`
	Amount      int64             `json:"amount"`
	Currency    string            `json:"currency"`
	Status      string            `json:"status"`
	Notes       map[string]string `json:"notes"`
}

// ─────────────────────────────────────────────────────────────
// POST /payment/webhook
// ─────────────────────────────────────────────────────────────

func (h *WebhookHandler) HandleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Read raw body — needed for HMAC verification
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("Webhook: failed to read body: %v", err)
		writeError(w, http.StatusBadRequest, "cannot read request body")
		return
	}

	// CRITICAL: Verify HMAC-SHA256 signature BEFORE processing anything
	signature := r.Header.Get("X-Razorpay-Signature")
	if !h.verifySignature(rawBody, signature) {
		log.Printf("Webhook: signature verification failed (sig=%s)", signature)
		writeError(w, http.StatusUnauthorized, "invalid webhook signature")
		return
	}

	// Parse payload
	var payload webhookPayload
	if err := json.Unmarshal(rawBody, &payload); err != nil {
		log.Printf("Webhook: failed to parse payload: %v", err)
		writeError(w, http.StatusBadRequest, "invalid JSON payload")
		return
	}

	paymentEntity := payload.Payload.Payment.Entity
	log.Printf("Webhook: received event=%s payment_id=%s order_id=%s",
		payload.Event, paymentEntity.ID, paymentEntity.OrderID)

	switch payload.Event {
	case "payment.captured":
		h.handlePaymentCaptured(w, r, paymentEntity)
	case "payment.failed":
		h.handlePaymentFailed(w, r, paymentEntity, signature)
	default:
		// Unknown event — acknowledge receipt but do nothing
		log.Printf("Webhook: unhandled event type: %s", payload.Event)
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": "event acknowledged"})
	}
}

// verifySignature checks HMAC-SHA256(webhookSecret, rawBody) == signature.
func (h *WebhookHandler) verifySignature(body []byte, signature string) bool {
	mac := hmac.New(sha256.New, []byte(h.cfg.RazorpayWebhookSecret))
	mac.Write(body)
	expected := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(signature))
}

// ─────────────────────────────────────────────────────────────
// payment.captured
// ─────────────────────────────────────────────────────────────

func (h *WebhookHandler) handlePaymentCaptured(w http.ResponseWriter, r *http.Request, entity webhookPaymentEntity) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	paymentsColl := h.db.Collection("payments")

	// Idempotency: check if this payment_id has already been processed
	var existingPayment Payment
	err := paymentsColl.FindOne(ctx, bson.M{
		"razorpay_payment_id": entity.ID,
		"status":              "captured",
	}).Decode(&existingPayment)
	if err == nil {
		// Already processed — return 200 immediately
		log.Printf("Webhook: payment %s already processed (idempotent)", entity.ID)
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": "already processed"})
		return
	}
	if err != mongo.ErrNoDocuments {
		log.Printf("Webhook: idempotency check DB error: %v", err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// Find the pending payment record by order_id
	var paymentDoc Payment
	err = paymentsColl.FindOne(ctx, bson.M{"order_id": entity.OrderID}).Decode(&paymentDoc)
	if err != nil {
		log.Printf("Webhook: payment record not found for order_id=%s: %v", entity.OrderID, err)
		// Still return 200 so Razorpay doesn't retry forever
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": "order not found, acknowledged"})
		return
	}

	now := time.Now()

	// Update payment record: set razorpay_payment_id, signature, status=captured
	_, err = paymentsColl.UpdateOne(ctx,
		bson.M{"order_id": entity.OrderID},
		bson.M{"$set": bson.M{
			"razorpay_payment_id": entity.ID,
			"status":              "captured",
			"webhook_received_at": now,
		}},
	)
	if err != nil {
		log.Printf("Webhook: failed to update payment %s: %v", entity.ID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// Calculate subscription duration
	var expiresAt time.Time
	switch paymentDoc.Plan {
	case "yearly":
		expiresAt = now.AddDate(1, 0, 0) // +365 days
	default: // monthly
		expiresAt = now.AddDate(0, 1, 0) // +30 days
	}

	// Upsert subscription record
	subsColl := h.db.Collection("subscriptions")
	subFilter := bson.M{"user_id": paymentDoc.UserID}
	subUpdate := bson.M{
		"$set": bson.M{
			"user_id":             paymentDoc.UserID,
			"plan":                "premium",
			"started_at":          now,
			"expires_at":          expiresAt,
			"razorpay_order_id":   entity.OrderID,
			"razorpay_payment_id": entity.ID,
			"status":              "active",
		},
	}
	upsertOpts := options.Update().SetUpsert(true)
	if _, err := subsColl.UpdateOne(ctx, subFilter, subUpdate, upsertOpts); err != nil {
		log.Printf("Webhook: failed to upsert subscription for user %s: %v", paymentDoc.UserID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	// Update users collection: set premium=true
	usersColl := h.db.Collection("users")
	userOID, _ := primitive.ObjectIDFromHex(paymentDoc.UserID)
	_, err = usersColl.UpdateOne(ctx,
		bson.M{"_id": userOID},
		bson.M{"$set": bson.M{"premium": true}},
	)
	if err != nil {
		// Non-fatal — log but don't fail the webhook
		log.Printf("Webhook: warning — could not update users.premium for user %s: %v", paymentDoc.UserID, err)
	}

	log.Printf("Webhook: payment.captured processed — user=%s plan=%s expires=%s",
		paymentDoc.UserID, paymentDoc.Plan, expiresAt.Format(time.RFC3339))

	// Publish payment.success event to RabbitMQ (non-fatal if publisher unavailable)
	if h.publisher != nil {
		if pubErr := h.publisher.PublishPaymentSuccess(map[string]any{
			"order_id":    entity.OrderID,
			"payment_id":  entity.ID,
			"user_id":     paymentDoc.UserID,
			"plan":        paymentDoc.Plan,
			"amount":      entity.Amount,
			"captured_at": now.Format(time.RFC3339),
		}); pubErr != nil {
			log.Printf("Webhook: failed to publish payment.success event: %v", pubErr)
		} else {
			log.Printf("Webhook: payment.success event published to RabbitMQ")
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": "payment processed"})
}

// ─────────────────────────────────────────────────────────────
// payment.failed
// ─────────────────────────────────────────────────────────────

func (h *WebhookHandler) handlePaymentFailed(w http.ResponseWriter, r *http.Request, entity webhookPaymentEntity, signature string) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	paymentsColl := h.db.Collection("payments")
	now := time.Now()

	_, err := paymentsColl.UpdateOne(ctx,
		bson.M{"order_id": entity.OrderID},
		bson.M{"$set": bson.M{
			"status":              "failed",
			"razorpay_payment_id": entity.ID,
			"webhook_received_at": now,
		}},
	)
	if err != nil {
		log.Printf("Webhook: failed to update payment as failed for order %s: %v", entity.OrderID, err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	log.Printf("Webhook: payment.failed recorded for order_id=%s payment_id=%s", entity.OrderID, entity.ID)
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": "failure recorded"})
}
