import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:http/http.dart' as http;

import '../services/auth_service.dart';
import '../theme/colors.dart';

// ─────────────────────────────────────────────────────────────
// Base URL — change to your server IP for physical device testing.
// 10.0.2.2 resolves to the host machine from an Android emulator.
// ─────────────────────────────────────────────────────────────
const _baseUrl = 'http://10.0.2.2:8081';

// ─────────────────────────────────────────────────────────────
// Providers
// ─────────────────────────────────────────────────────────────

final _subscriptionStatusProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final token = ref.watch(authProvider).token;
  if (token == null) return {'plan': 'free', 'is_active': false};
  final resp = await http.get(
    Uri.parse('$_baseUrl/payment/status'),
    headers: {'Authorization': 'Bearer $token'},
  );
  if (resp.statusCode == 200) {
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
  return {'plan': 'free', 'is_active': false};
});

final _paymentHistoryProvider =
    FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final token = ref.watch(authProvider).token;
  if (token == null) return [];
  final resp = await http.get(
    Uri.parse('$_baseUrl/payment/history'),
    headers: {'Authorization': 'Bearer $token'},
  );
  if (resp.statusCode == 200) {
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['payments'] as List?) ?? [];
  }
  return [];
});

// ─────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────

class PremiumScreen extends ConsumerStatefulWidget {
  const PremiumScreen({super.key});

  @override
  ConsumerState<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends ConsumerState<PremiumScreen> {
  late Razorpay _razorpay;
  bool _isLoading = false;
  Map<String, dynamic>? _lastOptions; // kept for retry after failure
  final _couponCtrl = TextEditingController();
  bool _couponApplied = false;
  bool _couponLoading = false;
  String? _couponError;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
  }

  @override
  void dispose() {
    _razorpay.clear();
    _couponCtrl.dispose();
    super.dispose();
  }

  // ── Razorpay callbacks ─────────────────────────────────────

  void _handlePaymentSuccess(PaymentSuccessResponse response) {
    // Defer to next event loop tick — same Activity-resume race as error handler.
    Future.delayed(Duration.zero, () async {
      if (!mounted) return;
      setState(() => _isLoading = true);
      await _verifyAndActivate(response);
    });
  }

