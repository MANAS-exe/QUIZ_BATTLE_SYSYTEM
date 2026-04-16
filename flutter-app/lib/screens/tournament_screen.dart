import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../services/auth_service.dart';
import '../theme/colors.dart';

final _host = defaultTargetPlatform == TargetPlatform.android ? '10.0.2.2' : 'localhost';

final _tournamentsProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final token = ref.watch(authProvider).token;
  if (token == null) return [];
  final resp = await http.get(
    Uri.parse('http://$_host:8080/tournament/list'),
    headers: {'Authorization': 'Bearer $token'},
  ).timeout(const Duration(seconds: 5));
  if (resp.statusCode == 200) {
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['tournaments'] as List?) ?? [];
  }
  return [];
});

class TournamentScreen extends ConsumerWidget {
  const TournamentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tournamentsAsync = ref.watch(_tournamentsProvider);
    final auth = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: appBg,
        foregroundColor: Colors.white,
        title: const Text('Tournaments', style: TextStyle(fontWeight: FontWeight.w700)),
        elevation: 0,
      ),
      body: tournamentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Failed to load tournaments', style: TextStyle(color: Colors.white38)),
        ),
        data: (tournaments) {
          if (tournaments.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.emoji_events_outlined, color: Colors.white.withValues(alpha: 0.15), size: 64),
                  const SizedBox(height: 16),
                  const Text('No tournaments yet', style: TextStyle(color: Colors.white38, fontSize: 16)),
                  const SizedBox(height: 6),
                  const Text('Check back soon!', style: TextStyle(color: Colors.white24, fontSize: 13)),
                ],
              ),
            );
          }

          final upcoming = tournaments.where((t) => t['status'] == 'upcoming').toList();
          final completed = tournaments.where((t) => t['status'] == 'completed').toList();

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (upcoming.isNotEmpty) ...[
                _SectionTitle(title: 'Upcoming', icon: Icons.schedule_rounded, color: appCoral),
                const SizedBox(height: 12),
                ...upcoming.map((t) => _TournamentCard(
                  tournament: t,
                  auth: auth,
                  onJoin: () => _joinTournament(context, ref, t['id'] as String? ?? ''),
                )),
              ],
              if (completed.isNotEmpty) ...[
                const SizedBox(height: 28),
                _SectionTitle(title: 'Completed', icon: Icons.check_circle_outline_rounded, color: Colors.green),
                const SizedBox(height: 12),
                ...completed.map((t) => _TournamentCard(tournament: t, auth: auth)),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _joinTournament(BuildContext context, WidgetRef ref, String tournamentId) async {
    final token = ref.read(authProvider).token;
    if (token == null) return;

    try {
      final resp = await http.post(
        Uri.parse('http://$_host:8080/tournament/join'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'tournament_id': tournamentId}),
      );
      final body = jsonDecode(resp.body) as Map<String, dynamic>;

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(body['message'] ?? body['error'] ?? 'Done'),
          backgroundColor: resp.statusCode == 200 ? Colors.green.shade700 : Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ));
      }
      ref.invalidate(_tournamentsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;

  const _SectionTitle({required this.title, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(
          color: color, fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.5,
        )),
      ],
    );
  }
}

class _TournamentCard extends StatelessWidget {
  final Map<String, dynamic> tournament;
  final AuthState auth;
  final VoidCallback? onJoin;

  const _TournamentCard({required this.tournament, required this.auth, this.onJoin});

