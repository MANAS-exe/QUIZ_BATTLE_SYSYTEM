import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_service.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:grpc/grpc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../proto/quiz.pb.dart' as pb;
import '../proto/quiz.pbgrpc.dart' as pbgrpc;

// ─────────────────────────────────────────
// DAILY REWARD
// ─────────────────────────────────────────

class DailyReward {
  final int coins;
  final int bonusGames;
  final String? badgeId;
  final int premiumTrialDays;
  final String title;
  final String subtitle;

  const DailyReward({
    required this.coins,
    this.bonusGames = 0,
    this.badgeId,
    this.premiumTrialDays = 0,
    required this.title,
    required this.subtitle,
  });
}

/// Returns the reward for a given consecutive login-streak day.
/// Milestones (14, 30) override the weekly cycle.
DailyReward rewardForDay(int streakDay) {
  if (streakDay == 30) {
    return const DailyReward(
      coins: 1000,
      bonusGames: 7,
      badgeId: 'monthly_master',
      premiumTrialDays: 7,
      title: 'Monthly Master!',
      subtitle: '30-day streak — 7 days Premium + 7 bonus games',
    );
  }
  if (streakDay == 14) {
    return const DailyReward(
      coins: 500,
      bonusGames: 5,
      badgeId: 'fortnight_fighter',
      title: 'Fortnight Fighter!',
      subtitle: '14-day streak — 500 coins + 5 bonus games',
    );
  }

  // Weekly cycle: map streakDay to 1–7
  final cycle = (streakDay - 1) % 7 + 1;
  switch (cycle) {
    case 1:
      return const DailyReward(
        coins: 50,
        title: 'Day 1 Streak!',
        subtitle: '50 coins',
      );
    case 2:
      return const DailyReward(
        coins: 75,
        title: 'Day 2 Streak!',
        subtitle: '75 coins',
      );
    case 3:
      return const DailyReward(
        coins: 100,
        bonusGames: 1,
        title: 'Day 3 Streak!',
        subtitle: '100 coins + 1 bonus game',
      );
    case 4:
      return const DailyReward(
        coins: 125,
        title: 'Day 4 Streak!',
        subtitle: '125 coins',
      );
    case 5:
      return const DailyReward(
        coins: 150,
        bonusGames: 2,
        title: 'Day 5 Streak!',
        subtitle: '150 coins + 2 bonus games',
      );
    case 6:
      return const DailyReward(
        coins: 200,
        title: 'Day 6 Streak!',
        subtitle: '200 coins',
      );
    case 7:
      return const DailyReward(
        coins: 250,
        bonusGames: 3,
        badgeId: 'week_warrior',
        title: 'Week Warrior!',
        subtitle: '250 coins + 3 bonus games + badge',
      );
    default:
      return const DailyReward(
        coins: 50,
        title: 'Daily Reward',
        subtitle: '50 coins',
      );
  }
}

// ─────────────────────────────────────────
// LAST MATCH DATA
// ─────────────────────────────────────────

class LastMatchData {
  final bool won;
  final int rank;
  final int score;
  final int answersCorrect;
  final int totalRounds;
  final int avgResponseMs;
  final int durationSeconds;
  final int maxStreak;
  final String winnerUsername;

  const LastMatchData({
    required this.won,
    required this.rank,
    required this.score,
    required this.answersCorrect,
    required this.totalRounds,
    required this.avgResponseMs,
    required this.durationSeconds,
    required this.maxStreak,
    required this.winnerUsername,
  });
}

// ─────────────────────────────────────────
// AUTH STATE
// ─────────────────────────────────────────

/// Free users can play [kFreeQuotaPerDay] matches per day.
/// Premium users have unlimited (represented as [kPremiumQuota]).
const int kFreeQuotaPerDay = 5;
const int kPremiumQuota = 999;

// Sentinel used in copyWith to distinguish "don't change" from "set to null"
// for nullable fields like premiumTrialExpiresAt.
const _unset = Object();

class AuthState {
  final String? token;
  final String? userId;
  final String? username;
  final String? email;              // Google email (or null for email/password users)
  final String? pictureUrl;         // Google profile picture URL
  final int rating;
  final bool isLoggedIn;
  final bool isPremium;             // true = paid premium (unlimited daily quizzes)
  final int dailyQuizUsed;          // matches played today (resets at midnight)
  final int matchesPlayed;
  final int matchesWon;
  final int currentStreak;          // consecutive login-day streak
  final int maxStreak;              // all-time max login-day streak
  final int maxQuestionStreak;      // best answer streak ever
  final List<LastMatchData> matchHistory; // newest-first, capped at 3

  // ── Daily rewards ──────────────────────────────────────────────
  final int coins;                       // total coins earned, never decreases
  final int bonusGamesRemaining;         // extra games; consumed before dailyQuizUsed
  final List<String> loginHistory;       // ISO date strings, last 30 days
  final String? premiumTrialExpiresAt;   // ISO datetime; null = no active trial
  final String? dailyRewardClaimedDate;  // ISO date of last reward claim

