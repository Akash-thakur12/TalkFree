import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';

/// POST `/grant-reward` body — exactly one reward per completed ad.
enum GrantRewardPurpose {
  call,
  number,
  otp,
}

extension GrantRewardPurposeApi on GrantRewardPurpose {
  /// Server `purpose` string.
  String get apiValue => name;
}

/// Result of POST `/grant-reward`.
class GrantRewardResult {
  const GrantRewardResult({
    required this.purpose,
    required this.creditsAdded,
    required this.baseCredits,
    required this.streakBonus,
    required this.streakCount,
    required this.adSubCounter,
    required this.adsWatchedToday,
    this.remainingDailyAds = 0,
    this.firstLifetimeAd = false,
    this.deduped = false,
    this.message,
    this.numberAdsProgress,
    this.otpAdsProgress,
  });

  final String purpose;
  final int creditsAdded;
  final int baseCredits;
  final int streakBonus;
  final int streakCount;
  final int adSubCounter;
  final int adsWatchedToday;
  final int remainingDailyAds;
  final bool firstLifetimeAd;
  /// Same [idempotencyKey] was already applied for this ad completion.
  final bool deduped;
  /// Server message when [deduped] (e.g. "Reward already granted").
  final String? message;
  final int? numberAdsProgress;
  final int? otpAdsProgress;
}

class GrantRewardException implements Exception {
  GrantRewardException(this.statusCode, this.message, {this.waitSeconds});

  final int statusCode;
  final String message;
  /// Server `waitSeconds` when HTTP 429 cooldown (optional).
  final int? waitSeconds;

  @override
  String toString() => 'GrantRewardException($statusCode): $message';
}

String _parseGrantRewardError(int statusCode, String body) {
  final t = body.trim();
  if (t.contains('<!DOCTYPE') ||
      t.contains('<html') ||
      t.contains('Cannot POST')) {
    return 'Rewards server unavailable (POST /grant-reward). '
        'Redeploy the Node API on Render with the latest server/index.js and FIREBASE_SERVICE_ACCOUNT_JSON.';
  }
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final err = j['error'];
      final m = j['message'];
      if (m != null && m.toString().isNotEmpty) {
        return m.toString();
      }
      if (err != null) return err.toString();
    }
  } catch (_) {}
  if (t.isNotEmpty && t.length < 300) return t;
  return 'Grant failed (HTTP $statusCode).';
}

String _newGrantIdempotencyKey() {
  final r = Random.secure();
  final bytes = List<int>.generate(24, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Secured reward: POST [VoiceBackendConfig.grantRewardUri] with Firebase ID token.
class GrantRewardService {
  GrantRewardService._();
  static final GrantRewardService instance = GrantRewardService._();

  /// Call once after each completed rewarded ad. [purpose] selects exactly one server reward.
  ///
  /// [adVerified] must be `true` only after the ad SDK reports a reward (e.g. `onUserEarnedReward`).
  Future<GrantRewardResult> requestMinuteGrant(
    GrantRewardPurpose purpose, {
    required bool adVerified,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Could not get Firebase ID token');
    }

    final idempotencyKey = _newGrantIdempotencyKey();
    final uri = VoiceBackendConfig.grantRewardUri();
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, dynamic>{
            'purpose': purpose.apiValue,
            'idempotencyKey': idempotencyKey,
            'adVerified': adVerified,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('grant-reward failed: ${response.statusCode} ${response.body}');
      }
      int? waitSeconds;
      try {
        final j = jsonDecode(response.body);
        if (j is Map && response.statusCode == 429) {
          waitSeconds = (j['waitSeconds'] as num?)?.toInt();
        }
      } catch (_) {}
      final msg = _parseGrantRewardError(response.statusCode, response.body);
      throw GrantRewardException(
        response.statusCode,
        msg,
        waitSeconds: waitSeconds,
      );
    }

    final j = jsonDecode(response.body) as Map<String, dynamic>?;
    final total = (j?['creditsAdded'] as num?)?.toInt() ?? 0;
    final base = (j?['baseCredits'] as num?)?.toInt();
    final streakB = (j?['streakBonus'] as num?)?.toInt() ?? 0;
    final streakC = (j?['streakCount'] as num?)?.toInt() ?? 0;
    final firstAd = j?['firstLifetimeAd'] == true;
    final deduped = j?['deduped'] == true;
    final grantMsg = (j?['message'] as String?)?.trim();
    final purposeStr = (j?['purpose'] as String?)?.trim() ?? purpose.apiValue;
    final numP = (j?['numberAdsProgress'] as num?)?.toInt();
    final otpP = (j?['otpAdsProgress'] as num?)?.toInt();
    return GrantRewardResult(
      purpose: purposeStr,
      creditsAdded: total,
      baseCredits: base ?? (total - streakB).clamp(0, total),
      streakBonus: streakB,
      streakCount: streakC,
      adSubCounter: (j?['adSubCounter'] as num?)?.toInt() ?? 0,
      adsWatchedToday: (j?['adsWatchedToday'] as num?)?.toInt() ?? 0,
      remainingDailyAds: (j?['remainingDailyAds'] as num?)?.toInt() ?? 0,
      firstLifetimeAd: firstAd,
      deduped: deduped,
      message: grantMsg?.isNotEmpty == true ? grantMsg : null,
      numberAdsProgress: numP,
      otpAdsProgress: otpP,
    );
  }
}
