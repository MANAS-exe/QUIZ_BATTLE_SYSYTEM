# Quiz Battle

Real-time multiplayer quiz game built with a **microservices architecture** — 5 Go backend services (3 gRPC + 1 HTTP + 1 worker), Flutter frontend, MongoDB, Redis, RabbitMQ, and Firebase Cloud Messaging.

Players register (email/password or Google), get matched with opponents, compete across timed rounds with difficulty-based scoring and speed bonuses, climb persistent leaderboards, earn daily rewards, refer friends, purchase premium via Razorpay, and receive FCM push notifications.

---

## Architecture

```
                        Flutter App (iOS / Android)
                          |           |           |         |
                   gRPC :50051   gRPC :50052   gRPC :50053  HTTP :8081
                          |           |           |         |
               +----------+     +-----+-----+    +----------+  +----------+
               |                |           |                   |
    Matchmaking Service    Quiz Engine Service    Scoring Service   Payment Service
    (Auth + Matchmaking)   (Game Loop + Rounds)   (Answer Scoring)  (Razorpay/Premium)
               |                |           |
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
| **Matchmaking** | :50051 / :8080 | User registration/login (JWT), Google OAuth, matchmaking pool, room creation, referral system, device token registration |
| **Quiz Engine** | :50052 | Consumes `match.created` (selects questions), runs game loop, streams events to clients, late-joiner catch-up |
| **Scoring** | :50053 | Consumes `answer.submitted` (validates + scores), updates Redis leaderboard, server-side leaderboard cap for free users |
| **Payment** | :8081 | Razorpay order creation, HMAC verification, subscription activation, coupon validation, publishes `payment.success` to RabbitMQ |
| **Notification Worker** | — | FCM push notifications, RabbitMQ consumers (referral conversion), cron scheduler (streak/daily/premium expiry) |

### Inter-Service Communication

| From | To | Mechanism | Event |
|------|----|-----------|-------|
| Matchmaking | Quiz Engine | RabbitMQ | `match.created` (triggers question selection) |
| Quiz Engine | Scoring | RabbitMQ | `answer.submitted` (triggers scoring) |
| Quiz Engine | (any) | RabbitMQ | `round.completed`, `match.finished` |
| Flutter | Matchmaking | gRPC :50051 | Register, Login, GoogleAuth, JoinMatchmaking, SubscribeToMatch |
| Flutter | Quiz Engine | gRPC :50052 | StreamGameEvents, SubmitAnswer |
| Flutter | Scoring | gRPC :50053 | GetLeaderboard |
| Flutter | Payment | HTTP :8081 | CreateOrder, VerifyPayment, GetStatus, ValidateCoupon |
| Payment | (any) | RabbitMQ | `payment.success` (post-capture event) |
| Quiz Engine | Notification Worker | RabbitMQ | `match.finished` (triggers referral conversion notification) |
| (cron/event) | Notification Worker | RabbitMQ | `notification.*` (streak, daily reward, tournament, premium expiry) |
| Notification Worker | Devices | FCM | Push notifications to Android/iOS devices |

---

## Tech Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Frontend | Flutter / Dart | Cross-platform mobile UI (iOS + Android) |
| Backend | Go 1.25 (4 services) | gRPC servers, HTTP server, game orchestration |
| Communication | gRPC + Protobuf | Real-time streaming, type-safe contracts |
| Database | MongoDB 7 | Users, questions, match history, payments |
| Cache / State | Redis 7 | Matchmaking pool, room state, leaderboards |
| Message Broker | RabbitMQ 3 | Async inter-service communication |
| Auth | JWT (HS256) + bcrypt + Google OAuth | Token-based auth with Google Sign-In |
| Payments | Razorpay | Premium subscriptions (monthly/yearly) |
| Push Notifications | Firebase Cloud Messaging (FCM) | Streak warnings, referral conversions, tournament reminders |
| State Management | Riverpod | Flutter reactive state |
| Navigation | GoRouter | Declarative routing with auth guards |
| Local Storage | SharedPreferences | JWT, streaks, coins, daily quota, login history |
| Image Caching | CachedNetworkImage | Google profile pictures |

---

## Project Structure

```
quiz_battle/
├── proto/
│   └── quiz.proto                     # Shared gRPC service definitions (4 services, 30+ messages)
├── shared/                            # Shared Go module (imported by all services)
│   ├── auth/jwt.go                    # JWT generation + validation
│   ├── middleware/auth.go             # gRPC auth interceptors (unary + stream)
│   └── models/room.go                # Room, Player, MatchCreatedEvent structs
├── matchmaking-service/               # Port :50051
│   ├── Dockerfile
│   ├── main.go                        # Auth + Matchmaking gRPC server
│   ├── handlers/
│   │   ├── auth.go                    # Register / Login (bcrypt + JWT)
│   │   ├── google_auth.go             # Google ID token verification + upsert
│   │   ├── matchmaking.go            # Join/Leave pool, room creation, server-side quota enforcement
│   │   ├── referral.go               # Referral system (get code, apply, claim, history)
│   │   ├── device_token.go           # POST /device/token (FCM token registration)
│   │   └── redis_keys.go             # PopulateUserRedisKeys — mirrors user state to Redis on login
│   ├── redis/
│   │   ├── room.go                    # CreateRoom with distributed lock + pipeline
│   │   └── lock.go                    # SET NX EX with UUID owner + Lua compare-and-delete
│   └── cmd/seed/main.go               # Seed test users to MongoDB
├── quiz-service/                      # Port :50052
│   ├── Dockerfile
│   ├── main.go                        # Quiz gRPC server + match.created consumer
│   ├── handlers/
│   │   ├── quiz.go                    # RunRound (timer loop, early-exit, TimerSync broadcast)
│   │   └── quiz_handler.go           # StreamGameEvents, SubmitAnswer, game loop, room hub
│   ├── questions/
│   │   └── selection.go              # Fisher-Yates shuffle, difficulty distribution, seen-question avoidance
│   └── rabbitmq/
│       ├── publisher.go               # Publishes answer.submitted, round.completed, match.finished
│       └── match_consumer.go          # Consumes match.created → SelectForRoom
├── scoring-service/                   # Port :50053
│   ├── Dockerfile
│   ├── main.go                        # Scoring gRPC server + answer consumer
│   ├── handlers/
│   │   └── scoring.go                 # CalculateScore, GetLeaderboard RPCs
│   ├── redis/
│   │   └── leaderboard.go            # Atomic Lua score updates (ZINCRBY + ZREVRANK + EXPIRE)
│   └── rabbitmq/
│       └── consumer.go                # Consumes answer.submitted → validate + score + update leaderboard
├── payment-service/                   # Port :8081
│   ├── Dockerfile
│   ├── main.go                        # HTTP server (Gin)
│   ├── handlers/
│   │   ├── payment.go                 # CreateOrder, VerifyPayment, GetStatus, GetHistory, ValidateCoupon
│   │   └── webhook.go                 # Razorpay webhook handler, HMAC verification, publishes payment.success
│   └── rabbitmq/
│       └── publisher.go               # RabbitMQ publisher for payment-success-queue
├── flutter-app/
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart                  # Router (8 routes), theme, auth init
│       ├── models/
│       │   └── game_event.dart        # Sealed event classes (9 types)
│       ├── services/
│       │   ├── auth_service.dart      # AuthState + AuthNotifier (JWT, Google, streaks, coins, rewards)
│       │   ├── game_service.dart      # 3 gRPC channels (50051/50052/50053), all RPC methods
│       │   ├── reconnect_service.dart # Exponential backoff (1-16s, 5 retries)
│       │   └── notification_service.dart # FCM permission, token registration, foreground/background handlers
│       ├── providers/
│       │   └── game_provider.dart     # Central game state machine (8 phases, win streak)
│       └── screens/
│           ├── login_screen.dart      # Email/password + Google Sign-In
│           ├── home_screen.dart       # Dashboard, daily quota, streak pill, reward popup
│           ├── matchmaking_screen.dart
│           ├── quiz_screen.dart
│           ├── leaderboard_screen.dart # Between-round + win streak badge
│           ├── results_screen.dart    # Share / Home / Play Again buttons
│           ├── spectating_screen.dart
│           ├── profile_screen.dart    # 4 tabs: Profile / Last Match / Badges / Streak
│           ├── premium_screen.dart    # Razorpay payment flow
│           └── global_leaderboard_screen.dart
├── notification-worker/                # Background worker (no port)
│   ├── Dockerfile
│   ├── main.go                        # Entry point — FCM + RabbitMQ consumers + scheduler
│   └── worker/
│       ├── fcm.go                     # Firebase Admin SDK wrapper (Send, SendMulticast)
│       ├── consumer.go                # RabbitMQ consumers (notification.*, match.finished)
│       ├── scheduler.go               # Cron jobs (streak warning, daily reward, premium expiry)
│       └── db.go                      # MongoDB helpers for token/user/subscription lookups
├── mongo-init/
│   └── init.js                        # Seed 30 questions + create all indexes
├── docker-compose.yml                 # All 5 services + MongoDB + Redis + RabbitMQ
├── Makefile                           # proto, infra, up, down, test, run-*, seed, kill
├── docs/
│   ├── architecture.md                # Detailed architecture + Phase audits + resolved gaps
│   ├── daily-rewards.md               # Daily rewards system spec
│   ├── home-screen.md                 # Home screen design decisions
│   ├── razorpay.md                    # Razorpay integration guide
│   ├── google-auth.md                 # Google Sign-In setup
│   ├── referral.md                    # Referral system spec
│   ├── push-notifications.md          # FCM integration + testing guide
│   ├── GAPS_AND_PLAN.md               # Audit gaps + resolution log
│   └── BUGS_AND_FIXES.md              # Known bugs + fixes log
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

