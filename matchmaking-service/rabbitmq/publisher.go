package rabbitmq

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"

	"quiz-battle/matchmaking/models"
)

const (
	exchangeName     = "sx"              // single topic exchange for all events
	exchangeType     = "topic"
	keyMatchCreated  = "match.created"   // routing key consumed by Room Service
	keyRoundCompleted = "round.completed" // routing key for round-end scoring
	keyMatchFinished  = "match.finished"  // routing key for match-end persistence
)

// Publisher holds a single AMQP connection and channel.
// For production, consider a reconnect loop — see TODO below.
type Publisher struct {
	conn    *amqp.Connection
	channel *amqp.Channel
}

// NewPublisher connects to RabbitMQ and declares the exchange.
// The exchange is declared idempotent (passive=false, durable=true)
// so it survives RabbitMQ restarts.
func NewPublisher(url string) (*Publisher, error) {
	conn, err := amqp.Dial(url)
	if err != nil {
		return nil, fmt.Errorf("amqp dial: %w", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("open channel: %w", err)
	}

	// Declare the shared topic exchange
	err = ch.ExchangeDeclare(
		exchangeName,
		exchangeType,
		true,  // durable — survives broker restart
		false, // auto-delete
		false, // internal
		false, // no-wait
		nil,
	)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("exchange declare: %w", err)
	}

	log.Printf("✅ RabbitMQ exchange declared: %s (%s)", exchangeName, exchangeType)

	return &Publisher{conn: conn, channel: ch}, nil
}

// PublishMatchCreated fires a match.created event onto the exchange.
// The Room Service and notification workers consume from this routing key.
func (p *Publisher) PublishMatchCreated(room *models.Room) error {
	event := models.MatchCreatedEvent{
		RoomID:      room.ID,
		Players:     room.Players,
		TotalRounds: room.TotalRounds,
		CreatedAt:   time.Now(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshal match.created event: %w", err)
	}

	err = p.channel.Publish(
		exchangeName,      // exchange
		keyMatchCreated,   // routing key
		false,             // mandatory — don't return unroutable messages
		false,             // immediate
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent, // survives broker restart
			Timestamp:    time.Now(),
			Body:         body,
		},
	)
	if err != nil {
		return fmt.Errorf("publish match.created: %w", err)
	}

	log.Printf("📨 Published match.created — room: %s, players: %d",
		room.ID, len(room.Players))

	// TODO: Add retry logic for publish failures
	// TODO: Implement publisher confirms (ch.Confirm + ack channel)
	// for guaranteed at-least-once delivery:
	// ch.Confirm(false)
	// confirms := ch.NotifyPublish(make(chan amqp.Confirmation, 1))
	// if ack := <-confirms; !ack.Ack { /* retry */ }

	return nil
}

// RoundCompletedEvent is published after every round (timer expired or all answered).
// Consumers use this to reveal the correct answer and finalise that round's scores.
type RoundCompletedEvent struct {
	RoomID           string    `json:"room_id"`
	RoundNumber      int       `json:"round_number"`
	QuestionID       string    `json:"question_id"`
	CorrectIndex     int       `json:"correct_index"` // revealed only after round ends
	RoundStartedAtMs int64     `json:"round_started_at_ms"`
	CompletedAt      time.Time `json:"completed_at"`
}

// MatchFinishedEvent is published once all rounds are done.
// Consumed by the leaderboard/persistence service to write final standings.
type MatchFinishedEvent struct {
	RoomID      string    `json:"room_id"`
	TotalRounds int       `json:"total_rounds"`
	FinishedAt  time.Time `json:"finished_at"`
}

// PublishRoundCompleted fires a round.completed event.
// The correct answer index is included so consumers can score and reveal it
// to clients without the answer ever travelling through the client stream
// before the round closes.
func (p *Publisher) PublishRoundCompleted(roomID string, roundNum int, questionID string, correctIndex int, roundStartedAtMs int64) error {
	event := RoundCompletedEvent{
		RoomID:           roomID,
		RoundNumber:      roundNum,
		QuestionID:       questionID,
		CorrectIndex:     correctIndex,
		RoundStartedAtMs: roundStartedAtMs,
		CompletedAt:      time.Now(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshal round.completed: %w", err)
	}

	if err := p.channel.Publish(
		exchangeName,
		keyRoundCompleted,
		false,
		false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			Timestamp:    time.Now(),
			Body:         body,
		},
	); err != nil {
		return fmt.Errorf("publish round.completed: %w", err)
	}

	log.Printf("📨 Published round.completed — room: %s round: %d", roomID, roundNum)
	return nil
}

// PublishMatchFinished fires a match.finished event after all rounds complete.
func (p *Publisher) PublishMatchFinished(roomID string, totalRounds int) error {
	event := MatchFinishedEvent{
		RoomID:      roomID,
		TotalRounds: totalRounds,
		FinishedAt:  time.Now(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshal match.finished: %w", err)
	}

	if err := p.channel.Publish(
		exchangeName,
		keyMatchFinished,
		false,
		false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			Timestamp:    time.Now(),
			Body:         body,
		},
	); err != nil {
		return fmt.Errorf("publish match.finished: %w", err)
	}

	log.Printf("🏁 Published match.finished — room: %s total rounds: %d", roomID, totalRounds)
	return nil
}

// Close cleans up the AMQP connection gracefully.
func (p *Publisher) Close() {
	if p.channel != nil {
		p.channel.Close()
	}
	if p.conn != nil {
		p.conn.Close()
	}
	log.Println("RabbitMQ connection closed")
}

// TODO: Add reconnect loop for production resilience
// RabbitMQ connections can drop. A production publisher should:
//   1. Listen on conn.NotifyClose(make(chan *amqp.Error))
//   2. On close, sleep with exponential backoff and re-dial
//   3. Re-declare the exchange and re-open the channel
//   4. Resume publishing