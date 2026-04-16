# Quiz Battle — Bugs, Root Causes & Fixes

A full record of every significant problem encountered during development, the root cause, and the fix applied.

---

## 1. 30-Second Delay on Last Round (Final Bug)

**Symptom:** When one player forfeited mid-match, the remaining players' answers for the last round were never received by the server. The round timer ran the full 30 seconds before ending.

**Root Cause:** `StreamGameEvents` in `quiz-service/handlers/quiz_handler.go` checked `LLEN room:{id}:questions` on every new connection. After all 10 questions had been popped from Redis by `RunRound`, this key returned 0, causing the handler to return `FAILED_PRECONDITION: room has no questions` and kill the Flutter client's gRPC stream. With no stream, the client could not call `SubmitAnswer`, so the server's early-exit logic never fired.

**Fix (`quiz-service/handlers/quiz_handler.go`):** Added a check: if the room already exists in the broadcast hub (game is already running), skip the question-count validation and just subscribe to the existing room. Only new rooms (first connection) need to validate question count.

---

## 2. Score / Leaderboard Empty After 3-Service Split

**Symptom:** After splitting into 3 microservices, all players showed 0 points on the leaderboard throughout the match.

**Root Cause:** `SubmitAnswer` in the quiz service wrote to `room:{id}:answers:{round}` using `HSETNX`. The scoring consumer used `HSETNX` on the same key as an idempotency check. When the quiz handler pre-wrote the key, the consumer's `HSETNX` returned 0 (already exists) and skipped scoring entirely.

**Fix:** Separated the two concerns into distinct Redis keys:
- `room:{id}:submitted:{round}` — written instantly by `SubmitAnswer` (used for early-exit detection)
- `room:{id}:answers:{round}` — written by the scoring consumer (idempotency guard)

The timer loop checks both keys and advances when the higher count matches the active player count.

---

## 3. Spectating Player Stuck on Spectating Screen

**Symptom:** A player who forfeited would stay on the "Match in Progress" screen forever and never reach the results screen.

**Root Cause 1:** The `onError` handler in `game_provider.dart` unconditionally set `phase: MatchPhase.idle`, which navigated back to matchmaking instead of results. When the gRPC stream died (match ended), the spectating player lost their state.

**Root Cause 2:** `game_provider.dart` was not processing `RoundResultEvent` while in the spectating phase. When `roundNumber >= totalRounds`, the match is over, but no navigation was triggered.

**Fix:**
- In `onError`: if `phase == spectating` and leaderboard is non-empty, call `_buildSyntheticMatchEnd()` instead of going idle.
- In `_handleEvent` spectating branch: handle `RoundResultEvent` — update `currentRound` and `leaderboard`, and trigger `_buildSyntheticMatchEnd()` when `roundNumber >= totalRounds`.
- `spectating_screen.dart`: added `ref.listen(matchPhaseProvider, ...)` to navigate to results as soon as phase becomes `finished`.

---

## 4. Match Duration Showing 0s on Results Screen

**Symptom:** The match summary chip always showed "0s" for match duration.

**Root Cause:** The `DurationSeconds` field was never set in the `buildMatchEndEvent` function. The variable `matchStartedAt` was not being tracked in the game loop.

**Fix (quiz service):** Store `matchStartedAt = time.Now()` at the start of `RunMatch`, then compute `time.Since(matchStartedAt).Seconds()` when building the `MatchEndEvent`.

**Fix (Flutter client):** Track `_matchStartedAt` in `GameNotifier` (set on first `QuestionBroadcastEvent`). Used in `_buildSyntheticMatchEnd()` to compute duration for forfeiting players.

---

## 5. Questions Exhausted — Match Ends After 7 Rounds

**Symptom:** Match ended automatically after 7–8 rounds because `LPOP` returned nil (no more questions in Redis).

**Root Cause:** The `match_history` collection in MongoDB accumulated previously-seen question IDs across all past matches. `SelectForRoom` excluded all seen questions, but with a limited question pool, there weren't enough unseen questions to fill 10 rounds.

