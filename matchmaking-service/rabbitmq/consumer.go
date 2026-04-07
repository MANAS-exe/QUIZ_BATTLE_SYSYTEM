package rabbitmq

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	goredis "github.com/gomodule/redigo/redis"
	amqp "github.com/rabbitmq/amqp091-go"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"

	rdb "quiz-battle/matchmaking/redis"
)

const (
	answerQueue      = "answer-processing-queue"
	answerDLQ        = "answer-processing-dlq"
	answerRoutingKey = "answer.submitted"

	basePoints    = 100
	speedBonusMax = 50
	speedWindowMs = 10_000 // 10 seconds — answers within this window earn a bonus

	answersTTLSeconds = 30 * 60 // mirrors room lifetime

	maxRetries  = 3
	retryDelay  = 2 * time.Second
)

// AnswerEvent is the JSON payload published on answer.submitted.
// Mirrors proto AnswerRequest + round_started_at_ms for speed bonus.
type AnswerEvent struct {
	RoomID           string `json:"room_id"`
	UserID           string `json:"user_id"`
	RoundNumber      int32  `json:"round_number"`
	QuestionID       string `json:"question_id"`
	AnswerIndex      int32  `json:"answer_index"`
	SubmittedAtMs    int64  `json:"submitted_at_ms"`
	RoundStartedAtMs int64  `json:"round_started_at_ms"`
}

// questionDoc is the minimal shape read from MongoDB questions collection.
type questionDoc struct {
	QuestionID   string `bson:"question_id"`
	CorrectIndex int32  `bson:"correctIndex"` // matches field name used in init.js seed
}

// Consumer reads answer.submitted events, validates answers against MongoDB,
// updates scores atomically in Redis, and guards against double-processing.
type Consumer struct {
	conn      *amqp.Connection
	channel   *amqp.Channel
	redis     *goredis.Pool
	questions *mongo.Collection
}

// NewConsumer connects to RabbitMQ, declares the queue bound to the shared
// topic exchange, and returns a ready Consumer.
// mongoDB should already be connected — pass client.Database("quiz").
func NewConsumer(amqpURL string, redisPool *goredis.Pool, mongoDB *mongo.Database) (*Consumer, error) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		return nil, fmt.Errorf("amqp dial: %w", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("open channel: %w", err)
	}

	// ── Dead Letter Queue ─────────────────────────────────────
	// Declared first so it exists before the main queue references it.
	// Messages nacked with requeue=false land here via the default exchange.
	_, err = ch.QueueDeclare(
		answerDLQ,
		true,  // durable
		false, // auto-delete
		false, // exclusive
		false, // no-wait
		nil,   // no special args — DLQ is just a plain holding queue
	)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("queue declare %s: %w", answerDLQ, err)
	}

	// ── Main queue with DLX args ───────────────────────────────
	// x-dead-letter-exchange: "" routes via the default exchange.
	// x-dead-letter-routing-key: the DLQ name is the routing key for the
	// default exchange, so rejected messages land directly on answerDLQ.
	_, err = ch.QueueDeclare(
		answerQueue,
		true,  // durable — survives broker restart
		false, // auto-delete
		false, // exclusive
		false, // no-wait
		amqp.Table{
			"x-dead-letter-exchange":    "",        // default exchange
			"x-dead-letter-routing-key": answerDLQ, // route straight to the DLQ
		},
	)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("queue declare %s: %w", answerQueue, err)
	}

	// Bind main queue to the shared topic exchange.
	err = ch.QueueBind(answerQueue, answerRoutingKey, exchangeName, false, nil)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("queue bind: %w", err)
	}

	// Process one message at a time — prevents overwhelming Redis/Mongo under burst.
	if err := ch.Qos(1, 0, false); err != nil {
		conn.Close()
		return nil, fmt.Errorf("set QoS: %w", err)
	}

	log.Printf("✅ Consumer ready — queue: %s, binding: %s → %s",
		answerQueue, exchangeName, answerRoutingKey)

	return &Consumer{
		conn:      conn,
		channel:   ch,
		redis:     redisPool,
		questions: mongoDB.Collection("questions"),
	}, nil
}

// Start begins consuming messages and blocks until ctx is cancelled.
// Each message is processed synchronously; delivery is ack'd or nack'd
// based on outcome so the broker knows what to retry.
func (c *Consumer) Start(ctx context.Context) error {
	msgs, err := c.channel.Consume(
		answerQueue,
		"",    // consumer tag — auto-generated
		false, // autoAck=false — we ack manually after processing
		false, // exclusive
		false, // no-local
		false, // no-wait
		nil,
	)
	if err != nil {
		return fmt.Errorf("consume %s: %w", answerQueue, err)
	}

	log.Printf("▶  Consuming from %s", answerQueue)

	for {
		select {
		case <-ctx.Done():
			log.Println("Consumer stopping — context cancelled")
			return nil

		case msg, ok := <-msgs:
			if !ok {
				return fmt.Errorf("consumer channel closed unexpectedly")
			}
			c.handle(msg)
		}
	}
}

