import 'dart:async';

import 'package:http/http.dart' as http;

import 'monetization_copy.dart';
import '../services/grant_reward_service.dart';

/// User-facing copy for rewarded-ad flows — keep messages consistent app-wide.
abstract final class RewardAdFeedback {
  RewardAdFeedback._();

  static const String incompleteAd = 'Watch full ad to earn credits';
  static const String processingReward = 'Processing reward...';
  static const String network = 'Check your internet connection';
  static const String serverIssue = 'Server issue. Try again later';
  static String dailyLimit =
      '${MonetizationCopy.dailyLimitTitle}. ${MonetizationCopy.dailyLimitBody}';

  static String cooldownBeforeNextAd() =>
      'Please wait before the next ad (cooldown active).';

  static String successCreditsAdded(int credits) =>
      '+$credits credits added 🎉';

  static String adsRemainingToday(int remaining) =>
      'You can watch $remaining ads today';

  static const String adShowFailed =
      'Could not show the ad. Try again in a moment.';
  static const String grantSyncFailed =
      'Could not add credits. Try again.';

  /// Maps [GrantRewardException] and generic errors to short UI strings.
  static String forGrantError(Object error) {
    if (error is GrantRewardException) {
      if (error.statusCode == 429) {
        final m = error.message;
        if (m.contains('Daily cap')) {
          return dailyLimit;
        }
        if (error.waitSeconds != null && error.waitSeconds! > 0) {
          return 'Wait ${error.waitSeconds}s to watch next ad';
        }
      }
      return _forStatus(error.statusCode, error.message);
    }
    if (_isNetworkLike(error)) return network;
    return grantSyncFailed;
  }

  /// Ad load/show failures (before `/grant-reward`).
  static String forAdPlaybackError(Object error) {
    if (_isNetworkLike(error)) return network;
    return adShowFailed;
  }

  static bool _isNetworkLike(Object error) {
    if (error is TimeoutException) return true;
    if (error is http.ClientException) return true;
    final s = error.toString();
    return s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('Failed host lookup') ||
        s.contains('Network is unreachable');
  }

  static String _forStatus(int code, String serverMessage) {
    switch (code) {
      case 429:
        return cooldownBeforeNextAd();
      case 403:
        return dailyLimit;
      case 503:
        return serverIssue;
      default:
        if (serverMessage.toLowerCase().contains('limit')) {
          return dailyLimit;
        }
        if (serverMessage.toLowerCase().contains('wait')) {
          return cooldownBeforeNextAd();
        }
        if (code >= 500) return serverIssue;
        return serverMessage.isNotEmpty ? serverMessage : serverIssue;
    }
  }
}
