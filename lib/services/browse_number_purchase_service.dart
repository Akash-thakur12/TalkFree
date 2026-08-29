import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';

class BrowseNumberPurchaseException implements Exception {
  BrowseNumberPurchaseException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'BrowseNumberPurchaseException($statusCode): $message';
}

/// Server-side credit deduction + Twilio purchase (no client Firestore credit writes).
class BrowseNumberPurchaseService {
  BrowseNumberPurchaseService._();
  static final BrowseNumberPurchaseService instance = BrowseNumberPurchaseService._();

  /// [price] must match server `BROWSE_NUMBER_PRICE` (default 150) and [VirtualNumber.defaultPrice].
  Future<void> purchaseNumber({
    required String phoneE164,
    required int price,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Could not get Firebase ID token');
    }
    final uri = VoiceBackendConfig.purchaseBrowseNumberUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, Object?>{
            'phoneNumber': phoneE164.trim(),
            'price': price,
          }),
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('purchase-browse-number: ${response.statusCode} ${response.body}');
      }
      throw BrowseNumberPurchaseException(
        response.statusCode,
        _parseError(response.body) ?? 'Purchase failed',
      );
    }
  }

  String? _parseError(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final m = j['message'];
        final e = j['error'];
        if (m != null && m.toString().isNotEmpty) return m.toString();
        if (e != null) return e.toString();
      }
    } catch (_) {}
    return null;
  }
}
