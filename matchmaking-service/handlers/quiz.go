package handlers

import (
	"context"
	"fmt"
	"log"
	"math"
	"time"

	"github.com/redis/go-redis/v9"
	quiz "github.com/yourorg/quiz-battle/proto/quiz"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"

	"quiz-battle/matchmaking/rabbitmq"
)

const mongoURI = "mongodb://localhost:27017/quizdb"

// ─────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────

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
// MAIN FUNCTION
// ─────────────────────────────────────────

func SelectQuestionsForRoom(roomID string, players []string, count int) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// 1. Connect to MongoDB
	mongoClient, err := mongo.Connect(ctx, options.Client().ApplyURI(mongoURI))
	if err != nil {
		return nil, fmt.Errorf("mongo connect: %w", err)
	}
	defer mongoClient.Disconnect(ctx) //nolint:errcheck

	db := mongoClient.Database("quizdb")

	// 2. Find question IDs already seen by these players
	seenIDs, err := fetchSeenQuestionIDs(ctx, db, players)
	if err != nil {
		return nil, fmt.Errorf("fetch seen questions: %w", err)
	}

	// 3. Calculate per-difficulty counts (40 / 40 / 20)
	easy := int(math.Round(float64(count) * 0.40))
	medium := int(math.Round(float64(count) * 0.40))
	hard := count - easy - medium

	// 4. Sample questions per difficulty
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

	// 5. Store in Redis as room:{id}:questions
	if err := storeQuestionsInRedis(ctx, roomID, questionIDs); err != nil {
		return nil, fmt.Errorf("redis store: %w", err)
	}

	return questionIDs, nil
}

// ─────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────

