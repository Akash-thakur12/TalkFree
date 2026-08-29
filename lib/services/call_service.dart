import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../config/credits_policy.dart';
import 'firestore_user_service.dart';
import 'terminate_call_service.dart';

/// In-call monitoring: estimated charge = ceil(elapsed min) × [CreditsPolicy.callCreditsPerBilledMinute].
/// Actual deduction happens on the server via Twilio `/call-status` when the call completes.
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  static const int _maxBalanceCheckRetries = 6;

  Timer? _timer;
  String? _uid;
  String? _twilioCallSid;
  DateTime? _callStartTime;
  VoidCallback? _onInsufficientCredits;
  void Function(String message)? _onError;
  Future<void> Function()? _hangUpActiveCall;
  bool _enforceBalanceChecks = true;

  bool get isBillingActive => _timer != null;

  bool _isRetriable(Object e) {
    if (e is FirebaseException) {
      switch (e.code) {
        case 'unavailable':
        case 'deadline-exceeded':
        case 'resource-exhausted':
        case 'aborted':
          return true;
      }
    }
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    return false;
  }

  /// Same as server: ceil(elapsedSeconds / 60).
  static int billedMinutesFromElapsedSeconds(int elapsedSec) {
    if (elapsedSec <= 0) return 0;
    return (elapsedSec + 59) ~/ 60;
  }

  static int creditsNeededForElapsedSeconds(int elapsedSec) {
    return billedMinutesFromElapsedSeconds(elapsedSec) *
        CreditsPolicy.callCreditsPerBilledMinute;
  }

  /// Set when Twilio exposes the active Call SID (after ringing).
  void setActiveCallSid(String? sid) {
    final t = sid?.trim();
    _twilioCallSid = (t != null && t.isNotEmpty) ? t : _twilioCallSid;
  }

  Future<void> _terminateTwilioCallIfPossible() async {
    final sid = _twilioCallSid;
    if (sid == null || sid.isEmpty) return;
    try {
      await TerminateCallService.instance.requestTerminate(sid);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('TerminateCallService: $e');
      }
    }
  }

  Future<void> _shutdownForInsufficientCredits() async {
    final cb = _onInsufficientCredits;
    final hangUp = _hangUpActiveCall;
    _clearTimerOnly();
    _uid = null;
    _twilioCallSid = null;
    _callStartTime = null;
    _onInsufficientCredits = null;
    _onError = null;
    _hangUpActiveCall = null;

    await _terminateTwilioCallIfPossible();

    if (hangUp != null) {
      try {
        await hangUp();
      } catch (_) {}
    }
    cb?.call();
  }

  void _clearTimerOnly() {
    _timer?.cancel();
    _timer = null;
  }

  /// Stops monitoring; does not hang up (calling UI handles hang up).
  void stopBilling() {
    _clearTimerOnly();
    _uid = null;
    _twilioCallSid = null;
    _callStartTime = null;
    _onInsufficientCredits = null;
    _onError = null;
    _hangUpActiveCall = null;
  }

  Future<void> _runOneBalanceCheck() async {
    final uid = _uid;
    final start = _callStartTime;
    if (uid == null || start == null) return;
    if (!_enforceBalanceChecks) return;

    final elapsedSec = DateTime.now().difference(start).inSeconds;
    final needed = creditsNeededForElapsedSeconds(elapsedSec);

    for (var attempt = 0; attempt < _maxBalanceCheckRetries; attempt++) {
      try {
        final balance = await FirestoreUserService.fetchUsableCredits(uid);
        if (balance < needed) {
          await _shutdownForInsufficientCredits();
          return;
        }
        return;
      } catch (e) {
        if (!_isRetriable(e) || attempt == _maxBalanceCheckRetries - 1) {
          if (kDebugMode) {
            debugPrint('CallService balance check failed: $e');
          }
          _onError?.call('$e');
          return;
        }
        await Future<void>.delayed(Duration(milliseconds: 250 * (1 << attempt)));
      }
    }
  }

  void startBilling({
    required String uid,
    String? twilioCallSid,
    Future<void> Function()? hangUpActiveCall,
    required VoidCallback onInsufficientCredits,
    void Function(String message)? onError,
    bool enforceBalanceChecks = true,
  }) {
    _timer?.cancel();
    _timer = null;

    _enforceBalanceChecks = enforceBalanceChecks;
    _uid = uid;
    _twilioCallSid = twilioCallSid?.trim().isNotEmpty == true ? twilioCallSid!.trim() : null;
    _callStartTime = DateTime.now();
    _hangUpActiveCall = hangUpActiveCall;
    _onInsufficientCredits = onInsufficientCredits;
    _onError = onError;

    if (enforceBalanceChecks) {
      unawaited(_runOneBalanceCheck());

      _timer = Timer.periodic(CreditsPolicy.callBalanceCheckInterval, (_) {
        unawaited(_runOneBalanceCheck());
      });
    }
  }

  /// After app resume — run an immediate balance check when enforcement is on.
  Future<void> syncAfterAppResumed() async {
    if (_uid == null || _callStartTime == null) return;
    if (!_enforceBalanceChecks) return;
    await _runOneBalanceCheck();
  }
}

/// Normalizes dialer input to E.164. Without a leading `+`, uses [defaultCallingCode]
/// (e.g. `91` for India, `1` for US).
String formatDialInputToE164(
  String raw, {
  String defaultCallingCode = '91',
}) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  if (t.startsWith('+')) {
    final d = t.substring(1).replaceAll(RegExp(r'\D'), '');
    return d.isEmpty ? '' : '+$d';
  }
  final d = t.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return '';
  return '+$defaultCallingCode$d';
}
