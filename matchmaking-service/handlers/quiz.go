package handlers

import (
	"context"
	"fmt"
	"log"
	"math"
	"time"

	goredis "github.com/gomodule/redigo/redis"
	quiz "github.com/yourorg/quiz-battle/proto/quiz"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"

	"quiz-battle/matchmaking/rabbitmq"
)

// ─────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────

// Question is the MongoDB document shape for the questions collection.
type Question struct {
	ID              primitive.ObjectID `bson:"_id"`
	Text            string             `bson:"text"`
	Options         []string           `bson:"options"`
	CorrectIndex    int                `bson:"correctIndex"`
	Difficulty      string             `bson:"difficulty"`
	Topic           string             `bson:"topic"`
	AvgResponseTime int                `bson:"avgResponseTimeMs"`
}

type MatchHistory struct {
	RoundQuestions []string `bson:"questionIds"`
}

// ─────────────────────────────────────────
// QUESTION SELECTION
// ─────────────────────────────────────────

// SelectQuestionsForRoom samples questions from MongoDB (avoiding previously seen ones)
// and stores the ordered list in Redis under room:{id}:questions.
func SelectQuestionsForRoom(pool *goredis.Pool, db *mongo.Database, roomID string, players []string, count int) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	seenIDs, err := fetchSeenQuestionIDs(ctx, db, players)
	if err != nil {
		return nil, fmt.Errorf("fetch seen questions: %w", err)
	}

	easy := int(math.Round(float64(count) * 0.40))
	medium := int(math.Round(float64(count) * 0.40))
	hard := count - easy - medium

	type pick struct {
		difficulty string
		n          int
	}
	picks := []pick{
		{"easy", easy},
		{"medium", medium},
		{"hard", hard},
	}

	var questionIDs []string
	for _, p := range picks {
		ids, err := sampleQuestions(ctx, db, p.difficulty, p.n, seenIDs)
		if err != nil {
			return nil, fmt.Errorf("sample %s questions: %w", p.difficulty, err)
		}
		questionIDs = append(questionIDs, ids...)
	}

	if len(questionIDs) == 0 {
		return nil, fmt.Errorf("no questions returned — check your questions collection")
	}

	if err := storeQuestionsInRedis(pool, roomID, questionIDs); err != nil {
		return nil, fmt.Errorf("redis store: %w", err)
	}

	return questionIDs, nil
}

// ─────────────────────────────────────────
// QUIZ SERVICE — round orchestration
// ─────────────────────────────────────────

// BroadcastFn sends a GameEvent to all connected clients in the room.
// It is non-blocking: implementations should drop events for slow consumers.
type BroadcastFn func(event *quiz.GameEvent)

// QuizService drives round execution for a single room.
// Construct once and call RunRound for each round in sequence.
type QuizService struct {
	rdb       *goredis.Pool
	mongoDB   *mongo.Database
	publisher *rabbitmq.Publisher
}

func NewQuizService(rdb *goredis.Pool, mongoDB *mongo.Database, pub *rabbitmq.Publisher) *QuizService {
	return &QuizService{rdb: rdb, mongoDB: mongoDB, publisher: pub}
}

// RunRound executes one quiz round end-to-end:
//
//  1. Pops the next question ID from the Redis LIST  room:{id}:questions
//  2. Fetches the full question document from MongoDB
//  3. Broadcasts QuestionBroadcast to all connected clients via broadcast()
//  4. Runs a 30-second server-side countdown, emitting TimerSync every second
//  5. Exits early if all players have already answered
//  6. Publishes "round.completed" to RabbitMQ (triggers scoring + reveal)
//  7. If no questions remain, publishes "match.finished"
// RoundInfo holds data about a completed round for the caller to broadcast.
type RoundInfo struct {
	QuestionID        string
	CorrectIndex      int
	CorrectAnswerText string // the actual text of the correct option
}