  // ── Referral ────────────────────────────────────────────────────
  final String? referralCode;         // this user's shareable 6-char code (e.g. "QB4X9K")
  final int referralCount;            // number of successful referrals made
  final int totalReferralCoins;       // lifetime coins earned through referrals
  final bool hasPendingReferralReward; // true if server has unclaimed coins/bonus
  final int pendingReferralCoins;      // coins waiting to be claimed (shown in stats before user claims)
  final bool alreadyReferred;          // true if this user applied someone else's code (eligible for discount)

  const AuthState({
    this.token,
    this.userId,
    this.username,
    this.email,
    this.pictureUrl,
    this.rating = 1000,
    this.isLoggedIn = false,
    this.isPremium = false,
    this.dailyQuizUsed = 0,
    this.matchesPlayed = 0,
    this.matchesWon = 0,
    this.currentStreak = 0,
    this.maxStreak = 0,
    this.maxQuestionStreak = 0,
    this.matchHistory = const [],
    this.coins = 0,
    this.bonusGamesRemaining = 0,
    this.loginHistory = const [],
    this.premiumTrialExpiresAt,
    this.dailyRewardClaimedDate,
    this.referralCode,
    this.referralCount = 0,
    this.totalReferralCoins = 0,
    this.hasPendingReferralReward = false,
    this.pendingReferralCoins = 0,
    this.alreadyReferred = false,
  });

  // ── Computed getters ───────────────────────────────────────────

  /// Convenience accessor — the most recent match, or null if none played.
  LastMatchData? get lastMatch =>
      matchHistory.isNotEmpty ? matchHistory.first : null;

  /// True when the user has paid premium OR an active premium trial.
  bool get isEffectivelyPremium {
    if (isPremium) return true;
    if (premiumTrialExpiresAt == null) return false;
    return DateTime.tryParse(premiumTrialExpiresAt!)?.isAfter(DateTime.now()) ??
        false;
  }

  /// Quizzes remaining today (free quota + bonus games).
  int get dailyQuizRemaining {
    if (isEffectivelyPremium) return kPremiumQuota;
    final freeLeft = (kFreeQuotaPerDay - dailyQuizUsed).clamp(0, kFreeQuotaPerDay);
    return freeLeft + bonusGamesRemaining;
  }

  /// True when a free (non-effectively-premium) user has used all games.
  bool get isQuotaExhausted =>
      !isEffectivelyPremium &&
      dailyQuizUsed >= kFreeQuotaPerDay &&
      bonusGamesRemaining == 0;

  double get winRate =>
      matchesPlayed == 0 ? 0 : matchesWon / matchesPlayed;

  /// Non-null when the user has logged in today but hasn't claimed their
  /// daily reward yet. Returns null if already claimed or streak is 0.
  DailyReward? get pendingReward {
    if (!isLoggedIn) return null;
    if (currentStreak == 0) return null;
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    if (dailyRewardClaimedDate == today) return null;
    return rewardForDay(currentStreak);
  }

  AuthState copyWith({
    String? token,
    String? userId,
    String? username,
    String? email,
    String? pictureUrl,
    int? rating,
    bool? isLoggedIn,
    bool? isPremium,
    int? dailyQuizUsed,
    int? matchesPlayed,
    int? matchesWon,
    int? currentStreak,
    int? maxStreak,
    int? maxQuestionStreak,
    List<LastMatchData>? matchHistory,
    int? coins,
    int? bonusGamesRemaining,
    List<String>? loginHistory,
    // Use sentinel so callers can explicitly set this to null.
    Object? premiumTrialExpiresAt = _unset,
    String? dailyRewardClaimedDate,
    String? referralCode,
    int? referralCount,
    int? totalReferralCoins,
    bool? hasPendingReferralReward,
    int? pendingReferralCoins,
    bool? alreadyReferred,
  }) {
    return AuthState(
      token: token ?? this.token,
      userId: userId ?? this.userId,
      username: username ?? this.username,
      email: email ?? this.email,
      pictureUrl: pictureUrl ?? this.pictureUrl,
      rating: rating ?? this.rating,
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      isPremium: isPremium ?? this.isPremium,
      dailyQuizUsed: dailyQuizUsed ?? this.dailyQuizUsed,
      matchesPlayed: matchesPlayed ?? this.matchesPlayed,
      matchesWon: matchesWon ?? this.matchesWon,
      currentStreak: currentStreak ?? this.currentStreak,
      maxStreak: maxStreak ?? this.maxStreak,
      maxQuestionStreak: maxQuestionStreak ?? this.maxQuestionStreak,
      matchHistory: matchHistory ?? this.matchHistory,
      coins: coins ?? this.coins,
      bonusGamesRemaining: bonusGamesRemaining ?? this.bonusGamesRemaining,
      loginHistory: loginHistory ?? this.loginHistory,
      premiumTrialExpiresAt: premiumTrialExpiresAt == _unset
          ? this.premiumTrialExpiresAt
          : premiumTrialExpiresAt as String?,
      dailyRewardClaimedDate:
          dailyRewardClaimedDate ?? this.dailyRewardClaimedDate,
      referralCode: referralCode ?? this.referralCode,
      referralCount: referralCount ?? this.referralCount,
      totalReferralCoins: totalReferralCoins ?? this.totalReferralCoins,
      hasPendingReferralReward:
          hasPendingReferralReward ?? this.hasPendingReferralReward,
      pendingReferralCoins: pendingReferralCoins ?? this.pendingReferralCoins,
      alreadyReferred: alreadyReferred ?? this.alreadyReferred,
    );
  }
}

