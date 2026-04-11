# Quiz Battle

Real-time multiplayer quiz game built with a **microservices architecture** — 3 Go gRPC services, Flutter frontend, MongoDB, Redis, and RabbitMQ.

Players register, get matched with opponents, compete across 10 timed rounds with difficulty-based scoring and speed bonuses, and climb persistent leaderboards.

---

## Architecture

```
                        Flutter App (iOS / Android / Web)
                          |           |           |
                   gRPC :50051   gRPC :50052   gRPC :50053
                          |           |           |
               +----------+     +-----+-----+    +------------+
               |                |           |                  |
    Matchmaking Service    Quiz Engine Service    Scoring Service
    (Auth + Matchmaking)   (Game Loop + Rounds)   (Answer Scoring)
               |                |           |                  |
               +---pub-------->|           |<------sub---------+
               | match.created  |           |  answer.submitted |
               +----------------+-----------+------------------+
                                |           |
                          +-----+-----+-----+-----+
                          |           |           |
                       MongoDB      Redis     RabbitMQ
```

### Service Responsibilities

| Service | Port | Responsibilities |
|---------|------|-----------------|
| **Matchmaking** | :50051 | User registration/login (JWT), matchmaking pool, room creation, publishes `match.created` |
| **Quiz Engine** | :50052 | Consumes `match.created` (selects questions), runs game loop, streams events to clients, publishes `answer.submitted` |
| **Scoring** | :50053 | Consumes `answer.submitted` (validates + scores), updates Redis leaderboard, exposes `GetLeaderboard` RPC |

### Inter-Service Communication

| From | To | Mechanism | Event |
|------|----|-----------|-------|
| Matchmaking | Quiz Engine | RabbitMQ | `match.created` (triggers question selection) |
| Quiz Engine | Scoring | RabbitMQ | `answer.submitted` (triggers scoring) |
| Quiz Engine | (any) | RabbitMQ | `round.completed`, `match.finished` |
| Flutter | Matchmaking | gRPC :50051 | Register, Login, JoinMatchmaking, SubscribeToMatch |
| Flutter | Quiz Engine | gRPC :50052 | StreamGameEvents, SubmitAnswer, GetRoomQuestions |
| Flutter | Scoring | gRPC :50053 | GetLeaderboard |

---

## Tech Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Frontend | Flutter / Dart | Cross-platform mobile UI |
| Backend | Go 1.25 (3 services) | gRPC servers, game orchestration |
| Communication | gRPC + Protobuf | Real-time streaming, type-safe contracts |
| Database | MongoDB 7 | Users, questions, match history |
| Cache / State | Redis 7 | Matchmaking pool, room state, leaderboards |
| Message Broker | RabbitMQ 3 | Async inter-service communication |
| Auth | JWT (HS256) + bcrypt | Token-based auth with password hashing |
| State Management | Riverpod | Flutter reactive state |
| Navigation | GoRouter | Declarative routing with auth guards |

---

## Project Structure

```
quiz_battle/
├── proto/
│   └── quiz.proto                     # Shared gRPC service definitions (4 services, 30+ messages)
├── shared/                            # Shared Go module (imported by all 3 services)
│   ├── auth/jwt.go                    # JWT generation + validation
│   ├── middleware/auth.go             # gRPC auth interceptors (unary + stream)
│   └── models/room.go                # Room, Player, MatchCreatedEvent structs
├── matchmaking-service/               # Port :50051
│   ├── Dockerfile
│   ├── main.go                        # Auth + Matchmaking gRPC server
│   ├── handlers/
│   │   ├── auth.go                    # Register / Login (bcrypt + JWT)
│   │   └── matchmaking.go            # Join/Leave pool, room creation, WaitingUpdate broadcast
│   └── redis/
│       ├── client.go                  # Connection pooling (MaxActive: 100)
│       ├── room.go                    # CreateRoom with distributed lock + pipeline
│       └── lock.go                    # SET NX EX with UUID owner + Lua compare-and-delete
├── quiz-service/                      # Port :50052
│   ├── Dockerfile
│   ├── main.go                        # Quiz gRPC server + match.created consumer
│   ├── handlers/
│   │   ├── quiz.go                    # RunRound (timer loop, early-exit, TimerSync broadcast)
│   │   └── quiz_handler.go           # StreamGameEvents, SubmitAnswer, game loop, room hub
│   ├── questions/
│   │   └── selection.go              # MongoDB $sample with difficulty distribution + seen-question avoidance
│   ├── redis/
│   │   ├── client.go                  # Connection pooling
│   │   └── leaderboard.go            # Atomic Lua score updates, player metadata
│   └── rabbitmq/
│       ├── publisher.go               # Publishes answer.submitted, round.completed, match.finished
│       └── match_consumer.go          # Consumes match.created → SelectForRoom
├── scoring-service/                   # Port :50053
│   ├── Dockerfile
│   ├── main.go                        # Scoring gRPC server + answer consumer
│   ├── handlers/
│   │   └── scoring.go                 # CalculateScore, GetLeaderboard RPCs
│   ├── redis/
│   │   ├── client.go                  # Connection pooling
│   │   └── leaderboard.go            # Atomic Lua score updates (ZINCRBY + ZREVRANK + EXPIRE)
│   └── rabbitmq/
│       └── consumer.go                # Consumes answer.submitted → validate + score + update leaderboard
├── flutter-app/
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart                  # Router (7 routes), theme, auth init
│       ├── models/
│       │   └── game_event.dart        # Sealed event classes (9 types)
│       ├── services/
│       │   ├── auth_service.dart      # Login/Register provider with JWT storage
│       │   ├── game_service.dart      # 3 gRPC channels (50051/50052/50053), all RPC methods
│       │   └── reconnect_service.dart # Exponential backoff (1-16s, 5 retries)
│       ├── providers/
│       │   └── game_provider.dart     # Central game state machine (8 phases)
│       └── screens/
│           ├── login_screen.dart
│           ├── matchmaking_screen.dart
│           ├── quiz_screen.dart
│           ├── leaderboard_screen.dart
│           ├── results_screen.dart
│           └── spectating_screen.dart
├── docker-compose.yml                 # All 3 services + MongoDB + Redis + RabbitMQ
├── mongo-init/
│   └── init.js                        # Seed 60 questions + create indexes
├── Makefile                           # proto, infra, up, down, test, run-*, seed, kill
└── README.md
```

