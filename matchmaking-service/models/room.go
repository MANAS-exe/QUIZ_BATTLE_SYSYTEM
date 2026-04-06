package models

import "time"

// PlayerStatus mirrors the proto enum for internal use
type PlayerStatus string

const (
	StatusConnected    PlayerStatus = "connected"
	StatusDisconnected PlayerStatus = "disconnected"
	StatusReconnecting PlayerStatus = "reconnecting"
)

// RoomState mirrors the proto MatchState enum
type RoomState string

const (
	RoomStateWaiting    RoomState = "waiting"
	RoomStateInProgress RoomState = "in_progress"
	RoomStateFinished   RoomState = "finished"
)

// Player represents a participant in a quiz room.
// Stored as a Redis hash under key: room:<roomId>:players
type Player struct {
	UserID    string       `json:"user_id"`
	Username  string       `json:"username"`
	Rating    int          `json:"rating"`
	Score     int          `json:"score"`
	Rank      int          `json:"rank"`
	Status    PlayerStatus `json:"status"`
	JoinedAt  time.Time    `json:"joined_at"`
}

// Room represents the full state of a quiz room.
// Stored as a Redis hash under key: room:<roomId>:state
type Room struct {
	ID           string      `json:"id"`
	State        RoomState   `json:"state"`
	Players      []Player    `json:"players"`
	TotalRounds  int         `json:"total_rounds"`
	CurrentRound int         `json:"current_round"`
	CreatedAt    time.Time   `json:"created_at"`
	StartsAt     time.Time   `json:"starts_at"`
}

// MatchCreatedEvent is the payload published to RabbitMQ
// on the "match.created" routing key.
type MatchCreatedEvent struct {
	RoomID      string    `json:"room_id"`
	Players     []Player  `json:"players"`
	TotalRounds int       `json:"total_rounds"`
	CreatedAt   time.Time `json:"created_at"`
}