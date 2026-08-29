import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/credits_policy.dart';
import '../config/voice_backend_config.dart';
import '../screens/subscription_screen.dart';
import '../services/firestore_user_service.dart';
import 'monetization_copy.dart';

const _kLastShownMs = 'talkfree_soft_paywall_last_shown_ms';
const _kLastShownUid = 'talkfree_soft_paywall_last_shown_uid';
const _kFatigueBlockMs = 'talkfree_paywall_fatigue_block_ms';
const _kNoIntentStreak = 'talkfree_paywall_no_intent_streak';
const _kImprTs7d = 'talkfree_paywall_impr_ts_7d_v1';

/// One soft paywall per app process per uid (session cap).
final Set<String> _softPaywallSessionShownUid = <String>{};

class PaywallRemoteUi {
  const PaywallRemoteUi({
    required this.variant,
    required this.lifetimeAdsThreshold,
    required this.priceLabel,
    required this.saveVsAdsHint,
    required this.ctaLabel,
  });

  final String variant;
  final int lifetimeAdsThreshold;
  final String priceLabel;
  final String saveVsAdsHint;
  final String ctaLabel;
}

PaywallRemoteUi? _paywallCache;
DateTime? _paywallCacheAt;

Future<PaywallRemoteUi> _loadPaywallUi() async {
  final now = DateTime.now();
  if (_paywallCache != null &&
      _paywallCacheAt != null &&
      now.difference(_paywallCacheAt!) < const Duration(minutes: 5)) {
    return _paywallCache!;
  }
  try {
    final headers = <String, String>{'Accept': 'application/json'};
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser != null) {
      final token = await authUser.getIdToken();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    final r = await http
        .get(VoiceBackendConfig.paywallConfigUri(), headers: headers)
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) throw StateError('paywall-config ${r.statusCode}');
    final j = jsonDecode(r.body);
    if (j is! Map) throw StateError('paywall-config body');
    final bucket = (j['metricBucket'] as String?)?.trim();
    final v = PaywallRemoteUi(
      variant: bucket ?? (j['variant'] as String?)?.trim() ?? 'A',
      lifetimeAdsThreshold: (j['lifetimeAdsThreshold'] as num?)?.toInt() ??
          CreditsPolicy.softPaywallLifetimeAdsThreshold,
      priceLabel: (j['priceLabel'] as String?)?.trim() ?? '₹59',
      saveVsAdsHint: (j['saveVsAdsHint'] as String?)?.trim() ?? '',
      ctaLabel: (j['ctaLabel'] as String?)?.trim() ?? MonetizationCopy.softPaywallPrimaryCta,
    );
    _paywallCache = v;
    _paywallCacheAt = now;
    return v;
  } catch (_) {
    final fallback = PaywallRemoteUi(
      variant: 'A',
      lifetimeAdsThreshold: CreditsPolicy.softPaywallLifetimeAdsThreshold,
      priceLabel: '₹59',
      saveVsAdsHint: '',
      ctaLabel: MonetizationCopy.softPaywallPrimaryCta,
    );
    _paywallCache = fallback;
    _paywallCacheAt = now;
    return fallback;
  }
}

String _grantListKey(String uid) => 'talkfree_soft_paywall_grants_v1_$uid';

String _newPaywallEventId() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Call after a successful (non-deduped) `/grant-reward` so burst-window gating can count recent activity.
Future<void> recordSoftPaywallGrantSuccess() async {
  final u = FirebaseAuth.instance.currentUser;
  if (u == null) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final key = _grantListKey(u.uid);
    final raw = prefs.getString(key);
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = <int>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final dec = jsonDecode(raw);
        if (dec is List) {
          for (final e in dec) {
            if (e is int) {
              list.add(e);
            } else if (e is num) {
              list.add(e.toInt());
            }
          }
        }
      } catch (_) {}
    }
    list.add(now);
    final cutoff = now - CreditsPolicy.softPaywallBurstWindowMinutes * 60 * 1000;
    final pruned = list.where((t) => t >= cutoff).take(20).toList();
    await prefs.setString(key, jsonEncode(pruned));
  } catch (_) {}
}

Future<void> _setPaywallLastShown(String uid) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kLastShownMs, DateTime.now().millisecondsSinceEpoch);
  await prefs.setString(_kLastShownUid, uid);
}

Future<bool> _canShowSoftPaywallByCooldown(String uid) async {
  final prefs = await SharedPreferences.getInstance();
  final lastUid = prefs.getString(_kLastShownUid) ?? '';
  final lastMs = prefs.getInt(_kLastShownMs) ?? 0;
  if (lastUid != uid || lastMs <= 0) return true;
  final age = DateTime.now().millisecondsSinceEpoch - lastMs;
  return age >= CreditsPolicy.softPaywallCooldownHours * 60 * 60 * 1000;
}

Future<bool> _fatigueBlocked() async {
  final prefs = await SharedPreferences.getInstance();
  final until = prefs.getInt(_kFatigueBlockMs) ?? 0;
  if (until <= 0) return false;
  return DateTime.now().millisecondsSinceEpoch < until;
}

Future<void> _setFatigueBlock48h() async {
  final prefs = await SharedPreferences.getInstance();
  final until =
      DateTime.now().millisecondsSinceEpoch + const Duration(hours: 48).inMilliseconds;
  await prefs.setInt(_kFatigueBlockMs, until);
}

