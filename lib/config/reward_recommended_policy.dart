/// When to show the “⭐ Recommended” hint on rewarded-ad rows (reduces noise after onboarding).
abstract final class RewardRecommendedPolicy {
  RewardRecommendedPolicy._();

  /// First N cold app launches always see the badge (then only in “confused” states).
  static const int maxAlwaysShowLaunches = 5;

  /// After [maxAlwaysShowLaunches], still show when balance is empty or the US line isn’t active yet.
  static bool showRecommendedBadge({
    required int appLaunchCount,
    required int usableCredits,
    required bool hasAssignedUsNumber,
  }) {
    if (appLaunchCount <= 0) return true;
    if (appLaunchCount <= maxAlwaysShowLaunches) return true;
    if (usableCredits <= 0) return true;
    if (!hasAssignedUsNumber) return true;
    return false;
  }
}
