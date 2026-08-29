import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';
import '../utils/user_facing_service_error.dart';

class RenewNumberException implements Exception {
  RenewNumberException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'RenewNumberException($statusCode): $message';
}

/// POST [VoiceBackendConfig.renewNumberUri] — extends `expiry_date` for the primary line.
class RenewNumberService {
  RenewNumberService._();
  static final RenewNumberService instance = RenewNumberService._();

  /// [mode] `ads` (requires server `number_renew_ad_progress`) or `credits`.
  Future<DateTime?> renew({required String mode}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Could not get Firebase ID token');
    }

    final uri = VoiceBackendConfig.renewNumberUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{'mode': mode}),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('renew-number failed: ${response.statusCode} ${response.body}');
      }
      throw RenewNumberException(
        response.statusCode,
        userFacingServiceError(_parseError(response.statusCode, response.body)),
      );
    }

    final j = jsonDecode(response.body) as Map<String, dynamic>?;
    final iso = (j?['expiry_date'] as String?)?.trim();
    if (iso == null || iso.isEmpty) return null;
    return DateTime.tryParse(iso);
  }

  String _parseError(int statusCode, String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final m = j['message'];
        final err = j['error'];
        if (m != null && m.toString().isNotEmpty) return m.toString();
        if (err != null) return err.toString();
      }
    } catch (_) {}
    final t = body.trim();
    if (t.isNotEmpty && t.length < 400) return t;
    return 'Renew failed (HTTP $statusCode).';
  }
}