// handle processes a single delivery.  Ack/Nack policy:
//   - Malformed JSON                    → Ack  (retrying can never fix bad JSON)
//   - Success                           → Ack
//   - Transient error, attempt < max    → sleep 2s, retry
//   - Transient error, attempts == max  → Nack requeue=false → broker sends to DLQ
func (c *Consumer) handle(msg amqp.Delivery) {
	var event AnswerEvent
	if err := json.Unmarshal(msg.Body, &event); err != nil {
		log.Printf("⚠️  Malformed answer.submitted payload, discarding: %v", err)
		msg.Ack(false)
		return
	}

	var lastErr error
	for attempt := 1; attempt <= maxRetries; attempt++ {
		lastErr = c.process(event)
		if lastErr == nil {
			msg.Ack(false)
			return
		}

		log.Printf("⚠️  attempt %d/%d failed — user: %s  room: %s  err: %v",
			attempt, maxRetries, event.UserID, event.RoomID, lastErr)

		if attempt < maxRetries {
			time.Sleep(retryDelay)
		}
	}

	// All retries exhausted — send to DLQ.
	// Log the full payload so it can be inspected / replayed from stdout.
	raw, _ := json.Marshal(event)
	log.Printf("💀 DLQ — message failed after %d attempts\n  reason : %v\n  payload: %s",
		maxRetries, lastErr, raw)

	// requeue=false: RabbitMQ routes the message to the dead-letter exchange
	// configured on answerQueue (default exchange → answerDLQ).
	msg.Nack(false, false)
}

// process runs the full pipeline for one answer event.
func (c *Consumer) process(ev AnswerEvent) error {
	// ── 1. Idempotency check ──────────────────────────────────
	// Redis hash  room:{id}:answers:{round}  field=userID  value=answerIndex
	answersKey := fmt.Sprintf("room:%s:answers:%d", ev.RoomID, ev.RoundNumber)

	conn := c.redis.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return fmt.Errorf("redis connection: %w", err)
	}

	exists, err := goredis.Int(conn.Do("HEXISTS", answersKey, ev.UserID))
	if err != nil {
		return fmt.Errorf("HEXISTS %s/%s: %w", answersKey, ev.UserID, err)
	}
	if exists == 1 {
		log.Printf("⏭  Duplicate answer — user %s room %s round %d, skipping",
			ev.UserID, ev.RoomID, ev.RoundNumber)
		return nil // not an error; ack the message
	}

	// ── 2. Fetch correct answer from MongoDB ──────────────────
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	oid, parseErr := primitive.ObjectIDFromHex(ev.QuestionID)
	if parseErr != nil {
		log.Printf("⚠️  Invalid question ID %s, discarding answer", ev.QuestionID)
		return nil
	}

	var q questionDoc
	err = c.questions.FindOne(ctx, bson.M{"_id": oid}).Decode(&q)
	if err != nil {
		if err == mongo.ErrNoDocuments {
			// Unknown question — discard rather than loop forever.
			log.Printf("⚠️  Unknown question %s, discarding answer", ev.QuestionID)
			return nil
		}
		return fmt.Errorf("mongo FindOne %s: %w", ev.QuestionID, err)
	}

	// ── 3. Score calculation ──────────────────────────────────
	points := 0
	isCorrect := ev.AnswerIndex == q.CorrectIndex

	if isCorrect {
		points = basePoints

		responseMs := ev.SubmittedAtMs - ev.RoundStartedAtMs
		if responseMs > 0 && responseMs < speedWindowMs {
			// Linear speed bonus: full bonus at 0ms, zero at speedWindowMs.
			// e.g. 3 000ms → bonus = 50 * (1 - 3000/10000) = 35
			bonus := int(float64(speedBonusMax) * (1 - float64(responseMs)/float64(speedWindowMs)))
			points += bonus
		}
	}

	// ── 4a. Track correct answers and response time ───────────
	if isCorrect {
		if incrErr := rdb.IncrCorrectAnswers(c.redis, ev.RoomID, ev.UserID); incrErr != nil {
			log.Printf("⚠️  IncrCorrectAnswers room=%s user=%s: %v", ev.RoomID, ev.UserID, incrErr)
		}
	}
	if responseMs := ev.SubmittedAtMs - ev.RoundStartedAtMs; responseMs > 0 && responseMs < 120_000 {
		if trackErr := rdb.TrackResponseTime(c.redis, ev.RoomID, ev.UserID, responseMs); trackErr != nil {
			log.Printf("⚠️  TrackResponseTime room=%s user=%s: %v", ev.RoomID, ev.UserID, trackErr)
		}
	}

	// ── 4b. Update leaderboard (atomic Lua) ──────────────────
	// UpdateScore uses ZINCRBY + ZREVRANK in a single Lua script.
	// Even if points == 0 we call it so the member always appears in the set.
	rank, err := rdb.UpdateScore(c.redis, ev.RoomID, ev.UserID, points)
	if err != nil {
		return fmt.Errorf("UpdateScore: %w", err)
	}

	// ── 5. Mark answer as processed (idempotency write) ───────
	// Store the submitted answer index so future duplicates are caught at step 1.
	_, err = conn.Do("HSET", answersKey, ev.UserID, ev.AnswerIndex)
	if err != nil {
		return fmt.Errorf("HSET %s/%s: %w", answersKey, ev.UserID, err)
	}
	// TTL mirrors the room lifetime so stale answer hashes are cleaned up automatically.
	if _, expErr := conn.Do("EXPIRE", answersKey, answersTTLSeconds); expErr != nil {
		log.Printf("⚠️  EXPIRE %s failed (memory leak risk): %v", answersKey, expErr)
	}

	log.Printf("✅ Scored — user: %s  room: %s  round: %d  correct: %v  points: %d  rank: %d",
		ev.UserID, ev.RoomID, ev.RoundNumber, isCorrect, points, rank)

	return nil
}

// Close shuts down the AMQP connection cleanly.
func (c *Consumer) Close() {
	if c.channel != nil {
		c.channel.Close()
	}
	if c.conn != nil {
		c.conn.Close()
	}
	log.Println("Consumer AMQP connection closed")
}
