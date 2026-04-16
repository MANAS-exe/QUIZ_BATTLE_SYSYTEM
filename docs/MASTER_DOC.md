# Quiz Battle — Master Documentation

> A comprehensive, chronological reference covering every service, feature, design decision, and bug fix in the Quiz Battle system.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Phase 1 — Core Game Infrastructure](#2-phase-1--core-game-infrastructure)
   - [2.1 Matchmaking Service](#21-matchmaking-service)
   - [2.2 Quiz Engine Service](#22-quiz-engine-service)
   - [2.3 Scoring Service](#23-scoring-service)
   - [2.4 RabbitMQ Event Bus](#24-rabbitmq-event-bus)
   - [2.5 Redis — State & Concurrency](#25-redis--state--concurrency)
   - [2.6 MongoDB — Persistent Storage](#26-mongodb--persistent-storage)
   - [2.7 Flutter Client — Game UI](#27-flutter-client--game-ui)
   - [2.8 Phase 1 Bugs & Fixes](#28-phase-1-bugs--fixes)
3. [Phase 2 — Features & Monetisation](#3-phase-2--features--monetisation)
   - [3.1 Google Sign-In](#31-google-sign-in)
   - [3.2 Home Screen](#32-home-screen)
   - [3.3 Daily Rewards & Login Streak](#33-daily-rewards--login-streak)
   - [3.4 Premium Subscription (Razorpay)](#34-premium-subscription-razorpay)
   - [3.5 Payment Service](#35-payment-service)
   - [3.6 Referral System](#36-referral-system)
   - [3.7 FCM Push Notifications](#37-fcm-push-notifications)
   - [3.8 Notification Worker Service](#38-notification-worker-service)
   - [3.9 Phase 2 Bugs & Fixes](#39-phase-2-bugs--fixes)
4. [Gap Audit & Final Fixes](#4-gap-audit--final-fixes)
5. [Full Architecture Summary](#5-full-architecture-summary)
6. [Running the Project](#6-running-the-project)

---

## 1. System Overview

### What is Quiz Battle?

A real-time multiplayer quiz game where players register, get matched with opponents, compete across timed rounds with difficulty-based scoring, climb persistent leaderboards, refer friends, earn daily rewards, purchase premium subscriptions, and receive push notifications.

### Why Microservices?

The project was initially a single Go binary. The spec required three independent services to demonstrate distributed systems knowledge. A fourth (Payment) and fifth (Notification Worker) were added in Phase 2.

| Service | Why it's separate |
|---------|------------------|
| **Matchmaking** | Owns player identity + room lifecycle; must be available even during games |
| **Quiz Engine** | Long-lived streaming connections; game state is isolated per room |
| **Scoring** | High write frequency (every answer); atomic Redis operations independent of game loop |
| **Payment** | PCI-adjacent; HTTP not gRPC; Razorpay webhook surface is isolated |
| **Notification Worker** | Fire-and-forget background process; no client-facing API |

### Why this tech stack?

| Choice | Why |
|--------|-----|
| **Go** | Low-latency gRPC streaming, goroutine-per-player model, small Docker images |
| **gRPC + Protobuf** | Type-safe contracts, efficient binary wire format, native streaming for real-time events |
| **Redis** | In-memory sorted sets for matchmaking pool and leaderboards; sub-millisecond latency for game state |
| **RabbitMQ** | Topic exchange lets multiple consumers process the same event independently (fan-out); DLQ for failed messages |
| **MongoDB** | Flexible schema for evolving user documents; `$sample` for random question selection |
| **Flutter** | Single codebase for iOS + Android; Riverpod for reactive state management |
| **Razorpay** | Free test mode, Indian payment methods (UPI, cards), webhook-based async confirmation |
| **FCM** | Free push notifications to both platforms; Firebase Admin SDK for server-side dispatch |

---

## 2. Phase 1 — Core Game Infrastructure

### 2.1 Matchmaking Service

**Port:** `:50051` (gRPC) + `:8080` (HTTP for REST endpoints)

**What it does:**
- User registration and login (bcrypt password hashing, JWT issuance)
- Google OAuth token verification and account upsert
- Matchmaking pool management (Redis sorted set keyed by rating)
- Room creation with distributed locking
- Publishes `match.created` to RabbitMQ

**How matchmaking works:**
1. Player calls `JoinMatchmaking` RPC with their userId, username, and rating
2. Server adds them to `matchmaking:pool` (Redis sorted set, score = rating)
3. After a 10-second lobby wait, `tryCreateRoom()` fires
4. Acquires a distributed lock (`SETNX` with UUID owner + 30s TTL)
5. Pops 2–10 players from the sorted set via `ZPOPMIN`
6. Creates room state in Redis (`room:{id}:state`, `room:{id}:players`)
7. Publishes `match.created` event to RabbitMQ exchange `sx`
8. Notifies all waiting players via their `SubscribeToMatch` streams

**Why a sorted set for matchmaking?**
Players are scored by rating. `ZPOPMIN` atomically removes the lowest-rated players, enabling rating-based matching. With a distributed lock wrapping the pop, no two goroutines can pop the same players.

**Server-side daily quota enforcement:**
Before adding a player to the pool, `enforceQuotaAndIncrement()` checks:
1. Active premium subscription in MongoDB → bypass quota
2. `users.daily_quiz_used` + `users.last_quiz_date` → if ≥5 today, return `ResourceExhausted`
3. Increment counter atomically
4. Mirror remaining quota to Redis (`user:{id}:daily_quota`) for observability

**Key files:**
- `matchmaking-service/handlers/matchmaking.go` — JoinMatchmaking, tryCreateRoom, enforceQuotaAndIncrement
- `matchmaking-service/handlers/auth.go` — Register, Login
- `matchmaking-service/handlers/google_auth.go` — Google OAuth
- `matchmaking-service/handlers/referral.go` — Referral system (Phase 2)
- `matchmaking-service/handlers/device_token.go` — FCM token registration (Phase 2)
- `matchmaking-service/handlers/redis_keys.go` — PopulateUserRedisKeys (Phase 2)
- `matchmaking-service/redis/lock.go` — Distributed lock (SETNX + Lua compare-and-delete)
- `matchmaking-service/redis/room.go` — Room creation pipeline

---

### 2.2 Quiz Engine Service

**Port:** `:50052` (gRPC)

**What it does:**
- Consumes `match.created` from RabbitMQ → selects questions for the room
- Hosts `StreamGameEvents` (server-streaming RPC) — the primary real-time channel
- Runs the game loop: broadcasts questions, manages timers, detects round completion
- Handles `SubmitAnswer` RPC — validates and publishes `answer.submitted`
- Saves `match_history` to MongoDB after the match ends

**How the game loop works:**
1. First player to call `StreamGameEvents` triggers the game loop via `sync.Once`
2. 5-second lobby wait for all players to subscribe
3. For each round (1 to totalRounds):
   a. `LPOP` next question from `room:{id}:questions`
   b. Broadcast `QuestionBroadcast` event (question text, options, 30s deadline)
   c. Start countdown — broadcast `TimerSync` every 1 second
   d. Early-exit: if all active players have answered, skip remaining timer
   e. `SETNX room:{id}:round:{n}:closed` — only first goroutine proceeds (prevents double round completion)
   f. Publish `round.completed` to RabbitMQ
   g. Wait 2s for scoring consumer, then broadcast `RoundResult` + `LeaderboardUpdate`
4. After all rounds (or early end): broadcast `MatchEnd`, save match_history

**Why `sync.Once` for the game loop?**
Multiple players connect to `StreamGameEvents` concurrently. Without `sync.Once`, each connection would start a separate game loop, causing duplicate rounds and race conditions.

**Late joiner catch-up:**
When a player connects after the game loop has started (not the first subscriber), the server immediately sends:
- The current `QuestionBroadcast` event (stored in `gameRoom.currentQuestion`)
- A `TimerSync` with the remaining time

This ensures late joiners can see and answer the current question immediately.

**Question selection:**
- Fisher-Yates shuffle replaces MongoDB `$sample` (which has repeat bias at small pool sizes)
- Distribution: 4 easy + 4 medium + 2 hard = 10 rounds
- Seen-question avoidance: fetches `questionIds` from `match_history` for all players in the room
- Fallback: if not enough unseen questions, sample from full pool but exclude already-selected IDs

**Key files:**
- `quiz-service/handlers/quiz_handler.go` — StreamGameEvents, game loop, room hub, late-joiner catch-up
- `quiz-service/handlers/quiz.go` — RunRound (timer, broadcast, SETNX guard)
- `quiz-service/questions/selection.go` — Fisher-Yates shuffle, difficulty distribution
- `quiz-service/rabbitmq/match_consumer.go` — Consumes match.created
- `quiz-service/rabbitmq/publisher.go` — Publishes answer.submitted, round.completed, match.finished

---

### 2.3 Scoring Service

**Port:** `:50053` (gRPC)

**What it does:**
- Consumes `answer.submitted` from RabbitMQ → validates, calculates score, updates leaderboard
- Exposes `GetLeaderboard` RPC (with server-side cap for free users)
- Consumes `match.finished` for post-match processing
- Consumes `match.finished` on analytics queue (logs to stdout)

**How scoring works:**
1. Scoring consumer receives `answer.submitted` message
2. Idempotency check: `HEXISTS room:{id}:answers:{round} {userId}` — skip if already scored
3. Fetch correct answer from MongoDB `questions` collection
4. Calculate score:
   - Base: Easy=100, Medium=125, Hard=150 (0 if wrong)
   - Speed bonus: `50 * (1 - responseMs / 10000)` — linear decay over 10 seconds
5. Update leaderboard atomically via Lua script:
   ```lua
   redis.call('ZINCRBY', key, points, member)
   redis.call('EXPIRE', key, 1800)
   local rank = redis.call('ZREVRANK', key, member)
   return rank
   ```
6. Store answer metadata in `room:{id}:answers:{round}` hash

**Why a Lua script for leaderboard updates?**
`ZINCRBY` and `ZREVRANK` are two separate Redis commands. Without atomicity, a concurrent update between them would return a stale rank. The Lua script executes all three operations in a single Redis server round-trip — no race condition window.

**Leaderboard cap for free users:**
`GetLeaderboard()` extracts the user ID from JWT context and checks MongoDB subscriptions. Free users see only the top 3 entries plus their own entry. Premium users see the full leaderboard.

**Key files:**
- `scoring-service/handlers/scoring.go` — CalculateScore, GetLeaderboard, isPremium
- `scoring-service/redis/leaderboard.go` — Lua atomic update script
- `scoring-service/rabbitmq/consumer.go` — answer.submitted consumer, DLQ routing

---

### 2.4 RabbitMQ Event Bus

**Exchange:** `sx` (topic, durable)

All inter-service communication flows through a single topic exchange. Each consumer declares its own durable queue with a routing key binding.

| Routing Key | Producer | Consumer(s) | Purpose |
|-------------|----------|-------------|---------|
| `match.created` | Matchmaking | Quiz Engine | Triggers question selection for new room |
| `answer.submitted` | Quiz Engine | Scoring | Triggers score calculation + leaderboard update |
| `round.completed` | Quiz Engine | (logged) | Round-level observability |
| `match.finished` | Quiz Engine | Scoring (persistence) + Scoring (analytics) + Notification Worker | Post-match processing, referral conversion notifications |
| `notification.*` | Cron/events | Notification Worker | Push notification dispatch (streak, daily reward, tournament, premium expiry) |
| `payment.success` | Payment | — | Published after Razorpay webhook captures a payment |

**Dead Letter Queue:**
`answer-processing-queue` is configured with `x-dead-letter-exchange` and `x-dead-letter-routing-key`. After 3 failed processing attempts, messages are NACK'd to `answer-processing-dlq` for manual investigation.

**Why RabbitMQ over Kafka?**
- Message acknowledgement (ACK/NACK) with redelivery — critical for exactly-once scoring
- Topic exchange with wildcard routing (`notification.*`) — simple fan-out
- Management UI at `:15672` for observability during demos
- Lower operational complexity for a 5-service system

---

### 2.5 Redis — State & Concurrency

Redis holds all ephemeral game state. Every key has a 30-minute TTL for automatic cleanup.

| Key Pattern | Owner | Purpose |
|-------------|-------|---------|
| `matchmaking:pool` | Matchmaking | Sorted set of waiting players (score = rating) |
| `player:{id}` | Matchmaking | Hash with player details (username, rating, joined_at) |
| `room:{id}:state` | Matchmaking | JSON blob with room metadata |
| `room:{id}:players` | Matchmaking | Hash of player data per room |
| `room:lock:{id}` | Matchmaking | Distributed lock (SETNX + UUID owner) |
| `room:{id}:questions` | Quiz Engine | List of question IDs (LPOP per round) |
| `room:{id}:submitted:{round}` | Quiz Engine | Hash of submitted answers (instant, for early-exit detection) |
| `room:{id}:round:{n}:closed` | Quiz Engine | SETNX guard preventing double round completion |
| `room:{id}:round:{n}:started_at` | Quiz Engine | Round start timestamp for speed bonus calculation |
| `room:{id}:leaderboard` | Scoring | Sorted set of cumulative scores |
| `room:{id}:answers:{round}` | Scoring | Hash of scored answers (idempotency guard) |
| `room:{id}:correct_counts` | Scoring | Hash tracking correct answer count per player |
| `user:{id}:plan` | Matchmaking | `free` or `premium` (set on login, 1-day TTL) |
| `user:{id}:daily_quota` | Matchmaking | Remaining games today (set on login + matchmaking join) |
| `user:{id}:streak` | Matchmaking | Hash: current, longest, last_login (set on login) |
| `referral:code:{code}` | Matchmaking | Maps referral code → userId (set on code generation) |

**Concurrency guarantees (all via Redis):**

| Problem | Solution |
|---------|----------|
| Concurrent score updates | Lua script: `ZINCRBY + EXPIRE + ZREVRANK` atomic |
| Concurrent room creation | Distributed lock: `SET NX EX` + UUID owner + Lua compare-and-delete |
| Multiple game loop starts | `sync.Once` in Go |
| Duplicate answer scoring | `HEXISTS` idempotency check |
| Double round completion | `SETNX room:{id}:round:{n}:closed` — first goroutine wins |
| Matchmaking ZPOPMIN race | Global Redis lock around ZPOPMIN |

---

### 2.6 MongoDB — Persistent Storage

| Collection | Key Fields | Indexes |
|------------|-----------|---------|
| `users` | username (unique), password_hash, google_id, email, picture_url, rating, referral_code (unique sparse), referred_by, referral_count, pending_referral_coins, daily_quiz_used, last_quiz_date | username (unique), email (sparse), referral_code (unique sparse) |
| `questions` | question_id, text, options[4], correctIndex, difficulty, topic, avgResponseTimeMs | difficulty, topic |
| `match_history` | roomId, players[{userId, username, finalScore, rank, answersCorrect, avgResponseTimeMs}], questionIds, rounds, winner, createdAt, durationMs | players.userId, createdAt |
| `payments` | userId, orderId, razorpay_payment_id, plan, status, amount, expiresAt | order_id (unique), user_id |
| `subscriptions` | user_id, plan, status, started_at, expires_at, razorpay_order_id | user_id, expires_at |
| `device_tokens` | user_id (unique), token, platform, updated_at | user_id (unique) |
| `referrals` | referrer_id, referee_id (unique), code_used, created_at | referrer_id, referee_id (unique) |

**Seed data:** 30 questions across 12 topics (vocabulary, grammar, idioms, etc.) + 6 test users.

---

### 2.7 Flutter Client — Game UI

**Architecture:**
- 3 gRPC channels: matchmaking (50051), quiz (50052), scoring (50053)
- 1 HTTP client: payment service (8081)
- State: Riverpod `StateNotifier` (`AuthNotifier` for user state, `GameNotifier` for match state)
- Navigation: GoRouter with auth guards
- Reconnection: `ReconnectService` wraps `StreamGameEvents` with exponential backoff (1s→2s→4s→8s→16s, max 5 retries)
- Timer: Server-driven via `TimerSync` events (absolute `DeadlineMs` timestamp, not local drift-prone timer)

**10 Screens:**
| Screen | Route | Purpose |
|--------|-------|---------|
| Login | `/login` | Email/password + Google Sign-In |
| Home | `/home` | Dashboard — quota, streak, reward popup, stats, upsell |
| Matchmaking | `/matchmaking` | Lobby with player avatars, countdown |
| Quiz | `/quiz` | Question + 4 answers + countdown ring |
| Leaderboard | `/leaderboard` | Between-round scores + streak badges |
| Results | `/results` | Winner + Share / Home / Play Again |
| Spectating | `/spectating` | Read-only live view for forfeited players |
| Profile | `/profile` | 5 tabs: Profile / Last Match / Badges / Streak / Referral |
| Premium | `/premium` | Plan comparison + Razorpay checkout + coupon field |
| Global Leaderboard | `/global-leaderboard` | All-time top players |

---

### 2.8 Phase 1 Bugs & Fixes

#### Bug 1: 30-Second Delay on Last Round
**Symptom:** When one player forfeited, remaining players' answers were never received. Timer ran full 30s.
**Root Cause:** `StreamGameEvents` checked `LLEN room:{id}:questions` on every connection. After all questions were popped, it returned 0 and killed the stream.
**Fix:** If the room already exists in the broadcast hub, skip question-count validation and just subscribe.

#### Bug 2: Score / Leaderboard Empty After 3-Service Split
**Symptom:** All players showed 0 points after splitting into microservices.
**Root Cause:** Both quiz handler and scoring consumer used `HSETNX` on the same Redis key. Quiz handler's pre-write caused scoring consumer to skip.
**Fix:** Separated into two distinct keys: `room:{id}:submitted:{round}` (instant) and `room:{id}:answers:{round}` (scoring consumer).

#### Bug 3: Spectating Player Stuck
**Symptom:** Forfeited player never reached results screen.
**Fix:** Added `_buildSyntheticMatchEnd()` when stream dies while spectating; process `RoundResultEvent` in spectating phase.

#### Bug 4: Match Duration Showing 0s
**Fix:** Track `matchStartedAt` in game loop, compute `time.Since()` for MatchEnd.

#### Bug 5: Questions Repeating Within a Match
**Root Cause:** MongoDB `$sample` re-visits documents when requested size exceeds ~5% of collection.
**Fix:** Replaced with Fisher-Yates shuffle in Go. Each difficulty bucket excludes IDs from earlier buckets.

#### Bug 6: Matchmaking Race Condition
**Symptom:** 3+ players in same room, or ghost matches.
**Fix:** Wrapped `ZPOPMIN + room creation` in a global distributed lock.

#### Bug 7: Distributed Lock Blind Delete
**Symptom:** Slow goroutine could delete another's lock after TTL expired.
**Fix:** UUID owner token + Lua compare-and-delete script.

#### Bug 8: Auth Context Not Enforced
**Symptom:** Any client could forge userId in request.
**Fix:** All handlers now read `middleware.UserIDFromContext(ctx)` instead of `req.UserId`.

#### Bug 9: Timer Hardcoded to 30s
**Fix:** Use `question.timeLimitMs / 1000` from server broadcast. `TimerSync` corrects drift.

#### Bug 10: Leaderboard Keys Had No TTL
**Fix:** Added `redis.call('EXPIRE', leaderKey, 1800)` to the Lua script.

#### Bug 11: Missing MongoDB Indexes
**Fix:** Added unique index on `users.username`, index on `questions.difficulty`, index on `match_history.players.userId`.

#### Bug 12: Duplicate `redis/client.go`
**Fix:** Deleted dead code file; all call sites already used the pool.

---

## 3. Phase 2 — Features & Monetisation

### 3.1 Google Sign-In

**What:** Users authenticate with their Google account — one tap, no password.

**Why:**
- No passwords to forget or manage
- Google provides verified email + profile picture
- Reduced sign-up friction → higher conversion

**How:**
1. Flutter calls `GoogleSignIn.signIn()` → user sees Google consent screen
2. Gets Google's signed ID token (JWT)
3. Sends to backend: `POST http://localhost:8080/auth/google { "id_token": "eyJ..." }`
4. Backend verifies token with Google's tokeninfo API
5. Validates `aud` claim matches `GOOGLE_CLIENT_ID`, checks `email_verified`
6. Upserts user in MongoDB (creates new or links existing account by email)
7. Issues app JWT, returns user data including Google profile picture URL

**Username derivation:** `"John Doe"` → `"johnd"` (given + first letter of family). If taken, appends last 4 digits of Google `sub`. Up to 10 collision retries.

**Account linking:** If a user registered with email/password using the same email, Google login links to the existing account. The `google_id` field is added to their document.

**Security:**
- Server-side verification only — ID token never trusted on client
- `aud` claim validated in production
- No Google token stored — only app's own JWT persisted

---

### 3.2 Home Screen

**What:** The main landing page after login — dashboard with all key information.

**Components (top to bottom):**
1. **Top Bar** — coin capsule + streak pill (flame icon) + settings
2. **Profile Card** — Google avatar, username, rating, W/L record, premium badge
3. **Daily Quota Card** — `3 / 5 games played today · +3 bonus`
4. **Play Button** — primary CTA; disabled with upgrade prompt if quota exhausted
5. **Quick Stats** — matches today, win rate, current answer streak
6. **Premium Upsell Card** — shown for free users; hidden for premium/trial
7. **Referral Share Card** — shows referral code with one-tap copy
8. **Leaderboard Preview** — top 3 + own rank (full for premium)
9. **Daily Reward Dialog** — animated popup on first open each day if unclaimed

---

### 3.3 Daily Rewards & Login Streak

**What:** Users earn escalating rewards for consecutive daily logins. Missing a day resets the streak.

**Why:**
- Drives daily active usage (DAU)
- Creates a psychological loss aversion (don't break the streak)
- Coins system provides engagement currency for future features

**How it works:**
- On every login, `_updateLoginStreak()` runs: appends today's date to `loginHistory` (last 30 ISO dates), computes streak by walking backwards counting consecutive days
- If `dailyRewardClaimedDate != today`, `pendingReward` getter returns a non-null `DailyReward`
- `HomeScreen.initState` shows the reward dialog via `addPostFrameCallback`
- User taps "Claim" → `claimDailyReward()` adds coins + bonus games to state, sets claim date

**Reward table:**
| Day | Coins | Bonus Games | Badge | Premium Trial |
|-----|-------|-------------|-------|---------------|
| 1 | 50 | — | — | — |
| 2 | 75 | — | — | — |
| 3 | 100 | +1 | — | — |
| 5 | 150 | +2 | — | — |
| 7 | 250 | +3 | Week Warrior | — |
| 14 | 500 | +5 | Fortnight Fighter | — |
| 30 | 1000 | +7 | Monthly Master | 7 days Premium |

After day 7, the weekly cycle repeats. Milestones at 14 and 30 always override.

**All logic is client-side** (SharedPreferences) — works fully offline. The streak is also mirrored to Redis (`user:{id}:streak`) on login for demo observability.

---

### 3.4 Premium Subscription (Razorpay)

**What:** Free users get 5 games/day. Premium users get unlimited games + full leaderboard + premium badge.

**Why Razorpay:**
- Free test mode (no real money)
- Indian payment methods (UPI, cards)
- Webhook-based async payment confirmation
- HMAC signature verification for security

**Plans:**
| Plan | Price | Duration |
|------|-------|---------|
| Monthly | ₹499 | 30 days |
| Yearly | ₹3,999 | 365 days |

**Coupon system:** Any user can enter a friend's referral code as a coupon on the premium screen. Backend validates the code exists and isn't the user's own code. Discount: Monthly ₹499→₹399, Yearly ₹3,999→₹3,499.

**Payment flow:**
1. Flutter sends `POST /payment/create-order` with plan + optional coupon code
2. Backend creates a Razorpay order, saves pending payment in MongoDB
3. Flutter opens Razorpay checkout SDK
4. On success: `POST /payment/verify` with HMAC-SHA256 signature verification
5. Backend activates subscription in MongoDB, sets `users.premium = true`
6. Flutter calls `GET /payment/status` → updates local state immediately

**Webhook handler:** `POST /payment/webhook` verifies `X-Razorpay-Signature` header using `HMAC-SHA256(webhook_secret, raw_body)`. Handles `payment.captured` (upserts subscription, publishes `payment.success` to RabbitMQ) and `payment.failed` events. Idempotent: checks if payment_id already processed before writing.

**`isEffectivelyPremium`:** Computed getter that returns `true` for either paid premium OR an active daily-reward premium trial. All quota checks, upsell visibility, and leaderboard limits use this getter.

---

### 3.5 Payment Service

**Port:** `:8081` (HTTP)

**What it does:**
- Creates Razorpay orders
- Verifies payment signatures (HMAC-SHA256)
- Manages subscription lifecycle in MongoDB
- Validates referral coupons for discounts
- Publishes `payment.success` events to RabbitMQ
- Handles Razorpay webhook callbacks

**Endpoints:**
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `POST` | `/payment/create-order` | JWT | Create Razorpay order + pending payment record |
| `POST` | `/payment/verify` | JWT | Verify HMAC signature, activate subscription |
| `GET` | `/payment/status` | JWT | Return current premium status |
| `GET` | `/payment/history` | JWT | Return past payments |
| `GET` | `/payment/validate-coupon` | JWT | Validate referral code as discount coupon |
| `POST` | `/payment/webhook` | Razorpay signature | Handle async payment events |

**Key files:**
- `payment-service/handlers/payment.go` — CreateOrder, VerifyPayment, GetStatus, GetHistory, ValidateCoupon
- `payment-service/handlers/webhook.go` — HandleWebhook, handlePaymentCaptured, HMAC verification
- `payment-service/rabbitmq/publisher.go` — Publishes payment.success to RabbitMQ

---

### 3.6 Referral System

**What:** Every user gets a unique 6-character code. New users apply a friend's code to earn rewards for both parties.

**Why:**
- New user acquisition — existing players become ambassadors
- Shorter matchmaking queues — more players = faster matches
- Retention — referrer has social stake in friend's activity

**Code format:** 6 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (excludes ambiguous `0/O/1/I/L`). Generated with `crypto/rand`. 31^6 ≈ 887M combinations.

**Rewards:**
| Who | Coins | Bonus Games |
|-----|-------|-------------|
| Referrer | +200 | +2 |
| Referee | +100 | +1 |

Rewards are **pending** until claimed via `GET /referral/claim`.

**Anti-abuse (5 server-side checks):**
1. `referred_by` must be empty (can't apply twice)
2. Account must be ≤7 days old
3. Can't apply own code (self-referral)
4. Referrer's count must be < 10 (cap)
5. Code must be exactly 6 valid chars

**Lazy code generation:** Users who registered before the referral system get their code generated on first `GET /referral/code` call.

**Redis caching:** Referral codes are mirrored to `referral:code:{code}` → `userId` in Redis for demo observability.

---

### 3.7 FCM Push Notifications

**What:** Firebase Cloud Messaging for real-time push notifications to Android/iOS.

**Why:**
- Re-engagement: bring users back to maintain streaks
- Real-time events: notify referrers when friends complete quizzes
- Lifecycle: warn before premium expires

**5 notification types:**
| Type | Trigger | Target | Mechanism |
|------|---------|--------|-----------|
| `streak_warning` | 7 PM IST daily | All users | Cron |
| `daily_reward` | 8 AM IST daily | All users | Cron |
| `premium_expiry` | 9 AM IST daily | Users expiring in 3 days | Cron |
| `referral_converted` | Referee plays first match | Referrer only | RabbitMQ `match.finished` |
| `tournament_reminder` | On-demand | All or specific users | RabbitMQ `notification.tournament_reminder` |

**Flutter integration:**
- `notification_service.dart` — requests permission, registers FCM token, handles foreground/background messages, stores pending route for tap navigation
- Token registered with backend on every login (Google, email/password, register)
- Background handler is a top-level function with `@pragma('vm:entry-point')`

---

### 3.8 Notification Worker Service

**Port:** None (background worker)

**What it does:**
- Connects to RabbitMQ and consumes `notification.*` and `match.finished` events
- Dispatches FCM notifications via Firebase Admin SDK
- Runs cron scheduler for time-based notifications
- Manages FCM multicast (batches of 500 tokens per FCM limit)

**Architecture:**
```
RabbitMQ ──► NotificationConsumer (notification.*) ──► FCM SendMulticast
         ──► MatchFinishedConsumer (match.finished) ──► Referral conversion check ──► FCM Send
Cron     ──► Scheduler (3 jobs) ──► FCM SendMulticast
```

**Referral conversion (exactly-once):**
When `match.finished` fires, the worker checks each player's `referred_by` field. If set and `referee_first_match_notified` is false, it atomically sets the flag and sends a notification to the referrer. The atomic flag prevents duplicate sends on worker restart.

**Key files:**
- `notification-worker/main.go` — wires MongoDB, FCM, RabbitMQ consumers, scheduler
- `notification-worker/worker/fcm.go` — Firebase Admin SDK wrapper
- `notification-worker/worker/consumer.go` — NotificationConsumer + MatchFinishedNotificationConsumer
- `notification-worker/worker/scheduler.go` — Cron jobs with `robfig/cron/v3`
- `notification-worker/worker/db.go` — MongoDB helpers for token/user/subscription lookups

**Setup required:**
- `FIREBASE_CREDENTIALS_JSON` env var (service account JSON, single line)
- `google-services.json` at `flutter-app/android/app/` (not committed — in `.gitignore`)

---

### 3.9 Phase 2 Bugs & Fixes

#### Bug 13: Daily Quota Not Decrementing
**Symptom:** Home screen showed "5 remaining" after a game.
**Root Cause:** `consumeDailyQuiz()` was defined but never called.
**Fix:** Added call in `matchmaking_screen.dart → _onMatchFound` when match is confirmed.

#### Bug 14: `isQuotaExhausted` Ignoring Bonus Games
**Fix:** Updated getter to check `bonusGamesRemaining == 0` alongside `dailyQuizUsed >= 5`. `consumeDailyQuiz()` now drains bonus games first.

#### Bug 15: Premium Status Not Reflecting on New Device
**Fix:** Added `_syncPremiumFromServer()` after every login — calls `GET /payment/status` with 5s timeout.

#### Bug 16: Razorpay Activity Resume Crash (Android)
**Symptom:** Black screen after payment failure on Android.
**Root Cause:** Razorpay callbacks fire during Activity `onResume` before Flutter widget tree is restored.
**Fix:** Wrapped all Razorpay callback bodies in `Future.delayed(Duration.zero, ...)`.

#### Bug 17: Android Manifest Merge Conflict (Razorpay)
**Fix:** Added `tools:replace="android:exported,android:theme"` on CheckoutActivity.

#### Bug 18: Profile Picture Not Persisting Across Screens
**Fix:** Added `CachedNetworkImage` avatar widgets to Profile and Matchmaking screens.

#### Bug 19: Login Streak Incrementing on Match, Not Login
**Fix:** Moved `_updateLoginStreak()` to `_loadLocalStats()` which runs after every login. Replaced `_lastPlayed` key with `loginHistory` JSON array.

#### Bug 20: Premium Trial Not Reflected Without Logout
**Fix:** Introduced `isEffectivelyPremium` computed getter. All UI checks use this instead of `isPremium`.

#### Bug 21: `copyWith` Could Not Clear `premiumTrialExpiresAt` to Null
**Fix:** Sentinel object pattern — `static const _unset = Object()` — distinguishes "set to null" from "don't change".

#### Bug 22: Referrer Not Getting Coins / Slots Showing 10
**Root Cause:** Stale local state — referral data only synced on login.
**Fix:** Auto-sync on REFERRAL tab open + pull-to-refresh via `RefreshIndicator`.

#### Bug 23: Any 6-Char String Shown as Valid Coupon
**Fix:** Replaced client-side format validation with real `GET /payment/validate-coupon` backend call.

#### Bug 24: Notification Not Triggering for Password-Login Users
**Root Cause:** `_initNotifications()` only called in Google login path.
**Fix:** Added call in `register()` and `login()` methods alongside Google auth.

#### Bug 25: Docker build.gradle.kts Missing Repositories
**Fix:** Added `repositories { google(); mavenCentral() }` to `buildscript` block.

#### Bug 26: notification-worker .env Not Loaded by Docker
**Fix:** Added `env_file: notification-worker/.env` to docker-compose.yml. Compacted JSON to single line (Docker env_file requirement).

#### Bug 27: Daily Reward Popup Double-Showing (Prevented by Design)
**Prevention:** `claimDailyReward()` sets `dailyRewardClaimedDate = today` in both Riverpod state and SharedPreferences synchronously before dialog dismissal. Fully idempotent.

#### Bug 28: JoinMatchmaking Deleting SubscribeToMatch Channel
**Symptom:** Room created but both players got "No subscription" — MatchFound never delivered.
**Root Cause:** `JoinMatchmaking` had `delete(h.playerChans, req.UserId)` cleanup that removed the channel registered by the already-connected `SubscribeToMatch` stream.
**Fix:** Removed the delete. `SubscribeToMatch` itself overwrites the map entry on each new connection.

#### Bug 29: `panic: send on closed channel` Crashing Matchmaking
**Symptom:** Matchmaking service crashed when a player re-joined, disconnecting all players.
**Root Cause:** `JoinMatchmaking` called `close(oldCh)` on previous channel; concurrent broadcast goroutines still held references.
**Fix:** Removed `close(oldCh)`. Added `recover()` guard in `broadcastWaitingUpdate`.

#### Bug 30: Matchmaking Countdown Timer Decreasing by 2s
**Root Cause:** `_startCountdown()` didn't cancel the previous timer, so double-tap caused two timers running.
**Fix:** Added `_countdownTimer?.cancel()` at the top of `_startCountdown()`.

#### Bug 31: Daily Quota Silently Blocking Matchmaking
**Symptom:** Player sat in lobby but never joined pool. No error shown.
**Root Cause:** `enforceQuotaAndIncrement` returned `ResourceExhausted` but Flutter didn't surface the error.
**Impact:** Other player waited forever for a match that could never happen.

#### Bug 32: User Stats Not Persisted to MongoDB
**Symptom:** Stats reset to 0 on app reinstall or new device login.
**Fix:** Added `GET/POST /user/stats` endpoints. Flutter now pushes all stats to MongoDB after every `_saveLocalStats()` and pulls them on login. 20 fields now persisted.

#### Bug 33: FCM Not Triggering for Password-Login Users
**Fix:** Added `_initNotifications()` to `register()` and `login()` methods.

#### Bug 34: UPI Not Showing in Razorpay Checkout
**Root Cause:** Empty `prefill.contact` + web-only `config.display.blocks` in native SDK.
**Fix:** Removed unsupported options, set non-empty contact placeholder.

#### Bug 35: Logout Not Navigating to Login Screen
**Root Cause:** `logout()` was `void` not `Future<void>` — state not reset before GoRouter redirect.
**Fix:** Changed to `Future<void>`, awaited before `context.go('/login')`.

---

## 4. Gap Audit & Final Fixes

A comprehensive audit on 2026-04-13 compared the codebase against all Phase 1 + Phase 2 requirements. Six gaps were identified and fixed:

| Gap | What was missing | Fix |
|-----|-----------------|-----|
| **Server-side quota** | Quota tracked only in Flutter SharedPreferences | `enforceQuotaAndIncrement()` in matchmaking checks MongoDB + mirrors to Redis |
| **payment-success-queue** | No RabbitMQ event after payment | New `payment-service/rabbitmq/publisher.go`; webhook publishes `payment.success` |
| **Redis observability keys** | `user:{id}:plan`, `daily_quota`, `streak`, `referral:code:{code}` empty | New `redis_keys.go` → `PopulateUserRedisKeys()` called on every login |
| **MongoDB indexes** | Missing indexes on payments, subscriptions, topics | Added 7 new indexes in `mongo-init/init.js` |
| **Leaderboard cap** | Free users saw full leaderboard | `GetLeaderboard()` now caps to top 3 + own entry for free users |
| **Late joiner catch-up** | Late joiners missed current question | `gameRoom` stores current question; `StreamGameEvents` sends it to non-first subscribers |

**Cleanup also performed:**
- Updated `.gitignore` for `.env` files and Firebase configs
- Removed tracked secrets (`.env`, `google-services.json`) from git index
- Removed `flutter-app/build/` artifacts from git
- Deleted `.DS_Store` files

---

## 5. Full Architecture Summary

```
Flutter App (iOS / Android)
  ├── gRPC :50051 ──► Matchmaking Service   (Auth + Matchmaking + Referral + Device Token)
  ├── gRPC :50052 ──► Quiz Engine Service   (Game Loop + Questions + Late-Joiner Catch-up)
  ├── gRPC :50053 ──► Scoring Service       (Leaderboard + Scoring + Free User Cap)
  ├── HTTP :8081  ──► Payment Service       (Razorpay + Subscriptions + Coupons)
  └── FCM  ◄──────── Notification Worker    (Push Notifications)

RabbitMQ Exchange: sx (topic, durable)
  match.created      → quiz-match-created-queue     (Quiz Engine: select questions)
  answer.submitted   → answer-processing-queue      (Scoring: score + update leaderboard)
                     → answer-processing-dlq        (Dead letter after 3 failures)
  round.completed    → round-completed-queue        (Observability logging)
  match.finished     → match-finished-queue         (Scoring: persist match_history)
                     → match-analytics-queue        (Analytics stub)
                     → notification-match-queue      (Notification: referral conversion)
  notification.*     → notification-worker-queue     (Notification: push dispatch)
  payment.success    → payment-success-queue         (Post-capture event)

Infrastructure: MongoDB 7 + Redis 7 + RabbitMQ 3
Docker Compose: 8 containers (5 services + 3 infra), all with health checks
```

---

## 6. Running the Project

### Docker Compose (recommended)
```bash
make up                          # Build + start everything
# or
docker compose up --build -d     # Detached mode
```

### Local development
```bash
make infra                       # Start MongoDB, Redis, RabbitMQ
make seed && make seed-users     # Seed data
make run-matchmaking             # Terminal 1
make run-quiz                    # Terminal 2
make run-scoring                 # Terminal 3
cd payment-service && go run .   # Terminal 4
make run-notification-worker     # Terminal 5
cd flutter-app && flutter run    # Terminal 6 (+ Terminal 7 for 2nd emulator)
```

### Environment files (not committed)
```bash
# payment-service/.env
RAZORPAY_KEY_ID=rzp_test_xxx
RAZORPAY_KEY_SECRET=xxx
RAZORPAY_WEBHOOK_SECRET=xxx

# notification-worker/.env
FIREBASE_CREDENTIALS_JSON={"type":"service_account",...}
RABBITMQ_URL=amqp://guest:guest@localhost:5672/
MONGO_URI=mongodb://localhost:27017

# flutter-app/android/app/google-services.json (from Firebase Console)
```

### Verify everything works
```bash
# RabbitMQ UI
open http://localhost:15672       # guest/guest

# Redis CLI
docker compose exec redis redis-cli
> ZRANGE matchmaking:pool 0 -1 WITHSCORES
> GET user:{id}:plan
> HGETALL user:{id}:streak
> GET referral:code:{CODE}

# MongoDB
docker compose exec mongodb mongosh quizdb
> db.users.findOne()
> db.match_history.find().sort({createdAt:-1}).limit(1)
> db.device_tokens.find()
```
