import 'dart:math' as math;

/// TalkFree credit / ad reward rules (single source of truth).
///
/// **Outbound call billing (VoIP)** — server `POST /call-live-tick` + `settleOutboundCallBill`:
/// - **Free:** 1 credit every 6s while connected (10 credits / billed minute).
/// - **Premium:** 1 credit every 4s while connected (15 credits / billed minute; `CALL_CREDITS_PER_MINUTE_PREMIUM`).
/// - **Settlement** reconciles Twilio duration vs prepaid live ticks (see `server/index.js`).
abstract final class CreditsPolicy {
  CreditsPolicy._();

  /// Default usable balance for a **new** Firestore `users/{uid}` document.
  static const int initialCreditsForNewUser = 0;

  /// Credits per rewarded ad (server `POST /grant-reward`; free = 2, premium = 3).
  static int creditsPerRewardedAdForUser(bool isPremium) =>
      isPremium ? 3 : 2;

  /// Max rewarded ad grants per UTC day (server-enforced).
  static int maxRewardedAdsForUser(bool isPremium) =>
      isPremium ? 25 : 25;

  /// Minimum seconds between ad grants (server + UI cooldown).
  static int adRewardCooldownSecondsForUser(bool isPremium) =>
      isPremium ? 10 : 45;

  /// Legacy single-tier constant (free tier cap) — prefer [maxRewardedAdsForUser].
  static const int maxRewardedAdsPerDay = 25;

  /// Legacy free-tier cooldown — prefer [adRewardCooldownSecondsForUser].
  static const int adRewardCooldownSeconds = 45;

  /// Credits charged per **full minute** of billed talk — **free** users.
  static const int creditsPerMinute = 10;

  /// Per-minute rate for **premium** (server `CALL_CREDITS_PER_MINUTE_PREMIUM`).
  static const int creditsPerMinutePremium = 15;

  /// One-time welcome credits when premium is first activated (server `PREMIUM_WELCOME_BONUS`).
  static const int premiumWelcomeBonusCredits = 100;

  /// Monthly bonus range midpoint (server `POST /claim-premium-monthly-bonus`).
  static const int premiumMonthlyBundleCredits = 200;

  /// After balance hits 0 on a premium call, keep the line open this many seconds (once per call; UI + no extra ticks).
  static const int premiumCallGraceSeconds = 20;

  /// Starter pack: credits added on successful `starter_credits` purchase.
  static const int starterPackCredits = 80;

  /// Razorpay-backed credit packs (`POST /purchase-credits-pack` + `/verify-payment`).
  static const List<CreditPackOffer> creditPackOffers = [
    CreditPackOffer(
      packId: 'small',
      rupeesLabel: '₹49',
      credits: 100,
    ),
    CreditPackOffer(
      packId: 'medium',
      rupeesLabel: '₹99',
      credits: 250,
    ),
    CreditPackOffer(
      packId: 'large',
      rupeesLabel: '₹199',
      credits: 600,
    ),
  ];

  /// Free tier: after this many lifetime rewarded ads, show soft “skip ads / credits pack” before the next grant.
  static const int softPaywallLifetimeAdsThreshold = 40;

  /// Require this many successful grants in [softPaywallBurstWindowMinutes] before the paywall may show.
  static const int softPaywallMinGrantsInBurstWindow = 3;

  /// Rolling window (minutes) for “heavy burst” paywall gating.
  static const int softPaywallBurstWindowMinutes = 10;

  /// Minimum time between paywall impressions for the same user.
  static const int softPaywallCooldownHours = 24;

  /// When usable credits are at or below this (free tier), paywall may trigger without the 3-in-10m burst.
  static const int softPaywallLowCreditsMaxUsable = 10;

  /// With low credits, require at least this many lifetime rewarded ads before bypassing burst.
  static const int softPaywallLowCreditsMinLifetimeAds = 20;

  /// Premium browse-number purchase (server `BROWSE_NUMBER_PRICE`).
  static const int browseNumberPriceCredits = 150;

  static int creditsPerMinuteForUser(bool isPremium) =>
      isPremium ? creditsPerMinutePremium : creditsPerMinute;

  /// Free tier per-minute rate minus Pro rate (for “savings” copy on Pro home).
  static int get creditsSavedPerMinuteVsFree =>
      creditsPerMinute - creditsPerMinutePremium;

  /// Legacy: first connect bucket in older docs; live ticks use [connectedLiveCreditPerTick].
  static const int creditsPerCallTick = 10;

  /// Each `/call-live-tick` pulse while in call (**free:** every [connectedLiveCreditIntervalSec]).
  static const int connectedLiveCreditPerTick = 1;

  static const int connectedLiveCreditIntervalSec = 6;

