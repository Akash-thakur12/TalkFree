import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';

/// POST `/api/twilio/provision-number` failed (non-200).
class ProvisionNumberException implements Exception {
  ProvisionNumberException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'ProvisionNumberException($statusCode): $message';
}

/// Premium-only: POST `/purchase-number` — server purchases [phoneNumber] (E.164) and updates Firestore.
class ProvisionNumberService {
  ProvisionNumberService._();
  static final ProvisionNumberService instance = ProvisionNumberService._();

  Future<void> provision({required String phoneNumber}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw ProvisionNumberException(401, 'Not signed in');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw ProvisionNumberException(401, 'Could not get Firebase ID token');
    }

    final uri = VoiceBackendConfig.provisionNumberUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{
            'phoneNumber': phoneNumber.trim(),
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (response.statusCode == 200) {
      return;
    }
    if (kDebugMode) {
      debugPrint('provision-number failed: ${response.statusCode} ${response.body}');
    }
    throw ProvisionNumberException(
      response.statusCode,
      _parseErrorBody(response.body),
    );
  }

  String _parseErrorBody(String body) {
    final t = body.trim();
    try {
      final j = jsonDecode(t);
      if (j is Map) {
        final m = j['message'];
        final err = j['error'];
        if (m != null && m.toString().isNotEmpty) return m.toString();
        if (err != null && err.toString().isNotEmpty) return err.toString();
      }
    } catch (_) {}
    if (t.isNotEmpty && t.length < 500) return t;
    return 'Could not claim this number. Please try again.';
  }
}