---

## Prerequisites

```bash
# macOS
brew install go protobuf redis

# Flutter SDK — https://docs.flutter.dev/get-started/install

# Protobuf plugins
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
dart pub global activate protoc_plugin

# Docker — https://docs.docker.com/desktop/install/mac-install/

# Xcode + iOS Simulators
xcode-select --install
```

---

## Quick Start

### 1. Start infrastructure

```bash
make infra
# Starts MongoDB (:27017), Redis (:6379), RabbitMQ (:5672 / UI :15672)
```

### 2. Start all 3 backend services (separate terminals)

```bash
# Terminal 1
make run-matchmaking

# Terminal 2
make run-quiz

# Terminal 3
make run-scoring
```

You should see:
```
✅ Redis connected       ✅ RabbitMQ connected       ✅ MongoDB connected
✅ AuthService registered
✅ MatchmakingService registered
🚀 Matchmaking gRPC server listening on :50051

✅ QuizService registered
▶  Match consumer consuming from quiz-match-created-queue
🚀 Quiz gRPC server listening on :50052

✅ ScoringService registered
▶  Scoring consumer consuming from answer-processing-queue
🚀 Scoring gRPC server listening on :50053
```

### 3. Or run everything containerized

```bash
make up
# Builds and starts all 3 services + infra via Docker Compose
```

### 4. Start iOS simulators

```bash
xcrun simctl list devices booted
# Copy device IDs

# Terminal A
cd flutter-app && flutter run -d <DEVICE_ID_1>

# Terminal B
cd flutter-app && flutter run -d <DEVICE_ID_2>
```

### 5. Play!

1. Register with different usernames on each simulator
2. Tap "Start Matchmaking" on both
3. Wait ~10 seconds for match
4. Answer questions — faster correct answers earn more points!

---

## Makefile Commands

```bash
make proto             # Regenerate Go + Dart protobuf files
make infra             # Start MongoDB, Redis, RabbitMQ (Docker)
make up                # Build + start everything (Docker Compose)
make down              # Stop all containers
make build             # Build all 3 Go services
make run-matchmaking   # Run matchmaking-service locally
make run-quiz          # Run quiz-service locally
make run-scoring       # Run scoring-service locally
make test              # Run all Go tests
make test-flutter      # Run Flutter tests
make seed              # Re-seed MongoDB questions
make kill              # Kill processes on ports 50051-50053, 8080
make clean             # Flutter clean + Docker volume cleanup
```

---

## Scoring System

| Difficulty | Base Points | + Speed Bonus (max) | Max Per Round |
|------------|------------|---------------------|---------------|
| Easy | 100 | +50 | 150 |
| Medium | 125 | +50 | 175 |
| Hard | 150 | +50 | 200 |

**Speed bonus** = `50 * (1 - responseMs / 10000)` — linear decay over 10 seconds.

**Question distribution** per match: 4 easy + 4 medium + 2 hard = 10 rounds.

**Rating** increases by total match score after each game.

---

## Key Technical Decisions

### Why 3 Services?
Each service owns a clear domain and communicates via RabbitMQ:
- **Matchmaking** owns the player pool and room creation
- **Quiz Engine** owns game state and round execution
- **Scoring** owns answer validation and leaderboard

They share Redis (different key namespaces) and MongoDB (different collections).