**Fix 1 (demo mode):** `clearMatchHistory` deletes old `match_history` entries for the same players before each new match, effectively giving a fresh pool every game.

**Fix 2 (fallback):** If `$sample` returns fewer than `count` questions after exclusion, fall back to sampling from the full pool — but still exclude questions already selected in this batch to avoid intra-match duplicates.

---

## 6. Questions Repeating Within a Single Match

**Symptom:** The same question appeared more than once in the same match.

**Root Cause:** The fallback in `selection.go` called `sampleQuestions(ctx, db, "", remaining, nil)` with `nil` as the exclusion list. MongoDB's `$sample` stage could return question IDs that were already selected earlier in the same `SelectForRoom` call.

**Fix (`quiz-service/questions/selection.go`):** Pass the already-selected `questionIDs` slice as the exclusion list when calling the fallback: `sampleQuestions(ctx, db, "", remaining, questionIDs)`.

---

## 7. Matchmaking Race Condition

**Symptom:** Occasionally, 3+ players would end up in the same room, or a player would be matched against themselves (ghost match), especially with fast successive join requests.

**Root Cause:** Multiple matchmaking goroutines ran `ZPOPMIN` on the matchmaking pool concurrently. Two goroutines could both pop the same set of players and both attempt to create a room.

**Fix (`matchmaking-service/handlers/matchmaking.go`):** Wrap the `ZPOPMIN + room creation` section in a global Redis distributed lock (`matchmaking_create`) so only one goroutine executes the pairing logic at a time.

---

## 8. Distributed Lock Blind Delete (Security)

**Symptom:** A slow `tryCreateRoom` goroutine could delete another goroutine's lock after its own TTL expired — causing two rooms to be created simultaneously.

**Root Cause:** `ReleaseLock` used a plain `DEL` command without verifying lock ownership.

**Fix (`matchmaking-service/redis/lock.go`):** Generate a UUID owner token on `AcquireLock`, store it as the lock value, and use a Lua `compare-and-delete` script in `ReleaseLock` to atomically verify ownership before deletion.

---

## 9. Auth Context Not Enforced

**Symptom:** Any client could submit answers or join rooms on behalf of another user by forging the `userId` field in the request protobuf.

**Root Cause:** Handlers read `req.UserId` from the request payload instead of the verified JWT context.

**Fix (all handlers):** Replace all `req.UserId` reads with `middleware.UserIDFromContext(ctx)`, which reads the user ID embedded in the verified JWT by the gRPC interceptor.

---

## 10. User Profile Stats Not Persisting

**Symptom:** After a match, player stats (matches played, wins, rating) were not saved if the user navigated away without pressing "Play Again". On next app launch, stats reset to defaults.

**Root Cause 1:** `recordMatchResult` was only called inside the "Play Again" `onPressed` callback. If the user closed the app or went back, the call was never made.

**Root Cause 2:** `_saveLocalStats` did not persist the `rating` field to `SharedPreferences`, so accumulated XP was lost on restart.

**Fix:**
- Converted `ResultsScreen` from `ConsumerWidget` to `ConsumerStatefulWidget`. Added a `_statsSaved` flag that triggers `recordMatchResult` via `addPostFrameCallback` as soon as `matchEnd != null` — regardless of which button the user presses.
- Added `rating` to `_saveLocalStats` / `_loadLocalStats`. On load, use the higher of the server rating (from login) and the locally-saved rating.

---

## 11. Auth Init Called Multiple Times in build()

**Symptom:** `_client` was assigned multiple times in `AuthNotifier.init()` because `build()` called `init()` on every rebuild.

**Root Cause:** No guard around the initialization block.

**Fix (`auth_service.dart`):** Added `bool _initialized = false` flag; `init()` returns early if already called.

---

## 12. Timer Hardcoded to 30s on Client

**Symptom:** If the server-side round duration were ever changed, the client countdown would be wrong — and for spectating players, time remaining could go negative.

**Root Cause:** `quiz_screen.dart` had `const totalSecs = 30.0` hardcoded instead of reading from the question broadcast.