  /// Premium live tick period (ms): `60000 / creditsPerMinutePremium` → 15 credits / minute.
  static const int premiumLiveTickPeriodMs =
      4000; // 60000 / 15; keep in sync with server settlement

  static Duration get premiumLiveTickPeriod =>
      const Duration(milliseconds: premiumLiveTickPeriodMs);

  /// Settlement alignment for free tier (ceil(seconds / 6) tick units).
  static const int callCreditsPerBilledMinute = 10;

  static const int callCreditsPerBilledMinutePremium = 15;

  static int callCreditsPerBilledMinuteForUser(bool isPremium) =>
      isPremium ? callCreditsPerBilledMinutePremium : callCreditsPerBilledMinute;

  static const Duration callBalanceCheckInterval = Duration(seconds: 4);

  static const Duration freeRewardCreditTtl = Duration(hours: 24);

  /// Minimum balance to start a call (both tiers — credit-based calling).
  static const int minCreditsToStartCall = callCreditsPerBilledMinute;

  static int minCreditsToStartCallFor(bool isPremium) => minCreditsToStartCall;

  /// Show low-balance nudges when usable credits fall below this.
  static const int lowCreditWarningThreshold = 10;

  /// Consecutive UTC days with ≥1 rewarded ad — milestone bonuses (server `POST /grant-reward`).
  static const List<int> adStreakMilestoneDays = [3, 7, 14, 30];

  static int streakBonusCreditsAtMilestoneDay(int day) {
    switch (day) {
      case 3:
        return 5;
      case 7:
        return 10;
      case 14:
        return 25;
      case 30:
        return 50;
      default:
        return 0;
    }
  }

  static ({int day, int bonusCredits})? nextStreakMilestoneAfter(int currentStreakDays) {
    for (final d in adStreakMilestoneDays) {
      if (currentStreakDays < d) {
        final b = streakBonusCreditsAtMilestoneDay(d);
        if (b > 0) return (day: d, bonusCredits: b);
      }
    }
    return null;
  }

  /// Pro / credit browse path only — free US line unlock uses [numberUnlockAdsRequired] ads, not credits.
  static const int assignNumberMinCredits = 100;
  static const int numberRenewAdsRequired = 5;
  static const int numberRenewCredits = 100;
  static const int maxRenewalsPerDay = 2;
  /// Premium outbound SMS (Twilio); free tier uses [otpAdsRequiredPerSms] rewarded ads per send instead.
  static const int smsOutboundCreditCost = 3;

  /// Free tier: rewarded ads required before auto-assign US number (server + UI).
  static const int numberUnlockAdsRequired = 80;

  /// Free tier: banked rewarded ads toward one outbound SMS (server `POST /send-sms`).
  static const int otpAdsRequiredPerSms = 5;

  @Deprecated('Use numberUnlockAdsRequired')
  static const int assignNumberMinAdsWatched = numberUnlockAdsRequired;

  /// Rough outbound talk time (seconds) from one rewarded-ad **call** grant at live-tick rates.
  static int approxTalkSecondsForAdGrant(bool isPremium) {
    final c = creditsPerRewardedAdForUser(isPremium);
    if (c <= 0) return 0;
    if (!isPremium) {
      return c * connectedLiveCreditIntervalSec;
    }
    return math.max(1, ((c * premiumLiveTickPeriodMs) / 1000).round());
  }

  /// Short copy under “watch ad → call” CTAs (matches grant size + tick cadence).
  static String rewardAdEmotionalSubtitleCall(bool isPremium) {
    final c = creditsPerRewardedAdForUser(isPremium);
    final sec = approxTalkSecondsForAdGrant(isPremium);
    return '+$c credits (~$sec sec call)';
  }

  static String rewardAdEmotionalSubtitleNumber() =>
      'Unlock progress ($numberUnlockAdsRequired needed)';

  static String rewardAdEmotionalSubtitleOtp() =>
      'Use for 1 SMS ($otpAdsRequiredPerSms needed)';

  static int leaseDurationMsForPlanType(String? planType) {
    switch (planType?.toLowerCase().trim()) {
      case 'daily':
        return const Duration(days: 1).inMilliseconds;
      case 'weekly':
        return const Duration(days: 7).inMilliseconds;
      case 'monthly':
        return 2592000000;
      case 'yearly':
        return 31536000000;
      default:
        return 2592000000;
    }
  }
}

/// One purchasable credit pack (server `plan_key`: `credit_pack_{packId}`).
class CreditPackOffer {
  const CreditPackOffer({
    required this.packId,
    required this.rupeesLabel,
    required this.credits,
  });

  final String packId;
  final String rupeesLabel;
  final int credits;

  String get planKey => 'credit_pack_$packId';
}
