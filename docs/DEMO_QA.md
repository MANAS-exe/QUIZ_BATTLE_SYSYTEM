# Demo Q&A — Prepared Answers

## Design Choices & Justifications

### Why 5 microservices instead of a monolith?

Each service has a distinct failure domain and scaling requirement:
- **Matchmaking** must stay available even during active games — if the game loop crashes, new matches can still start
- **Quiz Engine** holds long-lived gRPC streams (one per player) — isolating these prevents a slow consumer from blocking auth or matchmaking
- **Scoring** has the highest write frequency (every answer triggers Redis updates) — keeping it separate lets us scale it independently
- **Payment** uses HTTP (not gRPC) because Razorpay webhooks require HTTP endpoints — mixing protocols in one binary adds unnecessary complexity
- **Notification Worker** is fire-and-forget with no client API — it runs as a background consumer with zero impact on request latency

### Why Redis for matchmaking and room state?

- **Sub-millisecond latency**: matchmaking pool operations (ZADD, ZPOPMIN) complete in <1ms
- **Sorted sets**: players are ranked by rating in the pool — ZPOPMIN atomically removes the lowest-rated players for rating-based matching
- **Atomic operations**: Lua scripts execute ZINCRBY + ZREVRANK in a single round-trip — no race condition window
- **TTLs**: room keys auto-expire after 30 minutes — zombie rooms clean themselves up
- **Alternative considered**: PostgreSQL — too slow for real-time game state; would add 5-10ms per leaderboard update

### Why RabbitMQ over Kafka?

- **Message acknowledgement**: ACK/NACK with redelivery is critical for scoring — if a message fails, it retries instead of being lost
- **Dead Letter Queue**: after 3 failed attempts, messages go to `answer-processing-dlq` for manual investigation
- **Topic exchange**: wildcard routing (`notification.*`) lets us add new notification types without changing queue bindings
- **Fan-out**: `match.finished` is consumed by 3 different services independently — each gets its own copy
- **Operational simplicity**: RabbitMQ Management UI at :15672 is invaluable for debugging during development
- **Kafka trade-off**: Kafka is better for high-throughput event streaming (>100K msgs/sec) but overkill for a quiz game with <100 concurrent matches

### Scoring formula

```
Base: Easy=100, Medium=125, Hard=150 (0 if wrong)
Speed bonus: 50 * (1 - responseMs / 30000) — linear decay over 30 seconds
Max per round: Easy=150, Medium=175, Hard=200
```

**Why this works**: The speed bonus (max 50 points) is significant enough to reward fast answers but not so large that it dominates accuracy. A correct answer at 20 seconds still beats a wrong answer. The 10-round format (4 easy + 4 medium + 2 hard) gives a theoretical max of 1850 points — enough spread to differentiate players.

### Atomic leaderboard updates (Lua script)

```lua
redis.call('ZINCRBY', key, points, member)
redis.call('EXPIRE', key, 1800)
local rank = redis.call('ZREVRANK', key, member)
return rank
```

**Why Lua**: Without atomicity, two players answering simultaneously would trigger two separate ZINCRBY commands. Between ZINCRBY and ZREVRANK, the other player's score might change, returning a stale rank. The Lua script executes all three operations in a single Redis server round-trip — zero race condition window.

### Razorpay webhook verification

```
HMAC-SHA256(webhook_secret, raw_request_body) == X-Razorpay-Signature header
```

**Why it's secure**: The webhook secret is known only to our server and Razorpay. An attacker cannot forge a valid signature without the secret. We verify BEFORE processing any data — if the signature doesn't match, we return 401 immediately. Idempotency is handled separately by checking if the `payment_id` already exists in the `captured` state.

### Daily quota — preventing race conditions

The quota check happens **server-side** in `enforceQuotaAndIncrement()` during `JoinMatchmaking`:
1. Check MongoDB `subscriptions` for active premium → bypass if premium
2. Read `daily_quiz_used` + `last_quiz_date` from MongoDB `users`
3. If `used >= 5`, return `ResourceExhausted`
4. Increment atomically with `$set`

**Why not Redis**: The quota must survive server restarts and be consistent across multiple matchmaking service instances. MongoDB provides durability. Redis is used only for caching (`user:{id}:daily_quota`) for CLI demo visibility.

### Referral anti-abuse strategy

5 server-side checks:
1. `referred_by` must be empty → can't apply twice
2. Account must be ≤7 days old → prevents dormant account abuse
3. Can't apply own code → self-referral check
4. Referrer count < 10 → limits coordinated farming
5. Code format: exactly 6 alphanumeric chars → fast-fail before DB lookup

