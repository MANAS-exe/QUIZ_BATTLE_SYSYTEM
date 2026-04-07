# Quiz Battle

Real-time multiplayer quiz game — Flutter frontend, Go gRPC backend, MongoDB, Redis, RabbitMQ.

Players register, get matched with opponents, compete across 10 timed rounds, earn speed-bonus points, and climb the leaderboard.

---

## Architecture

```
Flutter App (iOS/Android)
    |
    | gRPC (:50051)
    v
Go Backend (matchmaking-service)
    |
    +---> MongoDB 7    (users, questions, match history)
    +---> Redis 7      (matchmaking pool, room state, leaderboards, answer tracking)
    +---> RabbitMQ 3   (async answer scoring, round/match events)
```

## Tech Stack

| Component         | Technology              | Purpose                                      |
|-------------------|-------------------------|----------------------------------------------|
| Frontend          | Flutter / Dart          | Cross-platform mobile UI                     |
| Backend           | Go 1.25                 | gRPC server, game orchestration              |
| Communication     | gRPC + Protobuf         | Real-time streaming, type-safe contracts     |
| Database          | MongoDB 7               | Users, questions, match history              |
| Cache / State     | Redis 7                 | Matchmaking pool, room state, leaderboards   |
| Message Broker    | RabbitMQ 3              | Async answer scoring pipeline                |
| Auth              | JWT (HS256) + bcrypt    | Token-based authentication                   |
| State Management  | Riverpod                | Flutter reactive state                       |
| Navigation        | GoRouter                | Declarative routing with auth guards         |

---

## Prerequisites

Install these before starting:

```bash
# Homebrew (macOS)
brew install go protobuf redis mongodb-community rabbitmq

# Flutter SDK
# https://docs.flutter.dev/get-started/install

# Protobuf plugins
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
dart pub global activate protoc_plugin

# Docker (for running infra services)
# https://docs.docker.com/desktop/install/mac-install/

# Xcode + iOS Simulators (for Flutter iOS)
xcode-select --install
```

---

## Quick Start

### 1. Start infrastructure services

```bash
docker compose up -d
```

This starts MongoDB (:27017), Redis (:6379), and RabbitMQ (:5672 / UI :15672).

Verify services are running:

```bash
docker compose ps
```

### 2. Seed the database

MongoDB needs questions to exist. The seed script runs automatically via docker-compose `mongo-init` volume. If you need to re-seed:

```bash
docker exec -i quiz_battle-mongodb-1 mongosh quizdb < mongo-init/init.js
```

### 3. Start the Go backend

```bash
cd matchmaking-service
go run main.go
```

You should see:

```
✅ Redis connected: localhost:6379
✅ RabbitMQ connected: amqp://guest:guest@localhost:5672/
✅ MongoDB connected: mongodb://localhost:27017
✅ AuthService registered
✅ MatchmakingService registered
✅ QuizService registered
🌐 gRPC-Web server listening on :8080
▶  Consuming from answer-processing-queue
🚀 Matchmaking gRPC server listening on :50051
```

### 4. Start iOS simulators

```bash
# List available simulators
xcrun simctl list devices available | grep iPhone

# Boot two (or more) simulators
xcrun simctl boot "iPhone 17"
xcrun simctl boot "iPhone 16"
# Or create a named one:
xcrun simctl create player2 "iPhone 16"
xcrun simctl boot player2

# Open Simulator app
open -a Simulator
```

### 5. Run Flutter app on each simulator

Open separate terminal tabs for each:

```bash
# List booted devices
flutter devices

# Terminal 1
cd flutter-app
flutter run -d <DEVICE_ID_1>

# Terminal 2
cd flutter-app
flutter run -d <DEVICE_ID_2>
```

Find device IDs with:

```bash
xcrun simctl list devices booted
```

Example:

```bash
flutter run -d F42DED08-20C4-463B-ADAA-8AF4277CDE78
flutter run -d B3C9EDA8-FF6C-4BE8-8BEE-8A214B567AD4
```

### 6. Play!

1. Register/Login on each simulator (different usernames)
2. Tap "Start Matchmaking" on all devices
3. Wait 10 seconds for lobby to fill
4. Match starts automatically — answer questions!

---

## Common Commands

### Flutter