### 2. Start all backend services (separate terminals)

```bash
# Terminal 1
make run-matchmaking

# Terminal 2
make run-quiz

# Terminal 3
make run-scoring

# Terminal 4 (optional — only needed for Razorpay / premium features)
cd payment-service && go run main.go
```

You should see:
```
✅ Redis connected       ✅ RabbitMQ connected       ✅ MongoDB connected
🚀 Matchmaking gRPC server listening on :50051
🚀 Quiz gRPC server listening on :50052
🚀 Scoring gRPC server listening on :50053
🚀 Payment HTTP server listening on :8081
```

### 3. Or run everything containerized

```bash
make up
# Builds and starts all services + infra via Docker Compose
```

### 4. Seed data

```bash
make seed          # 60 questions into MongoDB
make seed-users    # 6 test users (alice/bob/charlie/diana/evan/fiona, password: speakx123)
```

### 5. Start iOS simulators

```bash
xcrun simctl list devices booted
# Copy device IDs

# Terminal A
cd flutter-app && flutter run -d <DEVICE_ID_1>

# Terminal B
cd flutter-app && flutter run -d <DEVICE_ID_2>
```

### 6. Play!

1. Register or use a test account on each simulator
2. Tap **Play Now** on both devices
3. Wait ~10 seconds for the match lobby
4. Answer questions — faster correct answers earn more points!

