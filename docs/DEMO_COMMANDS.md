# Quiz Battle — Demo Commands Reference

A collection of commands to inspect live system state during a demo or evaluation.
All commands run against the local Docker environment.

---

## Table of Contents

1. [Docker — Service Health](#1-docker--service-health)
2. [RabbitMQ — Message Bus](#2-rabbitmq--message-bus)
3. [Redis — Real-time State](#3-redis--real-time-state)
4. [MongoDB — Persistent Data](#4-mongodb--persistent-data)
5. [Live Match Walkthrough](#5-live-match-walkthrough)

---

## 1. Docker — Service Health

### All services running
```bash
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
```
Shows every container (matchmaking, quiz-engine, scoring, payment, notification-worker, MongoDB, Redis, RabbitMQ) with its current status and exposed ports. `(healthy)` means the built-in healthcheck is passing.

**Expected output:**
```
NAME                       STATUS                PORTS
quiz_engine                Up 2 hours            0.0.0.0:50052->50052/tcp
quiz_matchmaking           Up About an hour      0.0.0.0:8080->8080/tcp, 0.0.0.0:50051->50051/tcp
quiz_mongodb               Up 2 days (healthy)   0.0.0.0:27017->27017/tcp
quiz_notification_worker   Up 2 hours
quiz_payment               Up 2 hours            0.0.0.0:8081->8081/tcp
quiz_rabbitmq              Up 2 days (healthy)   0.0.0.0:5672->5672/tcp, 0.0.0.0:15672->15672/tcp
quiz_redis                 Up 2 days (healthy)   0.0.0.0:6379->6379/tcp
quiz_scoring               Up 2 hours            0.0.0.0:50053->50053/tcp
```

### Resource usage (CPU + memory per container)
```bash
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
```
Proves microservices are lightweight. Go services typically sit under 15 MB RAM each. MongoDB and RabbitMQ are the heaviest consumers, which is expected.

### Logs for a specific service (live)
```bash
docker logs quiz_matchmaking --tail=50 --follow
```
Replace `quiz_matchmaking` with any container name. During a live match you'll see join/room-create/match-found events streaming in real time.

---

## 2. RabbitMQ — Message Bus

### Queues: names, consumer count, pending messages
```bash
docker exec quiz_rabbitmq rabbitmqctl list_queues name consumers messages
```
The most useful single command for showing the event-driven architecture is alive.

| Queue | Consumer | What it does |
|---|---|---|
| `quiz-match-created-queue` | 1 | Quiz-service picks up new room → selects questions |
| `answer-processing-queue` | 1 | Scoring-service processes submitted answers |
| `round-completed-queue` | 1 | Triggers next round or match-end logic |
| `match-finished-queue` | 1 | Persists final scores to MongoDB |
| `match-analytics-queue` | 1 | Archives match data for leaderboard |
| `payment-success-queue` | 0 | Razorpay webhook → credits user subscription |
| `notification-match-queue` | 1 | Fires FCM push when a match is found |
| `notification-worker-queue` | 1 | General FCM notification dispatcher |
| `answer-processing-dlq` | 0 | Dead-letter queue — catches failed answer events |

**`consumers=1` means a Go service is actively listening. `messages=0` means no backlog — everything is being processed in real time.**

### Exchange and routing keys
```bash
docker exec quiz_rabbitmq rabbitmqctl list_bindings source_name routing_key
```
Shows the `sx` (topic) exchange routing events to queues. Routing keys: `match.created`, `answer.submitted`, `round.completed`, `match.finished`, `payment.success`, `notification.*`

This demonstrates the pub/sub topology — services are decoupled and communicate only through events on the exchange.

### Exchanges (all types)
```bash
docker exec quiz_rabbitmq rabbitmqctl list_exchanges name type
```
The `sx` exchange is a **topic** exchange — supports wildcard routing (`notification.*` matches all notification subtypes).

### Messages in-flight during a live match
```bash
watch -n1 "docker exec quiz_rabbitmq rabbitmqctl list_queues name messages"
```
Run this while two players are in a match. You'll see `answer-processing-queue` briefly spike to 1–2 as answers come in, then drop back to 0 as scoring processes them. Good visual for real-time event throughput.

### RabbitMQ Web UI
Open [http://localhost:15672](http://localhost:15672) — username `guest`, password `guest`.
Graphical alternative to the CLI commands above with live message rate charts.

---

## 3. Redis — Real-time State

Redis holds all ephemeral match state: the matchmaking pool, room data, leaderboards, per-user quota, and referral codes.

### All keys currently in Redis
```bash
docker exec quiz_redis redis-cli KEYS "*"
```
Shows the full keyspace. During an active match you'll see `room:<id>`, `leaderboard:<id>`, and `questions:<id>` keys appear and disappear.

### Matchmaking pool (who is currently searching)
```bash
docker exec quiz_redis redis-cli ZRANGE matchmaking:pool 0 -1 WITHSCORES
```
A sorted set where each member is a user ID and the score is their rating. Players are matched by proximity of rating. Empty when no one is searching; populated the moment "Start Matchmaking" is tapped.

### Active room state (during a live match)
```bash
docker exec quiz_redis redis-cli HGETALL room:<room-id>
```
Replace `<room-id>` with the ID printed in matchmaking logs. Shows all room fields: players, status, current round, question list, timestamps.

### Live leaderboard for a match
```bash
docker exec quiz_redis redis-cli ZREVRANGE leaderboard:<room-id> 0 -1 WITHSCORES
```
A sorted set sorted by score descending. Updated after every answer is processed by the scoring service. The Flutter UI reads this in real time via gRPC streaming.

### User's daily quota (free games remaining)
```bash
docker exec quiz_redis redis-cli GET user:<user-id>:daily_quota
```
Mirrors what the server enforces. Returns a number (e.g. `3`) for free users or `unlimited` for premium. Updated every time a match starts. Expires automatically at midnight UTC.

### User's plan tier
```bash
docker exec quiz_redis redis-cli GET user:<user-id>:plan
```
Returns `free` or `premium`. Set on login and cached for 24 hours. The matchmaking quota gate reads this key as a fast-path check before hitting MongoDB.

### User's login streak (observability key)
```bash
docker exec quiz_redis redis-cli GET user:<user-id>:streak
```
Mirrors the current login streak cached in Redis for the notification-worker to use when sending "You're on a 3-day streak!" push notifications.

### All referral codes
```bash
docker exec quiz_redis redis-cli KEYS "referral:code:*"
```
Each `referral:code:<CODE>` key maps a 6-character code to the owner's user ID. Looked up in O(1) when someone redeems a code.

### Redis memory usage
```bash
docker exec quiz_redis redis-cli INFO memory | grep used_memory_human
```
Typically under 2 MB — proves Redis is not being used as a database, only as a cache/state store.

### Connected clients
```bash
docker exec quiz_redis redis-cli INFO clients | grep connected_clients
```
Shows how many Go services are holding persistent connections to Redis (typically 8 — one connection pool per service).

---

## 4. MongoDB — Persistent Data

### All collections
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "db.getCollectionNames()"
```
Lists all 8 collections: `users`, `questions`, `match_history`, `tournaments`, `subscriptions`, `referrals`, `device_tokens`, `payments`.

### Leaderboard — top players by rating
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.users.find(
  {matches_played: {\$gt: 0}},
  {username:1, rating:1, matches_played:1, matches_won:1, coins:1}
).sort({rating: -1}).limit(10).toArray()
"
```
The persistent global leaderboard. Rating is an Elo-style number that increases on wins and decreases on losses. The Flutter leaderboard screen queries this.

### All users with quota and streak info
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.users.find({}, {
  username:1, rating:1, coins:1,
  matches_played:1, matches_won:1,
  daily_quiz_used:1, bonus_games_remaining:1,
  current_streak:1, longest_streak:1
}).toArray()
"
```
Full user state snapshot. Good for showing the daily quota system (`daily_quiz_used` resets to 0 each UTC day) and streak tracking side by side.

### Active premium subscriptions
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.subscriptions.find(
  {status:'active', expires_at: {\$gt: new Date()}},
  {user_id:1, plan:1, expires_at:1}
).toArray()
"
```
Shows who has paid for premium. The matchmaking quota gate cross-checks this before allowing unlimited games.

### Recent match history
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.match_history.find(
  {},
  {room_id:1, winner_username:1, total_rounds:1, players:1}
).sort({_id:-1}).limit(5).toArray()
"
```
Persisted after every match ends via the `match-finished-queue` consumer. Includes per-player final score, rank, correct answers, and average response time.

### Referral statistics
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.referrals.aggregate([
  {\$group: {
    _id: null,
    total_referrals: {\$sum: 1},
    claimed: {\$sum: {\$cond: ['\$claimed', 1, 0]}},
    pending: {\$sum: {\$cond: ['\$claimed', 0, 1]}}
  }}
]).toArray()
"
```
Shows total referrals created vs claimed. Pending referrals are paid out when the referred user plays their first match.

### Questions in the bank (with difficulty breakdown)
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.questions.aggregate([
  {\$group: {_id: '\$difficulty', count: {\$sum: 1}}}
]).toArray()
"
```
Shows how many questions exist per difficulty level. The quiz-service draws from this pool, shuffles using Fisher-Yates, and tracks seen questions per user to avoid repetition within a match.

### Upcoming tournaments
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.tournaments.find(
  {status: 'upcoming'},
  {name:1, start_time:1, entry_fee:1, prize_pool:1, max_players:1}
).sort({start_time:1}).toArray()
"
```

### FCM device tokens (registered devices)
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.device_tokens.find({}, {user_id:1, platform:1, registered_at:1}).toArray()
"
```
Every device that has opened the app registers here. The notification-worker uses these tokens to send FCM push notifications for match invites, streak reminders, and daily reward alerts.

### Payment records
```bash
docker exec quiz_mongodb mongosh quizdb --quiet --eval "
db.payments.find({}, {user_id:1, amount:1, status:1, plan:1, created_at:1}).sort({_id:-1}).limit(5).toArray()
"
```
Razorpay webhook events land here. `status: verified` means the signature was validated and the subscription was activated.

---

## 5. Live Match Walkthrough

Run these in order while two players go through a full match to narrate the data flow:

```bash
# 1. Before match: pool is empty
docker exec quiz_redis redis-cli ZRANGE matchmaking:pool 0 -1 WITHSCORES

# 2. Player 1 taps "Start Matchmaking" — appears in pool
docker exec quiz_redis redis-cli ZRANGE matchmaking:pool 0 -1 WITHSCORES

# 3. Player 2 joins — pool has 2 players
docker exec quiz_redis redis-cli ZRANGE matchmaking:pool 0 -1 WITHSCORES

# 4. After lobbyWait (10s), room is created — pool empties, room key appears
docker exec quiz_redis redis-cli KEYS "room:*"
docker exec quiz_redis redis-cli HGETALL room:<room-id>

# 5. RabbitMQ: match.created event consumed, quiz-service selected questions
docker exec quiz_rabbitmq rabbitmqctl list_queues name messages

# 6. During match: watch leaderboard update after each answer
docker exec quiz_redis redis-cli ZREVRANGE leaderboard:<room-id> 0 -1 WITHSCORES

# 7. Match ends: check match_history was persisted
docker exec quiz_mongodb mongosh quizdb --quiet --eval \
  "db.match_history.find().sort({_id:-1}).limit(1).toArray()"

# 8. Check user stats updated (rating, coins, streak)
docker exec quiz_mongodb mongosh quizdb --quiet --eval \
  "db.users.find({username:'manas1'}, {rating:1, coins:1, matches_played:1, matches_won:1, current_streak:1}).toArray()"

# 9. Daily quota decremented
docker exec quiz_redis redis-cli GET user:<user-id>:daily_quota
```

---

## Quick Reference

| What you want to show | Command |
|---|---|
| All services running | `docker compose ps` |
| CPU/RAM per service | `docker stats --no-stream` |
| Event queues + consumers | `docker exec quiz_rabbitmq rabbitmqctl list_queues name consumers messages` |
| Who is searching for a match | `docker exec quiz_redis redis-cli ZRANGE matchmaking:pool 0 -1 WITHSCORES` |
| Live leaderboard in a room | `docker exec quiz_redis redis-cli ZREVRANGE leaderboard:<id> 0 -1 WITHSCORES` |
| User quota remaining | `docker exec quiz_redis redis-cli GET user:<id>:daily_quota` |
| Global player leaderboard | `mongosh quizdb --eval "db.users.find().sort({rating:-1}).limit(10)"` |
| Recent matches | `mongosh quizdb --eval "db.match_history.find().sort({_id:-1}).limit(3)"` |
| Premium subscribers | `mongosh quizdb --eval "db.subscriptions.find({status:'active'})"` |
| Registered push devices | `mongosh quizdb --eval "db.device_tokens.find()"` |
| RabbitMQ web dashboard | [http://localhost:15672](http://localhost:15672) (guest / guest) |
