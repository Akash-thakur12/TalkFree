import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Loads `.env` from Flutter assets (`pubspec.yaml` → `assets: - .env`) and merges
/// compile-time `--dart-define=KEY=value` entries (e.g. CI / local overrides).
abstract final class AppEnv {
  AppEnv._();

  static Map<String, String> get _dartDefineMerge {
    const key = String.fromEnvironment('RAZORPAY_KEY_ID', defaultValue: '');
    const cur = String.fromEnvironment('RAZORPAY_CURRENCY', defaultValue: '');
    final m = <String, String>{};
    if (key.trim().isNotEmpty) m['RAZORPAY_KEY_ID'] = key.trim();
    if (cur.trim().isNotEmpty) m['RAZORPAY_CURRENCY'] = cur.trim();
    return m;
  }

  /// Call once from `main()` before [runApp]. Always leaves [dotenv] initialized.
  static Future<void> loadDotEnv() async {
    final merge = _dartDefineMerge;
    try {
      await dotenv.load(fileName: '.env', mergeWith: merge);
      if (kDebugMode) {
        debugPrint(
          'dotenv: loaded .env (${dotenv.env.length} keys, merge: ${merge.length})',
        );
      }
    } catch (e, st) {
      debugPrint(
        'dotenv: asset .env missing or invalid — $e\n'
        'Copy .env.example → .env in project root, or use --dart-define.\n$st',
      );
      dotenv.loadFromString(
        envString: '',
        isOptional: true,
        mergeWith: merge,
      );
    }
    if (kDebugMode) {
      final id = dotenv.env['RAZORPAY_KEY_ID'] ?? '';
      debugPrint(
        'dotenv: RAZORPAY_KEY_ID ${id.isEmpty ? "NOT SET" : "set (${id.length} chars)"}',
      );
    }
  }
}