---

## Makefile Commands

```bash
make proto             # Regenerate Go + Dart protobuf files
make infra             # Start MongoDB, Redis, RabbitMQ (Docker)
make up                # Build + start everything (Docker Compose)
make down              # Stop all containers
make build             # Build all Go services
make run-matchmaking   # Run matchmaking-service locally
make run-quiz          # Run quiz-service locally
make run-scoring       # Run scoring-service locally
make test              # Run all Go tests
make test-flutter      # Run Flutter unit tests (31 tests)
make seed              # Re-seed MongoDB questions
make seed-users        # Seed 6 test users
make kill              # Kill processes on ports 50051-50053, 8080, 8081
make clean             # Flutter clean + Docker volume cleanup
```

---

## Authentication

Two login methods are supported:

### Email / Password
- Register via `POST` gRPC `Register` → bcrypt hash stored in MongoDB
- Login via gRPC `Login` → JWT (HS256, 24h) returned
- Credentials saved in SharedPreferences for silent session restore

### Google Sign-In
- Flutter opens Google consent screen via `google_sign_in` SDK
- ID token exchanged at `POST http://localhost:8080/auth/google`
- Backend verifies token with Google, upserts user in MongoDB, returns JWT
- Profile picture URL stored and shown across all screens (CachedNetworkImage)
- Silent re-authentication on app restart via `signInSilently()`

Every gRPC call carries `Authorization: Bearer <token>` metadata. Interceptors validate the token and inject `userId` into context — handlers never trust the request body for identity.

---

## Game Flow