```bash
# Get dependencies
cd flutter-app && flutter pub get

# Analyze code
flutter analyze

# Hot reload (in running flutter terminal)
r

# Hot restart (resets state)
R

# Clean build
flutter clean && flutter pub get

# Generate iOS project files (if missing)
flutter create . --platforms ios
```

### Go Backend

```bash
cd matchmaking-service

# Run server
go run main.go

# Build binary
go build -o quiz-server main.go
./quiz-server

# Run tests
go test ./...

# Download dependencies
go mod tidy
```

### Protobuf Regeneration

Run from the project root (`quiz_battle/`):

```bash
# Go protos
PATH="$PATH:$HOME/go/bin" protoc \
  --proto_path=proto \
  --go_out=proto --go_opt=paths=source_relative \
  --go-grpc_out=proto --go-grpc_opt=paths=source_relative \
  quiz.proto

# Dart protos
PATH="$PATH:$HOME/.pub-cache/bin" protoc \
  --proto_path=proto \
  --dart_out=grpc:flutter-app/lib/proto \
  quiz.proto
```

### Docker / Infrastructure

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f mongodb
docker compose logs -f redis
docker compose logs -f rabbitmq

# Reset all data (removes volumes)
docker compose down -v

# RabbitMQ management UI
open http://localhost:15672
# Login: guest / guest
```

### Redis CLI

```bash
# Connect
redis-cli

# Check matchmaking pool
ZRANGE matchmaking:pool 0 -1 WITHSCORES

# Check room state
KEYS room:*
HGETALL room:<roomId>:players
LRANGE room:<roomId>:questions 0 -1
ZREVRANGE room:<roomId>:leaderboard 0 -1 WITHSCORES

# Flush matchmaking pool (if stuck)
DEL matchmaking:pool

# Flush everything (nuclear option)
FLUSHALL
```

### MongoDB CLI

```bash
# Connect
docker exec -it quiz_battle-mongodb-1 mongosh quizdb

# Check users
db.users.find().pretty()

# Check questions count
db.questions.countDocuments()

# Check a user's rating
db.users.findOne({username: "manas1"})

# Reset all user ratings to 1000
db.users.updateMany({}, {$set: {rating: 1000}})
```

---

## Killing Ports (Troubleshooting)

If you get "address already in use" errors:

```bash
# Find what's using a port
lsof -i :50051    # gRPC
lsof -i :8080     # gRPC-Web
lsof -i :6379     # Redis
lsof -i :27017    # MongoDB
lsof -i :5672     # RabbitMQ

# Kill by PID
kill -9 <PID>

# Kill by port (one-liner)
lsof -ti :50051 | xargs kill -9
lsof -ti :8080 | xargs kill -9

# Kill all Go processes
pkill -f "go run main.go"
pkill -f quiz-server

# Kill all Flutter processes
pkill -f flutter_tools
```

---

## Troubleshooting

### "No application found for TargetPlatform.ios"

iOS project files are missing:

```bash
cd flutter-app
flutter create . --platforms ios
```

### "dart:html is not available on this platform"

You imported `grpc_web.dart` which is web-only. Only use `grpc.dart` for iOS/Android:

```dart
import 'package:grpc/grpc.dart';       // correct
// import 'package:grpc/grpc_web.dart'; // remove this
```

### "address already in use" on :50051

Kill the old Go server:

```bash
lsof -ti :50051 | xargs kill -9
```

### Redis connection refused

Make sure Docker services are running:

```bash
docker compose up -d redis
```

Or if running Redis natively:

```bash
brew services start redis
```

### RabbitMQ connection refused

```bash
docker compose up -d rabbitmq
# Wait 10-15 seconds for RabbitMQ to fully start
docker compose logs rabbitmq | tail -5
```

### MongoDB connection refused

```bash
docker compose up -d mongodb
```

### Matchmaking stuck / not finding match

The pool might have stale entries from a crashed session:

```bash
redis-cli DEL matchmaking:pool
```

Then restart the Go server and retry.

### "Play Again" not working properly

Hot restart the Flutter apps (press `R` in the Flutter terminal). This resets all Riverpod providers.

### Last round not showing results

Restart the Go server — this is caused by the event channel buffer filling up from a previous long session. A fresh server start resets all in-memory state.

### Build errors after proto changes

Regenerate both Go and Dart protos (see Protobuf Regeneration section above), then:

```bash
# Go
cd matchmaking-service && go build ./...

