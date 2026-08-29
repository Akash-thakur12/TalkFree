import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';

/// Server-created Razorpay Order (amount in smallest currency unit).
class SubscriptionOrderResponse {
  const SubscriptionOrderResponse({
    required this.orderId,
    required this.amount,
    required this.currency,
    required this.keyId,
    this.planKey,
  });

  final String orderId;
  final int amount;
  final String currency;
  final String keyId;
  /// Set for `POST /purchase-credits-pack` (Razorpay order `notes.plan_key`).
  final String? planKey;
}

class SubscriptionPaymentException implements Exception {
  SubscriptionPaymentException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'SubscriptionPaymentException($statusCode): $message';
}

/// Parsed JSON from `POST /verify-payment`.
class VerifyPaymentResult {
  const VerifyPaymentResult({
    this.plan,
    this.welcomeBonusCredits = 0,
    this.starterCreditsAdded = 0,
    this.creditPackCreditsAdded = 0,
    this.idempotent = false,
  });

  final String? plan;
  final int welcomeBonusCredits;
  final int starterCreditsAdded;
  /// Credits from `credit_pack_*` verify (paid balance).
  final int creditPackCreditsAdded;
  final bool idempotent;
}

/// Razorpay Checkout → server verification only (no client Firestore premium writes).
class SubscriptionPaymentService {
  SubscriptionPaymentService._();
  static final SubscriptionPaymentService instance = SubscriptionPaymentService._();

  Future<String?> _bearer() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    return user.getIdToken();
  }

  /// Creates a Razorpay Order for [planKey] (`daily`…`yearly`). Opens Checkout with [orderId].
  Future<SubscriptionOrderResponse> createSubscriptionOrder(String planKey) async {
    final token = await _bearer();
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final uri = VoiceBackendConfig.createSubscriptionOrderUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{'plan': planKey}),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('create-subscription-order: ${response.statusCode} ${response.body}');
      }
      throw SubscriptionPaymentException(
        response.statusCode,
        _parseError(response.body) ?? 'Could not create order',
      );
    }
    final j = jsonDecode(response.body) as Map<String, dynamic>;
    return SubscriptionOrderResponse(
      orderId: j['orderId'] as String,
      amount: (j['amount'] as num).toInt(),
      currency: j['currency'] as String,
      keyId: j['keyId'] as String,
      planKey: j['planKey'] as String?,
    );
  }

  /// Razorpay order for a credit pack (`small` | `medium` | `large`). Verify with [verifyPayment].
  Future<SubscriptionOrderResponse> createCreditsPackOrder(String pack) async {
    final token = await _bearer();
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final uri = VoiceBackendConfig.purchaseCreditsPackUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{'pack': pack}),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('purchase-credits-pack: ${response.statusCode} ${response.body}');
      }
      throw SubscriptionPaymentException(
        response.statusCode,
        _parseError(response.body) ?? 'Could not create pack order',
      );
    }
    final j = jsonDecode(response.body) as Map<String, dynamic>;
    return SubscriptionOrderResponse(
      orderId: j['orderId'] as String,
      amount: (j['amount'] as num).toInt(),
      currency: j['currency'] as String,
      keyId: j['keyId'] as String,
      planKey: j['planKey'] as String?,
    );
  }

  /// After Razorpay success callback — server verifies HMAC and sets Pro in Firestore (Admin only).
  Future<VerifyPaymentResult> verifyPayment({
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
  }) async {
    final token = await _bearer();
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final uri = VoiceBackendConfig.verifyPaymentUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{
            'razorpay_payment_id': razorpayPaymentId,
            'razorpay_order_id': razorpayOrderId,
            'razorpay_signature': razorpaySignature,
          }),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('verify-payment: ${response.statusCode} ${response.body}');
      }
      throw SubscriptionPaymentException(
        response.statusCode,
        _parseError(response.body) ?? 'Verification failed',
      );
    }
    final j = jsonDecode(response.body);
    if (j is! Map<String, dynamic>) {
      return const VerifyPaymentResult();
    }
    final plan = j['plan'] as String?;
    final welcome = (j['welcomeBonus'] as num?)?.toInt() ?? 0;
    final starter = (j['starterCreditsAdded'] as num?)?.toInt() ?? 0;
    final packCredits = (j['creditPackCreditsAdded'] as num?)?.toInt() ?? 0;
    final idem = j['idempotent'] == true;
    return VerifyPaymentResult(
      plan: plan,
      welcomeBonusCredits: welcome,
      starterCreditsAdded: starter,
      creditPackCreditsAdded: packCredits,
      idempotent: idem,
    );
  }

  /// Best-effort monthly premium credit grant (server enforces cadence).
  Future<void> tryClaimPremiumMonthlyBonus() async {
    final token = await _bearer();
    if (token == null || token.isEmpty) return;
    try {
      final r = await http
          .post(
            VoiceBackendConfig.claimPremiumMonthlyBonusUri(),
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json; charset=utf-8',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (kDebugMode && r.statusCode != 200) {
        debugPrint('claim-premium-monthly-bonus: ${r.statusCode} ${r.body}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('tryClaimPremiumMonthlyBonus: $e');
      }
    }
  }

  String? _parseError(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] != null) return j['error'].toString();
    } catch (_) {}
    return null;
  }
}