Future<void> _resetNoIntentStreak() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kNoIntentStreak, 0);
}

Future<void> _onPaywallDismissedWithoutIntent() async {
  final prefs = await SharedPreferences.getInstance();
  final s = (prefs.getInt(_kNoIntentStreak) ?? 0) + 1;
  await prefs.setInt(_kNoIntentStreak, s);
  if (s >= 3) {
    await _setFatigueBlock48h();
    await prefs.setInt(_kNoIntentStreak, 0);
  }
}

Future<List<int>> _readImpressionTs7d() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kImprTs7d);
  if (raw == null || raw.isEmpty) return [];
  try {
    final dec = jsonDecode(raw);
    if (dec is! List) return [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - const Duration(days: 7).inMilliseconds;
    final out = <int>[];
    for (final e in dec) {
      final t = e is int ? e : (e is num ? e.toInt() : 0);
      if (t >= cutoff) out.add(t);
    }
    return out;
  } catch (_) {
    return [];
  }
}

Future<bool> _maxImpressions7dReached() async {
  final list = await _readImpressionTs7d();
  return list.length >= 3;
}

Future<void> _appendImpressionTs7d() async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now().millisecondsSinceEpoch;
  final list = await _readImpressionTs7d();
  list.add(now);
  final cutoff = now - const Duration(days: 7).inMilliseconds;
  final pruned = list.where((t) => t >= cutoff).take(30).toList();
  await prefs.setString(_kImprTs7d, jsonEncode(pruned));
}

Future<int> _recentGrantCount(String uid) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_grantListKey(uid));
    if (raw == null || raw.isEmpty) return 0;
    final dec = jsonDecode(raw);
    if (dec is! List) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - CreditsPolicy.softPaywallBurstWindowMinutes * 60 * 1000;
    var n = 0;
    for (final e in dec) {
      final t = e is int ? e : (e is num ? e.toInt() : 0);
      if (t >= cutoff) n++;
    }
    return n;
  } catch (_) {
    return 0;
  }
}

Future<bool> _firePaywallMetric(String type, String eventId) async {
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) return false;
    final r = await http
        .post(
          VoiceBackendConfig.recordPaywallUri(),
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, String>{'type': type, 'eventId': eventId}),
        )
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return false;
    final j = jsonDecode(r.body);
    if (j is Map && j['deduped'] == true) return false;
    return true;
  } catch (_) {
    return false;
  }
}

/// After SDK reward, before POST `/grant-reward` — gated upsell (session + 24h + burst + fatigue + 7d cap).
Future<void> maybeShowSoftAdPaywallBeforeGrant(
  BuildContext context, {
  required bool isPremium,
}) async {
  if (isPremium || !context.mounted) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  final uid = user.uid;
  if (_softPaywallSessionShownUid.contains(uid)) return;

  if (await _fatigueBlocked()) return;
  if (await _maxImpressions7dReached()) return;

  final ui = await _loadPaywallUi();
  if (!context.mounted) return;

  final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
  if (!context.mounted) return;
  final life = FirestoreUserService.lifetimeAdsWatchedFromUserData(snap.data());
  if (life < ui.lifetimeAdsThreshold) return;

  final usable = FirestoreUserService.computeUsableCredits(snap.data());
  final bypassBurstForLowCredits = usable <= CreditsPolicy.softPaywallLowCreditsMaxUsable &&
      life >= CreditsPolicy.softPaywallLowCreditsMinLifetimeAds;
  final burst = await _recentGrantCount(uid);
  if (!bypassBurstForLowCredits &&
      burst < CreditsPolicy.softPaywallMinGrantsInBurstWindow) {
    return;
  }
  if (!await _canShowSoftPaywallByCooldown(uid)) return;

  if (!context.mounted) return;
  _softPaywallSessionShownUid.add(uid);
  final impressionId = _newPaywallEventId();
  final counted = await _firePaywallMetric('impression', impressionId);
  if (counted) {
    await _appendImpressionTs7d();
  }
  if (!context.mounted) {
    _softPaywallSessionShownUid.remove(uid);
    return;
  }

  final saveLine = ui.saveVsAdsHint.isNotEmpty
      ? ui.saveVsAdsHint
      : MonetizationCopy.softPaywallSaveApproxRupeeLine(
          lifetimeAdsThreshold: ui.lifetimeAdsThreshold,
          priceLabel: ui.priceLabel,
        );

  final goShop = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      title: const Text(MonetizationCopy.softPaywallTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            MonetizationCopy.softPaywallValueLine,
            style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(MonetizationCopy.softPaywallBody(ui.priceLabel)),
          const SizedBox(height: 8),
          Text(saveLine),
          const SizedBox(height: 10),
          Text(MonetizationCopy.softPaywallStarterMinutesLine()),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text(MonetizationCopy.softPaywallDismiss),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ui.ctaLabel),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  await _setPaywallLastShown(uid);
  if (goShop == true) {
    await _resetNoIntentStreak();
    if (context.mounted) {
      final intentId = _newPaywallEventId();
      await _firePaywallMetric('intent_click', intentId);
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(SubscriptionScreen.createRoute());
    }
  } else {
    await _onPaywallDismissedWithoutIntent();
  }
}
