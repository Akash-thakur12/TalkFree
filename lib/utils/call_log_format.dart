import 'package:cloud_firestore/cloud_firestore.dart';

import 'us_phone_format.dart';

/// Shared formatting for `users/{uid}/call_history` rows (server + UI).
abstract final class CallLogFormat {
  CallLogFormat._();

  static String formatDurationMmSs(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  static String formatClockTime(Timestamp? ts) {
    if (ts == null) return '—';
    final d = ts.toDate().toLocal();
    final h = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    return '$h:$min';
  }

  /// `Today`, `Yesterday`, or `12 Apr` (adds year if not current year).
  static String formatSettledDate(Timestamp? ts) {
    if (ts == null) return '—';
    final d = ts.toDate().toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final cal = DateTime(d.year, d.month, d.day);
    const mo = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    if (cal == today) return 'Today';
    if (cal == yesterday) return 'Yesterday';
    if (d.year == now.year) {
      return '${d.day} ${mo[d.month - 1]}';
    }
    return '${d.day} ${mo[d.month - 1]} ${d.year}';
  }

  static int creditsDeducted(Map<String, dynamic> data) {
    final charged = data['creditsCharged'];
    if (charged is num && charged > 0) return charged.round();
    final attempt = data['creditsAttempted'] ?? data['finalCharge'];
    if (attempt is num) return attempt.round();
    return 0;
  }

  static String? firstPstnNumber(Map<String, dynamic> data) {
    for (final leg in <Object?>[data['from'], data['to']]) {
      final s = (leg ?? '').toString().trim();
      if (s.isEmpty) continue;
      if (s.toLowerCase().startsWith('client:')) continue;
      return s;
    }
    return null;
  }

  static String peerPhoneNumber(Map<String, dynamic> data) {
    final from = (data['from'] ?? '').toString().trim();
    final to = (data['to'] ?? '').toString().trim();
    final fl = from.toLowerCase();
    final tl = to.toLowerCase();
    if (fl.startsWith('client:')) return to;
    if (tl.startsWith('client:')) return from;
    if (to.isNotEmpty) return to;
    if (from.isNotEmpty) return from;
    return '';
  }

  static bool isOutgoingCall(Map<String, dynamic> data) {
    final from = (data['from'] ?? '').toString().toLowerCase();
    return from.startsWith('client:');
  }

  static bool isOutgoingFromDocument(Map<String, dynamic> data) {
    final raw = data['direction'];
    if (raw is String) {
      final t = raw.toLowerCase().trim();
      if (t == 'outgoing') return true;
      if (t == 'incoming') return false;
    }
    return isOutgoingCall(data);
  }

  static String maskClientIdForTitle(String value, bool outgoing) {
    final t = value.trim();
    if (t.isEmpty) return value;
    if (t.toLowerCase().startsWith('client:')) {
      return outgoing ? 'Private Line' : 'TalkFree User';
    }
    return value;
  }

  static ({String primary, String? subtitle}) callHistoryLabels(
    Map<String, dynamic> data,
    bool outgoing,
  ) {
    final pstn = firstPstnNumber(data);
    if (pstn != null) {
      return (primary: pstn, subtitle: null);
    }
    final peer = peerPhoneNumber(data);
    if (peer.isEmpty) {
      return (primary: 'Unknown', subtitle: null);
    }
    return (
      primary: maskClientIdForTitle(peer, outgoing),
      subtitle: null,
    );
  }

  /// Flag + region label for E.164-ish strings (US / India focus).
  static ({String flag, String label}) regionForPhone(String raw) {
    final d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.length >= 12 && d.startsWith('91')) {
      return (flag: '🇮🇳', label: 'India');
    }
    if (d.length == 11 && d.startsWith('1')) {
      return (flag: '🇺🇸', label: 'US');
    }
    if (d.length == 10) {
      return (flag: '🇺🇸', label: 'US');
    }
    return (flag: '🌐', label: '');
  }

  static String prettyDisplayNumber(String raw) {
    final region = regionForPhone(raw);
    if (region.label == 'US') {
      return formatUsPhoneForDisplay(raw);
    }
    if (region.label == 'India') {
      final d = raw.replaceAll(RegExp(r'\D'), '');
      if (d.length >= 12 && d.startsWith('91')) {
        final rest = d.substring(2);
        if (rest.length >= 10) {
          return '+91 ${rest.substring(0, 5)} ${rest.substring(5)}';
        }
      }
    }
    return raw.trim();
  }

  static CallLogKind callKind(
    Map<String, dynamic> data,
    bool outgoing,
    int durationSec,
  ) {
    if (durationSec <= 0) {
      return CallLogKind.missed;
    }
    return outgoing ? CallLogKind.outgoing : CallLogKind.incoming;
  }
}

enum CallLogKind { outgoing, incoming, missed }
