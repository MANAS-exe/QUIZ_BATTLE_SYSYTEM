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

	rdb "quiz-battle/scoring/redis"
)

const (
	exchangeName     = "sx"
	answerQueue      = "answer-processing-queue"
	answerDLQ        = "answer-processing-dlq"
	answerRoutingKey = "answer.submitted"

	basePointsEasy   = 100
	basePointsMedium = 125
	basePointsHard   = 150
	speedBonusMax    = 50
	speedWindowMs    = 30_000 // full round duration — bonus decays linearly over 30s

	answersTTLSeconds = 30 * 60

	maxRetries = 3
	retryDelay = 2 * time.Second
)

type AnswerEvent struct {
	RoomID           string `json:"room_id"`
	UserID           string `json:"user_id"`
	RoundNumber      int    `json:"round_number"`
	QuestionID       string `json:"question_id"`
	AnswerIndex      int    `json:"answer_index"`
	SubmittedAtMs    int64  `json:"submitted_at_ms"`
	RoundStartedAtMs int64  `json:"round_started_at_ms"`
}

type questionDoc struct {
	QuestionID   string `bson:"question_id"`
	CorrectIndex int32  `bson:"correctIndex"`
	Difficulty   string `bson:"difficulty"`
}

type Consumer struct {
	conn      *amqp.Connection
	channel   *amqp.Channel
	redis     *goredis.Pool
	questions *mongo.Collection
}

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

	// Declare exchange (idempotent)
	if err := ch.ExchangeDeclare(exchangeName, "topic", true, false, false, false, nil); err != nil {
		conn.Close()
		return nil, fmt.Errorf("exchange declare: %w", err)
	}

	_, err = ch.QueueDeclare(answerDLQ, true, false, false, false, nil)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("queue declare %s: %w", answerDLQ, err)
	}

	_, err = ch.QueueDeclare(
		answerQueue, true, false, false, false,
		amqp.Table{
			"x-dead-letter-exchange":    "",
			"x-dead-letter-routing-key": answerDLQ,
		},
	)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("queue declare %s: %w", answerQueue, err)
	}

	err = ch.QueueBind(answerQueue, answerRoutingKey, exchangeName, false, nil)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("queue bind: %w", err)
	}

	if err := ch.Qos(1, 0, false); err != nil {
		conn.Close()
		return nil, fmt.Errorf("set QoS: %w", err)
	}

	log.Printf("✅ Scoring consumer ready — queue: %s, binding: %s → %s",
		answerQueue, exchangeName, answerRoutingKey)

	return &Consumer{
		conn:      conn,
		channel:   ch,
		redis:     redisPool,
		questions: mongoDB.Collection("questions"),
	}, nil
}

func (c *Consumer) Start(ctx context.Context) error {
	msgs, err := c.channel.Consume(answerQueue, "", false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume %s: %w", answerQueue, err)
	}

	log.Printf("▶  Scoring consumer consuming from %s", answerQueue)

	for {
		select {
		case <-ctx.Done():
			log.Println("Scoring consumer stopping")
			return nil
		case msg, ok := <-msgs:
			if !ok {
				return fmt.Errorf("consumer channel closed")
			}
			c.handle(msg)
		}
	}
}

func (c *Consumer) handle(msg amqp.Delivery) {
	var event AnswerEvent
	if err := json.Unmarshal(msg.Body, &event); err != nil {
		log.Printf("⚠️  Malformed payload, discarding: %v", err)
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
		log.Printf("⚠️  attempt %d/%d failed — user: %s room: %s err: %v",
			attempt, maxRetries, event.UserID, event.RoomID, lastErr)
		if attempt < maxRetries {
			time.Sleep(retryDelay)
		}
	}

	raw, _ := json.Marshal(event)
	log.Printf("💀 DLQ — failed after %d attempts\n  reason: %v\n  payload: %s",
		maxRetries, lastErr, raw)
	msg.Nack(false, false)
}

