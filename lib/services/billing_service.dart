import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_scaffold_messenger.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import 'firestore_user_service.dart';

/// Central place to push an authoritative usable-credit total to Firestore after
/// ads or calls so listeners (e.g. dashboard) see updates quickly even if a
/// write was delayed.
class BillingService {
  BillingService._();
  static final BillingService instance = BillingService._();

  /// Updates `users/{uid}` so `paidCredits` / `rewardCredits` / `credits` match
  /// [newBalance] (usable total). Returns `false` on network or permission errors.
  Future<bool> syncCreditsToCloud(int newBalance) async {
    try {
      await FirestoreUserService.syncUsableCreditsToCloud(newBalance);
      return true;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('BillingService.syncCreditsToCloud failed: $e\n$st');
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = appScaffoldMessengerKey.currentContext;
        if (ctx == null || !ctx.mounted) return;
        AppSnackBar.showRoot(
          SnackBar(
            content: const Text('Sync failed, will retry later'),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(ctx),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      });
      return false;
    }
  }
}