```
Register / Login (email or Google)
    |
Home Screen — daily quota + streak + Play Now button
    |
Matchmaking Lobby (waiting for 4 players)
    |                                           match.created
Matchmaking Service ──────────────────────────→ RabbitMQ ──→ Quiz Engine
    |                                                         (selects questions)
Match Found → consumeDailyQuiz() called → All clients connect to StreamGameEvents
    |
5 Rounds:
  → Question broadcast (30s timer)
  → Players answer → SubmitAnswer writes to Redis immediately
  → Round advances as soon as all active players answer (or timer expires)
  → answer.submitted → RabbitMQ → Scoring Service (scores + updates leaderboard)
  → RoundResult broadcast (correct answer + fastest correct player + win streak)
  → Between-round leaderboard (5s pause) — shows answer streak + win streak badges
    |
Match End → Results Screen
  → Winner announced, final scores
  → XP = total match score → rating updated in MongoDB
  → Three buttons: Share · Home · Play Again
```

### Forfeit Flow
- Player taps X → sends `answerIndex: -1` → marked inactive
- Player sees spectating screen with live scores
- Remaining players continue; rounds advance based on active count
- If 1 player left → auto-win regardless of score
- All players receive MatchEnd when game finishes

---

## Scoring System

| Difficulty | Base Points | + Speed Bonus (max) | Max Per Round |
|------------|------------|---------------------|---------------|
| Easy | 100 | +50 | 150 |
| Medium | 125 | +50 | 175 |
| Hard | 150 | +50 | 200 |

**Speed bonus** = `50 * (1 - responseMs / 10000)` — linear decay over 10 seconds.

**Question distribution** per match: 4 easy + 4 medium + 2 hard = 10 rounds total (configurable).

**Rating** increases by total match score after each game.

---

## Daily Rewards & Login Streak

A complete daily engagement system. All logic is **client-side** (SharedPreferences) — works fully offline.

### How It Works

Every time the user opens the app and logs in for the **first time that calendar day**, their login streak increments by 1. Missing a day resets the streak to 1 on the next login.

### Reward Popup

On first open of the home screen each day, an **animated popup** appears automatically if the user has an unclaimed reward. The user must tap **Claim Reward** to receive it. Tapping **Later** dismisses without claiming (popup reappears next open).

### Reward Table

| Streak Day | Coins | Bonus Games | Badge | Premium Trial |
|------------|-------|-------------|-------|---------------|
| 1 | 50 | — | — | — |
| 2 | 75 | — | — | — |
| 3 | 100 | +1 | — | — |
| 4 | 125 | — | — | — |
| 5 | 150 | +2 | — | — |
| 6 | 200 | — | — | — |
| **7** | **250** | **+3** | **Week Warrior** | — |
| **14** *(milestone)* | **500** | **+5** | **Fortnight Fighter** | — |
| **30** *(milestone)* | **1000** | **+7** | **Monthly Master** | **7 days Premium** |

After day 7 the weekly cycle repeats (day 8 = day 1 rewards, etc.). Milestones at 14 and 30 always override the cycle.

### Coins

A soft currency that accumulates permanently (never expires, never decreases). Shown on the Profile → STREAK tab. Used for future cosmetic features.

### Bonus Games

Bonus games stack on top of the free daily 5. For example, day-3 reward grants +1 bonus game → the user gets **6 games that day** (and any remaining bonus games carry over to the next day).

The daily quota card on the home screen shows:
```
3 / 5 games played today  ·  +3 bonus
```

### Premium Trial

The Day-30 milestone grants **7 days of free Premium**. During the trial:
- Unlimited daily games
- Full global leaderboard (not capped at top 3)
- Premium badge displayed

The trial is time-based and checked in real-time via the `isEffectivelyPremium` computed getter — no logout/login cycle needed when it expires.

### Home Screen — Streak Pill

A flame counter appears in the top bar whenever streak > 0:
```
🔥 7
```

### Profile → STREAK Tab (4th tab)

- **Streak Summary** — current streak, all-time best streak
- **Coins Card** — total coins earned + bonus games remaining
- **30-Day Calendar** — 7-column grid; green = logged in, gold border = today, dim = missed day

---

## Premium Subscription (Razorpay)

Free users get **5 games/day**. Premium users get unlimited games.

### Plans

| Plan | Price | Duration |
|------|-------|---------|
| Monthly | ₹499 | 30 days |
| Yearly | ₹3,999 | 365 days |

### Payment Flow

```
1. User taps "Go Premium" → payment-service POST /payment/create-order
2. Razorpay checkout opens in Flutter WebView / SDK
3. On success → POST /payment/verify (HMAC-SHA256 signature check)
4. Verification passes → subscription activated in MongoDB
5. Flutter calls GET /payment/status → isPremium = true
6. Local SharedPreferences updated + state reflects premium immediately
```