// ─────────────────────────────────────────
// AUTH NOTIFIER
// ─────────────────────────────────────────

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState());

  late final pbgrpc.AuthServiceClient _client;
  bool _initialized = false;

  // Google Sign-In singleton — reused across sign-in calls
  final _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
    serverClientId: '719168042393-acjhshba35836lojheenogj9qrps76p3.apps.googleusercontent.com',
  );

  void init(ClientChannel channel) {
    if (_initialized) return;
    _client = pbgrpc.AuthServiceClient(channel);
    _initialized = true;
  }

  // ── Google Sign-In ─────────────────────────────────────────────

  /// Signs in with Google and exchanges the ID token with the backend.
  ///
  /// WHY: Google sign-in is the primary auth method. It gives us a verified
  /// email, a stable user ID (google sub), and a profile picture without
  /// requiring users to remember passwords.
  ///
  /// HOW:
  ///   1. Flutter opens Google consent screen via google_sign_in SDK
  ///   2. On success, retrieve the ID token from Google's response
  ///   3. POST the token to our backend /auth/google (port 8080)
  ///   4. Backend verifies with Google, upserts user in MongoDB, returns JWT
  ///   5. Store JWT + user profile locally (SharedPreferences)
  ///
  /// Returns null on success, error message string on failure.
  Future<String?> googleSignIn() async {
    try {
      // Trigger Google Sign-In flow
      final account = await _googleSignIn.signIn();
      if (account == null) return 'Sign-in cancelled';

      // Get the ID token (signed JWT from Google)
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) return 'Failed to get Google ID token';

      // Exchange with backend
      final res = await _callGoogleAuthEndpoint(idToken);
      if (res == null) return 'Server unreachable';

      if (res['success'] != true) {
        return res['message'] as String? ?? 'Google login failed';
      }

      // Build auth state from backend response
      final userId = res['user_id'] as String? ?? '';
      final username = res['username'] as String? ?? account.displayName ?? 'User';

      state = AuthState(
        token: res['token'] as String?,
        userId: userId,
        username: username,
        email: res['email'] as String? ?? account.email,
        pictureUrl: res['picture_url'] as String? ?? account.photoUrl,
        rating: (res['rating'] as num?)?.toInt() ?? 1000,
        isLoggedIn: true,
        isPremium: false,
      );

      // Persist Google credentials for session restore
      await _saveGoogleSession(userId, idToken);
      await _loadLocalStats();
      await _syncPremiumFromServer();
      await _syncStatsFromServer();
      await _syncReferralFromServer();
      _initNotifications();
      return null;
    } on PlatformException catch (e) {
      // iOS SDK throws PlatformException when GoogleService-Info.plist is
      // missing or the OAuth client ID / URL scheme is not configured in
      // Info.plist. Show a clear error instead of crashing.
      debugPrint('[GoogleSignIn] PlatformException: ${e.code} — ${e.message}');
      if (e.code == 'sign_in_failed') {
        return 'Google Sign-In not configured for this build.\n'
            'Use email/password login instead.';
      }
      return 'Google Sign-In error (${e.code}): ${e.message}';
    } catch (e) {
      debugPrint('[GoogleSignIn] error: $e');
      return 'Google sign-in failed. Try email/password instead.';
    }
  }

  /// Attempts to silently restore a previous Google session on app start.
  /// This is faster than re-opening the Google consent screen.
  Future<bool> tryRestoreGoogleSession() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account == null) return false;
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) return false;
      final err = await googleSignIn();
      return err == null;
    } catch (_) {
      return false;
    }
  }

  /// Calls POST http://<host>:8080/auth/google with the Google ID token.
  /// Returns the decoded JSON body, or null if the request fails.
  Future<Map<String, dynamic>?> _callGoogleAuthEndpoint(String idToken) async {
    // Android emulator uses 10.0.2.2 to reach the host machine's localhost.
    // Physical device: use your machine's LAN IP instead.
    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    final baseUrl = 'http://$host:8080';
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/auth/google'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'id_token': idToken}),
          )
          .timeout(const Duration(seconds: 10));

      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[GoogleAuth] HTTP error: $e');
      return null;
    }
  }

  // ── Email / Password Auth ──────────────────────────────────────

  /// Try to restore a saved email/password session on app start.
  Future<bool> tryRestoreSession() async {
    final prefs = await SharedPreferences.getInstance();

    // Try Google session first (preferred)
    final savedIdToken = prefs.getString('google_id_token');
    if (savedIdToken != null) {
      final err = await googleSignIn();
      if (err == null) return true;
      // Token expired — fall through to email/password
    }

    final username = prefs.getString('saved_username');
    final password = prefs.getString('saved_password');
    if (username == null || password == null) return false;

    final err = await login(username, password);
    return err == null;
  }

  Future<String?> getSavedUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('saved_username');
  }

  Future<String?> register(String username, String password) async {
    try {
      final req = pb.AuthRequest()
        ..username = username
        ..password = password;
      final res = await _client.register(req);
      if (res.success) {
        state = AuthState(
          token: res.token,
          userId: res.userId,
          username: res.username,
          rating: res.rating,
          isLoggedIn: true,
        );
        await _saveCredentials(username, password);
        await _loadLocalStats();
        await _syncPremiumFromServer();
        await _syncStatsFromServer();
        await _syncReferralFromServer();
        _initNotifications();
        return null;
      }
      return res.message;
    } on GrpcError catch (e) {
      debugPrint('[AuthService] register error: ${e.codeName} — ${e.message}');
      return e.message ?? 'Registration failed';
    }
  }

  Future<String?> login(String username, String password) async {
    try {
      final req = pb.AuthRequest()
        ..username = username
        ..password = password;
      final res = await _client.login(req);
      if (res.success) {
        state = AuthState(
          token: res.token,
          userId: res.userId,
          username: res.username,
          rating: res.rating,
          isLoggedIn: true,
        );
        await _saveCredentials(username, password);
        await _loadLocalStats();
        await _syncPremiumFromServer();
        await _syncStatsFromServer();
        await _syncReferralFromServer();
        _initNotifications();
        return null;
      }
      return res.message;
    } on GrpcError catch (e) {
      debugPrint('[AuthService] login error: ${e.codeName} — ${e.message}');
      return e.message ?? 'Login failed';
    }
  }

  // ── Change Password ─────────────────────────────────────────────

  /// Changes the password for the currently logged-in user.
  /// Returns null on success, or an error message string.
  Future<String?> changePassword(String newPassword) async {
    final token = state.token;
    if (token == null) return 'Not logged in';
    if (newPassword.length < 4) return 'Password must be at least 4 characters';

    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    try {
      final response = await http
          .post(
            Uri.parse('http://$host:8080/user/change-password'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'new_password': newPassword}),
          )
          .timeout(const Duration(seconds: 10));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200 && body['success'] == true) {
        // Update saved password so auto-login still works
        final prefs = await SharedPreferences.getInstance();
        final savedUsername = prefs.getString('saved_username');
        if (savedUsername != null) {
          await prefs.setString('saved_password', newPassword);
        }
        return null;
      }
      return body['message'] as String? ?? 'Failed to change password';
    } catch (e) {
      debugPrint('[AuthService] changePassword error: $e');
      return 'Network error — please try again';
    }
  }

  // ── Premium ────────────────────────────────────────────────────

  /// Toggles premium status (demo only — real app would verify a receipt).
  Future<void> togglePremium() async {
    final prefs = await SharedPreferences.getInstance();
    final newVal = !state.isPremium;
    state = state.copyWith(isPremium: newVal);
    await prefs.setBool('${_statsKey}_premium', newVal);
  }

  /// Sets premium status to true after a successful Razorpay payment.
  Future<void> setPremium(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(isPremium: value);
    await prefs.setBool('${_statsKey}_premium', value);
  }

  /// Fetches real-time subscription status from the payment service and
  /// updates local state + SharedPreferences. Called after every login so
  /// premium status is synced across devices.
  Future<void> _syncPremiumFromServer() async {
    final token = state.token;
    if (token == null) return;

    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    try {
      final resp = await http
          .get(
            Uri.parse('http://$host:8081/payment/status'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final isActive = body['is_active'] as bool? ?? false;
        if (isActive != state.isPremium) {
          final prefs = await SharedPreferences.getInstance();
          state = state.copyWith(isPremium: isActive);
          await prefs.setBool('${_statsKey}_premium', isActive);
        }
      }
    } catch (e) {
      // Non-fatal — fall back to locally cached value
      debugPrint('[AuthService] premium sync failed: $e');
    }
  }

  /// Fetches ALL persistent user stats from the server and merges into local
  /// state. This ensures stats survive app reinstall or new device login.
  Future<void> _syncStatsFromServer() async {
    final token = state.token;
    if (token == null) return;

    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    try {
      final resp = await http
          .get(
            Uri.parse('http://$host:8080/user/stats'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        final b = jsonDecode(resp.body) as Map<String, dynamic>;

        // Use the higher of local and server for numeric counters
        int max(int a, int b) => a > b ? a : b;

        final serverHistory = (b['login_history'] as List?)
            ?.map((e) => e.toString())
            .toList();

        state = state.copyWith(
          rating: max(b['rating'] as int? ?? 0, state.rating),
          matchesPlayed: max(b['matches_played'] as int? ?? 0, state.matchesPlayed),
          matchesWon: max(b['matches_won'] as int? ?? 0, state.matchesWon),
          coins: max(b['coins'] as int? ?? 0, state.coins),
          // bonus_games_remaining can decrease — use server value, not max
          bonusGamesRemaining: b['bonus_games_remaining'] as int? ?? state.bonusGamesRemaining,
          currentStreak: max(b['current_streak'] as int? ?? 0, state.currentStreak),
          maxStreak: max(b['longest_streak'] as int? ?? 0, state.maxStreak),
          maxQuestionStreak: max(b['max_question_streak'] as int? ?? 0, state.maxQuestionStreak),
          loginHistory: serverHistory != null && serverHistory.length > state.loginHistory.length
              ? serverHistory
              : state.loginHistory,
          premiumTrialExpiresAt: (b['premium_trial_expiry'] as String?) ?? state.premiumTrialExpiresAt,
          dailyRewardClaimedDate: (b['daily_reward_claimed'] as String?) ?? state.dailyRewardClaimedDate,
        );

        // Restore last match from server if local history is empty
        if (state.matchHistory.isEmpty && (b['lm_score'] as int? ?? 0) > 0) {
          state = state.copyWith(
            matchHistory: [
              LastMatchData(
                won: b['lm_won'] as bool? ?? false,
                rank: b['lm_rank'] as int? ?? 0,
                score: b['lm_score'] as int? ?? 0,
                answersCorrect: b['lm_answers_correct'] as int? ?? 0,
                totalRounds: b['lm_total_rounds'] as int? ?? 0,
                avgResponseMs: b['lm_avg_response_ms'] as int? ?? 0,
                durationSeconds: b['lm_duration_seconds'] as int? ?? 0,
                maxStreak: b['lm_max_streak'] as int? ?? 0,
                winnerUsername: b['lm_winner_username'] as String? ?? '',
              ),
            ],
          );
        }

        _saveLocalStats();
        debugPrint('[AuthService] stats synced from server — played: ${state.matchesPlayed}, won: ${state.matchesWon}');
      }
    } catch (e) {
      debugPrint('[AuthService] stats sync failed: $e');
    }
  }

  /// Pushes all local stats to MongoDB so they survive app reinstall.
  /// Called fire-and-forget after every _saveLocalStats().
  void _pushStatsToServer() {
    final token = state.token;
    if (token == null) return;

    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';

    // Send only the most recent match to the server (backward-compat with lm_* fields).
    final lm = state.matchHistory.isNotEmpty ? state.matchHistory.first : null;
    http
        .post(
          Uri.parse('http://$host:8080/user/stats'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'rating': state.rating,
            'matches_played': state.matchesPlayed,
            'matches_won': state.matchesWon,
            'coins': state.coins,
            'bonus_games_remaining': state.bonusGamesRemaining,
            'current_streak': state.currentStreak,
            'longest_streak': state.maxStreak,
            'max_question_streak': state.maxQuestionStreak,
            'login_history': state.loginHistory,
            'premium_trial_expiry': state.premiumTrialExpiresAt ?? '',
            'daily_reward_claimed': state.dailyRewardClaimedDate ?? '',
            'lm_won': lm?.won ?? false,
            'lm_rank': lm?.rank ?? 0,
            'lm_score': lm?.score ?? 0,
            'lm_answers_correct': lm?.answersCorrect ?? 0,
            'lm_total_rounds': lm?.totalRounds ?? 0,
            'lm_avg_response_ms': lm?.avgResponseMs ?? 0,
            'lm_duration_seconds': lm?.durationSeconds ?? 0,
            'lm_max_streak': lm?.maxStreak ?? 0,
            'lm_winner_username': lm?.winnerUsername ?? '',
          }),
        )
        .timeout(const Duration(seconds: 5))
        .then((_) => debugPrint('[AuthService] stats pushed to server'))
        .catchError((e) => debugPrint('[AuthService] stats push failed: $e'));
  }

  // ── Referral ───────────────────────────────────────────────────

  /// Fetches the user's referral code and stats from the backend and syncs to
  /// local state + SharedPreferences. Called after every login.
  ///
  /// If the server is unreachable, the cached code/count from SharedPreferences
  /// is used so the UI doesn't go blank offline.
  ///
  /// Side effect: `hasPendingReferralReward` is set to true when the server
  /// reports pending_coins > 0 or pending_bonus > 0. The Profile → REFERRAL
  /// tab reads this flag to show a claim button.
  /// Public wrapper — called by the REFERRAL tab on open to catch rewards that
  /// arrived since the last login (e.g., someone used the user's code while the
  /// app was already running).
  Future<void> refreshReferralData() => _syncReferralFromServer();

  /// Fire-and-forget: registers the FCM device token with the backend.
  /// Called after every successful login. Errors are non-fatal.
  void _initNotifications() {
    final token = state.token;
    if (token == null) return;
    NotificationService.instance.init(token: token).catchError((e) {
      debugPrint('[NotificationService] init error: $e');
    });
  }

  Future<void> _syncReferralFromServer() async {
    final token = state.token;
    if (token == null) return;

    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    try {
      final resp = await http
          .get(
            Uri.parse('http://$host:8080/referral/code'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final code = body['code'] as String? ?? '';
        final count = (body['referral_count'] as num?)?.toInt() ?? 0;
        final totalCoins = (body['total_coins_earned'] as num?)?.toInt() ?? 0;
        final pendingCoins = (body['pending_coins'] as num?)?.toInt() ?? 0;
        final pendingBonus = (body['pending_bonus'] as num?)?.toInt() ?? 0;
        final hasPending = pendingCoins > 0 || pendingBonus > 0;
        final alreadyReferred = body['already_referred'] as bool? ?? false;

        state = state.copyWith(
          referralCode: code.isNotEmpty ? code : null,
          referralCount: count,
          totalReferralCoins: totalCoins,
          hasPendingReferralReward: hasPending,
          pendingReferralCoins: pendingCoins,
          alreadyReferred: alreadyReferred,
        );

        final prefs = await SharedPreferences.getInstance();
        if (code.isNotEmpty) {
          await prefs.setString('${_statsKey}_referralCode', code);
        }
        await prefs.setInt('${_statsKey}_referralCount', count);
        await prefs.setInt('${_statsKey}_totalReferralCoins', totalCoins);
        await prefs.setBool('${_statsKey}_alreadyReferred', alreadyReferred);
      }
    } catch (e) {
      // Non-fatal — fall back to cached values.
      debugPrint('[Referral] sync failed: $e');
      final prefs = await SharedPreferences.getInstance();
      final cachedCode = prefs.getString('${_statsKey}_referralCode');
      if (cachedCode != null) {
        state = state.copyWith(
          referralCode: cachedCode,
          referralCount: prefs.getInt('${_statsKey}_referralCount') ?? 0,
          totalReferralCoins:
              prefs.getInt('${_statsKey}_totalReferralCoins') ?? 0,
          alreadyReferred:
              prefs.getBool('${_statsKey}_alreadyReferred') ?? false,
        );
      }
    }
  }

  /// Applies a friend's referral code to the authenticated user's account.
  ///
  /// Returns null on success, or an error message string on failure.
  ///
  /// Constraints enforced server-side:
  ///  - Code must be unused (user hasn't been referred before)
  ///  - Account must be ≤7 days old
  ///  - Cannot be your own code
  ///  - Referrer must be under the 10-referral cap
  ///
  /// On success, pending rewards are added to the user's account on the server.
  /// Call [claimReferralRewards] to apply them to local state.
  Future<String?> applyReferralCode(String code) async {
    final token = state.token;
    if (token == null) return 'Not logged in';
    final trimmed = code.trim();
    if (trimmed.isEmpty) return 'Referral code cannot be empty';

    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    try {
      final resp = await http
          .post(
            Uri.parse('http://$host:8080/referral/apply'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'code': trimmed.toUpperCase()}),
          )
          .timeout(const Duration(seconds: 10));

      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && body['success'] == true) {
        // Server applied the code — sync to pick up pending rewards.
        await _syncReferralFromServer();
        return null; // success
      }
      return body['message'] as String? ?? 'Failed to apply referral code';
    } catch (e) {
      debugPrint('[Referral] applyCode error: $e');
      return 'Network error — please check your connection';
    }
  }

  /// Claims all pending referral rewards from the server and applies them to
  /// local coin + bonus game balances.
  ///
  /// Returns null on success (including "no rewards to claim"), or an error
  /// message string on failure.
  ///
  /// This is idempotent: calling it when there are no pending rewards is a
  /// no-op that returns null.
  Future<String?> claimReferralRewards() async {
    final token = state.token;
    if (token == null) return 'Not logged in';

    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    try {
      final resp = await http
          .get(
            Uri.parse('http://$host:8080/referral/claim'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));

      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && body['success'] == true) {
        final coins = (body['reward_coins'] as num?)?.toInt() ?? 0;
        final bonus = (body['reward_bonus'] as num?)?.toInt() ?? 0;

        if (coins > 0 || bonus > 0) {
          final newCoins = state.coins + coins;
          final newBonus = state.bonusGamesRemaining + bonus;
          final newTotalReferralCoins = state.totalReferralCoins + coins;

          state = state.copyWith(
            coins: newCoins,
            bonusGamesRemaining: newBonus,
            totalReferralCoins: newTotalReferralCoins,
            hasPendingReferralReward: false,
            pendingReferralCoins: 0,
          );

          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('${_statsKey}_coins', newCoins);
          await prefs.setInt('${_statsKey}_bonusGames', newBonus);
          await prefs.setInt(
              '${_statsKey}_totalReferralCoins', newTotalReferralCoins);

          debugPrint(
              '[Referral] claimed +$coins coins, +$bonus bonus games');
        } else {
          // No rewards — clear pending flag so the UI button disappears.
          state = state.copyWith(hasPendingReferralReward: false);
        }
        return null; // success
      }
      return body['message'] as String? ?? 'Server error';
    } catch (e) {
      debugPrint('[Referral] claimRewards error: $e');
      return 'Network error — please check your connection';
    }
  }

  // ── Daily Quota ────────────────────────────────────────────────

  /// Increments the daily quiz counter. Call this when a match STARTS
  /// (not when it ends — so even a forfeited game counts against quota).
  ///
  /// Bonus games are consumed first; only when they run out does
  /// dailyQuizUsed increment.
  Future<void> consumeDailyQuiz() async {
    if (state.isEffectivelyPremium) return;
    final prefs = await SharedPreferences.getInstance();
    final today = _today();

    if (state.bonusGamesRemaining > 0) {
      final newBonus = state.bonusGamesRemaining - 1;
      state = state.copyWith(bonusGamesRemaining: newBonus);
      await prefs.setInt('${_statsKey}_bonusGames', newBonus);
    } else {
      final newUsed = state.dailyQuizUsed + 1;
      state = state.copyWith(dailyQuizUsed: newUsed);
      await prefs.setInt('${_statsKey}_dq_used', newUsed);
      await prefs.setString('${_statsKey}_dq_date', today);
    }
  }

  // ── Daily Reward ───────────────────────────────────────────────

  /// Claims the pending daily reward.
  ///
  /// Grants coins, bonus games, and premium trial if applicable.
  /// Marks the reward as claimed for today — calling this twice in the same
  /// day is a no-op.
  Future<void> claimDailyReward() async {
    final reward = state.pendingReward;
    if (reward == null) return; // already claimed or no streak

    final today = _today();
    final prefs = await SharedPreferences.getInstance();

    final newCoins = state.coins + reward.coins;
    final newBonus = state.bonusGamesRemaining + reward.bonusGames;

    String? trialExpiry = state.premiumTrialExpiresAt;
    if (reward.premiumTrialDays > 0) {
      final expiry = DateTime.now().add(Duration(days: reward.premiumTrialDays));
      trialExpiry = expiry.toIso8601String();
    }

    state = state.copyWith(
      coins: newCoins,
      bonusGamesRemaining: newBonus,
      premiumTrialExpiresAt: trialExpiry,
      dailyRewardClaimedDate: today,
    );

    await prefs.setInt('${_statsKey}_coins', newCoins);
    await prefs.setInt('${_statsKey}_bonusGames', newBonus);
    await prefs.setString('${_statsKey}_rewardDate', today);
    if (trialExpiry != null) {
      await prefs.setString('${_statsKey}_trialExpiry', trialExpiry);
    }

    debugPrint('[DailyReward] claimed day-${state.currentStreak}: '
        '+${reward.coins} coins, +${reward.bonusGames} bonus games');
  }

  // ── Match Result ───────────────────────────────────────────────

  /// Called after a match ends to update local stats.
  void recordMatchResult({
    required bool won,
    required int newRating,
    int matchMaxStreak = 0,
    LastMatchData? lastMatch,
  }) {
    final played = state.matchesPlayed + 1;
    final wins = state.matchesWon + (won ? 1 : 0);
    final bestQStreak = matchMaxStreak > state.maxQuestionStreak
        ? matchMaxStreak
        : state.maxQuestionStreak;

    // Prepend the new match and keep at most 3 entries.
    final newHistory = lastMatch != null
        ? [lastMatch, ...state.matchHistory].take(3).toList()
        : state.matchHistory;

    state = state.copyWith(
      rating: newRating,
      matchesPlayed: played,
      matchesWon: wins,
      maxQuestionStreak: bestQStreak,
      matchHistory: newHistory,
    );
    _saveLocalStats();
  }

  Future<void> logout() async {
    await _googleSignIn.signOut();
    await NotificationService.instance.clearToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('google_id_token');
    await prefs.remove('saved_username');
    await prefs.remove('saved_password');
    state = const AuthState();
  }

  // ── Private helpers ────────────────────────────────────────────

  String get _statsKey => 'stats_${state.userId}';

  String _today() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

  /// Updates the login-day streak from the stored login history.
  ///
  /// Called from [_loadLocalStats] (i.e., on every login).
  /// Uses a history-based approach for accuracy:
  ///   - Append today to the history list (deduplicated).
  ///   - Count consecutive trailing days to compute streak.
  Future<void> _updateLoginStreak() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_statsKey}_loginHistory';
    final today = _today();

    // Load existing history
    List<String> history;
    try {
      final raw = prefs.getString(key);
      history = raw != null
          ? List<String>.from(jsonDecode(raw) as List)
          : <String>[];
    } catch (_) {
      history = <String>[];
    }

    // Append today if not already present
    if (!history.contains(today)) {
      history.add(today);
      // Keep only last 30 unique days
      if (history.length > 30) {
        history = history.sublist(history.length - 30);
      }
      await prefs.setString(key, jsonEncode(history));
    }

    // Compute streak: walk backwards from today counting consecutive days
    final streak = _computeStreakFromHistory(history, today);
    final newMax = streak > state.maxStreak ? streak : state.maxStreak;

    state = state.copyWith(
      currentStreak: streak,
      maxStreak: newMax,
      loginHistory: history,
    );
    // Persist updated streak values
    await prefs.setInt('${_statsKey}_streak', streak);
    await prefs.setInt('${_statsKey}_maxStreak', newMax);
  }

  /// Counts consecutive days ending at [today] in [history].
  int _computeStreakFromHistory(List<String> history, String today) {
    if (history.isEmpty) return 0;

    // Build a set for O(1) lookup
    final set = history.toSet();
    int streak = 0;
    DateTime cursor = DateTime.parse(today);

    while (true) {
      final dateStr = cursor.toIso8601String().substring(0, 10);
      if (set.contains(dateStr)) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      } else {
        break;
      }
    }
    return streak;
  }

  Future<void> _saveCredentials(String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_username', username);
    await prefs.setString('saved_password', password);
  }

  Future<void> _saveGoogleSession(String userId, String idToken) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('google_id_token', idToken);
    await prefs.setString('last_google_user', userId);
  }

  Future<void> _saveLocalStats() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _statsKey;
    await prefs.setInt('${key}_rating', state.rating);
    await prefs.setInt('${key}_played', state.matchesPlayed);
    await prefs.setInt('${key}_won', state.matchesWon);
    await prefs.setInt('${key}_maxQStreak', state.maxQuestionStreak);
    await prefs.setBool('${key}_premium', state.isPremium);
    await prefs.setInt('${key}_coins', state.coins);
    await prefs.setInt('${key}_bonusGames', state.bonusGamesRemaining);
    // Persist daily quota so it survives app restarts
    await prefs.setInt('${key}_dq_used', state.dailyQuizUsed);
    await prefs.setString('${key}_dq_date', _today());

    // Persist match history as JSON (replaces legacy lm_* scalar keys)
    final historyJson = jsonEncode(state.matchHistory.map((lm) => {
      'won': lm.won,
      'rank': lm.rank,
      'score': lm.score,
      'answers_correct': lm.answersCorrect,
      'total_rounds': lm.totalRounds,
      'avg_response_ms': lm.avgResponseMs,
      'duration_seconds': lm.durationSeconds,
      'max_streak': lm.maxStreak,
      'winner_username': lm.winnerUsername,
    }).toList());
    await prefs.setString('${key}_match_history_v2', historyJson);

    // Push all stats to MongoDB (fire-and-forget)
    _pushStatsToServer();
  }

  Future<void> _loadLocalStats() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _statsKey;
    final savedRating = prefs.getInt('${key}_rating') ?? state.rating;

    // Daily quota — reset if date changed
    final savedDqDate = prefs.getString('${key}_dq_date');
    final dqUsed =
        savedDqDate == _today() ? (prefs.getInt('${key}_dq_used') ?? 0) : 0;

    // Premium trial expiry
    final trialExpiry = prefs.getString('${key}_trialExpiry');

    // Daily reward claimed date
    final rewardDate = prefs.getString('${key}_rewardDate');

    // Coins & bonus games
    final coins = prefs.getInt('${key}_coins') ?? 0;
    final bonusGames = prefs.getInt('${key}_bonusGames') ?? 0;

    // Referral cache — real values are synced from server after _loadLocalStats()
    final cachedReferralCode = prefs.getString('${key}_referralCode');
    final cachedReferralCount = prefs.getInt('${key}_referralCount') ?? 0;
    final cachedTotalReferralCoins =
        prefs.getInt('${key}_totalReferralCoins') ?? 0;
    final cachedAlreadyReferred =
        prefs.getBool('${key}_alreadyReferred') ?? false;

    // Load match history — try new JSON format first, fall back to legacy lm_* keys.
    List<LastMatchData> matchHistory = [];
    final historyRaw = prefs.getString('${key}_match_history_v2');
    if (historyRaw != null) {
      try {
        final list = jsonDecode(historyRaw) as List;
        matchHistory = list.map((m) {
          final map = m as Map<String, dynamic>;
          return LastMatchData(
            won: map['won'] as bool? ?? false,
            rank: map['rank'] as int? ?? 0,
            score: map['score'] as int? ?? 0,
            answersCorrect: map['answers_correct'] as int? ?? 0,
            totalRounds: map['total_rounds'] as int? ?? 0,
            avgResponseMs: map['avg_response_ms'] as int? ?? 0,
            durationSeconds: map['duration_seconds'] as int? ?? 0,
            maxStreak: map['max_streak'] as int? ?? 0,
            winnerUsername: map['winner_username'] as String? ?? '',
          );
        }).toList();
      } catch (_) {}
    }
    // Backward-compat: migrate single-match lm_* keys to new list format.
    if (matchHistory.isEmpty) {
      final lmWon = prefs.getBool('${key}_lm_won');
      if (lmWon != null) {
        matchHistory = [
          LastMatchData(
            won: lmWon,
            rank: prefs.getInt('${key}_lm_rank') ?? 1,
            score: prefs.getInt('${key}_lm_score') ?? 0,
            answersCorrect: prefs.getInt('${key}_lm_correct') ?? 0,
            totalRounds: prefs.getInt('${key}_lm_rounds') ?? 0,
            avgResponseMs: prefs.getInt('${key}_lm_avgMs') ?? 0,
            durationSeconds: prefs.getInt('${key}_lm_duration') ?? 0,
            maxStreak: prefs.getInt('${key}_lm_streak') ?? 0,
            winnerUsername: prefs.getString('${key}_lm_winner') ?? '',
          ),
        ];
      }
    }

    state = state.copyWith(
      rating: savedRating > state.rating ? savedRating : state.rating,
      matchesPlayed: prefs.getInt('${key}_played') ?? 0,
      matchesWon: prefs.getInt('${key}_won') ?? 0,
      maxQuestionStreak: prefs.getInt('${key}_maxQStreak') ?? 0,
      isPremium: prefs.getBool('${key}_premium') ?? false,
      dailyQuizUsed: dqUsed,
      premiumTrialExpiresAt: trialExpiry,
      dailyRewardClaimedDate: rewardDate,
      coins: coins,
      bonusGamesRemaining: bonusGames,
      matchHistory: matchHistory,
      // Referral cache — will be refreshed by _syncReferralFromServer() below
      referralCode: cachedReferralCode,
      referralCount: cachedReferralCount,
      totalReferralCoins: cachedTotalReferralCoins,
      alreadyReferred: cachedAlreadyReferred,
    );

    // Update login streak on every login (streak ≠ match streak)
    await _updateLoginStreak();
  }
}

// ─────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});
