import '../config/credits_policy.dart';

/// Psychology / conversion strings (keep concise; avoid overuse in one screen).
abstract final class MonetizationCopy {
  MonetizationCopy._();

  /// Trust row — headline (number) + subtitle line below.
  static const String socialProofUpgradesTitle = '8,000+';
  static const String socialProofUpgradesSubtitle = 'in the last 24 hours';

  static const String proWithinTwoDays =
      '⚡ Most users go Pro within 2 days';

  /// Shown under the ad cooldown bar (free tier).
  static const String cooldownGoProHint =
      'Short wait — Pro skips this cooldown';
  static const String limitedTimeBonus = 'Limited time bonus';

  static const String watchAdEarn = 'Watch ad to get credits';
  static const String needCreditsToCall = 'You need credits to call';

  static const String outOfCreditsTitle = "You're out of credits";
  static const String tiredOfAdsTitle = 'Tired of watching ads?';
  static const String tiredOfAdsBody = 'Upgrade and call instantly ⚡';

  /// Shown after the ad SDK rewards heavy free-tier watchers (before server grant).
  static const String softPaywallTitle = 'Skip ads — get instant credits';
  static const String softPaywallValueLine =
      'No ads • Faster calls • Instant credits';

  static String softPaywallBody(String priceLabel) =>
      'You’ve powered through a lot of ads. Grab the Starter Pack ($priceLabel) for instant credits and less grinding.';

  /// Rough “time is money” nudge (not financial advice).
  static String softPaywallSaveApproxRupeeLine({
    required int lifetimeAdsThreshold,
    required String priceLabel,
  }) {
    final x = (lifetimeAdsThreshold * 15).clamp(150, 999);
    return 'Save ~₹$x+ in ad-watching time vs $priceLabel pack.';
  }

  static const String softPaywallPrimaryCta = 'View packs';
  static const String softPaywallDismiss = 'Continue for free reward';

  /// Rough talk time from Starter Pack credits at free-tier per-minute burn.
  static String softPaywallStarterMinutesLine() {
    final m = CreditsPolicy.starterPackCredits ~/ CreditsPolicy.creditsPerMinute;
    final mins = m < 1 ? 1 : m;
    return '~$mins mins talk at free-tier calling rate (Starter Pack).';
  }
  static const String dailyLimitTitle = 'Daily limit reached';
  static const String dailyLimitBody = 'Upgrade to continue now';

  /// One-shot hint while on a call (free tier, low balance).
  static String inCallLowCreditsProBenefit({required int premiumCreditsPerMin}) =>
      'Balance is low. Pro uses $premiumCreditsPerMin credits/min with steadier routing — optional upgrade.';

  static const String premiumInstantHeadline = 'Start Calling Instantly ⚡';
  static const String premiumInstantSub = '⚡ Instant access enabled';
}