  @override
  Widget build(BuildContext context) {
    final status = tournament['status'] as String? ?? '';
    final isUpcoming = status == 'upcoming';
    final isCompleted = status == 'completed';
    final premiumOnly = tournament['premium_only'] as bool? ?? false;
    final entryFee = tournament['entry_fee'] as int? ?? 0;
    final participants = (tournament['participants'] as List?)?.length ?? 0;
    final maxP = tournament['max_participants'] as int? ?? 0;
    final prizes = tournament['prizes'] as Map<String, dynamic>? ?? {};
    final startsAt = DateTime.tryParse(tournament['starts_at'] as String? ?? '')?.toLocal();

    // Check if current user already joined
    final myId = auth.userId ?? '';
    final alreadyJoined = (tournament['participants'] as List?)
        ?.any((p) => (p as Map<String, dynamic>)['user_id'] == myId) ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isCompleted
              ? [const Color(0xFF1A1A2E), const Color(0xFF0D0D1A)]
              : [const Color(0xFF1A1A2E), appCoral.withValues(alpha: 0.08)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isUpcoming ? appCoral.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Icon(
                isCompleted ? Icons.emoji_events_rounded : Icons.sports_esports_rounded,
                color: isCompleted ? appGold : appCoral,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tournament['name'] as String? ?? 'Tournament',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              if (premiumOnly)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: appGold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: appGold.withValues(alpha: 0.4)),
                  ),
                  child: Text('PRO', style: TextStyle(color: appGold, fontSize: 10, fontWeight: FontWeight.w800)),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Description
          Text(
            tournament['description'] as String? ?? '',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
          ),
          const SizedBox(height: 14),

          // Info pills
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _InfoPill(icon: Icons.people_rounded, text: '$participants / $maxP players'),
              _InfoPill(icon: Icons.quiz_rounded, text: '${tournament['rounds'] ?? 10} rounds'),
              if (startsAt != null)
                _InfoPill(icon: Icons.access_time_rounded, text: _formatDate(startsAt)),
              if (entryFee > 0)
                _InfoPill(icon: Icons.monetization_on_rounded, text: '$entryFee coins entry'),
              _InfoPill(icon: Icons.bar_chart_rounded, text: tournament['difficulty'] as String? ?? 'mixed'),
            ],
          ),

          // Prizes
          if (prizes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (prizes['first'] != null)
                  _PrizeBadge(label: '1st', coins: prizes['first'] as int, color: appGold),
                if (prizes['second'] != null) ...[
                  const SizedBox(width: 8),
                  _PrizeBadge(label: '2nd', coins: prizes['second'] as int, color: Colors.grey.shade400),
                ],
                if (prizes['third'] != null) ...[
                  const SizedBox(width: 8),
                  _PrizeBadge(label: '3rd', coins: prizes['third'] as int, color: const Color(0xFFCD7F32)),
                ],
              ],
            ),
          ],

          // Completed: show winner
          if (isCompleted && (tournament['participants'] as List?)?.isNotEmpty == true) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: appGold.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: appGold.withValues(alpha: 0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Results', style: TextStyle(color: appGold, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...(tournament['participants'] as List).take(3).map((p) {
                    final pp = p as Map<String, dynamic>;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          SizedBox(width: 24, child: Text('#${pp['rank']}',
                              style: const TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.w700))),
                          Text(pp['username'] as String? ?? '', style: const TextStyle(color: Colors.white, fontSize: 13)),
                          const Spacer(),
                          Text('${pp['score']} pts', style: TextStyle(color: appGold, fontSize: 12, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],

          // Join button
          if (isUpcoming) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: alreadyJoined ? null : onJoin,
                style: ElevatedButton.styleFrom(
                  backgroundColor: alreadyJoined ? Colors.green.shade800 : appCoral,
                  disabledBackgroundColor: Colors.green.shade800,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  alreadyJoined ? 'Registered' : 'Join Tournament',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = ['', 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.day} ${months[dt.month]} ${dt.year}, $h:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white38, size: 12),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }
}

class _PrizeBadge extends StatelessWidget {
  final String label;
  final int coins;
  final Color color;

  const _PrizeBadge({required this.label, required this.coins, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Icon(Icons.monetization_on_rounded, color: color, size: 12),
          const SizedBox(width: 2),
          Text('$coins', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
