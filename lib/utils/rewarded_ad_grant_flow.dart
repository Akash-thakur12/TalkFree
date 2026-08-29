import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/credits_policy.dart';
import '../config/reward_ad_ui_prefs.dart';
import '../services/ad_service.dart';
import '../services/grant_reward_service.dart'
    show GrantRewardException, GrantRewardPurpose, GrantRewardService;
import '../services/reward_sound_service.dart';
import '../theme/app_theme.dart';
import 'app_snackbar.dart';
import 'reward_ad_feedback.dart';
import 'soft_paywall_gate.dart';
import '../widgets/engagement_overlays.dart';

export 'soft_paywall_gate.dart' show maybeShowSoftAdPaywallBeforeGrant, recordSoftPaywallGrantSuccess;

/// Plays a rewarded ad then POSTs `/grant-reward` with [purpose] (server enforces one reward per ad).
Future<void> runRewardedAdGrantFlow({
  required BuildContext context,
  required bool isPremium,
  required GrantRewardPurpose purpose,
}) async {
  final earned = await AdService.instance.loadAndShowRewardedAd();
  if (!context.mounted) return;
  if (!earned) return;
  try {
    await maybeShowSoftAdPaywallBeforeGrant(context, isPremium: isPremium);
    if (!context.mounted) return;
    final result = await GrantRewardService.instance.requestMinuteGrant(
      purpose,
      adVerified: true,
    );
    if (!context.mounted) return;
    if (result.deduped) {
      EngagementOverlays.showRewardMicroToast(
        context,
        headline: 'Ad already counted',
        subline: result.message ?? 'Reward already granted.',
      );
      return;
    }
    if (purpose == GrantRewardPurpose.call && result.creditsAdded > 0) {
      unawaited(RewardSoundService.playCoin());
      EngagementOverlays.showAdRewardFanfare(
        context,
        creditsAdded: result.creditsAdded,
        streakBonus: result.streakBonus,
        streakDays: result.streakCount,
        welcomeFirstAd: result.firstLifetimeAd,
        isPremium: isPremium,
      );
      EngagementOverlays.showFloatingCreditDelta(
        context,
        delta: result.creditsAdded,
      );
    } else if (purpose == GrantRewardPurpose.call) {
      EngagementOverlays.showRewardMicroToast(
        context,
        headline: 'Reward saved',
        subline: 'Balance will sync shortly.',
      );
    } else if (purpose == GrantRewardPurpose.number) {
      final p = result.numberAdsProgress;
      final cap = CreditsPolicy.numberUnlockAdsRequired;
      EngagementOverlays.showRewardMicroToast(
        context,
        headline: '+1 unlock progress',
        subline: p != null
            ? '$p / $cap toward your US line'
            : 'One step closer to your number.',
      );
    } else if (purpose == GrantRewardPurpose.otp) {
      final p = result.otpAdsProgress;
      final cap = CreditsPolicy.otpAdsRequiredPerSms;
      EngagementOverlays.showRewardMicroToast(
        context,
        headline: '+1 SMS ready',
        subline: p != null
            ? '$p / $cap toward a free send'
            : 'Bank updated — keep going.',
      );
    }
    unawaited(recordSoftPaywallGrantSuccess());
    unawaited(_persistLastSelectedGrantPurpose(purpose));
  } on GrantRewardException catch (e) {
    if (context.mounted) {
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text(RewardAdFeedback.forGrantError(e)),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
    }
    return;
  } catch (e) {
    if (context.mounted) {
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text('Could not apply reward: $e'),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
    }
    return;
  }
}

Future<void> _persistLastSelectedGrantPurpose(GrantRewardPurpose purpose) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RewardAdUiPrefs.lastSelectedGrantPurposeStorageKey,
      purpose.name,
    );
  } catch (_) {
    // Best-effort only.
  }
}
