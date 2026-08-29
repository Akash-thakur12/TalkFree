import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';

/// Sends SMS via Render **`POST /send-sms`** only (no direct Twilio REST from the app).
///
/// Endpoint: [VoiceBackendConfig.productionOrigin]`/send-sms` (e.g.
/// `https://talkfree-server.onrender.com/send-sms`).
Future<void> sendTwilioSMS(String recipientNumber, String messageBody) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    throw StateError('Not signed in');
  }

  final token = await user.getIdToken();
  if (token == null || token.isEmpty) {
    throw StateError('Could not get Firebase ID token — sign in again.');
  }

  final uri = VoiceBackendConfig.sendSmsUri();
  final origin = VoiceBackendConfig.baseUrl;

  if (kDebugMode) {
    debugPrint(
      'SMS: POST $uri (Authorization: Bearer <idToken>, base=$origin)',
    );
  }

  final payload = <String, String>{
    'to': recipientNumber,
    'body': messageBody,
  };

  try {
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(payload),
        )
        .timeout(
          const Duration(seconds: 45),
          onTimeout: () => throw TwilioSmsException(
            'SMS request timed out — check network and Render status.',
            statusCode: 0,
          ),
        );

    if (kDebugMode) {
      debugPrint('SMS: HTTP ${response.statusCode}');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw _exceptionFromHttpResponse(response);
  } on TwilioSmsException {
    rethrow;
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('SMS request error: $e\n$st');
    }
    rethrow;
  }
}

/// Maps JSON error bodies from `POST /send-sms` (especially HTTP **502** Twilio failures).
TwilioSmsException _exceptionFromHttpResponse(http.Response response) {
  final status = response.statusCode;
  Map<String, dynamic>? map;
  try {
    final j = jsonDecode(response.body);
    if (j is Map<String, dynamic>) {
      map = j;
    } else if (j is Map) {
      map = Map<String, dynamic>.from(j);
    }
  } catch (_) {}

  if (map != null) {
    final err = map['error']?.toString().trim() ?? '';
    final tw = map['twilioCode']?.toString();
    final more = map['moreInfo']?.toString();

    // Exact Twilio REST message is in `error` for 502; keep it front and center.
    final buffer = StringBuffer();
    if (tw != null && tw.isNotEmpty) {
      buffer.write('[$tw] ');
    }
    if (err.isNotEmpty) {
      buffer.write(err);
    } else {
      buffer.write('Request failed (HTTP $status)');
    }

    return TwilioSmsException(
      buffer.toString().trim(),
      statusCode: status,
      twilioCode: tw,
      moreInfo: more,
    );
  }

  final body = response.body;
  // Express default when the route is missing — production often lags repo deploy.
  if (status == 404 &&
      (body.contains('Cannot POST /send-sms') || body.contains('Cannot POST'))) {
    return TwilioSmsException(
      'SMS API not deployed (HTTP 404). Redeploy your Render service with the '
      'latest server that defines POST /send-sms, then retry. '
      'Endpoint: ${VoiceBackendConfig.sendSmsUri()}',
      statusCode: status,
    );
  }

  final clipped = body.length > 280 ? '${body.substring(0, 280)}…' : body;
  return TwilioSmsException(
    'SMS failed (HTTP $status): $clipped',
    statusCode: status,
  );
}

/// Thrown when `/send-sms` returns a non-2xx body (e.g. Twilio error on **502**).
class TwilioSmsException implements Exception {
  TwilioSmsException(
    this.message, {
    this.statusCode,
    this.twilioCode,
    this.moreInfo,
  });

  /// User-facing text (includes Twilio’s message when the backend forwards it).
  final String message;
  final int? statusCode;
  final String? twilioCode;
  final String? moreInfo;

  @override
  String toString() => message;
}