**Fix:** Use `question.timeLimitMs / 1000` from the `QuestionBroadcastEvent` to initialize the client-side countdown. Server `TimerSyncEvent` events then correct any drift.

---

## 13. Leaderboard Keys Had No TTL

**Symptom:** Redis memory usage grew unboundedly — leaderboard keys for finished matches were never cleaned up.

**Root Cause:** The Lua script in `redis/leaderboard.go` incremented the sorted set but did not call `EXPIRE`.

**Fix:** Added `redis.call('EXPIRE', leaderKey, 1800)` to the Lua script so leaderboard keys expire 30 minutes after last write.

---

## 14. Missing MongoDB Indexes

**Symptom:** Slow matchmaking lookups and query scans on collections with many documents.

**Root Cause:** No indexes on `username` (unique check during registration), `questions.difficulty` (used in `$match` stage), or `match_history.players.userId` (used in `fetchSeenQuestionIDs`).

**Fix (`mongo-init/init.js`):** Added:
- `{ username: 1 }` unique index on `users`
- `{ difficulty: 1 }` index on `questions`
- `{ "players.userId": 1 }` index on `match_history`

---

## 15. Duplicate `redis/client.go` File

**Symptom:** Build error — `AddToPool` and `GetMatchablePlayers` functions defined in `redis/client.go` were dead code duplicating logic already in `redis/pool.go`.

**Fix:** Deleted `redis/client.go`; all call sites already used the pool directly.

---

## 16. Daily Quota Not Decrementing After Game

**Symptom:** The home screen showed "5 remaining" even after a player finished a game.

**Root Cause:** `consumeDailyQuiz()` was defined in `AuthNotifier` but never called anywhere. There was a comment in `home_screen.dart` saying it would be called "later", but the call site was never added.

**Fix (`matchmaking_screen.dart → _onMatchFound`):** Added `ref.read(authProvider.notifier).consumeDailyQuiz()` immediately when a match is confirmed. This fires before navigation to the quiz screen, updating `dailyQuizUsed` in both Riverpod state and SharedPreferences so the home screen reflects the correct count on return.

---

## 17. Questions Repeating Within a Single Match (Detailed Fix)

**Symptom:** The same question appeared in the same match multiple times.

**Root Cause (double):**
1. MongoDB `$sample` is documented to re-visit documents when the requested size exceeds ~5% of the collection (random in-memory scan). With 30 questions and 10 per match, this was frequently triggered.
2. Each difficulty bucket (`easy`, `medium`, `hard`) called `sampleQuestions` independently. The second and third buckets did not exclude IDs already selected by earlier buckets — so a question could be picked by both the easy bucket and the fallback pass.

**Fix (`quiz-service/questions/selection.go`):**
- Replaced `$sample` pipeline with `Find(_id projection) + Go Fisher-Yates shuffle` — fetches all eligible IDs into memory, shuffles with `math/rand/v2` (cryptographically seeded), returns first `n`. Guarantees strict uniqueness regardless of collection size.
- Each bucket now passes `append(seenIDs, questionIDs...)` as exclusions so already-selected IDs from earlier buckets are excluded.
- Fallback fill also passes the full selected list as exclusions.

---

## 18. Premium Status Not Reflected on New Device Login

**Symptom:** A player with an active premium subscription logged in on a different device and saw the free plan UI (quota bar, upsell card).

**Root Cause:** Premium flag was stored only in local SharedPreferences and never verified against the server on login. A fresh device had no local data so `isPremium` defaulted to `false`.

**Fix (`auth_service.dart → _syncPremiumFromServer`):** After every login/register/Google sign-in, the client calls `GET /payment/status` with the JWT and syncs the `is_active` field from the server into local SharedPreferences and Riverpod state. A 5-second timeout prevents blocking the login flow if the payment service is unreachable.

---

## 19. Razorpay Activity Resume Race Condition (Flutter)

**Symptom:** After a payment failure or cancellation on Android, the app crashed or showed a black screen. Sometimes the entire emulator process exited.