**Why these are sufficient**: Even with the worst-case abuse (10 fake accounts per referrer), the payoff is 2000 coins — low relative to the effort of creating 10 verified accounts.

### State management in Flutter (Riverpod)

**Why Riverpod over BLoC**:
- Less boilerplate — no separate Event/State classes
- `StateNotifier` + `copyWith` pattern is cleaner for our 25-field `AuthState`
- Family providers for parameterized streams (`matchmakingStreamProvider(userId)`)
- `ref.listen` for side effects (navigation on phase change)
- `ref.invalidate` for stream reset on "Play Again"

---

## Edge Cases

### User disconnects mid-match
- gRPC stream closure detected in `StreamGameEvents` defer block
- Player removed from `connected` map but kept in `active` (disconnect ≠ forfeit)
- `ReconnectService` in Flutter retries with exponential backoff (1s→16s, 5 retries)
- If all players disconnect, game loop exits and room keys auto-expire via TTL

### Double answer submission
- `HSETNX room:{id}:submitted:{round} {userId}` — second write returns 0 (already exists)
- Scoring consumer: `HEXISTS room:{id}:answers:{round} {userId}` — skips if already scored
- Two independent idempotency guards prevent double-scoring

### Razorpay webhook arrives twice
- `handlePaymentCaptured` checks: `FindOne({razorpay_payment_id, status: "captured"})` — if found, returns 200 immediately
- The webhook handler returns 200 even for duplicate/unknown events so Razorpay doesn't keep retrying

### Free user at daily limit hits Play
- `enforceQuotaAndIncrement()` returns `codes.ResourceExhausted` before adding to pool
- Flutter should show error — currently fails silently (known limitation)

### Premium expires mid-day
- `isEffectivelyPremium` is a computed getter checked in real-time on every widget build
- No logout needed — the moment `premiumTrialExpiresAt` passes `DateTime.now()`, the getter returns false

### Referral: own code
- Server checks: if code owner's userId == requesting userId → 400 "you cannot use your own referral code"

### Login streak after missing a day
- `_updateLoginStreak()` computes streak from `loginHistory` by walking backwards from today
- If yesterday is not in the history, streak resets to 1
- History stores last 30 ISO dates — survives reinstall via MongoDB sync

### Late joiner mid-match
- Game loop's `room.broadcast()` delivers all events to all subscribers
- Subscriber channel is buffered (40 events per round × totalRounds + 50)
- On reconnect, `ReconnectService` re-subscribes to `StreamGameEvents` and receives events from that point forward

### Network drop during Razorpay checkout
- Order stays in "created" state in MongoDB
- User can retry — `create-order` creates a new Razorpay order
- Old uncaptured orders expire automatically (Razorpay handles this)

### Tie in scoring
- If two players answer within 100ms of each other, it's declared a tie
- The answer reveal card shows "Tie!" with handshake icon instead of a fastest player
- For match winner determination, if final scores are equal, Redis ZREVRANGE breaks ties by lexicographic userID order (documented limitation)

---

## Common Questions

### How does FCM work without collecting phone numbers?
FCM uses a **device token** (random string generated by Firebase SDK on the device), not a phone number. The token identifies the app installation on a specific device. When the user logs in, the Flutter app sends this token to `POST /device/token`. The notification worker uses the token to send push notifications via Firebase Admin SDK.

### Is the leaderboard real-time?
Yes. After every answer, the scoring consumer atomically updates the Redis sorted set. The quiz-service broadcasts a `LeaderboardUpdate` event to all connected streams. The Flutter client receives it and re-renders the podium with animations. Updates arrive within 2 seconds of answering.

### Can this handle 1000 concurrent players?
The current architecture supports it with minor adjustments:
- Each room is isolated (separate Redis keys, separate game loop goroutine)
- Redis handles ~100K operations/sec — sufficient for 500 concurrent rooms
- RabbitMQ handles ~50K msgs/sec — scoring consumer would need horizontal scaling
- The main bottleneck would be gRPC stream connections on the quiz-service — solved by running multiple instances behind a load balancer

### Why MongoDB instead of PostgreSQL?
- Flexible schema: user documents evolve (referral fields, streak data, premium fields added over time)
- `$sample` for random question selection (though we replaced this with Fisher-Yates shuffle)
- Document model matches our JSON-heavy payloads (match history, player arrays)
- Trade-off: no joins — we denormalize (username stored in match_history alongside userId)
