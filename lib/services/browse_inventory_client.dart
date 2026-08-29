import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/voice_backend_config.dart';
import '../models/virtual_number.dart';
import '../utils/nanp_phone_display.dart';

/// One page from GET `/browse-available-numbers` (server proxies Twilio inventory).
class BrowseInventoryPage {
  const BrowseInventoryPage({
    required this.numbers,
    this.nextPage,
  });

  final List<VirtualNumber> numbers;

  /// Opaque path+query for the next page (pass as [nextPage] on the following request).
  final String? nextPage;
}

/// Full walk of Twilio paginated inventory for one country (US or CA).
class BrowseAggregatedInventory {
  const BrowseAggregatedInventory({
    required this.numbers,
    this.nextPage,
    this.truncatedByPageCap = false,
  });

  final List<VirtualNumber> numbers;

  /// If non-null, Twilio still has more numbers (or [truncatedByPageCap] hit the client cap).
  final String? nextPage;

  /// True when [nextPage] is set only because [BrowseInventoryClient.fetchAllLocalPages] stopped at [maxPages].
  final bool truncatedByPageCap;
}

/// Twilio `InRegion` codes — one pass each so we do not depend on flaky global pagination.
const List<String> _browseUsRegions = [
  'AL', 'AK', 'AZ', 'AR', 'CA', 'CO', 'CT', 'DE', 'DC', 'FL', 'GA', 'HI', 'ID',
  'IL', 'IN', 'IA', 'KS', 'KY', 'LA', 'ME', 'MD', 'MA', 'MI', 'MN', 'MS', 'MO',
  'MT', 'NE', 'NV', 'NH', 'NJ', 'NM', 'NY', 'NC', 'ND', 'OH', 'OK', 'OR', 'PA',
  'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VT', 'VA', 'WA', 'WV', 'WI', 'WY',
];

const List<String> _browseCaRegions = [
  'AB', 'BC', 'MB', 'NB', 'NL', 'NS', 'NT', 'NU', 'ON', 'PE', 'QC', 'SK', 'YT',
];

/// US/CA local number inventory via backend (no Twilio credentials in the app).
class BrowseInventoryClient {
  BrowseInventoryClient._();
  static final BrowseInventoryClient instance = BrowseInventoryClient._();

  static VirtualNumber _virtualNumberFromJson(Map<String, dynamic> m) {
    final e164 = (m['phoneNumber'] as String?)?.trim() ?? '';
    final locality = m['locality'] as String?;
    final region = m['region'] as String?;
    final country = (m['country'] as String?)?.trim().toUpperCase() ?? 'US';
    final sub = [locality, region]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(', ');
    final place = country == 'CA'
        ? (sub.isEmpty ? 'Canada' : '$sub · Canada')
        : (sub.isEmpty ? 'United States' : '$sub · US');
    return VirtualNumber(
      e164: e164,
      phoneNumber: NanpPhoneDisplay.format(e164),
      country: place,
      isoCountryCode: country,
    );
  }

  Future<BrowseInventoryPage> fetchLocalPage({
    required String country,
    int pageSize = 100,
    String? areaCode,
    String? contains,
    String? inRegion,
    String? nextPage,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Could not get Firebase ID token');
    }

    final uri = VoiceBackendConfig.browseAvailableNumbersUri(
      country: country,
      pageSize: pageSize,
      areaCode: areaCode,
      contains: contains,
      inRegion: inRegion,
      nextPage: nextPage,
    );

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
        debugPrint(
          'browse-available-numbers failed: ${response.statusCode} ${response.body}',
        );
      }
      throw StateError(
        'Could not load numbers (HTTP ${response.statusCode})',
      );
    }

    final j = jsonDecode(response.body) as Map<String, dynamic>?;
    final raw = j?['numbers'];
    if (raw is! List) {
      return const BrowseInventoryPage(numbers: []);
    }
    final out = <VirtualNumber>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final pn = (m['phoneNumber'] as String?)?.trim() ?? '';
      if (pn.isEmpty) continue;
      out.add(_virtualNumberFromJson(m));
    }
    final next = j?['nextPage'] as String?;
    final trimmed = next?.trim();
    return BrowseInventoryPage(
      numbers: out,
      nextPage: (trimmed != null && trimmed.isNotEmpty) ? trimmed : null,
    );
  }

  /// Chains Twilio [nextPage] until inventory is exhausted for [country] (`US` or `CA`).
  ///
  /// Optional [inRegion] sets Twilio `InRegion` on the **first** request only (state/province).
  ///
  /// Uses [pageSize] 1000 (server max) to reduce round-trips. De-duplicates by E.164.
  /// If Twilio returns more than [maxPages] pages, remaining inventory is exposed via
  /// [BrowseAggregatedInventory.nextPage] (use [fetchLocalPage] with that token, or tap
  /// “Load more” in the UI).
  Future<BrowseAggregatedInventory> fetchAllLocalPages({
    required String country,
    String? inRegion,
    int pageSize = 1000,
    int maxPages = 200,
  }) async {
    final merged = <VirtualNumber>[];
    final seen = <String>{};
    String? next;

    for (var i = 0; i < maxPages; i++) {
      final page = await fetchLocalPage(
        country: country,
        pageSize: pageSize,
        inRegion: next == null ? inRegion : null,
        nextPage: next,
      );
      for (final n in page.numbers) {
        if (seen.add(n.e164)) merged.add(n);
      }
      final np = page.nextPage?.trim();
      if (np == null || np.isEmpty) {
        return BrowseAggregatedInventory(
          numbers: merged,
          nextPage: null,
          truncatedByPageCap: false,
        );
      }
      next = np;
    }

    return BrowseAggregatedInventory(
      numbers: merged,
      nextPage: next,
      truncatedByPageCap: true,
    );
  }

  /// Full US or CA inventory: fetches every state/province in parallel batches, paginates
  /// each region, then merges (Twilio’s unpaged country listing often returns only ~1 page).
  Future<BrowseAggregatedInventory> fetchMergedInventoryByRegion({
    required String country,
    int pageSize = 1000,
    int maxPagesPerRegion = 100,
  }) async {
    final cc = country.trim().toUpperCase();
    final regions = cc == 'US'
        ? _browseUsRegions
        : cc == 'CA'
            ? _browseCaRegions
            : const <String>[];

    if (regions.isEmpty) {
      return fetchAllLocalPages(country: cc, pageSize: pageSize, maxPages: maxPagesPerRegion);
    }

    final merged = <VirtualNumber>[];
    final seen = <String>{};
    var anyTruncated = false;

    const batch = 6;
    for (var i = 0; i < regions.length; i += batch) {
      final slice = regions.skip(i).take(batch).toList();
      final futures = slice.map((r) async {
        try {
          return await fetchAllLocalPages(
            country: cc,
            inRegion: r,
            pageSize: pageSize,
            maxPages: maxPagesPerRegion,
          );
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('browse region $cc/$r failed: $e\n$st');
          }
          return const BrowseAggregatedInventory(numbers: []);
        }
      });
      final parts = await Future.wait(futures);
      for (final p in parts) {
        if (p.truncatedByPageCap) anyTruncated = true;
        for (final n in p.numbers) {
          if (seen.add(n.e164)) merged.add(n);
        }
      }
    }

    return BrowseAggregatedInventory(
      numbers: merged,
      nextPage: null,
      truncatedByPageCap: anyTruncated,
    );
  }
}