**Root Cause:** Razorpay SDK callbacks (`onPaymentError`, `onPaymentSuccess`, `onExternalWallet`) fire during Android Activity's `onResume`. Flutter's widget tree is not yet fully restored at this point, so calling `setState`, `showDialog`, or `ScaffoldMessenger.of(context)` synchronously inside these callbacks caused `_CastError` / `setState called during build`.

**Fix (`premium_screen.dart`):** Wrapped all three Razorpay callback bodies in `Future.delayed(Duration.zero, () { ... })` so the UI calls are deferred to the next event loop tick, after the Activity resume sequence completes.

---

## 20. Docker Build Failure — payment-service Go Version Mismatch

**Symptom:** `docker compose build payment-service` failed: `golang.org/x/sync v0.20.0 requires go >= 1.25.0`.

**Root Cause:** `payment-service/Dockerfile` used `golang:1.21-alpine` but `go.mod` declared `go 1.25.0` (required by a transitive dependency upgrade).

**Fix:** Changed `FROM golang:1.21-alpine` → `FROM golang:1.25-alpine` in `payment-service/Dockerfile` to match all other service Dockerfiles.

---

## 21. Android Manifest Merge Conflict (Razorpay CheckoutActivity)

**Symptom:** Flutter build failed: `Attribute application@android:exported value=(false) from AndroidManifest.xml conflicts with com.razorpay:checkout`.

**Root Cause:** Razorpay SDK's `AndroidManifest.xml` declares `CheckoutActivity` with `android:exported="true"` and a specific theme. The app's manifest had conflicting values.

