import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';
import '../utils/user_facing_service_error.dart';
import 'assign_number_service.dart';

String _parseError(int statusCode, String body) {
  final t = body.trim();
  if (t.contains('<!DOCTYPE') || t.contains('<html') || t.contains('Cannot POST')) {
    return 'Number server unavailable. Check API deployment and Firebase configuration.';
  }
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final m = j['message'];
      final err = j['error'];
      final detail = j['detail'];
      if (m != null && m.toString().isNotEmpty) return m.toString();
      if (detail != null && detail.toString().isNotEmpty) return detail.toString();
      if (err != null) return err.toString();
    }
  } catch (_) {}
  if (t.isNotEmpty && t.length < 400) return t;
  return 'Could not assign a free number (HTTP $statusCode).';
}

String _userFacing(int statusCode, String body) {
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

/// Secured: POST [VoiceBackendConfig.assignFreeNumberUri] with Firebase ID token.
class AssignFreeNumberService {
  AssignFreeNumberService._();
  static final AssignFreeNumberService instance = AssignFreeNumberService._();

  /// [planType] must match server: `daily`, `weekly`, `monthly`, `yearly`.
  Future<AssignNumberResult> requestAssignFreeNumber({
    String planType = 'monthly',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Could not get Firebase ID token');
    }

    final uri = VoiceBackendConfig.assignFreeNumberUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{'planType': planType}),
        )
        .timeout(const Duration(seconds: 90));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('assign-free-number failed: ${response.statusCode} ${response.body}');
      }
      throw AssignNumberException(
        response.statusCode,
        userFacingServiceError(
          _userFacing(response.statusCode, response.body),
        ),
      );
    }

    final j = jsonDecode(response.body) as Map<String, dynamic>?;
    final assigned = (j?['assigned_number'] as String?)?.trim() ?? '';
    final sid = (j?['twilioIncomingPhoneSid'] as String?)?.trim();
    final already = j?['alreadyAssigned'] == true;
    if (assigned.isEmpty) {
      throw AssignNumberException(500, 'Invalid assign-free-number response');
    }
    final pt = j?['planType'] as String? ?? j?['number_plan_type'] as String?;
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
