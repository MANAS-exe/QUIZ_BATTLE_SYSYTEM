# Quiz Battle — API Reference

## gRPC RPCs

All gRPC RPCs use Protobuf. Proto file: `proto/quiz.proto`

### AuthService (port :50051)

| RPC | Auth | Request | Response | Description |
|-----|------|---------|----------|-------------|
| `Register` | No | `username`, `password` | `success`, `token`, `userId`, `username`, `rating` | Register with email/password |
| `Login` | No | `username`, `password` | `success`, `token`, `userId`, `username`, `rating` | Login with email/password |

### MatchmakingService (port :50051)

| RPC | Auth | Request | Response | Description |
|-----|------|---------|----------|-------------|
| `JoinMatchmaking` | JWT | `userId`, `username`, `rating` | `success`, `message`, `queuePosition` | Join matchmaking pool (server-side quota check) |
| `LeaveMatchmaking` | JWT | `userId` | `success`, `message` | Leave matchmaking pool |
| `SubscribeToMatch` | JWT | `userId` | stream of `MatchEvent` | Server-streaming: WaitingUpdate + MatchFound events |

### QuizService (port :50052)

| RPC | Auth | Request | Response | Description |
|-----|------|---------|----------|-------------|
| `GetRoomQuestions` | JWT | `roomId` | `questions[]` | Get all questions for a room |
| `SubmitAnswer` | JWT | `roomId`, `userId`, `roundNumber`, `questionId`, `answerIndex`, `submittedAtMs` | `received`, `message` | Submit answer (idempotent via HSETNX) |
| `StreamGameEvents` | JWT | `roomId`, `userId` | stream of `GameEvent` | Server-streaming: Question, TimerSync, RoundResult, LeaderboardUpdate, MatchEnd, PlayerJoined |

### ScoringService (port :50053)

| RPC | Auth | Request | Response | Description |
|-----|------|---------|----------|-------------|
| `CalculateScore` | JWT | `roomId`, `userId` | `totalScore`, `newRank` | Get current score + rank for a player |
| `GetLeaderboard` | JWT | `roomId` | `roomId`, `roundNumber`, `scores[]` | Get sorted leaderboard (capped to top 3 for free users) |

---

## HTTP Endpoints

### Matchmaking Service (port :8080)

| Method | Path | Auth | Request | Response | Description |
|--------|------|------|---------|----------|-------------|
| `POST` | `/auth/google` | No | `{ "id_token": "..." }` | `{ success, token, user_id, username, email, picture_url, rating, is_new_user }` | Google Sign-In |
| `GET` | `/referral/code` | JWT | — | `{ success, code, referral_count, pending_coins, pending_bonus, total_coins_earned, already_referred }` | Get/generate referral code |
| `POST` | `/referral/apply` | JWT | `{ "code": "QB4X9K" }` | `{ success, reward_coins, reward_bonus, message }` | Apply a friend's code |
| `GET` | `/referral/claim` | JWT | — | `{ success, reward_coins, reward_bonus, message }` | Claim pending referral rewards |
| `GET` | `/referral/history` | JWT | — | `{ success, count, history[] }` | List referrals made by user |
| `POST` | `/device/token` | JWT | `{ "token": "fcm...", "platform": "android" }` | `{ success }` | Register FCM device token |
| `GET` | `/user/stats` | JWT | — | `{ rating, matches_played, matches_won, coins, current_streak, longest_streak, ... }` | Get all persistent user stats |
| `POST` | `/user/stats` | JWT | `{ matches_played, matches_won, coins, ... }` | `{ success }` | Push local stats to MongoDB ($max for counters) |
| `GET` | `/leaderboard` | No | — | `{ players[] }` | Global leaderboard |

### Payment Service (port :8081)

| Method | Path | Auth | Request | Response | Description |
|--------|------|------|---------|----------|-------------|
| `POST` | `/payment/create-order` | JWT | `{ "plan": "monthly", "coupon_code": "QB4X9K" }` | `{ order_id, amount, currency, key_id }` | Create Razorpay order |
| `POST` | `/payment/verify` | JWT | `{ payment_id, order_id, signature }` | `{ success }` | Verify HMAC-SHA256 signature |
| `GET` | `/payment/status` | JWT | — | `{ plan, is_active, expires_at }` | Get current subscription status |
| `GET` | `/payment/history` | JWT | — | `{ payments[] }` | List past payments |
| `GET` | `/payment/validate-coupon?code=X` | JWT | — | `{ valid, message }` | Validate referral code as coupon |
| `POST` | `/payment/webhook` | Razorpay sig | Razorpay webhook payload | `{ success }` | Handle payment.captured / payment.failed |

---

## RabbitMQ Events

Exchange: `sx` (topic, durable)

| Routing Key | Producer | Consumer(s) | Payload |
|-------------|----------|-------------|---------|
| `match.created` | Matchmaking | Quiz Engine | `{ room_id, players: [{user_id, username, rating}], total_rounds }` |
| `answer.submitted` | Quiz Engine | Scoring | `{ room_id, user_id, round_number, question_id, answer_index, submitted_at_ms, round_started_at_ms }` |
| `round.completed` | Quiz Engine | (logged) | `{ room_id, round_number, question_id, correct_index, round_started_at_ms }` |
| `match.finished` | Quiz Engine | Scoring + Notification Worker | `{ room_id, total_rounds }` |
| `notification.*` | Cron / events | Notification Worker | `{ type, title, body, user_ids? }` |
| `payment.success` | Payment | — | `{ order_id, payment_id, user_id, plan, amount, captured_at }` |

### Queues

| Queue | Routing Key | Consumer |
|-------|-------------|----------|
| `quiz-match-created-queue` | `match.created` | Quiz Engine |
| `answer-processing-queue` | `answer.submitted` | Scoring Worker |
| `answer-processing-dlq` | Dead letter | — |
| `round-completed-queue` | `round.completed` | Quiz Engine (logging) |
| `match-finished-queue` | `match.finished` | Scoring (persistence) |
| `match-analytics-queue` | `match.finished` | Analytics (stdout) |
| `notification-worker-queue` | `notification.*` | Notification Worker |
| `notification-match-queue` | `match.finished` | Notification Worker (referral) |
| `payment-success-queue` | `payment.success` | — |
