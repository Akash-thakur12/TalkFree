import '../config/credits_policy.dart';
import 'monetization_copy.dart';

/// Dynamic rewarded-ad CTA copy (Home / Dialer) — CTR-focused variants.
abstract final class RewardAdCtaCopy {
  RewardAdCtaCopy._();

  /// Primary line + subtitle for the main green ad button.
  static ({String title, String subtitle}) homeOrDialer({
    required int lifetimeAdsWatched,
    required int streakDays,
    required bool isPremium,
  }) {
    final perAd = CreditsPolicy.creditsPerRewardedAdForUser(isPremium);
    final next = CreditsPolicy.nextStreakMilestoneAfter(streakDays);
    if (lifetimeAdsWatched == 0) {
      return (
        title: MonetizationCopy.watchAdEarn,
        subtitle: 'Earn $perAd call credits per ad',
      );
    }
    if (isPremium &&
        next != null &&
        next.day - streakDays == 1) {
      return (
        title: '🔥 Unlock +${next.bonusCredits} BONUS now',
        subtitle: 'One more ad · streak pays off',
      );
    }
    return (
      title: MonetizationCopy.watchAdEarn,
      subtitle: 'Earn $perAd call credits per ad',
    );
  }
}