**Signature verification (no webhook):**
```
HMAC-SHA256(key_secret, order_id + "|" + payment_id) == razorpay_signature
```

### Premium Sync Across Devices

`AuthNotifier._syncPremiumFromServer()` calls `GET /payment/status` after every login. If the server says `is_active: true` and the local flag says false (or vice versa), the local state is updated. This handles:
- User buys premium on Phone A → logs in on Phone B → premium is active immediately
- Premium expires → next login on any device → plan shown as free

**`isEffectivelyPremium`** — a computed getter that returns `true` for either paid premium OR an active daily-reward premium trial. All quota/upsell checks use this getter, not `isPremium` directly.

### Payment Failure Handling

If Razorpay returns a failure callback:
- The `Future.delayed(Duration.zero, ...)` wrapper on Android prevents the Activity destruction from crashing the Flutter engine
- User sees a friendly error dialog (not a blank screen or crash)
- No quota is consumed on payment failure

### Test UPI ID

```
success@razorpay
```

See [docs/razorpay.md](docs/razorpay.md) for full setup, test credentials, and integration details.

---

## Flutter Client — State Architecture

### AuthState (auth_service.dart)

Single source of truth for all user data. Persisted to SharedPreferences keyed by `stats_<userId>_*`.

| Field | Type | Description |
|-------|------|-------------|
| `token` | String? | JWT for gRPC/HTTP auth headers |
| `userId` | String? | MongoDB user ID |
| `username` | String? | Display name |
| `pictureUrl` | String? | Google profile picture URL |
| `isPremium` | bool | Paid premium flag |
| `isEffectivelyPremium` | bool *(getter)* | `isPremium OR active trial` |
| `dailyQuizUsed` | int | Games played today (resets at midnight) |
| `bonusGamesRemaining` | int | Extra games from daily rewards (carry-over) |
| `dailyQuizRemaining` | int *(getter)* | `freeLeft + bonusGames` (or ∞ for premium) |
| `isQuotaExhausted` | bool *(getter)* | True when free + bonus both = 0 |
| `coins` | int | Total coins earned, never decreases |
| `loginHistory` | List\<String\> | ISO dates of last 30 logins |
| `currentStreak` | int | Consecutive login-day streak |
| `maxStreak` | int | All-time best login streak |
| `premiumTrialExpiresAt` | String? | ISO datetime; null = no active trial |
| `dailyRewardClaimedDate` | String? | ISO date; prevents double-claiming |
| `pendingReward` | DailyReward? *(getter)* | Non-null = show popup today |

### GameState (game_provider.dart)

Tracks the live match state machine across 8 phases.

| Field | Description |
|-------|-------------|
| `currentAnswerStreak` | Consecutive correct answers this match |
| `maxAnswerStreak` | Best answer streak this match |
| `currentWinStreak` | Consecutive rounds won (correct AND fastest) |
| `maxWinStreak` | Best win streak this match |

### Key Services

| Service | Description |
|---------|-------------|
| `GameService` | Wraps all gRPC calls across 3 channels |
| `ReconnectService` | Exponential backoff (1s→16s, max 5 retries) around `StreamGameEvents` |

---

## Screens

| Screen | Route | Description |
|--------|-------|-------------|
| `LoginScreen` | `/login` | Email/password + Google Sign-In |
| `HomeScreen` | `/home` | Dashboard — quota, streak pill, reward popup, quick stats, premium upsell, leaderboard preview |
| `MatchmakingScreen` | `/matchmaking` | Lobby with player avatars, countdown timer |
| `QuizScreen` | `/quiz` | Question + 4 answers, countdown timer, answer feedback |
| `LeaderboardScreen` | `/leaderboard` | Between-round scores, answer streak badge, win streak badge |
| `ResultsScreen` | `/results` | Final scores, winner banner, Share / Home / Play Again |
| `SpectatingScreen` | `/spectating` | Read-only live view for forfeited players |
| `ProfileScreen` | `/profile` | 4 tabs: Profile stats / Last Match / Badges / Streak calendar |
| `PremiumScreen` | `/premium` | Plan selection + Razorpay checkout |
| `GlobalLeaderboardScreen` | `/global-leaderboard` | All-time top players |

---

## Win Streak Badge

In `leaderboard_screen.dart` (between-round screen), two streak badges stack:

