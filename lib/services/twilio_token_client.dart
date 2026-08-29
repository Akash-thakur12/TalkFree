import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';

class TwilioTokenClient {
  TwilioTokenClient._();

  /// Fetches a Twilio Voice JWT; identity is always the signed-in Firebase uid (verified server-side).
  static Future<({String identity, String accessToken})> fetchAccessToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Could not get Firebase ID token');
    }
    final uri = VoiceBackendConfig.tokenUri();
    final res = await http
        .get(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $idToken',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'Voice token request failed (HTTP ${res.statusCode}).',
      );
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>?;
    final identity = data?['identity'] as String?;
    final token = data?['token'] as String?;
    if (identity == null || token == null || token.isEmpty) {
      throw StateError(
        'Invalid voice service response (missing identity or token).',
      );
    }
    return (identity: identity, accessToken: token);
  }
}
