import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';
import '../utils/user_facing_service_error.dart';

/// Shown when POST `/assign-number` returns 409 (number taken between list and purchase).
const String kAssignNumberTakenMessage =
    'Oops! This number was just taken. Please pick another one.';

/// Result of POST `/assign-number` (Twilio purchase + Firestore).
class AssignNumberResult {
  const AssignNumberResult({
    required this.assignedNumber,
    this.twilioIncomingPhoneSid,
    this.alreadyAssigned = false,
    this.planType,
    this.numberExpiryIso,
    this.creditsDeducted,
    this.newBalance,
  });

  final String assignedNumber;
  final String? twilioIncomingPhoneSid;
  final bool alreadyAssigned;
  final String? planType;
  final String? numberExpiryIso;
  final int? creditsDeducted;
  final int? newBalance;
}

class AssignNumberException implements Exception {
  AssignNumberException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'AssignNumberException($statusCode): $message';
}

String _parseError(int statusCode, String body) {
  final t = body.trim();
  if (t.contains('<!DOCTYPE') || t.contains('<html') || t.contains('Cannot POST')) {
    return 'Number server unavailable (POST /assign-number). '
        'Check API deployment and FIREBASE_SERVICE_ACCOUNT_JSON.';
  }
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final m = j['message'];
      final err = j['error'];
      if (m != null && m.toString().isNotEmpty) return m.toString();
      if (err != null) return err.toString();
    }
  } catch (_) {}
  if (t.isNotEmpty && t.length < 400) return t;
  return 'Assign number failed (HTTP $statusCode).';
}

String _userFacingAssignNumberError(int statusCode, String body) {
  if (statusCode == 409) {
    return kAssignNumberTakenMessage;
  }
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final err = j['error'];
      final code = j['code'];
      if (err == 'NUMBER_UNAVAILABLE' || code == 'NUMBER_UNAVAILABLE') {
        return kAssignNumberTakenMessage;
      }
      final m = j['message'];
      if (m != null && m.toString().isNotEmpty) {
        return m.toString();
      }
    }
  } catch (_) {}
  return _parseError(statusCode, body);
}

/// Secured: POST [VoiceBackendConfig.assignNumberUri] with Firebase ID token.
class AssignNumberService {
  AssignNumberService._();
  static final AssignNumberService instance = AssignNumberService._();

  /// [planType] must match server: `daily`, `weekly`, `monthly`, `yearly`.
  /// [phoneNumber] is E.164 from GET `/available-numbers` (user's choice).
  Future<AssignNumberResult> requestAssignNumber({
    required String phoneNumber,
    String planType = 'monthly',
    /// Server: `vip` (credits) or `premium` (Pro).
    String numberTier = 'vip',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Could not get Firebase ID token');
    }

    final uri = VoiceBackendConfig.assignNumberUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{
            'phoneNumber': phoneNumber.trim(),
            'planType': planType,
            'numberTier': numberTier,
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('assign-number failed: ${response.statusCode} ${response.body}');
      }
      throw AssignNumberException(
        response.statusCode,
        userFacingServiceError(
          _userFacingAssignNumberError(response.statusCode, response.body),
        ),
      );
    }

    final j = jsonDecode(response.body) as Map<String, dynamic>?;
    final assigned = (j?['assigned_number'] as String?)?.trim() ?? '';
    final sid = (j?['twilioIncomingPhoneSid'] as String?)?.trim();
    final already = j?['alreadyAssigned'] == true;
    if (assigned.isEmpty) {
      throw AssignNumberException(500, 'Invalid assign-number response');
    }
    final pt = j?['planType'] as String?;
    final ne = j?['number_expiry_date'] as String?;
    final cd = (j?['creditsDeducted'] as num?)?.toInt();
    final nb = (j?['newBalance'] as num?)?.toInt();
    return AssignNumberResult(
      assignedNumber: assigned,
      twilioIncomingPhoneSid: sid,
      alreadyAssigned: already,
      planType: pt,
      numberExpiryIso: ne,
      creditsDeducted: cd,
      newBalance: nb,
    );
  }
}
