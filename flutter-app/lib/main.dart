import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/game_provider.dart';
import 'screens/leaderboard_screen.dart';
import 'screens/matchmaking_screen.dart';
import 'screens/quiz_screen.dart';
import 'screens/results_screen.dart';

// ─────────────────────────────────────────
// ROUTER
// ─────────────────────────────────────────

final _router = GoRouter(
  initialLocation: '/matchmaking',
  routes: [
    GoRoute(
      path: '/matchmaking',
      name: 'matchmaking',
      builder: (context, state) => const MatchmakingScreen(),
    ),
    GoRoute(
      path: '/quiz',
      name: 'quiz',
      builder: (context, state) => const QuizScreen(),
    ),
    GoRoute(
      path: '/leaderboard',
      name: 'leaderboard',
      builder: (context, state) => const LeaderboardScreen(),
    ),
    GoRoute(
      path: '/results',
      name: 'results',
      builder: (context, state) => const ResultsScreen(),
    ),
  ],

  // Redirect to matchmaking if game state is missing (e.g. direct URL or app killed mid-match)
  redirect: (context, routerState) {
    final path = routerState.uri.path;
    const gameRoutes = ['/quiz', '/leaderboard', '/results'];
    if (gameRoutes.contains(path)) {
      final gameState = ProviderScope.containerOf(context).read(gameProvider);
      if (gameState.roomId == null) {
        return '/matchmaking';
      }
    }
    return null;
  },
);

// ─────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────

void main() {
  runApp(
    // ProviderScope is the Riverpod root — all providers live inside this
    const ProviderScope(
      child: QuizBattleApp(),
    ),
  );
}

// ─────────────────────────────────────────
// ROOT APP
// ─────────────────────────────────────────

class QuizBattleApp extends ConsumerWidget {
  const QuizBattleApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Quiz Battle',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      routerConfig: _router,
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0D0D1A),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFE94560),
        brightness: Brightness.dark,
        surface: const Color(0xFF1A1A2E),
        primary: const Color(0xFFE94560),
        secondary: const Color(0xFFFFB830),
      ),
    //   fontFamily: 'Inter',
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
        bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
        labelSmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1A1A2E),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFE94560),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}