**Fix (`flutter-app/android/app/src/main/AndroidManifest.xml`):** Added `xmlns:tools` namespace and `tools:replace="android:exported,android:theme"` on the `CheckoutActivity` entry, with `android:theme="@style/CheckoutTheme"` (the SDK's built-in theme name).

---

## 22. Profile Picture Not Persisting Across Screens

**Symptom:** Google profile picture showed on the Home screen but not on the Profile screen or the Matchmaking lobby. Other screens displayed a plain text initial letter even when a `pictureUrl` was set.

**Root Cause:** Only `home_screen.dart` had the `_Avatar` widget with `CachedNetworkImage`. The Profile screen's `_ProfileHeader` and the matchmaking lobby both hardcoded `Text(initial)` in `CircleAvatar`, ignoring `auth.pictureUrl` entirely.

**Fix:**
- `profile_screen.dart → _ProfileHeader`: Added `_buildAvatar(pictureUrl, initial)` and `_initialCircle(initial)` methods using `CachedNetworkImage`, matching the home screen pattern.
- `matchmaking_screen.dart → _buildLobby()`: Added `_buildLobbyAvatar(pictureUrl, initial)` replacing the hardcoded `Text(initial)`.

---

## 23. Login Streak Incrementing on Match Completion Instead of Login

**Symptom:** The streak counter only increased after finishing a match, not on simply opening the app. A player who logged in but didn't play would not have their streak counted.

**Root Cause:** `_updateDailyStreak()` was called inside `recordMatchResult()`, meaning a match had to be played to trigger a streak update.

**Fix (`auth_service.dart`):**
- Moved `_updateDailyStreak()` → renamed to `_updateLoginStreak()` and called from `_loadLocalStats()`, which runs after every successful login (email/password, Google, or session restore).
- Replaced `_lastPlayed` SharedPreferences key with a `loginHistory` JSON array (last 30 ISO dates).
- Streak computed from history via `_computeStreakFromHistory()` — walks backwards from today counting consecutive days. More robust against clock drift and app reinstalls.
- `recordMatchResult()` no longer touches streak at all.

---

## 24. `isQuotaExhausted` Ignoring Bonus Games

**Symptom:** If a player had bonus games remaining, the Play button still showed "Upgrade to Play More" and reported quota as exhausted.

**Root Cause:** `isQuotaExhausted` only checked `dailyQuizUsed >= kFreeQuotaPerDay` without considering `bonusGamesRemaining`. Similarly, `dailyQuizRemaining` did not add bonus games to the total.

**Fix (`auth_service.dart`):**
```dart
bool get isQuotaExhausted =>
    !isEffectivelyPremium &&
    dailyQuizUsed >= kFreeQuotaPerDay &&
    bonusGamesRemaining == 0;

int get dailyQuizRemaining {
  if (isEffectivelyPremium) return kPremiumQuota;
  final freeLeft = (kFreeQuotaPerDay - dailyQuizUsed).clamp(0, kFreeQuotaPerDay);
  return freeLeft + bonusGamesRemaining;
}
```

`consumeDailyQuiz()` now drains bonus games before incrementing `dailyQuizUsed`.

---

## 25. Premium Trial Not Reflected Without Logout

**Symptom:** When a user claimed a day-30 streak reward granting a 7-day premium trial, the upsell card and quota restrictions did not update until the next app restart.

**Root Cause:** The upsell card and quota checks used `auth.isPremium` (paid flag) directly. `premiumTrialExpiresAt` was stored in state but nothing read it.

**Fix:** Introduced `isEffectivelyPremium` getter:
```dart
bool get isEffectivelyPremium {
  if (isPremium) return true;
  if (premiumTrialExpiresAt == null) return false;
  return DateTime.tryParse(premiumTrialExpiresAt!)?.isAfter(DateTime.now()) ?? false;
}
```
All quota checks, upsell card visibility, leaderboard limits, and the quota card variant now use `isEffectivelyPremium`. Since it's a computed getter on `AuthState`, it reflects reality on every widget rebuild without requiring a logout.

---

## 26. `copyWith` Could Not Clear `premiumTrialExpiresAt` to Null

**Symptom:** After a premium trial expired, calling `state.copyWith(premiumTrialExpiresAt: null)` had no effect — the old expiry date was preserved.

**Root Cause:** Standard `copyWith` pattern uses `field ?? this.field`, which treats an explicit `null` argument the same as "don't change". There was no way to distinguish "set to null" from "leave unchanged".

**Fix:** Sentinel object pattern:
```dart
static const _unset = Object();

AuthState copyWith({
  Object? premiumTrialExpiresAt = _unset,
  ...
}) => AuthState(
  premiumTrialExpiresAt: premiumTrialExpiresAt == _unset
      ? this.premiumTrialExpiresAt
      : premiumTrialExpiresAt as String?,
  ...
);
```
Callers omitting the parameter get the existing value (sentinel path). Callers passing `null` explicitly clear it. Tests cover both cases.

---

## 27. Daily Reward Popup Appearing Multiple Times Per Day

**Symptom (hypothetical, prevented by design):** If the reward claim failed to persist before the dialog closed, the popup would reappear on the next home screen build during the same session.

**Prevention:** `claimDailyReward()` sets `dailyRewardClaimedDate = today` in **both** Riverpod state and SharedPreferences synchronously before the dialog is dismissed. Since the popup trigger (`pendingReward != null`) checks `dailyRewardClaimedDate == today`, a claimed reward can never trigger the popup again the same day — even if the app is force-killed and reopened.

`claimDailyReward()` is also fully idempotent: if called twice (e.g., double-tap on Claim button), the second call returns immediately because `pendingReward` is already null after the first call updates `dailyRewardClaimedDate`.

---

## 28. JoinMatchmaking Deleting SubscribeToMatch Channel

**Symptom:** Both players joined the matchmaking pool successfully and the server created a room, but neither player received the `MatchFound` event. Server logs showed `"No subscription for player X — they may have disconnected"` for **both** players even though both had active `SubscribeToMatch` streams.

**Root Cause:** `JoinMatchmaking` (line 92 of `matchmaking.go`) had cleanup code `delete(h.playerChans, req.UserId)` intended to remove stale channels from previous sessions (e.g. "Play Again"). However, `SubscribeToMatch` registers the channel **before** `JoinMatchmaking` is called by the Flutter client. So the sequence was:
1. Flutter calls `SubscribeToMatch` → channel registered in `playerChans`
2. Flutter calls `JoinMatchmaking` → **deletes the channel** from `playerChans`
3. Server creates room → looks up `playerChans` → empty → "No subscription"

**Fix (`matchmaking-service/handlers/matchmaking.go`):** Removed the `delete(h.playerChans, req.UserId)` from `JoinMatchmaking`. Stale channels from previous sessions are safely overwritten by `SubscribeToMatch` itself (which always sets `playerChans[userId] = ch` on each new stream connection).

---

## 29. `panic: send on closed channel` in Matchmaking Broadcasts

**Symptom:** The matchmaking service crashed with `panic: send on closed channel` when a player re-joined matchmaking (e.g. tapped "Play Again"). The entire service restarted, disconnecting all active players.

**Root Cause:** `JoinMatchmaking` called `close(oldCh)` on the previous session's channel before deleting it from the map. However, concurrent goroutines (`broadcastWaitingUpdate`, `tryCreateRoom`) could still hold a reference to the closed channel and attempt to send on it.

**Fix (`matchmaking-service/handlers/matchmaking.go`):** Removed `close(oldCh)` — now just deletes from the map. The old `SubscribeToMatch` goroutine exits via gRPC context cancellation. Added `recover()` guard in `broadcastWaitingUpdate` as extra safety.

---

## 30. Matchmaking Countdown Timer Decreasing by 2 Seconds

**Symptom:** The "Estimated wait" timer on the matchmaking screen decreased by 2 seconds per tick instead of 1.

**Root Cause:** `_startCountdown()` in `matchmaking_screen.dart` created a new `Timer.periodic` without cancelling the previous one. If `_onStartPressed()` was called twice (double-tap or re-entry), two timers ran simultaneously, each decrementing the `waitTimerProvider` by 1 per second — appearing as a 2-second jump.

**Fix (`flutter-app/lib/screens/matchmaking_screen.dart`):** Added `_countdownTimer?.cancel()` at the top of `_startCountdown()` before creating the new timer.

---

## 31. Daily Quota Silently Blocking Matchmaking

**Symptom:** Player could tap "Play Now" and enter the matchmaking lobby, but `JoinMatchmaking` gRPC call silently failed — the player never appeared in the pool. No error message was shown in the UI.

**Root Cause:** `enforceQuotaAndIncrement()` returned `codes.ResourceExhausted` when the free user's `daily_quiz_used >= 5`, but the Flutter matchmaking screen did not display the error to the user. The player sat in the lobby thinking they were searching, while the server had already rejected them.

**Impact:** The other player (who did join successfully) would wait the full 20-second countdown and auto-cancel because the pool never reached 2 players.

**Mitigation:** Reset the user's `daily_quiz_used` in MongoDB. Long-term fix: the matchmaking screen should catch and display `ResourceExhausted` errors from `JoinMatchmaking`.

---

## 32. User Stats Not Persisted to MongoDB (Only SharedPreferences)

**Symptom:** After reinstalling the app or logging in on a new device, all user stats (matches played, matches won, coins, streak, last match details) reset to 0. Only `rating` was preserved.

**Root Cause:** Stats were stored exclusively in Flutter's `SharedPreferences` (local to the device). MongoDB `users` collection only stored `rating`, `username`, and auth fields. There was no mechanism to push stats to the server or pull them on login.

**Fix:**
- **Backend:** Added `GET /user/stats` and `POST /user/stats` endpoints on the matchmaking service (`matchmaking-service/handlers/user_stats.go`). GET returns all persistent fields; POST uses `$max` for numeric counters (never goes backwards) and `$set` for strings/arrays.
- **Backend:** `updatePlayerRatings()` in quiz-service now also increments `matches_played` and `matches_won` (for the winner) in MongoDB after every match.
- **Flutter:** Added `_syncStatsFromServer()` called after every login — fetches all stats from server and merges with local state (takes higher value). Added `_pushStatsToServer()` called fire-and-forget after every `_saveLocalStats()` — pushes all stats to MongoDB including `loginHistory`, `lastMatch` (9 fields), `premiumTrialExpiresAt`, `dailyRewardClaimedDate`, `bonusGamesRemaining`.

**Fields now persisted to MongoDB:** rating, matches_played, matches_won, coins, bonus_games_remaining, current_streak, longest_streak, max_question_streak, login_history, premium_trial_expiry, daily_reward_claimed, lm_won, lm_rank, lm_score, lm_answers_correct, lm_total_rounds, lm_avg_response_ms, lm_duration_seconds, lm_max_streak, lm_winner_username.

---

## 33. Notification Not Triggering for Password-Login Users

**Symptom:** FCM push notifications worked for Google Sign-In users but not for users who logged in with username/password. The device token was never registered with the backend.

**Root Cause:** `_initNotifications()` (which calls `NotificationService.instance.init(token: token)`) was only called in the Google Sign-In login path. The `register()` and `login()` methods in `auth_service.dart` did not call it.

**Fix (`flutter-app/lib/services/auth_service.dart`):** Added `_initNotifications()` call after `_syncReferralFromServer()` in both the `register()` and `login()` methods, matching the Google Sign-In path.

---

## 34. UPI Payment Option Not Showing in Razorpay Checkout

**Symptom:** The Razorpay checkout showed Cards, Netbanking, Wallet, and Pay Later — but no UPI option.

**Root Cause:** Two issues:
1. `prefill.contact` was set to an empty string. Razorpay's native Android SDK **hides UPI entirely** when the contact field is empty (UPI requires a phone number for collect flow).
2. A custom `config.display.blocks` structure was included in the checkout options. This is a Razorpay **Standard Checkout (web)** feature that doesn't work with the `razorpay_flutter` native SDK and caused unexpected behavior.

**Fix (`flutter-app/lib/screens/premium_screen.dart`):** Removed the `method` and `config` keys (not needed — the native SDK shows all enabled methods by default). Set `prefill.contact` to a non-empty placeholder value. UPI will now appear on real devices with UPI apps installed. On emulators without Google Pay/PhonePe, Razorpay may still hide UPI (this is a Razorpay SDK limitation, not a code issue).

---

## 35. Logout Not Navigating to Login Screen

**Symptom:** After tapping logout, the user briefly saw the login screen, then was immediately redirected back to the home screen.

**Root Cause:** `logout()` was declared as `void` (not `Future<void>`). The profile screen called it without `await`, then immediately navigated to `/login`. Since the state hadn't been reset yet (`isLoggedIn` was still `true`), GoRouter's redirect guard saw a logged-in user on `/login` and redirected to `/home`.

**Fix:**
- Changed `logout()` return type from `void` to `Future<void>` in `auth_service.dart`
- Changed the profile screen to `await ref.read(authProvider.notifier).logout()` before navigating to `/login`

---

## Architecture: Monolith → 3 Microservices

The project initially shipped as a single Go binary. The spec required three independent services. The split was:

| Service | Port | Responsibilities |
|---------|------|-----------------|
| `matchmaking-service` | :50051 | Auth (Register/Login), Matchmaking queue, Room creation, `match.created` publisher |
| `quiz-service` | :50052 | `StreamGameEvents`, `SubmitAnswer`, question selection, round timer loop, `round.completed` / `match.finished` publisher |
| `scoring-service` | :50053 | `answer.submitted` consumer, score calculation, Redis leaderboard, `GetLeaderboard` RPC |

**Shared state via Redis key namespacing:**
- `matchmaking:*` — owned by matchmaking
- `room:{id}:questions`, `room:{id}:submitted:{round}` — owned by quiz
- `room:{id}:leaderboard`, `room:{id}:answers:{round}` — owned by scoring

**Cross-service messaging via RabbitMQ:**
- `match.created` → consumed by quiz (triggers question selection)
- `answer.submitted` → consumed by scoring (triggers score calculation)
- `round.completed`, `match.finished` → consumed by scoring (leaderboard finalization)