```
🔥 Answer Streak x4        (shows for ≥2 consecutive correct answers)
⚡ Speed Win Streak x2     (shows for ≥2 rounds won: correct AND fastest)
```

"Winning" a round = correct answer AND `fastestUserId == myUserId` from `RoundResultEvent`.

---

## Key Technical Decisions

### Why 4 Services?

| Service | Why Separate |
|---------|-------------|
| Matchmaking | Owns player identity + room lifecycle; must be available even during a game |
| Quiz Engine | Long-lived streaming connections; game state isolated per room |
| Scoring | High write frequency (every answer); atomic Redis ops independent of game loop |
| Payment | PCI-adjacent; HTTP not gRPC; Razorpay webhook surface isolated |

### Race Condition Prevention

| Problem | Solution |
|---------|----------|
| Concurrent score updates | Lua script: `ZINCRBY + EXPIRE + ZREVRANK` atomic |
| Concurrent room creation | Distributed lock: `SET NX EX` + UUID owner + Lua compare-and-delete |
| Multiple game loop starts | `sync.Once` — first subscriber triggers, others just receive |
| Duplicate answer scoring | `HEXISTS` idempotency check before scoring |
| Matchmaking ZPOPMIN race | Global Redis lock around ZPOPMIN |
| Razorpay Activity crash (Android) | `Future.delayed(Duration.zero, ...)` defers callback past Activity destruction |

### Question Deduplication

`SelectForRoom` in `quiz-service/questions/selection.go` fetches previously-seen `questionIds` from `match_history` for all players in the room, then excludes them. A Fisher-Yates shuffle replaces MongoDB `$sample` (which had a repeat bias at small pool sizes).

### Login Streak vs Match Streak

| Term | When Updated | Storage |
|------|-------------|---------|
| Login streak (`currentStreak`) | On login, via `_updateLoginStreak()` | SharedPreferences `loginHistory` (JSON array) |
| Answer streak (`maxAnswerStreak`) | Per round in `GameNotifier` | `GameState` (in-memory, stored at match end) |
| Win streak (`maxWinStreak`) | Per round in `GameNotifier` | `GameState` (in-memory) |

### `isEffectivelyPremium` vs `isPremium`

`isPremium` = paid Razorpay subscription.
`isEffectivelyPremium` = `isPremium OR (premiumTrialExpiresAt != null AND expiry > now)`.

All quota checks, upsell card visibility, and leaderboard limits use `isEffectivelyPremium`. This ensures the day-30 streak trial unlocks the same features as a paid subscription without any code duplication.

---

## Redis Key Ownership

| Service | Keys | TTL |
|---------|------|-----|
| Matchmaking | `matchmaking:pool`, `player:{id}`, `room:{id}:state`, `room:{id}:players`, `room:lock:{id}` | 30 min |
| Quiz Engine | `room:{id}:questions`, `room:{id}:submitted:{round}`, `room:{id}:round:{n}:started_at`, `room:{id}:round:{n}:closed` | 30 min |
| Scoring | `room:{id}:leaderboard`, `room:{id}:answers:{round}`, `room:{id}:correct_counts`, `room:{id}:response_sum`, `room:{id}:response_count` | 30 min |
| User/Premium | `user:{id}:plan` → free/premium, `user:{id}:daily_quota` → remaining or "unlimited" | 1 day |
| Referral | `referral:code:{code}` → userId | no TTL |
| Streak | `user:{id}:streak` hash → {current, longest, last_login} | no TTL |

---

## MongoDB Collections

| Collection | Owner | Key Fields |
|------------|-------|------------|
| `users` | Matchmaking | `username` (unique), `password_hash`, `rating`, `google_id` |
| `questions` | Quiz Engine | `text`, `options[4]`, `correctIndex`, `difficulty` (indexed), `topic` |
| `match_history` | Quiz Engine | `players[].userId` (indexed), `questionIds[]` |
| `payments` | Payment | `userId`, `orderId`, `paymentId`, `plan`, `status`, `expiresAt` |
| `subscriptions` | Payment | `user_id`, `plan`, `status`, `expires_at`, `razorpay_order_id` |
| `device_tokens` | Matchmaking | `user_id` (unique), `token`, `platform`, `updated_at` |
| `referrals` | Matchmaking | `referrer_id`, `referee_id` (unique), `code_used`, `created_at` |

---

## SharedPreferences Keys (Flutter)

All keys namespaced by `stats_<userId>_*`:

