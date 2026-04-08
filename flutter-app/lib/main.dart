import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/game_provider.dart';
import 'screens/leaderboard_screen.dart';
import 'screens/login_screen.dart';
import 'screens/matchmaking_screen.dart';
import 'screens/quiz_screen.dart';
import 'screens/results_screen.dart';
import 'screens/spectating_screen.dart';
import 'services/auth_service.dart';
import 'services/game_service.dart';

// ─────────────────────────────────────────
// ROUTER
// ─────────────────────────────────────────

final _router = GoRouter(
  initialLocation: '/login',
  routes: [
    GoRoute(
      path: '/login',
      name: 'login',
      builder: (context, state) => const LoginScreen(),
    ),
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
      path: '/spectating',
      name: 'spectating',
      builder: (context, state) => const SpectatingScreen(),
    ),
    GoRoute(
      path: '/results',
      name: 'results',
      builder: (context, state) => const ResultsScreen(),
    ),
  ],

  redirect: (context, routerState) {
    final path = routerState.uri.path;
    final container = ProviderScope.containerOf(context);
    final auth = container.read(authProvider);

    // Not logged in — force to login (except if already there)
    if (!auth.isLoggedIn && path != '/login') {
      return '/login';
    }

    // Logged in — don't stay on login
    if (auth.isLoggedIn && path == '/login') {
      return '/matchmaking';
    }

    // Game routes require an active room
    const gameRoutes = ['/quiz', '/leaderboard', '/spectating', '/results'];
    if (gameRoutes.contains(path)) {
      final gameState = container.read(gameProvider);
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
    // Initialize auth client with the shared gRPC channel
    final channel = ref.watch(grpcChannelProvider);
    ref.read(authProvider.notifier).init(channel);

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
        seedColor: const Color(0xFFC96442),
        brightness: Brightness.dark,
        surface: const Color(0xFF1A1A2E),
        primary: const Color(0xFFC96442),
        secondary: const Color(0xFFFFB830),
      ),
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
          backgroundColor: const Color(0xFFC96442),
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