func (s *QuizService) RunRound(
	ctx context.Context,
	roomID string,
	roundNum int,
	broadcast BroadcastFn,
	connectedCountFn func() int,
) (*RoundInfo, error) {
	conn := s.rdb.Get()
	defer conn.Close()

	// ── 1. Pop next question ID ────────────────────────────────────────────────
	questionsKey := fmt.Sprintf("room:%s:questions", roomID)
	questionID, err := goredis.String(conn.Do("LPOP", questionsKey))
	if err != nil {
		return nil, fmt.Errorf("pop question (room %s round %d): %w", roomID, roundNum, err)
	}

	// ── 2. Fetch question from MongoDB ─────────────────────────────────────────
	questionOID, err := primitive.ObjectIDFromHex(questionID)
	if err != nil {
		return nil, fmt.Errorf("invalid question ID %q: %w", questionID, err)
	}

	fetchCtx, fetchCancel := context.WithTimeout(ctx, 5*time.Second)
	defer fetchCancel()

	var q Question
	if err := s.mongoDB.Collection("questions").
		FindOne(fetchCtx, bson.M{"_id": questionOID}).Decode(&q); err != nil {
		return nil, fmt.Errorf("fetch question %s: %w", questionID, err)
	}

	// ── 3. Broadcast QuestionBroadcast ─────────────────────────────────────────
	const roundDuration = 30 * time.Second
	now := time.Now()
	deadline := now.Add(roundDuration)
	deadlineMs := deadline.UnixMilli()
	roundStartedAtMs := now.UnixMilli()

	startedAtKey := fmt.Sprintf("room:%s:round:%d:started_at", roomID, roundNum)
	if _, setErr := conn.Do("SET", startedAtKey, roundStartedAtMs, "EX", 30*60); setErr != nil {
		log.Printf("⚠️  Failed to store round start time room=%s round=%d: %v", roomID, roundNum, setErr)
	}

	broadcast(&quiz.GameEvent{
		Event: &quiz.GameEvent_Question{
			Question: &quiz.QuestionBroadcast{
				RoundNumber: int32(roundNum),
				Question: &quiz.Question{
					QuestionId:  questionID,
					Text:        q.Text,
					Options:     q.Options,
					Difficulty:  difficultyFromString(q.Difficulty),
					Topic:       q.Topic,
					TimeLimitMs: int32(roundDuration.Milliseconds()),
				},
				DeadlineMs: deadlineMs,
			},
		},
	})

	// ── 4 & 5. Server-side countdown — early-exit when all CONNECTED players answered
	answersKey := fmt.Sprintf("room:%s:answers:%d", roomID, roundNum)

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	timer := time.NewTimer(roundDuration)
	defer timer.Stop()

timerLoop:
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()

		case <-timer.C:
			break timerLoop

		case <-ticker.C:
			broadcast(&quiz.GameEvent{
				Event: &quiz.GameEvent_TimerSync{
					TimerSync: &quiz.TimerSync{
						RoundNumber:  int32(roundNum),
						ServerTimeMs: time.Now().UnixMilli(),
						DeadlineMs:   deadlineMs,
					},
				},
			})

			// Use connected player count (not total registered) for early exit
			activeCount := int64(connectedCountFn())

			// If no players left, exit immediately
			if activeCount <= 0 {
				log.Printf("⚡ No connected players — skipping round %d", roundNum)
				break timerLoop
			}

			answered, err := goredis.Int64(conn.Do("HLEN", answersKey))
			if err == nil && answered >= activeCount {
				log.Printf("⚡ All %d connected players answered — advancing round %d", activeCount, roundNum)
				break timerLoop
			}
		}
	}

	// ── 6. Publish round.completed ─────────────────────────────────────────────
	if err := s.publisher.PublishRoundCompleted(
		roomID, roundNum, questionID, q.CorrectIndex, roundStartedAtMs,
	); err != nil {
		log.Printf("WARN publish round.completed room=%s round=%d: %v", roomID, roundNum, err)
	}

	// ── 7. Publish match.finished when no questions remain ─────────────────────
	remaining, err := goredis.Int64(conn.Do("LLEN", questionsKey))
	if err != nil {
		log.Printf("WARN check remaining questions room=%s: %v", roomID, err)
	}
	if remaining == 0 {
		if err := s.publisher.PublishMatchFinished(roomID, roundNum); err != nil {
			log.Printf("WARN publish match.finished room=%s: %v", roomID, err)
		}
	}

	correctText := ""
	if q.CorrectIndex >= 0 && q.CorrectIndex < len(q.Options) {
		correctText = q.Options[q.CorrectIndex]
	}

	return &RoundInfo{
		QuestionID:        questionID,
		CorrectIndex:      q.CorrectIndex,
		CorrectAnswerText: correctText,
	}, nil
}