# Flutter
cd flutter-app && flutter clean && flutter pub get
```

### Xcode build failed after Flutter upgrade

```bash
cd flutter-app
flutter clean
rm -rf ios/Pods ios/Podfile.lock
flutter pub get
cd ios && pod install && cd ..
flutter run -d <DEVICE_ID>
```

---

## Project Structure

```
quiz_battle/
├── README.md                          # This file
├── docker-compose.yml                 # MongoDB, Redis, RabbitMQ
├── mongo-init/
│   └── init.js                        # Seed 20 quiz questions
├── proto/
│   ├── quiz.proto                     # gRPC service definitions
│   ├── quiz.pb.go                     # Generated Go messages
│   ├── quiz_grpc.pb.go                # Generated Go gRPC stubs
│   └── go.mod
├── matchmaking-service/               # Go backend
│   ├── main.go                        # Entry point, server setup
│   ├── go.mod / go.sum
│   ├── handlers/
│   │   ├── auth.go                    # Register / Login (JWT + bcrypt)
│   │   ├── matchmaking.go            # Join/Leave pool, room creation
│   │   ├── quiz.go                    # Question selection, round execution
│   │   └── quiz_handler.go           # Game loop, streaming, scoring
│   ├── middleware/
│   │   └── auth.go                    # JWT interceptors (unary + stream)
│   ├── models/
│   │   └── room.go                    # Room, Player structs
│   ├── redis/
│   │   ├── pool.go                    # Connection pooling
│   │   ├── client.go                  # Matchmaking pool operations
│   │   ├── room.go                    # Room creation with distributed lock
│   │   ├── lock.go                    # SET NX EX distributed locking
│   │   └── leaderboard.go            # Atomic score updates (Lua), metadata
│   └── rabbitmq/
│       ├── publisher.go               # Publish match/answer/round events
│       └── consumer.go                # Consume + score answers
└── flutter-app/                       # Flutter frontend
    ├── pubspec.yaml
    └── lib/
        ├── main.dart                  # Router, theme, entry point
        ├── models/
        │   └── game_event.dart        # Sealed event classes
        ├── services/
        │   ├── auth_service.dart      # Login/Register provider
        │   ├── game_service.dart      # gRPC client + proto mappers
        │   └── reconnect_service.dart # Exponential backoff reconnection
        ├── providers/
        │   └── game_provider.dart     # Central game state notifier
        ├── screens/
        │   ├── login_screen.dart      # Auth UI
        │   ├── matchmaking_screen.dart# Lobby + search UI
        │   ├── quiz_screen.dart       # Question + answer UI
        │   ├── leaderboard_screen.dart# Between-round scores
        │   └── results_screen.dart    # Final match results
        └── proto/
            ├── quiz.pb.dart           # Generated Dart messages
            ├── quiz.pbgrpc.dart       # Generated Dart gRPC stubs
            ├── quiz.pbjson.dart
            └── quiz.pbenum.dart
```

---

## Environment Variables

The Go backend reads these (with defaults):

| Variable       | Default                                  | Description          |
|---------------|------------------------------------------|----------------------|
| `GRPC_ADDR`   | `:50051`                                 | gRPC listen address  |
| `GRPC_WEB_ADDR` | `:8080`                                | gRPC-Web address     |
| `REDIS_ADDR`  | `localhost:6379`                         | Redis address        |
| `RABBITMQ_URL`| `amqp://guest:guest@localhost:5672/`     | RabbitMQ URL         |
| `MONGO_URI`   | `mongodb://localhost:27017`              | MongoDB URI          |

---

## Game Flow Summary

```
Register/Login
    ↓
Matchmaking Lobby (tap "Start")
    ↓
Waiting for players (10s lobby wait, min 2 players)
    ↓
Match Found → Quiz Screen
    ↓
10 Rounds:
  → Question displayed (30s timer)
  → Players answer (speed bonus for fast correct answers)
  → Early advance if all connected players answered
  → Round Result (correct answer + fastest player)
  → Leaderboard (5s pause)
    ↓
Match End → Results Screen
  → Winner announced
  → Personal stats (accuracy, XP, rank)
  → Ratings updated in database
  → Play Again / Share
```