func (c *Consumer) process(ev AnswerEvent) error {
	answersKey := fmt.Sprintf("room:%s:answers:%d", ev.RoomID, ev.RoundNumber)

	conn := c.redis.Get()
	defer conn.Close()

	if err := conn.Err(); err != nil {
		return fmt.Errorf("redis connection: %w", err)
	}

	// Idempotency check
	exists, err := goredis.Int(conn.Do("HEXISTS", answersKey, ev.UserID))
	if err != nil {
		return fmt.Errorf("HEXISTS: %w", err)
	}
	if exists == 1 {
		log.Printf("⏭  Duplicate answer — user %s room %s round %d", ev.UserID, ev.RoomID, ev.RoundNumber)
		return nil
	}

	// Fetch correct answer
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	oid, parseErr := primitive.ObjectIDFromHex(ev.QuestionID)
	if parseErr != nil {
		log.Printf("⚠️  Invalid question ID %s", ev.QuestionID)
		return nil
	}

	var q questionDoc
	err = c.questions.FindOne(ctx, bson.M{"_id": oid}).Decode(&q)
	if err != nil {
		if err == mongo.ErrNoDocuments {
			log.Printf("⚠️  Unknown question %s", ev.QuestionID)
			return nil
		}
		return fmt.Errorf("mongo FindOne: %w", err)
	}

	// Score calculation
	basePoints := basePointsEasy
	switch q.Difficulty {
	case "medium":
		basePoints = basePointsMedium
	case "hard":
		basePoints = basePointsHard
	}

	points := 0
	isCorrect := int32(ev.AnswerIndex) == q.CorrectIndex

	if isCorrect {
		points = basePoints
		responseMs := ev.SubmittedAtMs - ev.RoundStartedAtMs
		log.Printf("🔍 Timing — user: %s submitted: %d roundStart: %d responseMs: %d",
			ev.UserID, ev.SubmittedAtMs, ev.RoundStartedAtMs, responseMs)
		if responseMs > 0 && responseMs < speedWindowMs {
			bonus := int(float64(speedBonusMax) * (1 - float64(responseMs)/float64(speedWindowMs)))
			points += bonus
			log.Printf("⚡ Speed bonus — user: %s responseMs: %d bonus: +%d total: %d",
				ev.UserID, responseMs, bonus, points)
		}
	}

	// Track stats
	if isCorrect {
		rdb.IncrCorrectAnswers(c.redis, ev.RoomID, ev.UserID) //nolint:errcheck
	}
	if responseMs := ev.SubmittedAtMs - ev.RoundStartedAtMs; responseMs > 0 && responseMs < 120_000 {
		rdb.TrackResponseTime(c.redis, ev.RoomID, ev.UserID, responseMs) //nolint:errcheck
		// Store per-round response time for fastest-player detection
		roundTimeKey := fmt.Sprintf("room:%s:round_time:%d", ev.RoomID, ev.RoundNumber)
		conn.Do("HSET", roundTimeKey, ev.UserID, responseMs)   //nolint:errcheck
		conn.Do("EXPIRE", roundTimeKey, answersTTLSeconds)       //nolint:errcheck
	}

	// Update leaderboard
	rank, err := rdb.UpdateScore(c.redis, ev.RoomID, ev.UserID, points)
	if err != nil {
		return fmt.Errorf("UpdateScore: %w", err)
	}

	// Mark answer processed
	conn.Do("HSET", answersKey, ev.UserID, ev.AnswerIndex) //nolint:errcheck
	conn.Do("EXPIRE", answersKey, answersTTLSeconds)        //nolint:errcheck

	log.Printf("✅ Scored — user: %s room: %s round: %d correct: %v points: %d rank: %d",
		ev.UserID, ev.RoomID, ev.RoundNumber, isCorrect, points, rank)

	return nil
}

func (c *Consumer) Close() {
	if c.channel != nil {
		c.channel.Close()
	}
	if c.conn != nil {
		c.conn.Close()
	}
	log.Println("Scoring consumer closed")
}
