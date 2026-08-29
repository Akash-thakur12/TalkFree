import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../config/credits_policy.dart';

class InsufficientCreditsException implements Exception {
  InsufficientCreditsException([this.message = 'Insufficient credits']);
  final String message;
  @override
  String toString() => message;
}

class AdRewardCooldownException implements Exception {
  AdRewardCooldownException([this.message = 'Please wait before the next ad.']);
  final String message;
  @override
  String toString() => message;
}

class AdRewardDailyCapException implements Exception {
  AdRewardDailyCapException([this.message = 'Daily Limit Reached']);
  final String message;
  @override
  String toString() => message;
}

class FirestoreUserService {
  FirestoreUserService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static DocumentReference<Map<String, dynamic>> _userRef(String uid) =>
      _db.collection('users').doc(uid);

  static int _int(dynamic v, [int d = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return d;
  }

  static Timestamp? _ts(Map<String, dynamic> d, String k) => d[k] as Timestamp?;

  static int _readAdsWatchedToday(Map<String, dynamic> m, String dayKey) {
    final reset =
        m['last_reset_date'] as String? ?? m['adRewardsDayKey'] as String? ?? '';
    if (reset != dayKey) return 0;
    if (m.containsKey('ads_watched_today')) return _int(m['ads_watched_today']);
    if (m.containsKey('adsWatchedToday')) return _int(m['adsWatchedToday']);
    return _int(m['adRewardsCount']);
  }

  static Timestamp? _readLastAdTimestamp(Map<String, dynamic> m) {
    DateTime? best;
    Timestamp? bestTs;
    for (final k in ['last_ad_timestamp', 'lastAdWatchTime', 'lastAdRewardAt']) {
      final a = m[k];
      if (a is! Timestamp) continue;
      final t = a.toDate().toUtc();
      if (best == null || t.isAfter(best)) {
        best = t;
        bestTs = a;
      }
    }
    return bestTs;
  }

  static void _migrateLegacyInPlace(Map<String, dynamic> d) {
    if (d.containsKey('paidCredits')) return;
    d['paidCredits'] = _int(d['credits']);
    d['rewardCredits'] = 0;
  }

  static bool _rewardExpired(Map<String, dynamic> d) {
    final exp = _ts(d, 'rewardCreditsExpiresAt');
    if (exp == null) return false;
    return DateTime.now().toUtc().isAfter(exp.toDate().toUtc());
  }

  static int computeUsableCredits(Map<String, dynamic>? data) {
    if (data == null) return 0;
    final d = Map<String, dynamic>.from(data);
    _migrateLegacyInPlace(d);
    final paid = _int(d['paidCredits']);
    var reward = _int(d['rewardCredits']);
    if (reward > 0 && _rewardExpired(d)) reward = 0;
    return paid + reward;
  }

  /// Real-time user document — use for credits UI synced everywhere.
  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchUserDocument(
    String uid,
  ) =>
      _userRef(uid).snapshots();

  /// Usable credits from a snapshot (same rules as [computeUsableCredits], no extra round-trip).
  static int usableCreditsFromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) =>
      computeUsableCredits(doc.data());

  /// Twilio line lease end — prefers `numberExpiry`, then `expiry_date`, then `number_expiry_date` (matches server).
  static DateTime? numberLeaseExpiryFromUserData(Map<String, dynamic>? data) {
    if (data == null) return null;
    for (final key in ['numberExpiry', 'expiry_date', 'number_expiry_date']) {
      final x = data[key];
      if (x is Timestamp) return x.toDate();
    }
    return null;
  }

  /// Pro subscription end — prefers `expiry_date` (Node `/verify-payment`), else [numberLeaseExpiryFromUserData].
  static DateTime? subscriptionExpiryFromUserData(Map<String, dynamic>? data) {
    if (data == null) return null;
    final ex = data['expiry_date'];
    if (ex is Timestamp) return ex.toDate();
    return numberLeaseExpiryFromUserData(data);
  }

  static bool _rawPremiumFlags(Map<String, dynamic> data) {
    final p = data['isPremium'];
    if (p is bool && p) return true;
    if (p is String && p.toLowerCase().trim() == 'true') return true;
    final raw =
        data['subscription_tier'] ?? data['subscriptionTier'] ?? data['plan'];
    if (raw == null) return false;
    final s = raw.toString().toLowerCase().trim();
    return s == 'pro' || s == 'premium';
  }

