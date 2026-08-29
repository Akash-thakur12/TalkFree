import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Razorpay Checkout key from dashboard (test: `rzp_test_…`, live: `rzp_live_…`).
///
/// **Precedence:** `--dart-define=RAZORPAY_KEY_ID=…` (compile-time) wins over `.env`
/// so `flutter run --dart-define=...` always works without merge-order surprises.
abstract final class RazorpayConfig {
  RazorpayConfig._();

  static String? _stripBom(String k) {
    var s = k.trim();
    if (s.startsWith('\uFEFF')) s = s.substring(1).trim();
    return s.isEmpty ? null : s;
  }

  static String? get keyId {
    const fromDefine =
        String.fromEnvironment('RAZORPAY_KEY_ID', defaultValue: '');
    final d = _stripBom(fromDefine);
    if (d != null) return d;

    if (!dotenv.isInitialized) return null;
    return _stripBom(dotenv.env['RAZORPAY_KEY_ID'] ?? '');
  }

  /// `INR` (amount in paise) or `USD` (amount in cents) — must match dashboard currency.
  static String get currency {
    const fromDefine =
        String.fromEnvironment('RAZORPAY_CURRENCY', defaultValue: '');
    if (fromDefine.trim().isNotEmpty) {
      return fromDefine.trim().toUpperCase();
    }
    if (!dotenv.isInitialized) return 'INR';
    return (dotenv.env['RAZORPAY_CURRENCY'] ?? 'INR').trim().toUpperCase();
  }

  /// True when a non-empty key is available (define or `.env`).
  static bool get hasKeyId {
    final k = keyId;
    return k != null && k.isNotEmpty;
  }
}
