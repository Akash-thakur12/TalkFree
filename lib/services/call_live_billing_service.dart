import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/credits_policy.dart';
import '../config/voice_backend_config.dart';

class _PendingTick {
  _PendingTick({
    required this.callSid,
    required this.amount,
    required this.queuedAt,
  });

  final String callSid;
  final int amount;
  final DateTime queuedAt;
}

/// **Tier 1:** [postLiveTick] → `POST /call-live-tick` (server debits **1** credit per tick; body `amount` is legacy).
/// **Tier 2:** [runFinalSettlementWindow] + [syncCallBilling] → `POST /sync-call-billing`
/// (Twilio duration vs prepaid; idempotent). Twilio `/call-status` webhook is a backup if the app dies.
///
/// **Network:** Failed live ticks (likely offline) are queued and flushed on next success,
/// [flushPendingTicksForCall], or [runFinalSettlementWindow].
class CallLiveBillingService {
  CallLiveBillingService._();
  static final CallLiveBillingService instance = CallLiveBillingService._();

  static final List<_PendingTick> _pendingTicks = <_PendingTick>[];
  static const int _maxQueuedTicks = 80;
  static const Duration _maxTickAge = Duration(minutes: 20);

  Future<String?> _bearer() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    return user.getIdToken();
  }

  bool _isLikelyNetworkFailure(Object e) {
    return e is SocketException ||
        e is TimeoutException ||
        e is http.ClientException;
  }

  void _enqueueTick(String callSid, int amount) {
    final sid = callSid.trim();
    if (sid.isEmpty) return;
    if (amount != CreditsPolicy.creditsPerCallTick &&
        amount != CreditsPolicy.connectedLiveCreditPerTick) {
      return;
    }
    final now = DateTime.now();
    _pendingTicks.removeWhere(
      (t) => now.difference(t.queuedAt) > _maxTickAge,
    );
    _pendingTicks.add(
      _PendingTick(callSid: sid, amount: amount, queuedAt: now),
    );
    while (_pendingTicks.length > _maxQueuedTicks) {
      _pendingTicks.removeAt(0);
    }
    if (kDebugMode) {
      debugPrint('call-live-tick queued for retry: sid=$sid amount=$amount (queue=${_pendingTicks.length})');
    }
  }

  Future<bool> _postLiveTickHttp({
    required String callSid,
    required int amount,
    required String token,
  }) async {
    final r = await http
        .post(
          VoiceBackendConfig.callLiveTickUri(),
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, Object?>{
            'callSid': callSid,
            'amount': amount,
          }),
        )
        .timeout(const Duration(seconds: 12));
    return r.statusCode == 200;
  }

  /// Sends any queued ticks for [callSid] (e.g. after reconnect or before settlement).
  Future<int> flushPendingTicksForCall(String callSid) async {
    final sid = callSid.trim();
    if (sid.isEmpty) return 0;
    final token = await _bearer();
    if (token == null || token.isEmpty) return 0;

    var flushed = 0;
    for (var i = _pendingTicks.length - 1; i >= 0; i--) {
      final t = _pendingTicks[i];
      if (t.callSid != sid) continue;
      try {
        if (await _postLiveTickHttp(callSid: sid, amount: t.amount, token: token)) {
          _pendingTicks.removeAt(i);
          flushed++;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('flushPendingTicksForCall: $e');
        }
      }
    }
    if (flushed > 0 && kDebugMode) {
      debugPrint('flushPendingTicksForCall: flushed $flushed for $sid');
    }
    return flushed;
  }

  /// Sends a live billing tick; server always deducts one prepaid unit (see [CreditsPolicy] for allowed [amount] values).
  Future<bool> postLiveTick({
    required String callSid,
    required int amount,
  }) async {
    final sid = callSid.trim();
    if (sid.isEmpty) return false;
    final token = await _bearer();
    if (token == null || token.isEmpty) return false;

    await flushPendingTicksForCall(sid);

    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (await _postLiveTickHttp(callSid: sid, amount: amount, token: token)) {
          await flushPendingTicksForCall(sid);
          return true;
        }
        lastError = Exception('call-live-tick HTTP not 200');
      } catch (e) {
        lastError = e;
        if (kDebugMode) {
          debugPrint('call-live-tick error: $e');
        }
      }
      await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }

    if (lastError != null && _isLikelyNetworkFailure(lastError)) {
      _enqueueTick(sid, amount);
    }
    return false;
  }

  Future<bool> _postSyncCallBillingOnce(String sid, String token) async {
    final r = await http
        .post(
          VoiceBackendConfig.syncCallBillingUri(),
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{'callSid': sid}),
        )
        .timeout(const Duration(seconds: 20));
    return r.statusCode == 200;
  }

  /// Single reconciliation attempt (Twilio REST duration + Firestore settle).
  Future<bool> syncCallBilling(String callSid) async {
    final sid = callSid.trim();
    if (sid.isEmpty) return false;
    final token = await _bearer();
    if (token == null || token.isEmpty) return false;

    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        if (await _postSyncCallBillingOnce(sid, token)) return true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('sync-call-billing error: $e');
        }
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
    }
    return false;
  }

  /// **Sync protection:** after [hangUp], repeatedly POST `/sync-call-billing` for [window] so Twilio
  /// exposes final call duration and the server can settle (handles flaky network / slow Twilio).
  /// Flushes queued live ticks for this [callSid] first.
  /// Returns true if at least one request succeeded with HTTP 200.
  Future<bool> runFinalSettlementWindow({
    required String callSid,
    Duration window = const Duration(seconds: 5),
  }) async {
    final sid = callSid.trim();
    if (sid.isEmpty) return false;
    final token = await _bearer();
    if (token == null || token.isEmpty) return false;

    await flushPendingTicksForCall(sid);

    final deadline = DateTime.now().add(window);
    var anyOk = false;
    while (DateTime.now().isBefore(deadline)) {
      await flushPendingTicksForCall(sid);
      try {
        if (await _postSyncCallBillingOnce(sid, token)) {
          anyOk = true;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('runFinalSettlementWindow: $e');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 650));
    }
    await flushPendingTicksForCall(sid);
    return anyOk;
  }
}
