/// Production TalkFree voice API on Render — single source of truth (no env/ngrok overrides).
abstract final class VoiceBackendConfig {
  VoiceBackendConfig._();

  static const String _host = 'talkfree-server.onrender.com';

  /// `https://talkfree-server.onrender.com` (no trailing slash).
  static const String productionOrigin = 'https://talkfree-server.onrender.com';

  /// Base URL only, no trailing slash.
  static String get baseUrl => productionOrigin;

  /// `GET /token` — Twilio Voice access JWT; requires Firebase `Authorization: Bearer`.
  static Uri tokenUri() => Uri.https(_host, '/token');

  /// `GET /browse-available-numbers` — US/CA local inventory (server-side Twilio).
  static Uri browseAvailableNumbersUri({
    required String country,
    int pageSize = 100,
    String? areaCode,
    String? contains,
    String? inRegion,
    String? nextPage,
  }) {
    final q = <String, String>{
      'country': country.trim().toUpperCase(),
      'pageSize': '$pageSize',
    };
    final ac = areaCode?.trim();
    if (ac != null && ac.isNotEmpty) {
      q['areaCode'] = ac;
    }
    final ct = contains?.trim();
    if (ct != null && ct.isNotEmpty) {
      q['contains'] = ct;
    }
    final ir = inRegion?.trim();
    if (ir != null && ir.isNotEmpty) {
      q['inRegion'] = ir;
    }
    final np = nextPage?.trim();
    if (np != null && np.isNotEmpty) {
      q['nextPage'] = np;
    }
    return Uri.https(_host, '/browse-available-numbers', q);
  }

  /// `POST /grant-reward` — Firebase ID token in `Authorization` (server adds credits).
  static Uri grantRewardUri() => Uri.https(_host, '/grant-reward');

  /// `POST /record-paywall` — JSON `{ "type", "eventId" }` for `user_stats` funnel (idempotent).
  static Uri recordPaywallUri() => Uri.https(_host, '/record-paywall');

  /// `GET /paywall-config` — A/B threshold + copy (no auth).
  static Uri paywallConfigUri() => Uri.https(_host, '/paywall-config');

  /// `GET /available-numbers` — Firebase ID token; optional `areaCode` query (3 digits).
  static Uri availableNumbersUri({String? areaCode}) {
    final q = <String, String>{};
    final ac = areaCode?.trim();
    if (ac != null && ac.isNotEmpty) {
      q['areaCode'] = ac;
    }
    return Uri.https(_host, '/available-numbers', q);
  }

  /// `POST /assign-number` — Firebase ID token; provisions a real US Twilio number when eligible.
  static Uri assignNumberUri() => Uri.https(_host, '/assign-number');

  /// `POST /renew-number` — Firebase ID token; JSON `{ "mode": "ads" | "credits" }`.
  static Uri renewNumberUri() => Uri.https(_host, '/renew-number');

  /// `POST /assign-free-number` — Firebase ID token; free tier auto-assigns first US local (eligible: ads or credits).
  static Uri assignFreeNumberUri() => Uri.https(_host, '/assign-free-number');

  /// `POST /purchase-number` — Firebase ID token; premium-only purchase of selected E.164 + Firestore.
  static Uri provisionNumberUri() => Uri.https(_host, '/purchase-number');

  /// `POST /purchase-browse-number` — Firebase ID token; deduct credits + buy number from browse inventory.
  static Uri purchaseBrowseNumberUri() => Uri.https(_host, '/purchase-browse-number');

  /// `POST /send-sms` — Firebase ID token; JSON `{ "to", "body" }` (server uses Twilio + assigned_number fallback).
  static Uri sendSmsUri() => Uri.https(_host, '/send-sms');

  /// `POST /terminate-call` — JSON `{ "callSid": "CA..." }` when balance cannot cover talk time.
  static Uri terminateCallUri() => Uri.https(_host, '/terminate-call');

  /// `POST /call-live-tick` — JSON `{ "callSid", "amount" }` (secured live credit pulses).
  static Uri callLiveTickUri() => Uri.https(_host, '/call-live-tick');

  /// `POST /sync-call-billing` — JSON `{ "callSid" }` after hangup (same settlement as Twilio `/call-status`).
  static Uri syncCallBillingUri() => Uri.https(_host, '/sync-call-billing');

  /// `POST /create-subscription-order` — JSON `{ "plan": "daily"|… }`; Razorpay Orders API.
  static Uri createSubscriptionOrderUri() =>
      Uri.https(_host, '/create-subscription-order');

  /// `POST /verify-payment` — Razorpay `payment_id`, `order_id`, `signature`; grants Pro via Admin.
  static Uri verifyPaymentUri() => Uri.https(_host, '/verify-payment');

  /// `POST /purchase-credits-pack` — JSON `{ "pack": "small"|"medium"|"large" }`; Razorpay order for credit packs.
  static Uri purchaseCreditsPackUri() => Uri.https(_host, '/purchase-credits-pack');

  /// `POST /claim-premium-monthly-bonus` — Firebase Bearer; recurring premium credit grant.
  static Uri claimPremiumMonthlyBonusUri() =>
      Uri.https(_host, '/claim-premium-monthly-bonus');

}