  Future<void> _verifyAndActivate(PaymentSuccessResponse response) async {

    try {
      final auth = ref.read(authProvider);
      // Verify payment server-side with HMAC signature
      final verifyResp = await http.post(
        Uri.parse('$_baseUrl/payment/verify'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${auth.token}',
        },
        body: jsonEncode({
          'payment_id': response.paymentId ?? '',
          'order_id': response.orderId ?? '',
          'signature': response.signature ?? '',
        }),
      );

      if (verifyResp.statusCode != 200) {
        final body = jsonDecode(verifyResp.body) as Map<String, dynamic>;
        throw Exception(body['message'] ?? 'Verification failed');
      }

      // Server confirmed — update local state
      await ref.read(authProvider.notifier).setPremium(true);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Payment verification failed: $e'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    setState(() => _isLoading = false);

    // Invalidate cached providers so the UI refreshes
    ref.invalidate(_subscriptionStatusProvider);
    ref.invalidate(_paymentHistoryProvider);

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.workspace_premium_rounded, color: appGold, size: 28),
            const SizedBox(width: 10),
            const Text('Premium Activated!',
                style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          'Your payment was verified.\n\nPayment ID: ${response.paymentId ?? "—"}',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Awesome!', style: TextStyle(color: appGold)),
          ),
        ],
      ),
    );
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    // Defer the ENTIRE handler — including setState — to the next event loop
    // tick. The Razorpay Activity just closed; Android is still handing
    // control back to the Flutter Activity. Any synchronous Flutter UI call
    // (setState, showDialog, Navigator) at this exact moment crashes the app
    // because the engine hasn't finished resuming the widget tree yet.
    Future.delayed(Duration.zero, () {
      if (!mounted) return;

      setState(() => _isLoading = false);

      // User cancelled (code 0) — silent dismiss, no dialog needed
      if (response.code == Razorpay.PAYMENT_CANCELLED) return;

      final message = response.message ?? 'Something went wrong with your payment.';

      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 26),
              SizedBox(width: 10),
              Text('Payment Failed', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              Text(
                'Error code: ${response.code}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your account has not been charged. You can try again.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
            ),
            if (_lastOptions != null)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFC96442),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try Again'),
                onPressed: () {
                  Navigator.of(context).pop();
                  setState(() => _isLoading = true);
                  _razorpay.open(_lastOptions!);
                },
              ),
          ],
        ),
      );
    });
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    Future.delayed(Duration.zero, () {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('External wallet selected: ${response.walletName ?? ""}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  // ── Create order & open Razorpay checkout ─────────────────

  Future<void> _startPayment(String plan) async {
    final auth = ref.read(authProvider);
    if (auth.token == null) return;

    setState(() => _isLoading = true);

    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/payment/create-order'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${auth.token}',
        },
        body: jsonEncode({
          'plan': plan,
          if (_couponApplied && _couponCtrl.text.trim().isNotEmpty)
            'coupon_code': _couponCtrl.text.trim().toUpperCase(),
        }),
      );

      final body = jsonDecode(resp.body) as Map<String, dynamic>;

      if (resp.statusCode != 200) {
        throw Exception(body['message'] ?? 'Failed to create order');
      }

      final options = {
        'key': body['key_id'] as String,
        'amount': body['amount'] as int,
        'currency': body['currency'] as String? ?? 'INR',
        'order_id': body['order_id'] as String,
        'name': 'Quiz Battle Premium',
        'description': plan == 'yearly'
            ? 'Yearly Plan — ₹3,999/year'
            : 'Monthly Plan — ₹499/month',
        'prefill': {
          'contact': '9876543210',
          'email': auth.email ?? 'user@quizbattle.com',
          'name': body['username'] as String? ?? '',
          'method': 'upi', // Pre-select UPI as default method
        },
        'upi': {
          'flow': 'collect', // Forces UPI collect flow (enter VPA) — works without UPI apps
        },
        'theme': {'color': '#C96442'},
      };

      _lastOptions = options;
      _razorpay.open(options);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final statusAsync = ref.watch(_subscriptionStatusProvider);
    final historyAsync = ref.watch(_paymentHistoryProvider);

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: appBg,
        foregroundColor: Colors.white,
        title: const Text('Premium Plans',
            style: TextStyle(fontWeight: FontWeight.w700)),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Opening payment...', style: TextStyle(color: Colors.white70)),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Current plan status card
                statusAsync.when(
                  loading: () => const SizedBox(
                    height: 80,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (status) => _CurrentPlanCard(
                    plan: status['plan'] as String? ?? 'free',
                    expiresAt: status['expires_at'] as String?,
                    isActive: status['is_active'] as bool? ?? false,
                  ),
                ),
                const SizedBox(height: 24),

                // Feature comparison table
                const _FeatureComparisonTable(),
                const SizedBox(height: 28),

                // Plan buttons — only show if not already premium
                if (!auth.isPremium) ...[
                  // Coupon code section
                  _CouponSection(
                    controller: _couponCtrl,
                    applied: _couponApplied,
                    loading: _couponLoading,
                    error: _couponError,
                    onApply: () async {
                      final code = _couponCtrl.text.trim().toUpperCase();
                      if (code.isEmpty) {
                        setState(() => _couponError = "Enter a friend's referral code");
                        return;
                      }
                      setState(() { _couponLoading = true; _couponError = null; });
                      try {
                        final token = ref.read(authProvider).token;
                        final resp = await http.get(
                          Uri.parse('$_baseUrl/payment/validate-coupon?code=$code'),
                          headers: {'Authorization': 'Bearer $token'},
                        );
                        final body = jsonDecode(resp.body) as Map<String, dynamic>;
                        if (!mounted) return;
                        setState(() {
                          _couponLoading = false;
                          _couponApplied = body['valid'] == true;
                          _couponError = body['valid'] == true ? null : body['message'] as String?;
                        });
                      } catch (_) {
                        if (!mounted) return;
                        setState(() {
                          _couponLoading = false;
                          _couponError = 'Could not validate code. Check your connection.';
                        });
                      }
                    },
                    onRemove: () => setState(() {
                      _couponApplied = false;
                      _couponError = null;
                      _couponCtrl.clear();
                    }),
                  ),
                  const SizedBox(height: 16),
                  _PlanButton(
                    label: 'Monthly Plan',
                    price: _couponApplied ? '₹399' : '₹499',
                    originalPrice: _couponApplied ? '₹499' : null,
                    period: '/month',
                    highlight: false,
                    onTap: _isLoading ? null : () => _startPayment('monthly'),
                  ),
                  const SizedBox(height: 14),
                  _PlanButton(
                    label: 'Yearly Plan',
                    price: _couponApplied ? '₹3,499' : '₹3,999',
                    originalPrice: _couponApplied ? '₹3,999' : null,
                    period: '/year',
                    subtitle: _couponApplied
                        ? 'Save ₹2,500 vs monthly'
                        : 'Save ₹2,000 vs monthly',
                    highlight: true,
                    onTap: _isLoading ? null : () => _startPayment('yearly'),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Secure payment via Razorpay · Cancel anytime',
                      style: TextStyle(
                          fontSize: 12, color: Colors.white.withValues(alpha: 0.4)),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],

                // Payment history
                historyAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (payments) => payments.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 20),
                          child: Column(
                            children: [
                              Icon(Icons.receipt_long_rounded, color: Colors.white.withValues(alpha: 0.15), size: 48),
                              const SizedBox(height: 10),
                              Text('No payment history yet',
                                  style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 13)),
                            ],
                          ),
                        )
                      : _PaymentHistorySection(payments: payments),
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Current Plan Card
// ─────────────────────────────────────────────────────────────

class _CurrentPlanCard extends StatelessWidget {
  final String plan;
  final String? expiresAt;
  final bool isActive;

  const _CurrentPlanCard({
    required this.plan,
    required this.expiresAt,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final isPremium = isActive && plan != 'free';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isPremium
              ? [const Color(0xFF2A1A00), appGold.withValues(alpha: 0.15)]
              : [const Color(0xFF1A1A2E), const Color(0xFF0D0D1A)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isPremium
              ? appGold.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isPremium
                ? Icons.workspace_premium_rounded
                : Icons.person_outline_rounded,
            color: isPremium ? appGold : Colors.white54,
            size: 40,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPremium ? 'Premium Member' : 'Free Plan',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isPremium ? appGold : Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                if (isPremium && expiresAt != null)
                  Text(
                    'Active until ${_formatDate(expiresAt!)}',
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  )
                else if (!isPremium)
                  const Text(
                    '5 free games per day',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day} ${_month(dt.month)} ${dt.year}';
    } catch (_) {
      return iso;
    }
  }

  String _month(int m) => const [
        '',
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ][m];
}

// ─────────────────────────────────────────────────────────────
// Feature Comparison Table
// ─────────────────────────────────────────────────────────────

class _FeatureComparisonTable extends StatelessWidget {
  const _FeatureComparisonTable();

  static const _features = [
    ('Daily games', '5 / day', 'Unlimited'),
    ('Spectate matches', 'No', 'Yes'),
    ('Global leaderboard', 'Top 3 only', 'Full rankings'),
    ('Priority matchmaking', 'No', 'Yes'),
    ('Detailed stats', 'Basic', 'Advanced'),
    ('Ad-free experience', 'No', 'Yes'),
    ('Badge & profile flair', 'No', 'Yes'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          // Header row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: Row(
              children: [
                const Expanded(
                  flex: 3,
                  child: Text('Feature',
                      style: TextStyle(
                          color: Colors.white54,
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                ),
                Expanded(
                  flex: 2,
                  child: Center(
                    child: Text('Free',
                        style: TextStyle(
                            color: Colors.white54,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Center(
                    child: Text('Premium',
                        style: TextStyle(
                            color: appGold,
                            fontWeight: FontWeight.w700,
                            fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
          // Feature rows
          ..._features.asMap().entries.map((entry) {
            final i = entry.key;
            final (feature, free, premium) = entry.value;
            final isLast = i == _features.length - 1;
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: isLast
                    ? null
                    : Border(
                        bottom: BorderSide(
                            color: Colors.white.withValues(alpha: 0.06))),
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(feature,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Center(
                      child: Text(free,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12)),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Center(
                      child: Text(premium,
                          style: TextStyle(
                              color: appGold,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Coupon Section
// ─────────────────────────────────────────────────────────────

class _CouponSection extends StatelessWidget {
  final TextEditingController controller;
  final bool applied;
  final bool loading;
  final String? error;
  final VoidCallback onApply;
  final VoidCallback onRemove;

  const _CouponSection({
    required this.controller,
    required this.applied,
    required this.loading,
    required this.error,
    required this.onApply,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        // Applied success state
        if (applied)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF2ECC71).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFF2ECC71).withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: Color(0xFF2ECC71), size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Coupon applied! Save ₹100 on Monthly · ₹500 on Yearly',
                    style: TextStyle(
                        color: Color(0xFF2ECC71),
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                GestureDetector(
                  onTap: onRemove,
                  child: const Icon(Icons.close_rounded,
                      color: Color(0xFF2ECC71), size: 18),
                ),
              ],
            ),
          )
        else ...[
          // Input row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: "Got a referral? Enter code",
                    hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.25),
                        fontSize: 13,
                        letterSpacing: 0,
                        fontWeight: FontWeight.w400),
                    prefixIcon: Icon(Icons.local_offer_rounded,
                        color: Colors.white38, size: 18),
                    filled: true,
                    fillColor: const Color(0xFF1A1A2E),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                          color: error != null
                              ? Colors.redAccent.withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          BorderSide(color: appGold.withValues(alpha: 0.7)),
                    ),
                  ),
                  onSubmitted: (_) => onApply(),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: loading ? null : onApply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: appGold,
                  disabledBackgroundColor: appGold.withValues(alpha: 0.5),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.black54, strokeWidth: 2),
                      )
                    : const Text('Apply',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(error!,
                style: const TextStyle(
                    color: Colors.redAccent, fontSize: 12)),
          ],
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Plan Button
// ─────────────────────────────────────────────────────────────

class _PlanButton extends StatelessWidget {
  final String label;
  final String price;
  final String? originalPrice; // non-null when a discount is active
  final String period;
  final String? subtitle;
  final bool highlight;
  final VoidCallback? onTap;

  const _PlanButton({
    required this.label,
    required this.price,
    this.originalPrice,
    required this.period,
    this.subtitle,
    required this.highlight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          gradient: highlight
              ? LinearGradient(
                  colors: [appGold.withValues(alpha: 0.9), const Color(0xFFFF8C00)],
                )
              : null,
          color: highlight ? null : const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: highlight ? Colors.transparent : Colors.white.withValues(alpha: 0.12),
            width: 1.5,
          ),
          boxShadow: highlight
              ? [
                  BoxShadow(
                    color: appGold.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  )
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              highlight
                  ? Icons.bolt_rounded
                  : Icons.calendar_month_rounded,
              color: highlight ? Colors.black : Colors.white70,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: highlight ? Colors.black : Colors.white,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 11,
                        color: highlight
                            ? Colors.black54
                            : Colors.white38,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (originalPrice != null)
                  Text(
                    originalPrice!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: highlight ? Colors.black38 : Colors.white30,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: highlight ? Colors.black38 : Colors.white30,
                    ),
                  ),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: price,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: highlight ? Colors.black : Colors.white,
                        ),
                      ),
                      TextSpan(
                        text: period,
                        style: TextStyle(
                          fontSize: 12,
                          color: highlight ? Colors.black54 : Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Payment History Section
// ─────────────────────────────────────────────────────────────

class _PaymentHistorySection extends StatelessWidget {
  final List<dynamic> payments;
  const _PaymentHistorySection({required this.payments});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Payment History',
          style: TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        ...payments.map((p) {
          final payment = p as Map<String, dynamic>;
          final status = payment['status'] as String? ?? 'unknown';
          final amount = (payment['amount'] as num?)?.toInt() ?? 0;
          final plan = payment['plan'] as String? ?? '';
          final createdAt = payment['created_at'] as String? ?? '';

          Color statusColor;
          IconData statusIcon;
          switch (status) {
            case 'captured':
              statusColor = Colors.green;
              statusIcon = Icons.check_circle_outline_rounded;
              break;
            case 'failed':
              statusColor = Colors.red;
              statusIcon = Icons.cancel_outlined;
              break;
            default:
              statusColor = Colors.orange;
              statusIcon = Icons.hourglass_empty_rounded;
          }

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            child: Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${plan[0].toUpperCase()}${plan.substring(1)} Plan',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                      ),
                      Text(
                        _formatDate(createdAt),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '₹${(amount / 100).toStringAsFixed(0)}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15),
                    ),
                    Text(
                      status.toUpperCase(),
                      style: TextStyle(
                          color: statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day} ${_month(dt.month)} ${dt.year}';
    } catch (_) {
      return iso;
    }
  }

  String _month(int m) => const [
        '',
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ][m];
}