| Key | Type | Description |
|-----|------|-------------|
| `_rating` | int | Cached ELO rating |
| `_played` / `_won` | int | Match counts |
| `_streak` / `_maxStreak` | int | Login streak values |
| `_maxQStreak` | int | Best answer streak ever |
| `_premium` | bool | Paid premium flag |
| `_dq_used` / `_dq_date` | int / String | Daily quota (resets when date changes) |
| `_coins` | int | Total coins earned |
| `_bonusGames` | int | Bonus games remaining (carry-over) |
| `_loginHistory` | String (JSON) | ISO dates of last 30 logins |
| `_trialExpiry` | String (ISO datetime) | Premium trial expiry; absent = no trial |
| `_rewardDate` | String (ISO date) | Date of last daily reward claim |
| `_lm_*` | various | Last match stats (won, rank, score, etc.) |

---

## RabbitMQ Exchange

**Exchange:** `sx` (topic, durable)

| Routing Key | Publisher | Consumer | Payload |
|-------------|----------|----------|---------|
| `match.created` | Matchmaking | Quiz Engine | roomId, players[], totalRounds |
| `answer.submitted` | Quiz Engine | Scoring | roomId, userId, roundNumber, questionId, answerIndex, timestamps |
| `round.completed` | Quiz Engine | (logged) | roomId, roundNumber, correctIndex |
| `match.finished` | Quiz Engine | Scoring + Notification Worker | roomId, totalRounds |
| `notification.*` | (cron/event) | Notification Worker | type, title, body, user_ids? |
| `payment.success` | Payment | — | order_id, user_id, plan, amount, captured_at |

---

## Environment Variables

### All Go services

| Variable | Default | Description |
|----------|---------|-------------|
| `GRPC_ADDR` | `:5005x` | gRPC listen address |
| `REDIS_ADDR` | `localhost:6379` | Redis address |
| `RABBITMQ_URL` | `amqp://guest:guest@localhost:5672/` | RabbitMQ URL |
| `MONGO_URI` | `mongodb://localhost:27017` | MongoDB URI |
| `JWT_SECRET` | `your-secret-key` | Shared JWT signing secret |

### Payment service

| Variable | Description |
|----------|-------------|
| `RAZORPAY_KEY_ID` | Razorpay API key (starts with `rzp_test_`) |
| `RAZORPAY_KEY_SECRET` | Razorpay secret for HMAC verification |
| `RAZORPAY_WEBHOOK_SECRET` | Razorpay webhook signing secret |
| `RABBITMQ_URL` | RabbitMQ URL (for payment-success-queue) |
| `MONGO_URI` | MongoDB connection string |
| `PORT` | HTTP listen port (default `:8081`) |

### Notification worker (`notification-worker/.env`)

| Variable | Description |
|----------|-------------|
| `FIREBASE_CREDENTIALS_JSON` | Firebase service account JSON (single line) |
| `RABBITMQ_URL` | RabbitMQ URL |
| `MONGO_URI` | MongoDB connection string |

---

## Seed Data

### Questions (`mongo-init/init.js`)
- 60 questions, 3 difficulty levels, 12 topics
- Run: `make seed`

### Test Users (`matchmaking-service/cmd/seed/main.go`)

| Username | Password | Rating |
|----------|----------|--------|
| alice | speakx123 | 1200 |
| bob | speakx123 | 1050 |
| charlie | speakx123 | 1380 |
| diana | speakx123 | 975 |
| evan | speakx123 | 1520 |
| fiona | speakx123 | 890 |

Run: `make seed-users`

---

## Troubleshooting

### Ports in use
```bash
make kill
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

### Questions repeating
The question pool is de-duplicated per player across matches. If the pool is too small relative to active players, the system falls back to unrestricted selection. Add more questions to `mongo-init/init.js` and run `make seed`.

### Premium not reflecting after payment
The Flutter app syncs premium status at every login via `GET /payment/status`. If the payment service is down, the local cached value is used. Force-sync by logging out and back in.

### Daily reward popup not appearing
The popup only appears if `pendingReward != null` in `AuthState`. Check:
1. `currentStreak > 0` — streak must be at least 1
2. `dailyRewardClaimedDate != today` — not already claimed today
3. `isLoggedIn == true`

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

## Running Tests

```bash
# Flutter unit tests (31 tests)
cd flutter-app && flutter test test/widget_test.dart

