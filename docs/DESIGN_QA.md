# Quiz Battle — Design Q&A

> Covers every design choice, implementation detail, and edge case from the Phase 2 spec.
> Structured as interviewer questions with detailed answers about what was built and why.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Why Redis for X](#2-why-redis-for-x)
3. [Why RabbitMQ for Y](#3-why-rabbitmq-for-y)
4. [Scoring Formula](#4-scoring-formula)
5. [Leaderboard Atomicity — Lua Scripts](#5-leaderboard-atomicity--lua-scripts)
6. [Razorpay Webhook Security](#6-razorpay-webhook-security)
7. [Daily Quota & Race Condition Prevention](#7-daily-quota--race-condition-prevention)
8. [Referral Anti-Abuse](#8-referral-anti-abuse)
9. [Flutter State Management — Riverpod](#9-flutter-state-management--riverpod)
10. [Edge Cases](#10-edge-cases)

---

## 1. Architecture

### Q: Why microservices? Why not a monolith?

We chose **3 independent Go services + 2 supporting services** over a monolith because each service has a fundamentally different scaling profile:

| Service | Port | Bottleneck |
|---|---|---|
| Matchmaking | `:50051` | I/O-bound — waiting for players to join |
| Quiz Engine | `:50052` | CPU-bound — managing round timers per room |
| Scoring | `:50053` | Redis-bound — leaderboard updates per answer |
| Payment | `:8081` | Network-bound — waiting for Razorpay webhooks |
| Notification Worker | — | Queue-bound — consuming FCM events |

If these were in one binary, a spike in quiz traffic would starve matchmaking. Separate processes let each scale independently. They communicate only through RabbitMQ events — no shared memory, no in-process calls.

**Trade-off accepted:** More operational overhead (5 binaries, docker-compose, health checks). Acceptable for this use case because each service is independently deployable.

---

### Q: How do the 3 core services talk to each other?

They don't call each other directly. All inter-service communication is event-driven through RabbitMQ topic exchange `sx`:

```
Flutter app
    │
    ├─ gRPC → Matchmaking (:50051) → publishes match.created
    │                                        │
    │                                        ▼
    │                               Quiz Engine consumes match.created
    │                               Quiz Engine runs rounds → publishes answer.submitted
    │                                        │
    ├─ gRPC → Quiz Engine (:50052)           ▼
    │   (submit answer)             Scoring Service consumes answer.submitted
    │   (stream events)             Scoring Service updates Redis leaderboard
    │                               Scoring Service publishes round.completed
    │                                        │
    └─ gRPC → Scoring (:50053)              ▼
        (get leaderboard)           Quiz Engine consumes round.completed
                                    Quiz Engine broadcasts next round or match end
                                    Quiz Engine publishes match.finished
                                             │
                                             ▼
                                    Scoring writes match_history to MongoDB
                                    Notification Worker sends push notifications
```

The quiz engine is the orchestrator — it triggers rounds and reacts to events. Scoring is a pure processor — it only updates numbers. They never need to know about each other's internals.

---

### Q: Why gRPC instead of REST for service-client communication?

Three reasons:

1. **Bidirectional streaming** — REST cannot stream. The quiz gameplay requires the server to push events (question broadcast, timer sync, round results, leaderboard updates, match end) to all clients simultaneously. gRPC server-side streaming handles this natively with `StreamGameEvents`.

2. **Type safety** — Proto definitions are the contract between Flutter and Go. If a field is renamed or removed, both sides break at compile time, not at runtime in production.

3. **Performance** — protobuf binary encoding is ~3-10× smaller than JSON. For a game sending timer sync events every second to every player in every room, this matters.

**Trade-off:** gRPC is harder to test (needs grpcurl/grpcui vs curl). Mitigated by enabling server reflection, which we exposed publicly for demo purposes.

---

## 2. Why Redis for X

### Q: Why use Redis for the matchmaking pool instead of MongoDB?

The matchmaking pool has three requirements that MongoDB cannot meet efficiently:

1. **Atomicity on join + read**: When player A joins, we need to atomically add them and broadcast the new pool state to all waiting players. Redis `ZADD` + `ZRANGE` is a single-threaded pipeline — no transactions needed.

2. **Sub-millisecond latency**: A player tapping "Start Matchmaking" expects immediate feedback. Redis sorted set `ZADD` is O(log N). MongoDB `insertOne` involves network, BSON serialization, and write journal — typically 5-15ms vs Redis's 0.1-0.3ms.

3. **Auto-expiry**: Players who crash without pressing Cancel must auto-leave the pool. Redis `EXPIRE` on the `player:{userId}` key handles this — MongoDB requires a separate cleanup job.

**Data structure used:**
```
matchmaking:pool          → Sorted Set: member=userId, score=rating
player:{userId}           → Hash: username, rating, joined_at  TTL=30s
```

The sorted set score is the player's rating. `ZPOPMIN` takes the lowest-rated players first, which naturally groups similar-skill players into rooms.

---

### Q: Why Redis for room state and the question list?

Room state lives only for the duration of a match — typically 5-15 minutes. Persisting it to MongoDB would be wasteful (write a document every round start). Redis keys with 30-minute TTL are self-cleaning.

The question list is a Redis `LIST`:
```
room:{roomId}:questions  → List: [questionId1, questionId2, ...]
```

`LPOP` on this list is the mechanism for serving rounds. It's:
- **Destructive** — each pop removes the question, guaranteeing it won't be served again in the same match
- **Atomic** — no two goroutines can pop the same question
- **Terminating** — when `LLEN` returns 0, the match is over

If this were MongoDB, we'd need an index field `served: true` updated atomically per round — more complex, slower.

---

### Q: Why Redis for the live leaderboard?

The leaderboard is a Redis Sorted Set:
```
leaderboard:{roomId}  → Sorted Set: member=userId, score=points
```

`ZINCRBY` increments a player's score atomically. `ZREVRANGE WITHSCORES` returns the full ranked list in O(log N + M) time. The rank of any player is `ZREVRANK` — also O(log N).

**The alternative** — recomputing rank from all player scores in MongoDB after every answer — would require a sort over all players per answer submission. In a 10-player room with 10 rounds, that's 100 sort operations vs 100 O(log N) Redis ops.

---

### Q: Why Redis for quota caching?

The matchmaking quota gate runs on every join attempt. If we hit MongoDB for every player every time they tap "Start Matchmaking", the DB becomes a bottleneck at scale.

```
user:{userId}:daily_quota  → String: "3" or "unlimited"   TTL=24h
user:{userId}:plan         → String: "free" or "premium"  TTL=24h
```

On login, the matchmaking service populates these keys from MongoDB. If Redis restarts, the worst case is one extra MongoDB read per user on their next login — not data loss.

---

## 3. Why RabbitMQ for Y

### Q: Why RabbitMQ instead of direct gRPC calls between services?

Direct gRPC would couple services together. If the scoring service is down, the quiz engine would fail to score an answer and crash the round. With RabbitMQ:

- Quiz engine publishes `answer.submitted` and immediately moves on — it doesn't wait for scoring to finish
- Scoring service processes at its own pace — if it's slow, messages queue up but the game continues
- If scoring crashes, messages survive in the durable queue and are processed when it restarts

**RabbitMQ vs Kafka:** Kafka is better for high-throughput log streaming (millions of events/second). RabbitMQ is better for task queues with complex routing, acknowledgement, and dead-lettering — which is exactly what answer processing needs. A single quiz match generates ~100 events. Kafka's overhead isn't justified.

---

### Q: How does the topic exchange routing work?

All services publish to a single exchange `sx` (type: topic, durable). Each consumer binds a durable queue to a routing key pattern:

| Routing Key | Publisher | Consumer Queue |
|---|---|---|
| `match.created` | Matchmaking | `quiz-match-created-queue` |
| `answer.submitted` | Quiz Engine | `answer-processing-queue` |
| `round.completed` | Quiz Engine | `round-completed-queue` |
| `match.finished` | Quiz Engine | `match-finished-queue` AND `match-analytics-queue` |
| `payment.success` | Payment | `payment-success-queue` |
| `notification.*` | All services | `notification-worker-queue` |

The `notification.*` wildcard is why a topic exchange was chosen over direct. One routing key pattern catches `notification.streak`, `notification.referral`, `notification.tournament` — no code change needed to add new notification types.

`match.finished` fans out to two queues simultaneously — the persistence worker and the analytics stub. RabbitMQ delivers an independent copy to each. Neither queue knows the other exists.

---

### Q: How does the answer processing DLQ work?

The scoring consumer uses QoS prefetch of 1 — it processes one answer at a time:

```
On malformed JSON:   msg.Ack(false)   → discard (no point retrying bad data)
On transient error:  retry 3× with 2s delay, then msg.Nack(false, false) → DLQ
On success:          msg.Ack(false)   → remove from queue
```

`Nack(false, false)` means: don't requeue to the original queue, let the dead-letter policy route it to `answer-processing-dlq`. From there, a human (or monitoring alert) can inspect why it failed — maybe a Redis connection was lost mid-flight, or a question ID was malformed.

The DLQ is declared durable with no consumers — it only accumulates. In production you'd have an alert when its depth exceeds a threshold.

---

## 4. Scoring Formula

### Q: How many points does a correct answer earn?

Points are calculated as:

```
score = base_points(difficulty) + speed_bonus
```

| Difficulty | Base Points |
|---|---|
| Easy | 100 |
| Medium | 125 |
| Hard | 150 |

Speed bonus:
```
speed_bonus = 50 × (1 - responseMs / 30000)
```

Maximum 50 bonus points if answered instantly, 0 bonus if answered at exactly the 30-second mark. Wrong answers score 0 (no penalty — avoids discouraging guessing).

**Example:** Correct answer on a Hard question in 3 seconds:
```
150 + 50 × (1 - 3000/30000) = 150 + 50 × 0.9 = 150 + 45 = 195 points
```

**Why linear decay instead of exponential?** Linear is simpler to understand for players ("every second costs me ~1.7 points") and produces a meaningful spread between fast and slow correct answers without punishing moderate-speed players too harshly.

**Why no penalty for wrong answers?** The game is designed to encourage participation. A penalty would cause players to stop answering when unsure, making the match feel unfair if one player happens to know more about the topic.

---

### Q: How is response time measured?

Response time is measured **server-side**, not client-side. This is intentional:

```go
// SubmitAnswer handler:
serverNowMs := time.Now().UnixMilli()
roundStartedAtMs, _ = redis.Int64(conn.Do("GET", startedAtKey))
responseMs = serverNowMs - roundStartedAtMs
```

Why server-side? Clients running on different emulators/devices have different clocks. An emulator's clock can be ahead or behind the server by hundreds of milliseconds. If we used `req.SubmittedAtMs` (the client's timestamp), a player with a fast clock would appear to answer faster than they actually did. The server clock is the single source of truth.

---

## 5. Leaderboard Atomicity — Lua Scripts

### Q: Why use a Lua script for leaderboard updates?

Without Lua, updating a leaderboard requires two separate Redis commands:

```
ZINCRBY leaderboard:{id} {points} {userId}  ← goroutine A
ZREVRANK leaderboard:{id} {userId}           ← goroutine A reads rank
```

Between these two commands, goroutine B could also run `ZINCRBY`, making goroutine A's `ZREVRANK` return a stale rank. This is a classic TOCTOU (time-of-check to time-of-use) race condition.

The Lua script runs atomically — Redis is single-threaded and executes the entire script before processing any other command:

```lua
local key    = KEYS[1]
local member = ARGV[1]
local points = tonumber(ARGV[2])

redis.call('ZINCRBY', key, points, member)
redis.call('EXPIRE',  key, 1800)
local rank = redis.call('ZREVRANK', key, member)
return rank
```

Three operations, zero interleaving. The returned rank is always the rank after this specific increment. Every player sees a consistent leaderboard.

**The alternative** — Redis transactions (`MULTI`/`EXEC`) — also prevents interleaving but doesn't support conditional logic. Lua scripts are the standard approach for atomic multi-step Redis operations.

---

### Q: Where else is atomicity enforced?

**Round completion dedup (SETNX guard):**
```go
closedKey := fmt.Sprintf("room:%s:round:%d:closed", roomID, roundNum)
n, _ := redis.Int(conn.Do("SETNX", closedKey, "1"))
conn.Do("EXPIRE", closedKey, 30*60)
if n == 0 {
    // Another goroutine already closed this round — abort
    return
}
```

When the round timer and "all players answered" fire at the same millisecond, two goroutines both exit the timer loop. The first to `SETNX` wins (returns 1) and proceeds to publish `round.completed`. The second sees `n == 0` and returns silently. Without this guard, `round.completed` would be published twice, triggering a duplicate round and double-scoring.

**Answer dedup (HSETNX):**
```go
// In SubmitAnswer:
setRes, _ := conn.Do("HSETNX", submittedKey, req.UserId, req.AnswerIndex)
// setRes == 0 means this userId already has an entry — duplicate submission
```

`HSETNX` (Hash Set if Not eXists) only writes if the field doesn't exist. If a player double-taps "Submit" or retries due to network lag, the second submission is a no-op. The scoring consumer performs the same check on the `answers` hash before updating the leaderboard.

---

## 6. Razorpay Webhook Security

### Q: How is the webhook verified?

Razorpay signs every webhook payload with HMAC-SHA256 using the webhook secret you set in their dashboard. The handler verifies this before processing:

```go
func (h *WebhookHandler) verifySignature(body []byte, signature string) bool {
    mac := hmac.New(sha256.New, []byte(h.cfg.RazorpayWebhookSecret))
    mac.Write(body)
    expected := hex.EncodeToString(mac.Sum(nil))
    return hmac.Equal([]byte(expected), []byte(signature))
}
```

Key details:
- The raw request body is hashed (not the parsed JSON) — JSON field order can change
- `hmac.Equal` uses constant-time comparison — prevents timing attacks where an attacker measures how long comparison takes to infer the expected hash byte by byte
- If verification fails: return `401 Unauthorized` immediately — no payment is processed

**Without this check**, anyone who knows your webhook URL could POST a fake `payment.captured` event and get a premium subscription for free.

---

### Q: How is webhook idempotency handled?

Razorpay can send the same webhook multiple times (retries on 5xx, network timeout, etc.). The handler prevents double-processing:

```go
// Check if this payment_id was already processed
var existing PaymentDoc
err := h.db.Collection("payments").FindOne(ctx, bson.M{
    "razorpay_payment_id": paymentID,
    "status": "captured",
}).Decode(&existing)

if err == nil {
    // Already processed — return 200 OK to stop Razorpay retrying
    w.WriteHeader(http.StatusOK)
    return
}
```

A unique index on `razorpay_payment_id` in the `payments` collection means even if the check-then-insert races, the second insert fails with a duplicate key error rather than creating two subscription records.

---

### Q: What happens after a successful payment?

```
Razorpay webhook → POST /webhook/razorpay
    ↓
verifySignature (HMAC-SHA256)
    ↓
Parse payment.captured event
    ↓
Idempotency check (already processed?)
    ↓
Insert payment document to MongoDB
    ↓
Upsert subscription: {userId, plan: "premium", status: "active", expires_at: +30 days}
    ↓
Publish payment.success to RabbitMQ
    ↓
Notification Worker sends "Payment successful" FCM push
    ↓
Redis: SET user:{userId}:plan "premium" EX 86400
        SET user:{userId}:daily_quota "unlimited" EX 86400
    ↓
Return 200 OK to Razorpay (stops retries)
```

The Redis keys are updated immediately so the next `JoinMatchmaking` call sees `plan=premium` without a MongoDB round-trip.

---

## 7. Daily Quota & Race Condition Prevention

### Q: How does the free quota (5 games/day) work?

Every user document in MongoDB has:
```json
{
  "daily_quiz_used": 3,
  "last_quiz_date": "2026-04-16",
  "bonus_games_remaining": 2
}
```

On every `JoinMatchmaking` call, the server runs `enforceQuotaAndIncrement`:

1. **Premium check first**: Query `subscriptions` collection for an active subscription expiring in the future. If found → allow, skip all quota checks.

2. **Daily counter reset**: If `last_quiz_date != today (UTC)`, treat `daily_quiz_used` as 0 — the day has rolled over.

3. **Decision tree**:
   ```
   freeExhausted = usedToday >= 5
   hasBonus      = bonus_games_remaining > 0
   
   if !freeExhausted  → consume free game ($inc daily_quiz_used, $set last_quiz_date=today)
   if freeExhausted && hasBonus → consume bonus ($inc bonus_games_remaining: -1)
   if freeExhausted && !hasBonus → return ResourceExhausted error (block)
   ```

**Why UTC?** The server stores `last_quiz_date` as a UTC date string (`"2026-04-16"`). The Flutter client also uses UTC (`DateTime.now().toUtc()`) for the same comparison. This prevents the mismatch where a player's local midnight resets the client counter but the server still blocks them until UTC midnight.

---

### Q: Is there a race condition where two concurrent joins both pass the quota check?

Yes, this is a real risk. Two `JoinMatchmaking` calls arriving simultaneously for the same user could both read `daily_quiz_used = 4`, both see `4 < 5`, and both proceed — effectively granting 6 games instead of 5.

**Mitigation used**: MongoDB's `UpdateOne` with `$inc` is an atomic server-side operation. We increment the counter without reading it first:

```go
usersColl.UpdateOne(ctx,
    bson.M{"_id": oid},
    bson.M{"$set": bson.M{
        "last_quiz_date":  today,
        "daily_quiz_used": usedToday + 1,
    }},
)
```

**The remaining gap**: The read (`FindOne`) and the write (`UpdateOne`) are separate operations — a race between these two for the exact same millisecond could allow 6 games. A production-hardened fix would use `FindOneAndUpdate` with a filter condition: `{"daily_quiz_used": {"$lt": 5}}` — this atomically reads, checks, and increments in one operation. For demo purposes the current implementation is acceptable.

---

### Q: How does the Flutter client track quota locally?

The client maintains a local counter in `SharedPreferences`:

```
${key}_dq_used    → int (matches used today)
${key}_dq_date    → String (YYYY-MM-DD UTC date of last count)
```

On every match start, `consumeDailyQuiz()` increments this counter and saves both fields. On app restart, `_loadLocalStats()` checks if `dq_date == today`; if not, resets `dq_used` to 0.

This local counter drives the UI progress bar ("3/5 matches"). The server is the authoritative gate — the client counter is only for display. A mismatch between client and server (e.g., user played on another device) is resolved when `GET /user/stats` syncs from MongoDB on login.

---

## 8. Referral Anti-Abuse

### Q: How are referral codes generated?

```go
const referralCodeChars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
// 31 characters — intentionally excludes 0/O, 1/I/L (visually ambiguous)
// 31^6 ≈ 887 million possible codes
```

6 characters chosen from 31 unambiguous characters gives 887 million codes — effectively no collisions for any realistic user base.

**Why `crypto/rand` instead of `math/rand`?** Math/rand is seeded from time — an attacker who knows approximately when a user registered could brute-force their code in a feasible time window. `crypto/rand` uses the OS entropy pool (hardware randomness) — computationally infeasible to predict.

---

### Q: What prevents someone from abusing the referral system?

Five independent checks, all server-side:

1. **One referral per user**: Each user's document has a `referred_by` field. If it's already set, reject any new referral code application. You can only ever be referred once.

2. **Account age limit (7 days)**: The referee's account must be `≤7 days old` at the time of applying the code. Prevents someone creating an old account, gaming the system by applying a code later.

3. **No self-referral**: `referrer.ID != referee.ID` — you cannot apply your own code.

4. **Referrer cap (10 referrals max)**: Each user's `referral_count` is checked before granting the referral. Prevents a single person from farming 1000 accounts to generate unlimited bonus games.

5. **Genuine new user check**: The code can only be applied within the first 7 days. Combined with the account-age check, this means someone cannot create a dummy account, wait, then apply to appear legitimate.

**Rewards are pending, not instant**: When a referral is applied, the coins and bonus games are added to `pending_referral_coins` and `pending_bonus`, not directly to `coins` and `bonus_games_remaining`. The referee must play their first match, at which point the referrer's pending rewards are released. This prevents the pattern: create fake account, apply code, collect rewards, never play.

---

## 9. Flutter State Management — Riverpod

### Q: Why Riverpod instead of BLoC or Provider?

Three reasons for this use case:

1. **Granular rebuilds**: Derived providers (`currentQuestionProvider`, `timerProvider`, `leaderboardProvider`) allow individual widgets to subscribe to only the slice of state they need. The timer widget rebuilds every second. The leaderboard rebuilds after each answer. The question card only rebuilds between rounds. With BLoC, you'd need multiple separate BLoCs or `BlocSelector` — more boilerplate.

2. **No BuildContext required**: `ref.read(gameProvider.notifier)` works anywhere — inside async callbacks, services, background timers. BLoC requires a `BuildContext` to `context.read<>()`. This matters for handling gRPC stream events that arrive outside the widget tree.

3. **Family providers for parameterized streams**: `matchmakingStreamProvider.family<MatchmakingUpdate, String>` creates one stream instance per userId. If the userId changes (re-login), `ref.invalidate(matchmakingStreamProvider(userId))` tears down only that stream, not all state.

---

### Q: How does the game state machine work?

`GameState` has a `phase` enum that drives what the UI renders:

```
idle
  │ (onMatchFound)
  ▼
matchmaking → starting
  │ (first QuestionBroadcast)
  ▼
inRound
  │ (RoundResult received)
  ▼
betweenRounds
  │ (next QuestionBroadcast)
  ▼
inRound
  │ ... (repeats for each round)
  │ (MatchEnd received)
  ▼
finished
```

`spectating` is a special state when a player's stream disconnects mid-match but then reconnects — they continue receiving events but cannot submit answers.

Phase transitions happen inside `GameNotifier._handleEvent()`:
- `QuestionBroadcastEvent` → set phase to `inRound`, clear previous answer, start countdown
- `RoundResultEvent` → set phase to `betweenRounds`, reveal correct answer
- `MatchEndEvent` → set phase to `finished`, store final scores for results screen
- `ReconnectingEvent` → set phase to `spectating`, show reconnect banner

---

### Q: How is the countdown timer handled?

The server broadcasts `TimerSync` every second with an absolute deadline:
```protobuf
message TimerSync {
  int32 round_number   = 1;
  int64 server_time_ms = 2;  // server's current epoch ms
  int64 deadline_ms    = 3;  // absolute epoch ms when round closes
}
```

The client computes remaining seconds from the absolute deadline:
```dart
int get remainingSeconds {
    final now = DateTime.now().millisecondsSinceEpoch;
    return ((deadlineMs - now) / 1000).ceil().clamp(0, 30);
}
```

**Why absolute deadline instead of "X seconds remaining"?** If we sent "28 seconds remaining" and the packet takes 200ms in transit, the client shows 28 when the true remaining is 27.8. Absolute deadlines mean each client independently computes the correct value from their own clock. Clock drift between server and client is typically <100ms on LAN/emulator.

The `AnimationController` in the UI is driven by this value — it's set (not animated) to the new remaining time on each `TimerSync`. The animation between ticks is smooth because `AnimationController` interpolates. The seconds display jumps (29→28→27) but the circular progress ring animates smoothly between those positions.

---

## 10. Edge Cases

### Q: A player disconnects mid-match. What happens?

**gRPC stream closure** is detected in the `defer` block of `StreamGameEvents`:
```go
defer room.removeSub(ch, req.UserId)
```

This removes the player's channel from the broadcast list. They stop receiving events. However, they are **not** removed from `room.active` — stream disconnect ≠ forfeit. A player backgrounding the app would disconnect but still want to rejoin.

If the player re-opens the app, `StreamGameEvents` is called again. The `gameRoom` still exists in the hub (until all players disconnect). The player is re-added to `room.subs` and receives the late-joiner catch-up: the current question (stored in `room.currentQuestion`) with the remaining deadline.

**If only 1 active player remains** (all others have explicitly forfeited via `SubmitAnswer` with `answerIndex = -1`), the game loop detects `room.activeCount() == 1` at the start of the next round and ends the match with that player as the winner. Disconnected players (not forfeited) still count as "active" — a brief disconnect doesn't hand victory to the opponent.

---

### Q: A player submits the same answer twice. What happens?

Two guards prevent double-scoring:

**Guard 1 — in SubmitAnswer (quiz-service):**
```go
setRes, _ := conn.Do("HSETNX", submittedKey, req.UserId, req.AnswerIndex)
// setRes == 0: field already exists — this is a duplicate
```
`HSETNX` is atomic. The second submission writes nothing and returns 0. The answer is still published to RabbitMQ (the quiz engine doesn't block on this), but the key exists.

**Guard 2 — in the scoring consumer (scoring-service):**
```go
exists, _ := redis.Int(conn.Do("HEXISTS", answersKey, event.UserID))
if exists == 1 {
    // Already scored — ACK and return
    msg.Ack(false)
    return nil
}
```
Before writing the score, the consumer checks if this userId already has an entry in `room:{id}:answers:{round}`. If yes, it ACKs the message (removes it from queue) without doing any scoring. No double points.

---

### Q: Razorpay sends the same webhook twice. What happens?

```go
// Check for existing captured payment
err := h.db.Collection("payments").FindOne(ctx, bson.M{
    "razorpay_payment_id": paymentID,
    "status": "captured",
}).Decode(&existing)

if err == nil {
    // Already processed
    w.WriteHeader(http.StatusOK)
    return
}
```

The second webhook is detected (payment document already exists), returns `200 OK` immediately, and exits. No second subscription is created, no extra coins awarded. Returning 200 (not 4xx) is intentional — telling Razorpay "success" stops it from retrying further.

A unique index on `razorpay_payment_id` provides a second layer: even if two webhook deliveries arrive at the exact same millisecond and both pass the FindOne check, only one `InsertOne` succeeds. The other gets a `duplicate key` error, which the handler logs and returns 200 for.

---

### Q: A free user tries to join when their quota is exhausted. What happens?

**Server-side** (matchmaking.go):
```go
if freeExhausted && !hasBonus {
    return status.Error(codes.ResourceExhausted,
        "Daily free limit reached. Upgrade to Premium for unlimited games.")
}
```
The gRPC call returns `ResourceExhausted` (code 8). The player is never added to the matchmaking pool.

**Client-side** (matchmaking_screen.dart):
```dart
} catch (e) {
    final msg = e.toString().contains('Daily free limit')
        ? 'Daily limit reached (5/5 games). Come back tomorrow or upgrade to Premium!'
        : 'Could not join matchmaking. Please try again.';
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Color(0xFFE74C3C)),
    );
    setState(() => _searching = false);
}
```

The search UI cancels and a red snackbar appears. The quota card on the lobby screen already shows `5/5` in red with "Limit reached — resets at 05:30" (the user's local time equivalent of midnight UTC), so the user understands the situation before even tapping Start.

**Why enforce server-side and not just hide the button client-side?** A motivated user could call the gRPC endpoint directly (via grpcurl) and bypass any client-side check. Server-side enforcement is non-negotiable.

---

### Q: A premium user's plan expires mid-day. When does gating kick in?

The subscription document has:
```json
{ "status": "active", "expires_at": "2026-05-12T17:17:01Z" }
```

The quota check queries:
```go
subsColl.CountDocuments(ctx, bson.M{
    "user_id":    userID,
    "status":     "active",
    "expires_at": bson.M{"$gt": time.Now()},
})
```

`time.Now()` is evaluated fresh on every `JoinMatchmaking` call. Once `expires_at` passes, this query returns 0 — the next join attempt goes through the free-tier quota check. No cron job needed; expiry is checked automatically on every matchmaking join.

The Redis cache key `user:{userId}:plan` has a 24h TTL set at login. If a plan expires during the day without a new login, the Redis key may still say "premium" for up to 24h. However, the authoritative MongoDB check is always performed — Redis is only for observability metrics, not for the actual gate decision. The gate reads MongoDB directly every time.

---

### Q: How does referral code validation fail gracefully?

```
Invalid code (not in DB) → 404 "Referral code not found"
Own code applied         → 400 "Cannot use your own referral code"
Account too old (>7d)    → 400 "Referral codes can only be applied within 7 days of registration"
Already referred         → 400 "You have already applied a referral code"
Referrer hit cap (10)    → 400 "This referral code is no longer accepting new referrals"
```

All checks return specific error messages. The Flutter client shows these verbatim in a red SnackBar on the Referral tab. No silent failures.

---

### Q: How is login streak handled when a day is missed?

The streak logic runs in `_updateLoginStreak()` in `auth_service.dart`:

```dart
// loginHistory is a list of UTC date strings: ["2026-04-14", "2026-04-15", "2026-04-16"]
final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
final yesterday = DateTime.now().toUtc().subtract(Duration(days: 1))
                    .toIso8601String().substring(0, 10);

if (loginHistory.contains(today)) {
    // Already logged in today — no streak change
} else if (loginHistory.contains(yesterday)) {
    // Consecutive login — increment streak
    currentStreak += 1;
} else {
    // Missed a day — reset
    currentStreak = 1;
}
```

**Why store full history instead of just the last date?** The 30-day calendar on the Profile screen renders which days the user logged in. A simple "last login date" would not support this visualization. The full history is pruned to the last 30 entries before saving.

**Timezone edge case:** All dates are UTC strings. A player in UTC+5:30 at 23:00 local time is already at 17:30 UTC the same day — both client and server agree on "2026-04-16". The critical fix was making the client use `.toUtc()` — without it, local midnight would reset the client streak at a different time than the server considers a new day.

---

### Q: Network drops during Razorpay checkout. What happens to the order?

When the user taps "Pay", the Flutter app calls `POST /payment/order` on the payment service, which creates a Razorpay order (status: `created`) and returns the `order_id`. The Flutter SDK opens the Razorpay checkout sheet with this order ID.

If the network drops during checkout:
- The Razorpay checkout sheet shows an error
- The order is left in `created` status in Razorpay's system and in our `payments` collection
- No subscription is granted (webhook hasn't fired)

On the next "Subscribe" attempt:
- A new order is created (`created` status orders in Razorpay expire after 5 minutes by default)
- The old order document stays in MongoDB with `status: "created"` — this is fine, it's just a record

The user is never double-charged because Razorpay only fires `payment.captured` once per successful payment. Abandoned orders generate no webhook and no charge.

---

## Summary Table

| Design Choice | What We Used | Why |
|---|---|---|
| Service architecture | 5 Go microservices | Independent scaling, failure isolation |
| Inter-service comms | RabbitMQ topic exchange | Decoupling, durability, fan-out |
| Client-server protocol | gRPC + protobuf | Streaming, type safety, performance |
| Matchmaking pool | Redis Sorted Set | O(log N) atomic ops, auto-TTL |
| Live leaderboard | Redis Sorted Set + Lua | Atomic increment+rank in one op |
| Room state | Redis Hash + List | Match-lifetime TTL, LPOP for round dedup |
| Quota cache | Redis String | Sub-ms gate check, 24h TTL auto-expire |
| Persistent data | MongoDB | Rich queries, ACID per-document, durable |
| Scoring formula | Base + linear speed bonus | Simple, understandable, encourages speed |
| Atomicity (rounds) | Redis SETNX | Distributed mutex, no library needed |
| Atomicity (answers) | Redis HSETNX | Idempotent field write |
| Webhook security | HMAC-SHA256 + constant-time compare | Prevents forgery + timing attacks |
| Webhook idempotency | Unique index on payment_id | Database-enforced, survives race |
| Referral codes | crypto/rand, 31-char alphabet | Unpredictable, unambiguous |
| Referral anti-abuse | 5 server-side checks | Cannot be bypassed client-side |
| Quota enforcement | MongoDB atomic $inc | Server-authoritative, race-resistant |
| Flutter state | Riverpod StateNotifier | Granular rebuilds, no BuildContext required |
| Timer sync | Absolute deadline (epoch ms) | No cumulative clock drift |
| Reconnection | Exponential backoff, 5 attempts | Handles transient drops without flooding |
| Question dedup | Fisher-Yates shuffle on fetched IDs | Avoids MongoDB $sample repeat bug |
| DLQ | RabbitMQ dead-letter after 3 retries | Recoverable errors don't block the queue |