func fetchSeenQuestionIDs(ctx context.Context, db *mongo.Database, players []string) ([]string, error) {
	col := db.Collection("match_history")

	filter := bson.M{
		"players.userId": bson.M{"$in": players},
	}
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
		{
			{Key: "$match", Value: bson.M{
				"difficulty": difficulty,
				"_id":        bson.M{"$nin": excludeIDs},
			}},
		},
		{
			{Key: "$sample", Value: bson.M{"size": n}},
		},
		{
			{Key: "$project", Value: bson.M{"_id": 1}},
		},
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

func storeQuestionsInRedis(ctx context.Context, roomID string, questionIDs []string) error {
	rdb := redis.NewClient(&redis.Options{
		Addr: "localhost:6379",
	})
	defer rdb.Close() //nolint:errcheck

	key := fmt.Sprintf("room:%s:questions", roomID)

	// RPush accepts ...interface{} — convert the slice
	args := make([]any, len(questionIDs))
	for i, id := range questionIDs {
		args[i] = id
	}

	pipe := rdb.Pipeline()
	pipe.Del(ctx, key)
	pipe.RPush(ctx, key, args...)
	pipe.Expire(ctx, key, 30*time.Minute)

	_, err := pipe.Exec(ctx)
	return err
}

// ─────────────────────────────────────────
// QUIZ SERVICE — round orchestration
// ─────────────────────────────────────────

// QuizService drives round execution for a single room.
// Construct once per room and call RunRound for each round in sequence.
type QuizService struct {
	rdb       *redis.Client
	mongoDB   *mongo.Database
	publisher *rabbitmq.Publisher
}

func NewQuizService(rdb *redis.Client, mongoDB *mongo.Database, pub *rabbitmq.Publisher) *QuizService {
	return &QuizService{rdb: rdb, mongoDB: mongoDB, publisher: pub}
}

// RunRound executes one quiz round end-to-end:
//
//  1. Pops the next question ID from the Redis list  room:{id}:questions
//  2. Fetches the full question document from MongoDB
//  3. Broadcasts a QuestionBroadcast GameEvent to the client stream
//  4. Runs a 30-second server-side countdown, emitting a TimerSync event
//     every second so Flutter clients can correct any local clock drift
//  5. Exits the countdown early if all players have already answered
//  6. Publishes "round.completed" to RabbitMQ (triggers scoring + answer reveal)
//  7. If no questions remain in the list, publishes "match.finished"
//
// Why server-side timer: the server is the authoritative clock.  A client that
// paused or manipulated its local timer would gain extra time — the server
// deadline prevents that.  TimerSync also synchronises devices that joined the
// stream with a few seconds of lag.
//
// NOTE: stream is one player's gRPC server-streaming connection.  In a
// multi-player room you call RunRound once per player stream (or fan-out via a
// stream registry before calling RunRound).
func (s *QuizService) RunRound(
	roomID string,
	roundNum int,
	stream quiz.QuizService_StreamGameEventsServer,
) error {
	ctx := stream.Context()

	// ── 1. Pop next question ID ───────────────────────────────────────────────
	// LPop gives FIFO order from the list built by SelectQuestionsForRoom.
	questionsKey := fmt.Sprintf("room:%s:questions", roomID)
	questionID, err := s.rdb.LPop(ctx, questionsKey).Result()
	if err != nil {
		return fmt.Errorf("pop question (room %s round %d): %w", roomID, roundNum, err)
	}

	// ── 2. Fetch question from MongoDB ────────────────────────────────────────
	questionOID, err := primitive.ObjectIDFromHex(questionID)
	if err != nil {
		return fmt.Errorf("invalid question ID %q: %w", questionID, err)
	}

	fetchCtx, fetchCancel := context.WithTimeout(ctx, 5*time.Second)
	defer fetchCancel()

	var q Question
	if err := s.mongoDB.Collection("questions").
		FindOne(fetchCtx, bson.M{"_id": questionOID}).Decode(&q); err != nil {
		return fmt.Errorf("fetch question %s: %w", questionID, err)
	}

	// ── 3. Broadcast QuestionBroadcast ────────────────────────────────────────
	const roundDuration = 30 * time.Second
	deadline := time.Now().Add(roundDuration)
	deadlineMs := deadline.UnixMilli()
	roundStartedAtMs := time.Now().UnixMilli()

	if err := stream.Send(&quiz.GameEvent{
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
	}); err != nil {
		return fmt.Errorf("send QuestionBroadcast: %w", err)
	}

	// ── 4 & 5. Server-side countdown with early-exit on all-answered ──────────
	// Player count is read once; answers are tracked in room:{id}:answers:{n}.
	playerCount, err := s.rdb.HLen(ctx, fmt.Sprintf("room:%s:players", roomID)).Result()
	if err != nil {
		return fmt.Errorf("get player count: %w", err)
	}
	answersKey := fmt.Sprintf("room:%s:answers:%d", roomID, roundNum)

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	timer := time.NewTimer(roundDuration)
	defer timer.Stop()

timerLoop:
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()

		case <-timer.C:
			// Hard deadline reached — move on regardless of answer count.
			break timerLoop

		case <-ticker.C:
			// Send TimerSync — client uses DeadlineMs to recompute remaining time,
			// eliminating drift that accumulates over multiple seconds.
			if err := stream.Send(&quiz.GameEvent{
				Event: &quiz.GameEvent_TimerSync{
					TimerSync: &quiz.TimerSync{
						RoundNumber:  int32(roundNum),
						ServerTimeMs: time.Now().UnixMilli(),
						DeadlineMs:   deadlineMs,
					},
				},
			}); err != nil {
				return fmt.Errorf("send TimerSync: %w", err)
			}

			// Early exit: all players submitted before the timer expired.
			answered, err := s.rdb.HLen(ctx, answersKey).Result()
			if err == nil && answered >= playerCount {
				break timerLoop
			}
		}
	}

	// ── 6. Publish round.completed ────────────────────────────────────────────
	// The correct answer travels only through RabbitMQ, never through the
	// client stream, so it cannot be intercepted before the round closes.
	if err := s.publisher.PublishRoundCompleted(
		roomID, roundNum, questionID, q.CorrectIndex, roundStartedAtMs,
	); err != nil {
		// Non-fatal: log and continue so remaining rounds are not blocked.
		log.Printf("WARN publish round.completed room=%s round=%d: %v", roomID, roundNum, err)
	}

	// ── 7. Publish match.finished when no questions remain ────────────────────
	remaining, err := s.rdb.LLen(ctx, questionsKey).Result()
	if err != nil {
		log.Printf("WARN check remaining questions room=%s: %v", roomID, err)
	}
	if remaining == 0 {
		if err := s.publisher.PublishMatchFinished(roomID, roundNum); err != nil {
			log.Printf("WARN publish match.finished room=%s: %v", roomID, err)
		}
	}

	return nil
}

// difficultyFromString maps the MongoDB string field to the proto enum.
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