### Race Condition Prevention
| Problem | Solution |
|---------|----------|
| Concurrent score updates | Lua script: `ZINCRBY + EXPIRE + ZREVRANK` atomic |
| Concurrent room creation | Distributed lock: `SET NX EX` with UUID owner + Lua compare-and-delete |
| Multiple game loop starts | `sync.Once` — first subscriber triggers, others just receive |
| Duplicate answer scoring | `HEXISTS` idempotency check before scoring |
| Matchmaking ZPOPMIN race | Global Redis lock around ZPOPMIN |

### Auth Flow
- JWT (HS256, 24h expiry) issued on Register/Login
- Every gRPC call carries `Authorization: Bearer <token>` metadata
- Interceptors validate token and inject `userId` into context
- Handlers read `userId` from context (not from request body) — prevents impersonation

### Redis Key Ownership

| Service | Keys |
|---------|------|
| Matchmaking | `matchmaking:pool`, `player:{id}`, `room:{id}:state`, `room:{id}:players`, `room:lock:{id}` |
| Quiz Engine | `room:{id}:questions`, `room:{id}:submitted:{round}`, `room:{id}:round:{round}:started_at` |
| Scoring | `room:{id}:leaderboard` (TTL 30min), `room:{id}:answers:{round}`, `room:{id}:correct_counts`, `room:{id}:response_sum/count` |

---

## Game Flow

```
Register / Login
    |
Matchmaking Lobby ("Start Matchmaking")
    |
Waiting for players (10s lobby, min 2 players)
    |                                           match.created
Matchmaking Service ──────────────────────────→ RabbitMQ ──→ Quiz Engine
    |                                                         (selects questions)
Match Found → All clients connect to Quiz Engine StreamGameEvents
    |
10 Rounds:
  → Question broadcast (30s timer)
  → Players answer → SubmitAnswer writes to Redis immediately
  → Round advances as soon as all active players answer
  → answer.submitted → RabbitMQ → Scoring Service (scores + updates leaderboard)
  → RoundResult broadcast (correct answer + fastest correct player)
  → Leaderboard broadcast (5s pause)
    |
Match End → Results Screen
  → Winner announced
  → XP = total match score (shown in results + added to rating)
  → Ratings updated in MongoDB
  → Play Again → fresh matchmaking
```

### Forfeit Flow
- Player taps X → sends `answerIndex: -1` → server marks player as inactive
- Player sees "Match in Progress" spectating screen with live scores
- Remaining players continue — rounds advance based on active count only
- If only 1 player left → auto-win (regardless of score)
- All players receive MatchEnd when game finishes

---

## Troubleshooting

### Ports in use
```bash
make kill
# Or manually:
lsof -ti :50051 | xargs kill -9
lsof -ti :50052 | xargs kill -9
lsof -ti :50053 | xargs kill -9
```

### Redis / RabbitMQ / MongoDB not connecting
```bash
make infra
docker compose ps   # verify all healthy
```

### Matchmaking stuck
```bash
redis-cli DEL matchmaking:pool
```

### Questions repeating / fewer than 10 rounds
Match history is cleared per-match (demo mode). If the question pool is exhausted across difficulty bands, the system fills remaining slots from any difficulty. Add more questions to `mongo-init/init.js` for variety.

### iOS build fails
```bash
cd flutter-app
flutter clean
flutter create . --platforms ios
flutter pub get
```

### Stale data after code changes
```bash
redis-cli FLUSHALL
docker exec quiz_mongodb mongosh quizdb --eval "db.match_history.deleteMany({})"
```

---

## Environment Variables

All 3 services read:

| Variable | Default | Description |
|----------|---------|-------------|
| `GRPC_ADDR` | `:50051` / `:50052` / `:50053` | gRPC listen address |
| `REDIS_ADDR` | `localhost:6379` | Redis address |
| `RABBITMQ_URL` | `amqp://guest:guest@localhost:5672/` | RabbitMQ URL |
| `MONGO_URI` | `mongodb://localhost:27017` | MongoDB URI |

Matchmaking also reads:
| `GRPC_WEB_ADDR` | `:8080` | gRPC-Web address (Flutter Web) |

---

## MongoDB Collections

| Collection | Owner | Key Fields |
|------------|-------|------------|
| `users` | Matchmaking | `username` (unique index), `password_hash`, `rating` |
| `questions` | Quiz Engine | `text`, `options[4]`, `correctIndex`, `difficulty` (indexed), `topic` |
| `match_history` | Quiz Engine | `players[].userId` (indexed), `questionIds[]` — cleared per match |

---

## RabbitMQ Exchange

**Exchange:** `sx` (topic, durable)

| Routing Key | Publisher | Consumer | Payload |
|-------------|----------|----------|---------|
| `match.created` | Matchmaking | Quiz Engine | roomId, players[], totalRounds |
| `answer.submitted` | Quiz Engine | Scoring | roomId, userId, roundNumber, questionId, answerIndex, timestamps |
| `round.completed` | Quiz Engine | (logged) | roomId, roundNumber, correctIndex |
| `match.finished` | Quiz Engine | (logged) | roomId, totalRounds |