# Go tests
make test
```

Flutter tests cover:
- `GameState` defaults and `copyWith`
- Win streak logic (5 cases)
- Daily quota with bonus games (6 cases)
- `isEffectivelyPremium` including trial expiry (5 cases)
- `rewardForDay` reward table (6 cases)
- `pendingReward` edge cases (4 cases)
- `copyWith` sentinel for nullable `premiumTrialExpiresAt` (2 cases)

---

## Phase 1 Audit — All 16 Requirements

| # | Requirement | Status | Notes |
|---|-------------|--------|-------|
| 1 | Flutter connected to real backend | ✅ | Real gRPC, no mock flags |
| 2 | 3 truly separate services | ✅ | Ports 50051/50052/50053 + 8081, independent binaries |
| 3 | All RabbitMQ consumers functional | ✅ | All 6 queues declared and consuming |
| 4 | match_history persisted with full fields | ✅ | All fields including score, rank, avgResponseMs |
| 5 | Double round completion prevented | ✅ | SETNX `room:{id}:round:{n}:closed` guard |
| 6 | Reconnection with state recovery | ✅ | ReconnectService + exponential backoff |
| 7 | Leaderboard updates atomic | ✅ | Lua script: ZINCRBY + EXPIRE + ZREVRANK |
| 8 | Zombie room cleanup (TTLs) | ✅ | All room keys EXPIRE 1800s |
| 9 | Timer sync server→client | ✅ | TimerSync every 1s with DeadlineMs |
| 10 | Idempotent answer processing | ✅ | HSETNX + HEXISTS double guard |
| 11 | PlayerJoined event broadcast | ✅ | Broadcast on StreamGameEvents subscription |
| 12 | Late joiner / mid-match join | ✅ | Late joiner receives current question + TimerSync on connect |
| 13 | Proper error handling | ✅ | gRPC status codes, ACK/NACK, try/catch in Flutter |
| 14 | All proto RPCs implemented | ✅ | Register, Login, GoogleAuth, Join/Leave/Subscribe, Stream/Submit, Score/GetLeaderboard |
| 15 | Docker includes all services | ✅ | mongo + redis + rabbitmq + 4 Go services, all with healthchecks |
| 16 | Comprehensive seed data | ✅ | 60 questions + 6 test users |

---

## Phase 2 Additions

| Feature | Status | Where |
|---------|--------|-------|
| Razorpay premium payments | ✅ | `payment-service/`, `premium_screen.dart` |
| Daily game quota (5/day) | ✅ | `auth_service.dart` → `consumeDailyQuiz()` |
| Bonus games from daily rewards | ✅ | `AuthState.bonusGamesRemaining` |
| Premium sync across devices | ✅ | `_syncPremiumFromServer()` after every login |
| Google Sign-In | ✅ | `matchmaking-service/handlers/google_auth.go` + `auth_service.dart` |
| Profile pictures (Google) | ✅ | CachedNetworkImage across Home / Matchmaking / Profile |
| Win streak (speed streak) badge | ✅ | `GameState.currentWinStreak`, `leaderboard_screen.dart` |
| Home + Play Again buttons in results | ✅ | `results_screen.dart` |
| Daily Rewards & Login Streak | ✅ | `auth_service.dart`, `home_screen.dart`, `profile_screen.dart` |
| Coins system | ✅ | `AuthState.coins`, Profile → STREAK tab |
| Premium trial (day-30 streak reward) | ✅ | `AuthState.isEffectivelyPremium` |
| 30-day login calendar | ✅ | Profile → STREAK tab |
| Referral system (anti-abuse) | ✅ | `matchmaking-service/handlers/referral.go`, Profile → REFERRAL tab |
| Coupon/referral discount on premium | ✅ | `payment-service/handlers/payment.go` → `ValidateCoupon` |
| FCM push notifications (5 types) | ✅ | `notification-worker/`, `notification_service.dart` |
| Server-side daily quota enforcement | ✅ | `matchmaking.go` → `enforceQuotaAndIncrement()` |
| Leaderboard cap for free users | ✅ | `scoring.go` → `GetLeaderboard()` caps to top 3 + own |
| Late joiner catch-up | ✅ | `quiz_handler.go` → sends current question on connect |
| Redis observability keys | ✅ | `redis_keys.go` → plan, quota, streak, referral on login |
| `payment-success-queue` in RabbitMQ | ✅ | `payment-service/rabbitmq/publisher.go` |

**Docs:** See [docs/](docs/) for detailed specs on each feature.

---

