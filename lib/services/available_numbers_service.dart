import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';

/// One row from GET `/available-numbers`.
class AvailablePhoneNumber {
  const AvailablePhoneNumber({
    required this.phoneNumber,
    this.friendlyName,
    this.locality,
    this.region,
    this.postalCode,
  });

  final String phoneNumber;
  final String? friendlyName;
  final String? locality;
  final String? region;
  final String? postalCode;

  String get subtitle {
    final parts = <String>[];
    if (locality != null && locality!.isNotEmpty) parts.add(locality!);
    if (region != null && region!.isNotEmpty) parts.add(region!);
    return parts.isEmpty ? phoneNumber : parts.join(', ');
  }
}

/// Fetches US local inventory from the TalkFree server (Voice + SMS + MMS).
class AvailableNumbersService {
  AvailableNumbersService._();
  static final AvailableNumbersService instance = AvailableNumbersService._();

  Future<List<AvailablePhoneNumber>> fetch({String? areaCode}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Could not get Firebase ID token');
    }

    final uri = VoiceBackendConfig.availableNumbersUri(areaCode: areaCode);
    final response = await http
        .get(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('available-numbers failed: ${response.statusCode} ${response.body}');
      }
      throw StateError(
        'Could not load numbers (HTTP ${response.statusCode})',
      );
    }

    final j = jsonDecode(response.body) as Map<String, dynamic>?;
    final raw = j?['numbers'];
    if (raw is! List) {
      return [];
    }
    final out = <AvailablePhoneNumber>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final pn = (m['phoneNumber'] as String?)?.trim() ?? '';
      if (pn.isEmpty) continue;
      out.add(
        AvailablePhoneNumber(
          phoneNumber: pn,
          friendlyName: m['friendlyName'] as String?,
          locality: m['locality'] as String?,
          region: m['region'] as String?,
          postalCode: m['postalCode'] as String?,
        ),
      );
    }
    return out;
  }
}
