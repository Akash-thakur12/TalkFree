import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';

/// Server-side Twilio REST hang-up (Voice SDK + same Twilio account).
class TerminateCallService {
  TerminateCallService._();
  static final TerminateCallService instance = TerminateCallService._();

  Future<void> requestTerminate(String callSid) async {
    final sid = callSid.trim();
    if (sid.isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final token = await user.getIdToken();
    if (token == null || token.isEmpty) return;

    final uri = VoiceBackendConfig.terminateCallUri();
    await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{'callSid': sid}),
        )
        .timeout(const Duration(seconds: 15));
  }
}