  /// Server line tier: `normal` | `vip` | `premium`.
  static String? numberTierFromUserData(Map<String, dynamic>? data) {
    if (data == null) return null;
    final v = data['number_tier'] ?? data['numberTier'];
    if (v is String) {
      final t = v.trim().toLowerCase();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  /// Primary line status from server (`active` | `expired`); legacy `number_status`.
  static String? numberLineStatusFromUserData(Map<String, dynamic>? data) {
    if (data == null) return null;
    for (final key in ['numberStatus', 'number_status']) {
      final v = data[key];
      if (v is String) {
        final t = v.trim();
        if (t.isNotEmpty) return t.toLowerCase();
      }
    }
    return null;
  }

  /// Rewarded ads banked toward server POST `/renew-number` (mode `ads`).
  static int numberRenewAdProgressFromUserData(Map<String, dynamic>? data) {
    if (data == null) return 0;
    final v = data['number_renew_ad_progress'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  /// Plan key for lease length (`daily` | `weekly` | `monthly` | `yearly`).
  static String? numberPlanTypeFromUserData(Map<String, dynamic>? data) {
    if (data == null) return null;
    final v = data['number_plan_type'];
    if (v is String) {
      final t = v.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  /// E.164 or `null` — checks `assigned_number` and legacy number fields.
  static String? assignedNumberFromUserData(Map<String, dynamic>? data) {
    if (data == null) return null;
    for (final key in [
      'assigned_number',
      'phoneNumber',
      'virtual_number',
      'allocatedNumber',
      'number',
    ]) {
      final v = data[key];
      if (v is String) {
        final t = v.trim();
        if (t.isNotEmpty && t != 'none') return t;
      }
    }
    return null;
  }

  /// Lifetime rewarded-ad views (`ads_watched_count` only — no daily fallback).
  static int lifetimeAdsWatchedFromUserData(Map<String, dynamic>? data) {
    if (data == null) return 0;
    final v = data['ads_watched_count'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  /// Progress toward free US number unlock (`number_ads_progress`, cap [CreditsPolicy.numberUnlockAdsRequired]).
  /// Migrates from lifetime `ads_watched_count` when the field is absent.
  static int numberAdsProgressFromUserData(Map<String, dynamic>? data) {
    if (data == null) return 0;
    final cap = CreditsPolicy.numberUnlockAdsRequired;
    final v = data['number_ads_progress'];
    if (v is int) return v.clamp(0, cap);
    if (v is num) return v.toInt().clamp(0, cap);
    final life = lifetimeAdsWatchedFromUserData(data);
    return life.clamp(0, cap);
  }

  /// Banked rewarded ads toward one outbound SMS on free tier (`otp_ads_progress`, cap 3).
  static int otpAdsProgressFromUserData(Map<String, dynamic>? data) {
    if (data == null) return 0;
    final v = data['otp_ads_progress'];
    final cap = CreditsPolicy.otpAdsRequiredPerSms;
    if (v is int) return v.clamp(0, cap);
    if (v is num) return v.toInt().clamp(0, cap);
    return 0;
  }

  /// Consecutive UTC days with ≥1 rewarded ad (`POST /grant-reward` maintains).
  static int adStreakCountFromUserData(Map<String, dynamic>? data) {
    if (data == null) return 0;
    return _int(data['ad_streak_count']);
  }

  /// `true` when Firestore flags say Pro **and** [subscriptionExpiryFromUserData] is null or after [at] (UTC).
  /// Matches Node `readEffectivePremiumUser` (stale `isPremium` before demotion still reads as non‑premium).
  ///
  /// **Security:** `isPremium` / credits must be written only by Firebase Admin (Node `/verify-payment`,
  /// `/grant-reward`, billing). See `firestore.rules`.
  static bool isPremiumFromUserData(Map<String, dynamic>? data, [DateTime? at]) {
    if (data == null) return false;
    if (!_rawPremiumFlags(data)) return false;
    final n = (at ?? DateTime.now()).toUtc();
    final exp = subscriptionExpiryFromUserData(data);
    if (exp == null) return true;
    return exp.toUtc().isAfter(n);
  }

  /// `'free'` | `'premium'` — derived from [isPremiumFromUserData].
  static String subscriptionTierFromUserData(Map<String, dynamic>? data) {
    return isPremiumFromUserData(data) ? 'premium' : 'free';
  }

  /// Dashboard / nav: treat legacy `'pro'` the same as `'premium'`.
  static bool isPremiumTierLabel(String? tier) {
    if (tier == null) return false;
    final s = tier.toLowerCase().trim();
    return s == 'pro' || s == 'premium';
  }

  /// Outbound calls completed (server increments on Twilio settlement).
  static int totalOutboundCallsFromUserData(Map<String, dynamic>? data) {
    if (data == null) return 0;
    final v = data['totalOutboundCalls'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  /// Sum of [durationSeconds] for settled outbound calls (server).
  static int totalCallTalkSecondsFromUserData(Map<String, dynamic>? data) {
    if (data == null) return 0;
    final v = data['totalCallTalkSeconds'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  static Future<bool> fetchIsPremium(String uid) async {
    final s = await _userRef(uid).get();
    return isPremiumFromUserData(s.data());
  }

  static Future<void> expireRewardCreditsIfNeeded(String uid) async {
    await _db.runTransaction((tx) async {
      final ref = _userRef(uid);
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final d = snap.data()!;
      final m = Map<String, dynamic>.from(d);
      _migrateLegacyInPlace(m);
      final paid = _int(m['paidCredits']);
      final reward = _int(m['rewardCredits']);
      if (reward <= 0) return;
      if (!_rewardExpired(m)) return;
      tx.update(ref, {
        'paidCredits': paid,
        'rewardCredits': 0,
        'rewardCreditsExpiresAt': null,
        'credits': paid,
      });
    });
  }

  /// Login bootstrap: ensure Firestore `users/{uid}` exists / email is fresh — **no** welcome credits API.
  static Future<void> syncUserAfterLogin(User user) async {
    await syncUserWithFirestoreOnLogin(user);
  }

  /// Creates `users/{uid}` for new sign-ins or refreshes email; returns current usable credits.
  /// New users get [CreditsPolicy.initialCreditsForNewUser] (0 — `paidCredits`/`credits`, `rewardCredits: 0`) and `virtual_number: null`.
  static Future<int> syncUserWithFirestoreOnLogin(User user) async {
    final ref = _userRef(user.uid);
    final email = user.email?.trim() ?? '';

    final existing = await ref.get();
    if (existing.exists) {
      await expireRewardCreditsIfNeeded(user.uid);
      final data = existing.data()!;
      final updates = <String, dynamic>{};
      if (email.isNotEmpty && (data['email'] as String?) != email) {
        updates['email'] = email;
      }
      if (data['isGuest'] != user.isAnonymous) {
        updates['isGuest'] = user.isAnonymous;
      }
      _backfillCanonicalUserFields(data, updates);
      if (updates.isNotEmpty) {
        await ref.update(updates);
      }
      final after = await ref.get();
      return computeUsableCredits(after.data());
    }

    if (email.isNotEmpty) {
      final dup = await _db
          .collection('users')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();
      if (dup.docs.isNotEmpty && dup.docs.first.id != user.uid && kDebugMode) {
        debugPrint(
          'Firestore: email "$email" exists on another doc; creating users/${user.uid}',
        );
      }
    }

    await ref.set(_newUserDocumentData(user));
    return CreditsPolicy.initialCreditsForNewUser;
  }

  /// Adds missing canonical fields for older `users/{uid}` documents (non-destructive).
  static void _backfillCanonicalUserFields(
    Map<String, dynamic> data,
    Map<String, dynamic> updates,
  ) {
    if (!data.containsKey('assigned_number')) {
      updates['assigned_number'] = data['virtual_number'] ?? data['allocatedNumber'];
    }
    if (!data.containsKey('ads_watched_count')) {
      updates['ads_watched_count'] =
          _int(data['ads_watched_today'] ?? data['adRewardsCount']);
    }
    if (!data.containsKey('created_at') && data['createdAt'] != null) {
      updates['created_at'] = data['createdAt'];
    }
  }

  static Map<String, dynamic> _newUserDocumentData(User user) {
    final email = user.email?.trim() ?? '';
    final initial = CreditsPolicy.initialCreditsForNewUser;
    return <String, dynamic>{
      'uid': user.uid,
      'email': email,
      'isGuest': user.isAnonymous,
      'credits': initial,
      'assigned_number': null,
      'virtual_number': null,
      'paidCredits': initial,
      'rewardCredits': 0,
      'rewardCreditsExpiresAt': null,
      'number': 'none',
      'allocatedNumber': null,
      'ad_progress': 0,
      'ads_watched_today': 0,
      'ads_watched_count': 0,
      'number_ads_progress': 0,
      'otp_ads_progress': 0,
      'last_reset_date': '',
      'last_ad_timestamp': null,
      'adRewardsCount': 0,
      'adRewardsDayKey': '',
      'adRewardCycleCount': 0,
      'isPremium': false,
      'premiumWelcomeBonusGranted': false,
      'created_at': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'totalOutboundCalls': 0,
      'totalCallTalkSeconds': 0,
      'welcomeCallingCreditsGranted': false,
    };
  }

  /// Sets authoritative total usable credits (paid bucket only; clears reward bucket).
  /// Call after local logic for ads/calls when you need to push a computed balance to Firestore.
  static Future<void> updateCreditsInCloud(int newBalance) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    if (newBalance < 0) {
      throw ArgumentError.value(newBalance, 'newBalance', 'must be >= 0');
    }
    await _userRef(user.uid).update(<String, Object?>{
      'paidCredits': newBalance,
      'rewardCredits': 0,
      'rewardCreditsExpiresAt': null,
      'credits': newBalance,
    });
  }

  /// Pushes [newBalance] (usable total) to `users/{uid}` while preserving reward
  /// credits when possible. If the document already matches [newBalance], still
  /// refreshes `credits` and bucket fields so clients get a snapshot quickly.
  static Future<void> syncUsableCreditsToCloud(int newBalance) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    if (newBalance < 0) {
      throw ArgumentError.value(newBalance, 'newBalance', 'must be >= 0');
    }
    await _db.runTransaction((tx) async {
      final ref = _userRef(user.uid);
      final snap = await tx.get(ref);
      if (!snap.exists) throw StateError('User document missing');
      final m = Map<String, dynamic>.from(snap.data()!);
      _migrateLegacyInPlace(m);
      var paid = _int(m['paidCredits']);
      var reward = _int(m['rewardCredits']);
      Timestamp? exp = _ts(m, 'rewardCreditsExpiresAt');
      if (reward > 0 && _rewardExpired(m)) {
        paid += reward;
        reward = 0;
        exp = null;
      }
      final current = paid + reward;
      if (current == newBalance) {
        tx.update(ref, <String, Object?>{
          'paidCredits': paid,
          'rewardCredits': reward,
          'rewardCreditsExpiresAt': reward > 0 ? exp : null,
          'credits': newBalance,
        });
        return;
      }
      final newPaid = paid + (newBalance - current);
      if (newPaid < 0) {
        throw ArgumentError.value(
          newBalance,
          'newBalance',
          'would make paidCredits negative',
        );
      }
      tx.update(ref, <String, Object?>{
        'paidCredits': newPaid,
        'rewardCredits': reward,
        'rewardCreditsExpiresAt': reward > 0 ? exp : null,
        'credits': newPaid + reward,
      });
    });
  }

  static Future<void> ensureUserDocument(String uid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && user.uid == uid) {
      await syncUserWithFirestoreOnLogin(user);
      return;
    }

    final ref = _userRef(uid);
    final snap = await ref.get();
    if (!snap.exists) {
      final initial = CreditsPolicy.initialCreditsForNewUser;
      await ref.set(<String, dynamic>{
        'uid': uid,
        'email': '',
        'isGuest': true,
        'credits': initial,
        'assigned_number': null,
        'virtual_number': null,
        'paidCredits': initial,
        'rewardCredits': 0,
        'number': 'none',
        'allocatedNumber': null,
        'ad_progress': 0,
        'ads_watched_today': 0,
        'ads_watched_count': 0,
        'number_ads_progress': 0,
        'otp_ads_progress': 0,
        'last_reset_date': '',
        'last_ad_timestamp': null,
        'adRewardsCount': 0,
        'adRewardsDayKey': '',
        'adRewardCycleCount': 0,
        'isPremium': false,
        'premiumWelcomeBonusGranted': false,
        'created_at': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'totalOutboundCalls': 0,
        'totalCallTalkSeconds': 0,
        'welcomeCallingCreditsGranted': false,
      });
      return;
    }
    final d = snap.data()!;
    if (!d.containsKey('paidCredits')) {
      final legacy = _int(d['credits']);
      await ref.update({
        'paidCredits': legacy,
        'rewardCredits': 0,
        'ad_progress': d['ad_progress'] ?? d['adRewardCycleCount'] ?? 0,
        'ads_watched_today': d['ads_watched_today'] ?? d['adRewardsCount'] ?? 0,
        'last_reset_date':
            d['last_reset_date'] ?? d['adRewardsDayKey'] ?? '',
        'adRewardsCount': d['adRewardsCount'] ?? 0,
        'adRewardsDayKey': d['adRewardsDayKey'] ?? '',
        'adRewardCycleCount': d['adRewardCycleCount'] ?? 0,
      });
    }
  }

  /// Records one rewarded-ad view (daily cap + cooldown). Prefer **POST /grant-reward** for credits.
  /// Returns [serverGrantNeeded] **true** — call [GrantRewardService] to sync server-side grant (credits from server).
  static Future<
      ({
        bool serverGrantNeeded,
      })> registerRewardedAdWatch(String uid) async {
    await _db.runTransaction((tx) async {
      final ref = _userRef(uid);
      final snap = await tx.get(ref);
      if (!snap.exists) throw StateError('User document missing');
      final m = Map<String, dynamic>.from(snap.data()!);
      _migrateLegacyInPlace(m);

      final now = DateTime.now().toUtc();
      final dayKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      var count = _readAdsWatchedToday(m, dayKey);
      var storedDay =
          m['last_reset_date'] as String? ?? m['adRewardsDayKey'] as String? ?? '';
      if (storedDay != dayKey) {
        count = 0;
        storedDay = dayKey;
      }

      final premium = isPremiumFromUserData(m, now);
      final coolDownSec = CreditsPolicy.adRewardCooldownSecondsForUser(premium);
      final cap = CreditsPolicy.maxRewardedAdsForUser(premium);

      final lastTs = _readLastAdTimestamp(m);
      if (lastTs != null) {
        final elapsed = now.difference(lastTs.toDate().toUtc()).inSeconds;
        if (elapsed < coolDownSec) {
          final wait = coolDownSec - elapsed;
          throw AdRewardCooldownException('Please wait $wait seconds');
        }
      }

      if (count >= cap) {
        throw AdRewardDailyCapException();
      }

      tx.update(ref, {
        'ad_progress': 0,
        'ad_sub_counter': 0,
        'adRewardCycleCount': 0,
        'ads_watched_today': count + 1,
        'last_reset_date': storedDay,
        'last_ad_timestamp': FieldValue.serverTimestamp(),
        'lastAdWatchTime': FieldValue.serverTimestamp(),
        'adRewardsCount': count + 1,
        'adRewardsDayKey': storedDay,
        'lastAdRewardAt': FieldValue.serverTimestamp(),
      });
    });
    return (serverGrantNeeded: true);
  }

  static Future<void> addPaidCredits(String uid, int amount) async {
    await _db.runTransaction((tx) async {
      final ref = _userRef(uid);
      final snap = await tx.get(ref);
      if (!snap.exists) throw StateError('User document missing');
      final m = Map<String, dynamic>.from(snap.data()!);
      _migrateLegacyInPlace(m);
      var paid = _int(m['paidCredits']);
      var reward = _int(m['rewardCredits']);
      Timestamp? exp = _ts(m, 'rewardCreditsExpiresAt');
      if (reward > 0 && _rewardExpired(m)) {
        paid += reward;
        reward = 0;
        exp = null;
      }
      paid += amount;
      tx.update(ref, {
        'paidCredits': paid,
        'rewardCredits': reward,
        'rewardCreditsExpiresAt': reward > 0 ? exp : null,
        'credits': paid + reward,
      });
    });
  }

  static Future<void> addCredits(String uid, int amount) async {
    await addPaidCredits(uid, amount);
  }

  static Future<void> deductCredits(String uid, int amount) async {
    await _db.runTransaction((tx) async {
      final ref = _userRef(uid);
      final snap = await tx.get(ref);
      if (!snap.exists) throw StateError('User document missing');
      final m = Map<String, dynamic>.from(snap.data()!);
      _migrateLegacyInPlace(m);
      var paid = _int(m['paidCredits']);
      var reward = _int(m['rewardCredits']);
      Timestamp? exp = _ts(m, 'rewardCreditsExpiresAt');

      if (reward > 0 && _rewardExpired(m)) {
        reward = 0;
        exp = null;
      }

      final usable = paid + reward;
      if (usable < amount) {
        throw InsufficientCreditsException();
      }

      var left = amount;
      final takeReward = left < reward ? left : reward;
      reward -= takeReward;
      left -= takeReward;
      paid -= left;

      tx.update(ref, {
        'paidCredits': paid,
        'rewardCredits': reward,
        'rewardCreditsExpiresAt': reward > 0 ? exp : null,
        'credits': paid + reward,
      });
    });
  }

  static Future<void> deductCallUsageTick(String uid, int amount) async {
    await deductCredits(uid, amount);
  }

  /// Latest usable total after expiring stale reward credits (server write when needed).
  static Future<int> fetchUsableCredits(String uid) async {
    await expireRewardCreditsIfNeeded(uid);
    final snap = await _userRef(uid).get();
    return computeUsableCredits(snap.data());
  }

  /// Live usable total — maps [watchUserDocument] (Firestore pushes; stays in sync across screens).
  static Stream<int> watchCredits(String uid) {
    return watchUserDocument(uid).map(usableCreditsFromSnapshot);
  }

  static ({
    int adsToday,
    int cooldownRemaining,
    bool dailyLimitReached,
  }) _adRewardStatusFromSnap(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    if (!doc.exists) {
      return (
        adsToday: 0,
        cooldownRemaining: 0,
        dailyLimitReached: false,
      );
    }
    final m = doc.data()!;
    final now = DateTime.now().toUtc();
    final dayKey =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final count = _readAdsWatchedToday(m, dayKey);
    final premium = isPremiumFromUserData(m, now);
    final coolDownSec = CreditsPolicy.adRewardCooldownSecondsForUser(premium);
    final cap = CreditsPolicy.maxRewardedAdsForUser(premium);

    var cool = 0;
    final last = _readLastAdTimestamp(m);
    if (last != null) {
      final elapsed = now.difference(last.toDate().toUtc()).inSeconds;
      if (elapsed < coolDownSec) {
        cool = coolDownSec - elapsed;
      }
    }
    final dailyLimitReached = count >= cap;
    return (
      adsToday: count,
      cooldownRemaining: cool,
      dailyLimitReached: dailyLimitReached,
    );
  }

  /// Derives rewarded-ad UI fields from the latest user document (same rules as streams).
  /// Cooldown uses wall-clock vs [last_ad_timestamp] — callers can re-run this every second
  /// from a cached snapshot to update the countdown without extra Firestore reads.
  static ({
    int adsToday,
    int cooldownRemaining,
    bool dailyLimitReached,
  }) adRewardStatusFromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) =>
      _adRewardStatusFromSnap(doc);

  /// Emits when the user document changes only (no 1 Hz timer — avoids global UI rebuilds).
  /// Recompute cooldown locally with [adRewardStatusFromSnapshot] + a 1 s tick if needed.
  static Stream<
      ({
        int adsToday,
        int cooldownRemaining,
        bool dailyLimitReached,
      })> watchAdRewardStatus(
    String uid,
  ) =>
      watchUserDocument(uid).map(_adRewardStatusFromSnap);

  static Stream<String?> watchAllocatedNumber(String uid) {
    return _userRef(uid).snapshots().map((doc) {
      final data = doc.data();
      if (data == null) return null;
      final assigned = data['assigned_number'];
      if (assigned is String && assigned.isNotEmpty && assigned != 'none') {
        return assigned;
      }
      final virtual = data['virtual_number'];
      if (virtual is String && virtual.isNotEmpty && virtual != 'none') {
        return virtual;
      }
      final allocated = data['allocatedNumber'];
      if (allocated is String && allocated.isNotEmpty && allocated != 'none') {
        return allocated;
      }
      final legacy = data['number'];
      if (legacy is String && legacy.isNotEmpty && legacy != 'none') {
        return legacy;
      }
      return null;
    });
  }

  static Future<void> setAllocatedNumber(String uid, String e164) async {
    await _userRef(uid).update({
      'assigned_number': e164,
      'virtual_number': e164,
      'allocatedNumber': e164,
      'number': e164,
    });
  }

  /// Inbound SMS / OTP — real-time stream on **`users/{uid}/messages/{messageId}`** (same path as rules).
  /// Server writes `createdAt` via `FieldValue.serverTimestamp()`; [InboxScreen] sorts newest first client-side.
  /// Each document may use `body`/`text`, `from`, `createdAt`/`timestamp` (flexible schema).
  static Stream<QuerySnapshot<Map<String, dynamic>>> watchInboxMessages(String uid) {
    return _userRef(uid).collection('messages').snapshots();
  }

  /// Outbound call rows — written by server Twilio `/call-status` (`settledAt`, `to`, etc.).
  static Stream<QuerySnapshot<Map<String, dynamic>>> watchCallHistory(
    String uid, {
    int limit = 100,
  }) =>
      _userRef(uid)
          .collection('call_history')
          .orderBy('settledAt', descending: true)
          .limit(limit)
          .snapshots();

}