// ─────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────

func fetchSeenQuestionIDs(ctx context.Context, db *mongo.Database, players []string) ([]string, error) {
	col := db.Collection("match_history")
	filter := bson.M{"players.userId": bson.M{"$in": players}}
	findOpts := options.Find().SetProjection(bson.M{"questionIds": 1, "_id": 0})

	cursor, err := col.Find(ctx, filter, findOpts)
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx) //nolint:errcheck

	seen := make(map[string]struct{})
	for cursor.Next(ctx) {
		var h MatchHistory
		if err := cursor.Decode(&h); err != nil {
			continue
		}
		for _, id := range h.RoundQuestions {
			seen[id] = struct{}{}
		}
	}
	if err := cursor.Err(); err != nil {
		return nil, err
	}

	seenSlice := make([]string, 0, len(seen))
	for id := range seen {
		seenSlice = append(seenSlice, id)
	}
	return seenSlice, nil
}

func sampleQuestions(
	ctx context.Context,
	db *mongo.Database,
	difficulty string,
	n int,
	seenIDs []string,
) ([]string, error) {
	if n <= 0 {
		return nil, nil
	}

	col := db.Collection("questions")

	excludeIDs := make([]primitive.ObjectID, 0, len(seenIDs))
	for _, sid := range seenIDs {
		oid, err := primitive.ObjectIDFromHex(sid)
		if err == nil {
			excludeIDs = append(excludeIDs, oid)
		}
	}

	pipeline := mongo.Pipeline{
		{{Key: "$match", Value: bson.M{
			"difficulty": difficulty,
			"_id":        bson.M{"$nin": excludeIDs},
		}}},
		{{Key: "$sample", Value: bson.M{"size": n}}},
		{{Key: "$project", Value: bson.M{"_id": 1}}},
	}

	cursor, err := col.Aggregate(ctx, pipeline)
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx) //nolint:errcheck

	var ids []string
	for cursor.Next(ctx) {
		var result struct {
			ID primitive.ObjectID `bson:"_id"`
		}
		if err := cursor.Decode(&result); err != nil {
			continue
		}
		ids = append(ids, result.ID.Hex())
	}
	if err := cursor.Err(); err != nil {
		return nil, err
	}
	return ids, nil
}

func storeQuestionsInRedis(pool *goredis.Pool, roomID string, questionIDs []string) error {
	conn := pool.Get()
	defer conn.Close()

	key := fmt.Sprintf("room:%s:questions", roomID)

	if err := conn.Send("DEL", key); err != nil {
		return err
	}

	rpushArgs := make([]interface{}, 0, len(questionIDs)+1)
	rpushArgs = append(rpushArgs, key)
	for _, id := range questionIDs {
		rpushArgs = append(rpushArgs, id)
	}
	if err := conn.Send("RPUSH", rpushArgs...); err != nil {
		return err
	}

	if err := conn.Send("EXPIRE", key, 30*60); err != nil {
		return err
	}

	if err := conn.Flush(); err != nil {
		return err
	}

	// Drain 3 replies: DEL, RPUSH, EXPIRE
	for i := 0; i < 3; i++ {
		if _, err := conn.Receive(); err != nil {
			return err
		}
	}
	return nil
}

func difficultyFromString(s string) quiz.Difficulty {
	switch s {
	case "easy":
		return quiz.Difficulty_EASY
	case "medium":
		return quiz.Difficulty_MEDIUM
	case "hard":
		return quiz.Difficulty_HARD
	default:
		return quiz.Difficulty_DIFFICULTY_UNSPECIFIED
	}
}
