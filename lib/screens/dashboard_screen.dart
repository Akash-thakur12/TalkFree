import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, immutable, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/credits_policy.dart';
import '../config/reward_ad_ui_prefs.dart';
import '../config/reward_recommended_policy.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/system_ui.dart';
import '../services/ad_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/monetization_copy.dart';
import '../utils/reward_ad_feedback.dart';
import '../utils/rewarded_ad_grant_flow.dart'
    show maybeShowSoftAdPaywallBeforeGrant, recordSoftPaywallGrantSuccess;
import '../widgets/engagement_overlays.dart';
import '../widgets/purpose_rewarded_ad_strip.dart';
import '../widgets/soft_pulse.dart';
import '../services/firestore_user_service.dart';
import '../services/twilio_voip_facade.dart';
import '../services/grant_reward_service.dart';
import '../services/subscription_payment_service.dart';
import '../services/reward_sound_service.dart';
import 'call_history_screen.dart';
import 'dialer_screen.dart';
import 'inbox_screen.dart';
import 'settings_screen.dart';
import 'premium_credits_wallet_screen.dart';
import 'subscription_screen.dart';
import 'virtual_number_screen.dart';

/// Immutable rewarded-ad row for ValueNotifier (equality avoids redundant notifies).
@immutable
class _AdRewardView {
  const _AdRewardView({
    required this.adsToday,
    required this.cooldownRemaining,
    required this.dailyLimitReached,
  });

  final int adsToday;
  final int cooldownRemaining;
  final bool dailyLimitReached;

  _AdRewardView copyWith({
    int? adsToday,
    int? cooldownRemaining,
    bool? dailyLimitReached,
  }) {
    return _AdRewardView(
      adsToday: adsToday ?? this.adsToday,
      cooldownRemaining: cooldownRemaining ?? this.cooldownRemaining,
      dailyLimitReached: dailyLimitReached ?? this.dailyLimitReached,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _AdRewardView &&
            other.adsToday == adsToday &&
            other.cooldownRemaining == cooldownRemaining &&
            other.dailyLimitReached == dailyLimitReached;
  }

  @override
  int get hashCode => Object.hash(adsToday, cooldownRemaining, dailyLimitReached);
}

String _firstName(String displayName) {
  final t = displayName.trim();
  if (t.isEmpty) return 'there';
  return t.split(RegExp(r'\s+')).first;
}

String _formatTalkHhMm(int totalSeconds) {
  final s = totalSeconds < 0 ? 0 : totalSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  if (h > 0) {
    return '${h}h ${m}m';
  }
  if (m > 0) {
    return '${m}m';
  }
  return '0m';
}

String _proHomeLineSubtitle(String? assignedRaw, String? lineStatus) {
  final assigned = (assignedRaw ?? '').trim();
  if (assigned.isEmpty) {
    return 'Add a US number from the Number tab';
  }
  if (lineStatus == 'active') {
    return 'Your line is active';
  }
  if (lineStatus == 'expired') {
    return 'Your line needs renewal';
  }
  return 'Your number is ready';
}

/// Smooth numeric change for wallet / stats (no logic — display only).
class _AnimatedIntText extends StatefulWidget {
  const _AnimatedIntText({
    required this.value,
    required this.style,
  });

  final int value;
  final TextStyle style;

  @override
  State<_AnimatedIntText> createState() => _AnimatedIntTextState();
}

class _AnimatedIntTextState extends State<_AnimatedIntText> {
  late int _from;

  @override
  void initState() {
    super.initState();
    _from = widget.value;
  }

  @override
  void didUpdateWidget(covariant _AnimatedIntText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _from = oldWidget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: _from, end: widget.value),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        return Text(
          '$v',
          style: widget.style.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 0,
          ),
        );
      },
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.user,
    this.initialNavIndex = 0,
  }) : assert(
          initialNavIndex >= 0 && initialNavIndex < 5,
          'initialNavIndex: 0 home, 1 dialer, 2 number, 3 inbox, 4 premium',
        );

  final User user;

  /// `0` home · `1` dialer · `2` number · `3` inbox · `4` premium.
  final int initialNavIndex;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _rewardedAdBusy = false;
  /// True while `POST /grant-reward` is in flight (after ad earned reward).
  bool _grantRewardPending = false;
  late int _navIndex;

  /// Last rewarded-ad purpose the user chose (persisted) — highlights that row on all strips until they pick another.
  GrantRewardPurpose? _lastSelectedGrantPurpose;

  /// “⭐ Recommended” on primary ad rows (first launches + low credits / no line).
  bool _showRewardRecommendedBadge = true;
  int? _appLaunchCount;

  /// Client-side cooldown after a rewarded ad finishes (sync with tier policy).
  Timer? _localAdCooldownTimer;
  int _localAdCooldownSeconds = 0;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userDocSub;
  Timer? _cooldownWallClock;
  DocumentSnapshot<Map<String, dynamic>>? _latestUserDoc;

  /// Avoid spamming SnackBars if the user document stream errors repeatedly.
  bool _userDocStreamErrorNotified = false;

  final ValueNotifier<int> _credits = ValueNotifier<int>(0);
  /// US line from Firestore (`assigned_number` / mirrors) — updated live from [FirestoreUserService.watchUserDocument]
  /// while this screen stays mounted (including when other routes are pushed on top). No manual refresh needed after
  /// `Navigator.popUntil` from number provisioning; the next snapshot updates Home (Virtual Number card) automatically.
  final ValueNotifier<String?> _assignedNumber = ValueNotifier<String?>(null);
  final ValueNotifier<int> _lifetimeAdsWatched = ValueNotifier<int>(0);
  /// `'free'` | `'premium'` from Firestore ([FirestoreUserService.subscriptionTierFromUserData]).
  final ValueNotifier<String> _subscriptionTier = ValueNotifier<String>('free');
  /// Twilio line lease (for dashboard ring); `null` if unset / legacy.
  final ValueNotifier<DateTime?> _numberLeaseExpiry =
      ValueNotifier<DateTime?>(null);
  /// Server line status (`active` | `expired`); see [FirestoreUserService.numberLineStatusFromUserData].
  final ValueNotifier<String?> _numberLineStatus =
      ValueNotifier<String?>(null);
  /// Server `number_tier`: `normal` | `vip` | `premium`.
  final ValueNotifier<String?> _numberTier =
      ValueNotifier<String?>(null);
  final ValueNotifier<String?> _numberPlanType = ValueNotifier<String?>(null);
  /// Banked rewarded ads toward POST `/renew-number` (mode `ads`).
  final ValueNotifier<int> _numberRenewAdProgress = ValueNotifier<int>(0);
  /// Server-maintained totals (Twilio settlement); see [FirestoreUserService.totalOutboundCallsFromUserData].
  final ValueNotifier<int> _outboundCallsTotal = ValueNotifier<int>(0);
  final ValueNotifier<int> _totalCallTalkSeconds = ValueNotifier<int>(0);
  /// Server-maintained `ad_streak_count` (UTC consecutive ad days).
  final ValueNotifier<int> _adStreakCount = ValueNotifier<int>(0);
  final ValueNotifier<_AdRewardView> _adView = ValueNotifier<_AdRewardView>(
    const _AdRewardView(
      adsToday: 0,
      cooldownRemaining: 0,
      dailyLimitReached: false,
    ),
  );

  void _setAdViewIfChanged(_AdRewardView next) {
    if (_adView.value == next) return;
    _adView.value = next;
  }

  GrantRewardPurpose? _grantPurposeFromStorage(String? raw) {
    switch (raw) {
      case 'call':
        return GrantRewardPurpose.call;
      case 'number':
        return GrantRewardPurpose.number;
      case 'otp':
        return GrantRewardPurpose.otp;
      default:
        return null;
    }
  }

  GrantRewardPurpose _defaultStripEmphasisForTab(int tabIndex) {
    switch (tabIndex) {
      case 2:
        return GrantRewardPurpose.number;
      case 3:
        return GrantRewardPurpose.otp;
      default:
        return GrantRewardPurpose.call;
    }
  }

  GrantRewardPurpose _stripEmphasisForTab(int tabIndex) =>
      _lastSelectedGrantPurpose ?? _defaultStripEmphasisForTab(tabIndex);

  /// Stronger ad-strip pulse when the user repeats their last grant on this tab’s “natural” purpose.
  bool _repeatHabitPulseBoostForTab(int tabIndex) =>
      _lastSelectedGrantPurpose != null &&
      _lastSelectedGrantPurpose == _defaultStripEmphasisForTab(tabIndex);

  Future<void> _persistLastSelectedGrantPurpose(GrantRewardPurpose p) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(RewardAdUiPrefs.lastSelectedGrantPurposeStorageKey, p.name);
      if (mounted) {
        setState(() => _lastSelectedGrantPurpose = p);
      }
    } catch (_) {
      // Best-effort only.
    }
  }

  /// Single source of truth from cached snapshot + local post-ad cooldown (no full Scaffold rebuild).
  void _refreshFromLatestSnapshot() {
    final snap = _latestUserDoc;
    if (snap == null) return;
    final t = FirestoreUserService.adRewardStatusFromSnapshot(snap);
    final cool = math.max(t.cooldownRemaining, _localAdCooldownSeconds);
    _setAdViewIfChanged(
      _AdRewardView(
        adsToday: t.adsToday,
        cooldownRemaining: cool,
        dailyLimitReached: t.dailyLimitReached,
      ),
    );
    final cr = FirestoreUserService.usableCreditsFromSnapshot(snap);
    if (_credits.value != cr) {
      _credits.value = cr;
    }
    final d = snap.data();
    final assigned = FirestoreUserService.assignedNumberFromUserData(d);
    if (_assignedNumber.value != assigned) {
      _assignedNumber.value = assigned;
    }
    final lw = FirestoreUserService.lifetimeAdsWatchedFromUserData(d);
    if (_lifetimeAdsWatched.value != lw) {
      _lifetimeAdsWatched.value = lw;
    }
    final tier = FirestoreUserService.subscriptionTierFromUserData(d);
    if (_subscriptionTier.value != tier) {
      _subscriptionTier.value = tier;
    }
    final leaseExp = FirestoreUserService.numberLeaseExpiryFromUserData(d);
    if (_numberLeaseExpiry.value?.millisecondsSinceEpoch !=
        leaseExp?.millisecondsSinceEpoch) {
      _numberLeaseExpiry.value = leaseExp;
    }
    final lineSt = FirestoreUserService.numberLineStatusFromUserData(d);
    if (_numberLineStatus.value != lineSt) {
      _numberLineStatus.value = lineSt;
    }
    final nt = FirestoreUserService.numberTierFromUserData(d);
    if (_numberTier.value != nt) {
      _numberTier.value = nt;
    }
    final planT = FirestoreUserService.numberPlanTypeFromUserData(d);
    if (_numberPlanType.value != planT) {
      _numberPlanType.value = planT;
    }
    final renewP = FirestoreUserService.numberRenewAdProgressFromUserData(d);
    if (_numberRenewAdProgress.value != renewP) {
      _numberRenewAdProgress.value = renewP;
    }
    final calls = FirestoreUserService.totalOutboundCallsFromUserData(d);
    if (_outboundCallsTotal.value != calls) {
      _outboundCallsTotal.value = calls;
    }
    final talk = FirestoreUserService.totalCallTalkSecondsFromUserData(d);
    if (_totalCallTalkSeconds.value != talk) {
      _totalCallTalkSeconds.value = talk;
    }
    final streak = FirestoreUserService.adStreakCountFromUserData(d);
    if (_adStreakCount.value != streak) {
      _adStreakCount.value = streak;
    }
    _syncRewardRecommendedBadgeVisibility();
  }

  void _syncRewardRecommendedBadgeVisibility() {
    final isPro =
        FirestoreUserService.isPremiumTierLabel(_subscriptionTier.value);
    final bool next;
    if (isPro) {
      next = false;
    } else {
      final launches = _appLaunchCount ?? 0;
      final hasNum = (_assignedNumber.value ?? '').trim().isNotEmpty;
      next = RewardRecommendedPolicy.showRecommendedBadge(
        appLaunchCount: launches,
        usableCredits: _credits.value,
        hasAssignedUsNumber: hasNum,
      );
    }
    if (next != _showRewardRecommendedBadge) {
      setState(() => _showRewardRecommendedBadge = next);
    }
  }

  void _applyOptimisticAdWatched() {
    final v = _adView.value;
    final cap = CreditsPolicy.maxRewardedAdsForUser(
      FirestoreUserService.isPremiumTierLabel(_subscriptionTier.value),
    );
    _setAdViewIfChanged(
      v.copyWith(
        adsToday: v.adsToday + 1,
        dailyLimitReached: v.adsToday + 1 >= cap,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    applyTalkFreeDarkNavigationChrome();
    _navIndex = widget.initialNavIndex;
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _appLaunchCount = p.getInt('talkfree_app_launch_count') ?? 1;
        _lastSelectedGrantPurpose = _grantPurposeFromStorage(
          p.getString(RewardAdUiPrefs.lastSelectedGrantPurposeStorageKey),
        );
      });
      _syncRewardRecommendedBadgeVisibility();
    });
    _userDocSub =
        FirestoreUserService.watchUserDocument(widget.user.uid).listen(
      (snap) {
        _userDocStreamErrorNotified = false;
        _latestUserDoc = snap;
        _refreshFromLatestSnapshot();
      },
      onError: (Object e, StackTrace st) {
        if (kDebugMode) {
          debugPrint('watchUserDocument error: $e\n$st');
        }
        if (!mounted) return;
        if (_userDocStreamErrorNotified) return;
        _userDocStreamErrorNotified = true;
        AppSnackBar.show(context,
          SnackBar(
            content: const Text(
              'Could not load your credits. Check your connection and try again.',
            ),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: const Duration(seconds: 5),
          ),
        );
      },
    );
    _cooldownWallClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _refreshFromLatestSnapshot();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        SubscriptionPaymentService.instance.tryClaimPremiumMonthlyBonus(),
      );
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        unawaited(
          TwilioVoipFacade.instance.warmUpAndroidVoiceAtAppLaunch(
            widget.user.uid,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _userDocSub?.cancel();
    _cooldownWallClock?.cancel();
    _localAdCooldownTimer?.cancel();
    _credits.dispose();
    _assignedNumber.dispose();
    _lifetimeAdsWatched.dispose();
    _subscriptionTier.dispose();
    _numberLeaseExpiry.dispose();
    _numberLineStatus.dispose();
    _numberTier.dispose();
    _numberPlanType.dispose();
    _numberRenewAdProgress.dispose();
    _outboundCallsTotal.dispose();
    _totalCallTalkSeconds.dispose();
    _adStreakCount.dispose();
    _adView.dispose();
    super.dispose();
  }

  /// Fires when the user earned reward — before `/grant-reward` — so the button locks immediately.
  void _startPostAdCooldown() {
    _localAdCooldownTimer?.cancel();
    _localAdCooldownSeconds = CreditsPolicy.adRewardCooldownSecondsForUser(
      FirestoreUserService.isPremiumTierLabel(_subscriptionTier.value),
    );
    _refreshFromLatestSnapshot();
    _localAdCooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _localAdCooldownSeconds -= 1;
      if (_localAdCooldownSeconds <= 0) {
        _localAdCooldownSeconds = 0;
        _localAdCooldownTimer?.cancel();
        _localAdCooldownTimer = null;
      }
      _refreshFromLatestSnapshot();
    });
  }

  /// After server 429 cooldown — aligns local UI with [waitSeconds] from `/grant-reward`.
  void _applyServerCooldownSeconds(int waitSeconds) {
    _localAdCooldownTimer?.cancel();
    _localAdCooldownSeconds = math.max(1, waitSeconds);
    _refreshFromLatestSnapshot();
    _localAdCooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _localAdCooldownSeconds -= 1;
      if (_localAdCooldownSeconds <= 0) {
        _localAdCooldownSeconds = 0;
        _localAdCooldownTimer?.cancel();
        _localAdCooldownTimer = null;
      }
      _refreshFromLatestSnapshot();
    });
  }

  Future<void> _onWatchRewardedAd(
    int cooldownRemaining,
    bool dailyLimitReached,
    GrantRewardPurpose purpose,
  ) async {
    if (_rewardedAdBusy) return;
    if (dailyLimitReached) {
      if (!mounted) return;
      AppSnackBar.show(context,
        SnackBar(
          content: Text(RewardAdFeedback.dailyLimit),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      return;
    }
    if (cooldownRemaining > 0) {
      if (!mounted) return;
      AppSnackBar.show(context,
        SnackBar(
          content: Text(RewardAdFeedback.cooldownBeforeNextAd()),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      return;
    }
    setState(() {
      _rewardedAdBusy = true;
      _grantRewardPending = false;
    });
    try {
      final earned = await AdService.instance.loadAndShowRewardedAd();
      if (!mounted) return;
      if (earned) {
        setState(() => _grantRewardPending = true);
        try {
          await maybeShowSoftAdPaywallBeforeGrant(
            context,
            isPremium: FirestoreUserService.isPremiumTierLabel(
              _subscriptionTier.value,
            ),
          );
          if (!mounted) return;
          final result =
              await GrantRewardService.instance.requestMinuteGrant(
            purpose,
            adVerified: true,
          );
          if (!mounted) return;
          if (result.deduped) {
            EngagementOverlays.showRewardMicroToast(
              context,
              headline: 'Ad already counted',
              subline: result.message ?? 'Reward already granted.',
            );
            return;
          }
          unawaited(recordSoftPaywallGrantSuccess());
          _applyOptimisticAdWatched();
          _startPostAdCooldown();
          unawaited(_persistLastSelectedGrantPurpose(purpose));
          if (purpose == GrantRewardPurpose.call && result.creditsAdded > 0) {
            _credits.value = _credits.value + result.creditsAdded;
            unawaited(RewardSoundService.playCoin());
            EngagementOverlays.showAdRewardFanfare(
              context,
              creditsAdded: result.creditsAdded,
              streakBonus: result.streakBonus,
              streakDays: result.streakCount,
              welcomeFirstAd: result.firstLifetimeAd,
              isPremium: FirestoreUserService.isPremiumTierLabel(
                _subscriptionTier.value,
              ),
            );
            EngagementOverlays.showFloatingCreditDelta(
              context,
              delta: result.creditsAdded,
            );
            if (result.adsWatchedToday == 3) {
              if (!mounted) return;
              AppSnackBar.show(context,
                SnackBar(
                  content: Text(
                    '${MonetizationCopy.tiredOfAdsTitle}\n'
                    '${MonetizationCopy.tiredOfAdsBody}',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                  ),
                  behavior: SnackBarBehavior.floating,
                  margin: AppTheme.snackBarFloatingMargin(context),
                  duration: AppTheme.snackBarCalmDuration,
                ),
              );
            }
          } else if (purpose == GrantRewardPurpose.call) {
            EngagementOverlays.showRewardMicroToast(
              context,
              headline: 'Reward saved',
              subline: 'Balance will sync on the next refresh.',
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
        } on GrantRewardException catch (e) {
          if (!mounted) return;
          if (e.statusCode == 429 &&
              e.waitSeconds != null &&
              e.waitSeconds! > 0) {
            _applyServerCooldownSeconds(e.waitSeconds!);
          }
          AppSnackBar.show(context,
            SnackBar(
              content: Text(RewardAdFeedback.forGrantError(e)),
              behavior: SnackBarBehavior.floating,
              margin: AppTheme.snackBarFloatingMargin(context),
              duration: AppTheme.snackBarCalmDuration,
            ),
          );
        } catch (e) {
          if (!mounted) return;
          AppSnackBar.show(context,
            SnackBar(
              content: Text(RewardAdFeedback.forGrantError(e)),
              behavior: SnackBarBehavior.floating,
              margin: AppTheme.snackBarFloatingMargin(context),
              duration: AppTheme.snackBarCalmDuration,
            ),
          );
        } finally {
          if (mounted) {
            setState(() => _grantRewardPending = false);
          }
        }
      } else {
        AppSnackBar.show(context,
          SnackBar(
            content: Text(RewardAdFeedback.incompleteAd),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.show(context,
        SnackBar(
          content: Text(RewardAdFeedback.forAdPlaybackError(e)),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _rewardedAdBusy = false;
          _grantRewardPending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = widget.user.displayName?.trim();
    final displayName =
        name != null && name.isNotEmpty ? name : 'TalkFree user';

    // Credits outer so balance-only updates don't rebuild rewarded-ad UI (and vice versa).
    return ValueListenableBuilder<int>(
      valueListenable: _credits,
      builder: (context, credits, _) {
        return ValueListenableBuilder<_AdRewardView>(
          valueListenable: _adView,
          builder: (context, ad, _) {
            final cooldownRemaining = ad.cooldownRemaining;
            final adsToday = ad.adsToday;
            final dailyLimitReached = ad.dailyLimitReached;

            // One body subtree at a time — no IndexedStack (avoids touch bugs on some
            // OEM builds where an invisible sibling still wins hit testing).
            late final Widget tabBody;
            if (_navIndex == 0) {
              tabBody = _DashboardHomeTab(
                user: widget.user,
                displayName: displayName,
                theme: theme,
                rewardedAdBusy: _rewardedAdBusy,
                grantRewardPending: _grantRewardPending,
                cooldownRemaining: cooldownRemaining,
                adsToday: adsToday,
                dailyLimitReached: dailyLimitReached,
                credits: credits,
                assignedNumber: _assignedNumber,
                numberLeaseExpiry: _numberLeaseExpiry,
                numberLineStatus: _numberLineStatus,
                numberTier: _numberTier,
                numberPlanType: _numberPlanType,
                numberRenewAdProgress: _numberRenewAdProgress,
                lifetimeAdsWatched: _lifetimeAdsWatched,
                subscriptionTier: _subscriptionTier,
                outboundCallsTotal: _outboundCallsTotal,
                totalCallTalkSeconds: _totalCallTalkSeconds,
                adStreakCount: _adStreakCount,
                purposeStripEmphasis: _stripEmphasisForTab(0),
                repeatHabitPulseBoost: _repeatHabitPulseBoostForTab(0),
                showRewardRecommendedBadge: _showRewardRecommendedBadge,
                onWatchPurposeAd: (purpose) => _onWatchRewardedAd(
                  cooldownRemaining,
                  dailyLimitReached,
                  purpose,
                ),
                onGoToDialer: () => setState(() => _navIndex = 1),
                onGoToNumberTab: () => setState(() => _navIndex = 2),
                onOpenCallHistory: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => ValueListenableBuilder<String>(
                        valueListenable: _subscriptionTier,
                        builder: (context, tier, _) {
                          final isPro =
                              FirestoreUserService.isPremiumTierLabel(tier);
                          return CallHistoryScreen(
                            user: widget.user,
                            isPremium: isPro,
                            onStartCalling: () {
                              setState(() => _navIndex = 1);
                            },
                            onWatchPurposeAd: isPro
                                ? null
                                : (purpose) => _onWatchRewardedAd(
                                      cooldownRemaining,
                                      dailyLimitReached,
                                      purpose,
                                    ),
                            rewardedAdBusy: _rewardedAdBusy,
                            grantRewardPending: _grantRewardPending,
                            cooldownRemaining: cooldownRemaining,
                            dailyLimitReached: dailyLimitReached,
                            showRewardRecommendedBadge:
                                _showRewardRecommendedBadge,
                          );
                        },
                      ),
                    ),
                  );
                },
              );
            } else if (_navIndex == 1) {
              tabBody = ValueListenableBuilder<String>(
                valueListenable: _subscriptionTier,
                builder: (context, tier, _) {
                  final isPro = FirestoreUserService.isPremiumTierLabel(tier);
                  return DialerScreen(
                    key: const ValueKey<Object>('talkfree_dialer'),
                    user: widget.user,
                    isPremium: isPro,
                    emphasizeRewardPurpose: _stripEmphasisForTab(1),
                    repeatHabitPulseBoost: _repeatHabitPulseBoostForTab(1),
                    showRecommendedBadge: _showRewardRecommendedBadge,
                    embedInShell: true,
                    onOpenSettings: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => SettingsScreen(
                            user: widget.user,
                          ),
                        ),
                      );
                    },
                    onOpenHistory: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => ValueListenableBuilder<String>(
                            valueListenable: _subscriptionTier,
                            builder: (context, tier, _) {
                              final isPro = FirestoreUserService
                                  .isPremiumTierLabel(tier);
                              return CallHistoryScreen(
                                user: widget.user,
                                isPremium: isPro,
                                onStartCalling: () {
                                  setState(() => _navIndex = 1);
                                },
                                onWatchPurposeAd: isPro
                                    ? null
                                    : (purpose) => _onWatchRewardedAd(
                                          cooldownRemaining,
                                          dailyLimitReached,
                                          purpose,
                                        ),
                                rewardedAdBusy: _rewardedAdBusy,
                                grantRewardPending: _grantRewardPending,
                                cooldownRemaining: cooldownRemaining,
                                dailyLimitReached: dailyLimitReached,
                                showRewardRecommendedBadge:
                                    _showRewardRecommendedBadge,
                              );
                            },
                          ),
                        ),
                      );
                    },
                    onEarnMinutes: isPro
                        ? null
                        : (purpose) => _onWatchRewardedAd(
                              cooldownRemaining,
                              dailyLimitReached,
                              purpose,
                            ),
                    rewardedAdBusy: _rewardedAdBusy,
                    cooldownRemaining: cooldownRemaining,
                    rewardDailyLimitReached: dailyLimitReached,
                    outboundCallsTotal: _outboundCallsTotal,
                  );
                },
              );
            } else if (_navIndex == 2) {
              tabBody = VirtualNumberScreen(
                key: const ValueKey<String>('talkfree_number_tab'),
                embedInShell: true,
                userUid: widget.user.uid,
                userCredits: credits,
                showRecommendedBadge: _showRewardRecommendedBadge,
                onPurposeRewardAd: (purpose) => _onWatchRewardedAd(
                  cooldownRemaining,
                  dailyLimitReached,
                  purpose,
                ),
                rewardedAdBusy: _rewardedAdBusy,
                grantRewardPending: _grantRewardPending,
                cooldownRemaining: cooldownRemaining,
                rewardDailyLimitReached: dailyLimitReached,
                emphasizeRewardPurpose: _stripEmphasisForTab(2),
                repeatHabitPulseBoost: _repeatHabitPulseBoostForTab(2),
              );
            } else if (_navIndex == 3) {
              tabBody = InboxScreen(
                key: const ValueKey<String>('talkfree_inbox'),
                user: widget.user,
                onWatchPurposeAd: (purpose) => _onWatchRewardedAd(
                  cooldownRemaining,
                  dailyLimitReached,
                  purpose,
                ),
                rewardedAdBusy: _rewardedAdBusy,
                grantRewardPending: _grantRewardPending,
                cooldownRemaining: cooldownRemaining,
                dailyLimitReached: dailyLimitReached,
                showRewardRecommendedBadge: _showRewardRecommendedBadge,
                emphasizeRewardPurpose: _stripEmphasisForTab(3),
                repeatHabitPulseBoost: _repeatHabitPulseBoostForTab(3),
              );
            } else {
              tabBody = const SubscriptionScreen(embedInShell: true);
            }

            return ValueListenableBuilder<String>(
              valueListenable: _subscriptionTier,
              builder: (context, subscriptionTier, _) {
                final isFreeTier =
                    !FirestoreUserService.isPremiumTierLabel(subscriptionTier);
                return Scaffold(
                  backgroundColor: _navIndex == 0 && isFreeTier
                      ? AppColors.freeHomeCanvas
                      : AppTheme.darkBg,
                  appBar: AppBar(
                    backgroundColor: _navIndex == 0 && isFreeTier
                        ? AppColors.freeHomeCanvas
                        : AppTheme.darkBg,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    surfaceTintColor: Colors.transparent,
                    automaticallyImplyLeading: false,
                    leading: _navIndex == 0 && isFreeTier
                        ? IconButton(
                            tooltip: 'Menu',
                            icon: const Icon(Icons.menu_rounded),
                            color: AppColors.textOnDark,
                            onPressed: () {
                              showModalBottomSheet<void>(
                                context: context,
                                backgroundColor: AppColors.darkBackground,
                                shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(20),
                                  ),
                                ),
                                builder: (ctx) => SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(
                                        leading: Icon(
                                          Icons.star_rounded,
                                          color: AppColors.accentGold,
                                        ),
                                        title: Text(
                                          'Go Pro',
                                          style: GoogleFonts.inter(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          setState(() => _navIndex = 4);
                                        },
                                      ),
                                      ListTile(
                                        leading: Icon(
                                          Icons.settings_outlined,
                                          color: AppColors.textMutedOnDark,
                                        ),
                                        title: Text(
                                          'Settings',
                                          style: GoogleFonts.inter(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          Navigator.of(context).push<void>(
                                            MaterialPageRoute<void>(
                                              builder: (_) => SettingsScreen(
                                                user: widget.user,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          )
                        : null,
                    title: Text(
                      switch (_navIndex) {
                        0 => '',
                        1 => '',
                        2 => 'Number',
                        3 => '',
                        4 => 'Go Pro',
                        _ => 'TalkFree',
                      },
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        letterSpacing: -0.3,
                        color: _navIndex == 4
                            ? AppColors.accentGold
                            : AppColors.textOnDark,
                      ),
                    ),
                    actions: [
                      if (_navIndex == 0 && isFreeTier) ...[
                        IconButton(
                          tooltip: 'Refer & earn',
                          icon: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Icon(
                                Icons.card_giftcard_rounded,
                                color: AppColors.textMutedOnDark,
                              ),
                              Positioned(
                                right: -1,
                                top: -1,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEF4444),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppTheme.darkBg,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          onPressed: () async {
                            await Clipboard.setData(
                              const ClipboardData(text: 'https://talkfree.app'),
                            );
                            if (!context.mounted) return;
                            AppSnackBar.show(context,
                              SnackBar(
                                content: Text(
                                  'Invite link copied!',
                                  style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                behavior: SnackBarBehavior.floating,
                                margin: AppTheme.snackBarFloatingMargin(context),
                                duration: AppTheme.snackBarCalmDuration,
                              ),
                            );
                          },
                        ),
                      ],
                      if (_navIndex == 0 && !isFreeTier) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Material(
                            color: AppColors.cardDark,
                            shape: const CircleBorder(),
                            elevation: 0,
                            child: Ink(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.cardBorderSubtle,
                                ),
                              ),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () {
                                  Navigator.of(context).push<void>(
                                    MaterialPageRoute<void>(
                                      builder: (_) => SettingsScreen(
                                        user: widget.user,
                                      ),
                                    ),
                                  );
                                },
                                child: CircleAvatar(
                                  backgroundColor: AppColors.surfaceDark,
                                  radius: 20,
                                  child: Text(
                                    () {
                                      final t = displayName.trim();
                                      if (t.isEmpty) return 'T';
                                      return String.fromCharCode(t.runes.first)
                                          .toUpperCase();
                                    }(),
                                    style: GoogleFonts.inter(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                      color: AppColors.textOnDark,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (_navIndex != 1)
                        IconButton(
                          tooltip: 'Settings',
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: () {
                            Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => SettingsScreen(
                                  user: widget.user,
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                  body: Material(
                    color: _navIndex == 0 ? Colors.transparent : AppTheme.darkBg,
                    child: tabBody,
                  ),
                  bottomNavigationBar: BottomNavigationBar(
                    currentIndex: _navIndex,
                    onTap: (i) => setState(() {
                      _navIndex = i;
                    }),
                    type: BottomNavigationBarType.fixed,
                    backgroundColor: isFreeTier
                        ? AppColors.freeHomeCanvas
                        : AppTheme.darkBg,
                    selectedItemColor: _navIndex == 4
                        ? AppColors.accentGold
                        : (!isFreeTier && _navIndex == 0)
                            ? AppColors.accentGold
                            : (isFreeTier && _navIndex == 0)
                                ? AppColors.freeHomeNeon
                                : AppColors.primary,
                    unselectedItemColor: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.5),
                    items: [
                      BottomNavigationBarItem(
                        icon: const Icon(Icons.home_outlined),
                        activeIcon: Icon(
                          Icons.home_rounded,
                          color: isFreeTier
                              ? AppColors.freeHomeNeon
                              : AppColors.accentGold,
                        ),
                        label: 'Home',
                      ),
                      const BottomNavigationBarItem(
                        icon: Icon(Icons.phone_outlined),
                        activeIcon: Icon(Icons.phone_rounded),
                        label: 'Dialer',
                      ),
                      const BottomNavigationBarItem(
                        icon: Icon(Icons.sell_outlined),
                        activeIcon: Icon(Icons.sell_rounded),
                        label: 'Number',
                      ),
                      const BottomNavigationBarItem(
                        icon: Icon(Icons.chat_bubble_outline_rounded),
                        activeIcon: Icon(Icons.chat_bubble_rounded),
                        label: 'Inbox',
                      ),
                      // Unselected: grey (theme); selected tab 4 only: gold — matches free-home reference.
                      const BottomNavigationBarItem(
                        icon: Icon(Icons.star_outline_rounded),
                        activeIcon: Icon(
                          Icons.star_rounded,
                          color: AppColors.accentGold,
                        ),
                        label: 'Premium',
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

// --- Free-tier home (mockup-aligned) ----------------------------------------

/// Glass-style card without [BackdropFilter] (blur can black-screen some Android GPUs).
class _FreeGlassPanel extends StatelessWidget {
  const _FreeGlassPanel({
    required this.child,
    this.borderRadius = 20,
  });

  final Widget child;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          color: const Color(0xD9161A22),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x280B0E11),
              blurRadius: 24,
              offset: Offset(0, 10),
              spreadRadius: -6,
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

class _FreeUserHomeHeader extends StatelessWidget {
  const _FreeUserHomeHeader({required this.displayName});

  final String displayName;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello, ${_firstName(displayName)}',
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  height: 1.15,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Welcome back! Stay connected',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                  color: AppColors.textMutedOnDark.withValues(alpha: 0.95),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const _FreePhoneIllustration(),
      ],
    );
  }
}

class _FreePhoneIllustration extends StatelessWidget {
  const _FreePhoneIllustration();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      height: 88,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            child: Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.freeHomeGlowViolet
                        .withValues(alpha: 0.22),
                    blurRadius: 22,
                    spreadRadius: 1,
                  ),
                  BoxShadow(
                    color: AppColors.freeHomeGlowBlue.withValues(alpha: 0.2),
                    blurRadius: 18,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 4,
            child: Icon(
              Icons.wifi_tethering_rounded,
              size: 20,
              color: AppColors.freeHomeNeon.withValues(alpha: 0.9),
            ),
          ),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.freeHomeGlowBlue.withValues(alpha: 0.35),
                  AppColors.freeHomeGlowViolet.withValues(alpha: 0.2),
                  AppColors.freeHomeCanvas,
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
              border: Border.all(
                color: AppColors.freeHomeNeon.withValues(alpha: 0.25),
                width: 1.2,
              ),
            ),
            child: Icon(
              Icons.phone_in_talk_rounded,
              size: 36,
              color: const Color(0xFFB8F5C8),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mockup: side-by-side “Earn for calls” (primary) + “Earn for number” pill.
/// Each shows its own loading indicator only when that action was tapped.
class _FreeEarnForCallsCta extends StatefulWidget {
  const _FreeEarnForCallsCta({
    required this.tapEnabled,
    required this.dailyLimitReached,
    required this.onWatch,
  });

  final bool tapEnabled;
  final bool dailyLimitReached;
  final Future<void> Function(GrantRewardPurpose purpose) onWatch;

  @override
  State<_FreeEarnForCallsCta> createState() => _FreeEarnForCallsCtaState();
}

class _FreeEarnForCallsCtaState extends State<_FreeEarnForCallsCta> {
  bool _callsLoading = false;
  bool _numberLoading = false;

  bool get _anyLocalLoading => _callsLoading || _numberLoading;

  Future<void> _run(GrantRewardPurpose p) async {
    if (!widget.tapEnabled || _anyLocalLoading) return;
    HapticFeedback.lightImpact();
    setState(() {
      if (p == GrantRewardPurpose.call) {
        _callsLoading = true;
      } else {
        _numberLoading = true;
      }
    });
    try {
      await widget.onWatch(p);
    } finally {
      if (mounted) {
        setState(() {
          if (p == GrantRewardPurpose.call) {
            _callsLoading = false;
          } else {
            _numberLoading = false;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dailyLimitReached) {
      return const SizedBox.shrink();
    }
    final canStart = widget.tapEnabled && !_anyLocalLoading;
    final labelStyle = GoogleFonts.inter(
      fontWeight: FontWeight.w800,
      fontSize: 14,
      letterSpacing: -0.2,
    );
    final c = AppColors.freeHomeNeon;

    Widget pill({
      required String label,
      required bool isCalls,
    }) {
      final loading = isCalls ? _callsLoading : _numberLoading;
      final waitingOnOther = _anyLocalLoading && !loading;
      final strongBorder = isCalls;
      final enabled = canStart && !waitingOnOther;
      return Expanded(
        child: Material(
          color: const Color(0xFF0F1218),
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            onTap: enabled
                ? () => _run(
                      isCalls
                          ? GrantRewardPurpose.call
                          : GrantRewardPurpose.number,
                    )
                : null,
            borderRadius: BorderRadius.circular(22),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
              constraints: const BoxConstraints(minHeight: 52),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: (enabled || loading)
                      ? c.withValues(alpha: strongBorder ? 0.9 : 0.55)
                      : c.withValues(alpha: 0.2),
                  width: 1.4,
                ),
              ),
              child: loading
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: c,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.ondemand_video_rounded,
                          color: (enabled && !waitingOnOther)
                              ? c
                              : AppColors.textDimmed,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle.copyWith(
                              color: (enabled && !waitingOnOther)
                                  ? c
                                  : AppColors.textDimmed,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill(label: 'Earn for calls', isCalls: true),
        const SizedBox(width: 10),
        pill(label: 'Earn for number', isCalls: false),
      ],
    );
  }
}

class _FreeMinutesStatusCard extends StatelessWidget {
  const _FreeMinutesStatusCard({
    required this.credits,
  });

  final int credits;

  static const int _goalMinutes = 10;

  @override
  Widget build(BuildContext context) {
    final balanceMin = credits ~/ CreditsPolicy.creditsPerMinute;
    final goalCredits = _goalMinutes * CreditsPolicy.creditsPerMinute;
    final progress =
        goalCredits <= 0 ? 0.0 : (credits / goalCredits).clamp(0.0, 1.0);
    final n = AppColors.freeHomeNeon;

    return _FreeGlassPanel(
      borderRadius: 20,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.of(context).push<void>(
              PremiumCreditsWalletScreen.createRoute(),
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 1.2,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      n.withValues(alpha: 0.55),
                      n.withValues(alpha: 0.08),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'CALL CREDITS (EARNED WITH ADS)',
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.1,
                                  color: n,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    '$balanceMin',
                                    style: GoogleFonts.poppins(
                                      fontSize: 48,
                                      fontWeight: FontWeight.w700,
                                      height: 1.0,
                                      letterSpacing: -2,
                                      color: AppColors.textOnDark,
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Text(
                                      'Minutes',
                                      style: GoogleFonts.inter(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textMutedOnDark,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          width: 80,
                          height: 80,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CustomPaint(
                                size: const Size(80, 80),
                                painter: _FreeFullRingGaugePainter(
                                  progress: progress,
                                ),
                              ),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '$_goalMinutes',
                                    style: GoogleFonts.inter(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.textOnDark,
                                    ),
                                  ),
                                  Text(
                                    'min',
                                    style: GoogleFonts.inter(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textMutedOnDark,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '$balanceMin min balance',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textMutedOnDark,
                          ),
                        ),
                        Text(
                          '$_goalMinutes min goal',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: n,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 8,
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        valueColor: AlwaysStoppedAnimation<Color>(n),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full circular ring (mockup) — progress 0..1, starts top.
class _FreeFullRingGaugePainter extends CustomPainter {
  _FreeFullRingGaugePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const sw = 6.5;
    final r = math.min(size.width, size.height) / 2 - sw * 0.6;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    final bg = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round;
    final fg = Paint()
      ..color = AppColors.freeHomeNeon
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round;
    const start = -math.pi / 2;
    canvas.drawArc(rect, start, 2 * math.pi, false, bg);
    canvas.drawArc(
      rect,
      start,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant _FreeFullRingGaugePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _FreeAdRewardProgressCard extends StatelessWidget {
  const _FreeAdRewardProgressCard({
    required this.adsToday,
  });

  final int adsToday;

  @override
  Widget build(BuildContext context) {
    final cap = CreditsPolicy.maxRewardedAdsForUser(false);
    final dayProgress = cap <= 0 ? 0.0 : (adsToday / cap).clamp(0.0, 1.0);
    const subtitle = 'Simple rewarded ads';
    final filled = (dayProgress * 7).floor().clamp(0, 7);
    final n = AppColors.freeHomeNeon;

    return _FreeGlassPanel(
      borderRadius: 20,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0x1AFF6B2E),
                    border: Border.all(
                      color: const Color(0x4DF97316),
                    ),
                  ),
                  child: const Text('🔥', style: TextStyle(fontSize: 20)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Today's rewarded ads",
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          color: AppColors.textMutedOnDark,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: Colors.white.withValues(alpha: 0.06),
                    border: Border.all(
                      color: n.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    '$adsToday / $cap',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: n,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(7, (i) {
                final isLit = i < filled;
                return Padding(
                  padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isLit
                          ? n
                          : Colors.white.withValues(alpha: 0.1),
                      boxShadow: isLit
                          ? [
                              BoxShadow(
                                color: n.withValues(alpha: 0.45),
                                blurRadius: 5,
                              ),
                            ]
                          : null,
                      border: Border.all(
                        color: Colors.white.withValues(
                          alpha: isLit ? 0.35 : 0.08,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _FreeTrustStatsRow extends StatelessWidget {
  const _FreeTrustStatsRow();

  @override
  Widget build(BuildContext context) {
    Widget cell({
      required IconData icon,
      required Color iconColor,
      required String title,
      required String subtitle,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceDark.withValues(alpha: 0.88),
            border: Border.all(color: AppColors.cardBorderSubtle),
            boxShadow: AppTheme.fintechCardShadow,
          ),
          child: Column(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(height: 6),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: GoogleFonts.inter(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  color: AppColors.textMutedOnDark,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        cell(
          icon: Icons.bolt_rounded,
          iconColor: AppColors.accentGold,
          title: 'Instant Reward',
          subtitle:
              '${CreditsPolicy.adRewardCooldownSecondsForUser(false)} sec only',
        ),
        const SizedBox(width: 8),
        cell(
          icon: Icons.groups_rounded,
          iconColor: AppColors.inboxBannerBlue,
          title: MonetizationCopy.socialProofUpgradesTitle,
          subtitle: MonetizationCopy.socialProofUpgradesSubtitle,
        ),
        const SizedBox(width: 8),
        cell(
          icon: Icons.verified_user_rounded,
          iconColor: const Color(0xFFB794F6),
          title: 'Secure & Safe',
          subtitle: 'Trusted platform',
        ),
      ],
    );
  }
}

class _FreeProUpsellCard extends StatelessWidget {
  const _FreeProUpsellCard({required this.onUpgrade});

  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onUpgrade,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF2D1B4E).withValues(alpha: 0.95),
                const Color(0xFF4A1942).withValues(alpha: 0.92),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
            boxShadow: AppTheme.fintechCardShadow,
          ),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                right: -16,
                bottom: -20,
                child: Icon(
                  Icons.workspace_premium_rounded,
                  size: 120,
                  color: Colors.white.withValues(alpha: 0.04),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.accentGold.withValues(alpha: 0.55),
                        ),
                        gradient: RadialGradient(
                          colors: [
                            AppColors.accentGold.withValues(alpha: 0.35),
                            AppColors.accentGold.withValues(alpha: 0.08),
                          ],
                        ),
                      ),
                      child: Icon(
                        Icons.workspace_premium_rounded,
                        color: AppColors.accentGold,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'TalkFree Pro',
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.2,
                                  color: AppColors.textOnDark,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: AppColors.accentGold.withValues(alpha: 0.2),
                                  border: Border.all(
                                    color: AppColors.accentGold.withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  'PRO',
                                  style: GoogleFonts.inter(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.6,
                                    color: AppColors.accentGold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Lower call cost + No ads',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textMutedOnDark,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: onUpgrade,
                        borderRadius: BorderRadius.circular(14),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFFFF8A00),
                                Color(0xFFFF6B9D),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Upgrade',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FreeLimitedOfferStrip extends StatefulWidget {
  const _FreeLimitedOfferStrip({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_FreeLimitedOfferStrip> createState() => _FreeLimitedOfferStripState();
}

class _FreeLimitedOfferStripState extends State<_FreeLimitedOfferStrip> {
  Timer? _timer;
  static const int _loopSeconds = 5 * 60;
  late int _remainingSec;

  @override
  void initState() {
    super.initState();
    _remainingSec = _loopSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_remainingSec <= 1) {
          _remainingSec = _loopSeconds;
        } else {
          _remainingSec -= 1;
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = _remainingSec ~/ 3600;
    final m = (_remainingSec % 3600) ~/ 60;
    final s = _remainingSec % 60;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: widget.onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF4A1518).withValues(alpha: 0.95),
                const Color(0xFF2A0A0C).withValues(alpha: 0.96),
              ],
            ),
            border: Border.all(
              color: const Color(0xFFE53935).withValues(alpha: 0.35),
            ),
            boxShadow: AppTheme.fintechCardShadow,
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    color: const Color(0xFFFF6B6B),
                    size: 26,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          MonetizationCopy.limitedTimeBonus,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textOnDark,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Offer ends in',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textMutedOnDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFFFF8A00).withValues(alpha: 0.95),
                          const Color(0xFFFF5252).withValues(alpha: 0.85),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: Text(
                      'SAVE\n60%',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _timeBox(h.toString().padLeft(2, '0')),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      ':',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w900,
                        color: AppColors.textOnDark,
                      ),
                    ),
                  ),
                  _timeBox(m.toString().padLeft(2, '0')),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      ':',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w900,
                        color: AppColors.textOnDark,
                      ),
                    ),
                  ),
                  _timeBox(s.toString().padLeft(2, '0')),
                  const Spacer(),
                  Text(
                    'HRS   MIN   SEC',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: AppColors.textMutedOnDark,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeBox(String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xFF1A0A0A),
        border: Border.all(
          color: const Color(0xFFE53935).withValues(alpha: 0.45),
        ),
      ),
      child: Text(
        v,
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w900,
          color: AppColors.textOnDark,
        ),
      ),
    );
  }
}

class _DashboardHomeTab extends StatefulWidget {
  const _DashboardHomeTab({
    required this.user,
    required this.displayName,
    required this.theme,
    required this.rewardedAdBusy,
    required this.grantRewardPending,
    required this.cooldownRemaining,
    required this.adsToday,
    required this.dailyLimitReached,
    required this.credits,
    required this.assignedNumber,
    required this.numberLeaseExpiry,
    required this.numberLineStatus,
    required this.numberTier,
    required this.numberPlanType,
    required this.numberRenewAdProgress,
    required this.lifetimeAdsWatched,
    required this.subscriptionTier,
    required this.outboundCallsTotal,
    required this.totalCallTalkSeconds,
    required this.adStreakCount,
    required this.purposeStripEmphasis,
    this.repeatHabitPulseBoost = false,
    required this.showRewardRecommendedBadge,
    required this.onWatchPurposeAd,
    required this.onGoToDialer,
    required this.onGoToNumberTab,
    required this.onOpenCallHistory,
  });

  final User user;
  final String displayName;
  final ThemeData theme;
  final bool rewardedAdBusy;
  final bool grantRewardPending;
  final int cooldownRemaining;
  final int adsToday;
  final bool dailyLimitReached;
  /// Balance from parent [ValueNotifier] (single Firestore listener).
  final int credits;
  final ValueNotifier<String?> assignedNumber;
  final ValueNotifier<DateTime?> numberLeaseExpiry;
  final ValueNotifier<String?> numberLineStatus;
  final ValueNotifier<String?> numberTier;
  final ValueNotifier<String?> numberPlanType;
  final ValueNotifier<int> numberRenewAdProgress;
  final ValueNotifier<int> lifetimeAdsWatched;
  final ValueNotifier<String> subscriptionTier;
  final ValueNotifier<int> outboundCallsTotal;
  final ValueNotifier<int> totalCallTalkSeconds;
  final ValueNotifier<int> adStreakCount;
  final GrantRewardPurpose purposeStripEmphasis;
  final bool repeatHabitPulseBoost;
  final bool showRewardRecommendedBadge;
  final Future<void> Function(GrantRewardPurpose purpose) onWatchPurposeAd;
  final VoidCallback onGoToDialer;
  final VoidCallback onGoToNumberTab;
  final VoidCallback onOpenCallHistory;

  @override
  State<_DashboardHomeTab> createState() => _DashboardHomeTabState();
}

class _DashboardHomeTabState extends State<_DashboardHomeTab>
    with TickerProviderStateMixin {
  late Future<void> _ensureFuture;

  late final AnimationController _homeGreetingC;
  late final Animation<double> _homeGreetingFade;
  late final Animation<Offset> _homeGreetingSlide;

  late final AnimationController _homeCardC;
  late final Animation<double> _homeCardScale;

  late final AnimationController _homeProMarkBounceC;
  late final Animation<double> _homeProMarkScale;

  late final AnimationController _homeProGlowC;
  /// Horizontal shine sweep on the Pro home hero (Pro tier only).
  late final AnimationController _premiumShineC;

  void _onHomeGreetStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _homeCardC.forward();
    }
  }

  void _onHomeCardStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        FirestoreUserService.isPremiumTierLabel(
            widget.subscriptionTier.value)) {
      _homeProMarkBounceC.forward(from: 0);
    }
  }

  void _syncHomeProGlow() {
    final pro = FirestoreUserService.isPremiumTierLabel(
        widget.subscriptionTier.value);
    if (!mounted) return;
    if (pro) {
      if (!_homeProGlowC.isAnimating) {
        _homeProGlowC.repeat();
      }
    } else {
      _homeProGlowC
        ..stop()
        ..reset();
    }
  }

  void _syncPremiumShine() {
    final pro = FirestoreUserService.isPremiumTierLabel(
        widget.subscriptionTier.value);
    if (!mounted) return;
    if (pro) {
      if (!_premiumShineC.isAnimating) {
        _premiumShineC.repeat(reverse: true);
      }
    } else {
      _premiumShineC
        ..stop()
        ..reset();
    }
  }

  @override
  void initState() {
    super.initState();
    _ensureFuture =
        FirestoreUserService.ensureUserDocument(widget.user.uid);

    _homeGreetingC = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _homeGreetingFade =
        CurvedAnimation(parent: _homeGreetingC, curve: Curves.easeOutCubic);
    _homeGreetingSlide = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _homeGreetingC, curve: Curves.easeOutCubic),
    );

    _homeCardC = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _homeCardScale = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _homeCardC, curve: Curves.easeOutCubic),
    );

    _homeProMarkBounceC = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _homeProMarkScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.03)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.03, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 50,
      ),
    ]).animate(_homeProMarkBounceC);

    _homeProGlowC = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );

    _premiumShineC = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );

    _homeGreetingC.addStatusListener(_onHomeGreetStatus);
    _homeCardC.addStatusListener(_onHomeCardStatus);
    widget.subscriptionTier.addListener(_syncHomeProGlow);
    widget.subscriptionTier.addListener(_syncPremiumShine);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _homeGreetingC.forward();
      _syncHomeProGlow();
      _syncPremiumShine();
    });
  }

  @override
  void dispose() {
    widget.subscriptionTier.removeListener(_syncHomeProGlow);
    widget.subscriptionTier.removeListener(_syncPremiumShine);
    _homeGreetingC.removeStatusListener(_onHomeGreetStatus);
    _homeCardC.removeStatusListener(_onHomeCardStatus);
    _homeGreetingC.dispose();
    _homeCardC.dispose();
    _homeProMarkBounceC.dispose();
    _homeProGlowC.dispose();
    _premiumShineC.dispose();
    super.dispose();
  }

  void _retry() {
    setState(() {
      _ensureFuture =
          FirestoreUserService.ensureUserDocument(widget.user.uid);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ensureFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.cloud_off_rounded,
                    size: 48,
                    color: widget.theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Could not load your profile.',
                    style: widget.theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.error}',
                    style: widget.theme.textTheme.bodySmall?.copyWith(
                      color: widget.theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _retry,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        return ValueListenableBuilder<String>(
          valueListenable: widget.subscriptionTier,
          builder: (context, tier, _) {
            final proHome = FirestoreUserService.isPremiumTierLabel(tier);
            return Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: proHome
                            ? Alignment.topLeft
                            : Alignment.topCenter,
                        end: proHome
                            ? Alignment.bottomRight
                            : Alignment.bottomCenter,
                        colors: proHome
                            ? const [
                                Color(0xFF0E1118),
                                AppColors.darkBackground,
                                Color(0xFF10120A),
                              ]
                            : const [
                                AppColors.freeHomeCanvas,
                                Color(0xFF06080B),
                              ],
                      ),
                    ),
                  ),
                ),
                if (proHome)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0.88, -0.32),
                          radius: 1.22,
                          colors: [
                            AppColors.accentGold.withValues(alpha: 0.07),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.58],
                        ),
                      ),
                    ),
                  ),
                if (!proHome) ...[
                  Positioned(
                    top: -100,
                    left: -80,
                    child: IgnorePointer(
                      child: Container(
                        width: 260,
                        height: 260,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.freeHomeGlowViolet
                              .withValues(alpha: 0.11),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 20,
                    right: -100,
                    child: IgnorePointer(
                      child: Container(
                        width: 280,
                        height: 280,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.freeHomeGlowBlue
                              .withValues(alpha: 0.09),
                        ),
                      ),
                    ),
                  ),
                ],
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 1.18,
                        colors: [
                          (proHome
                                  ? AppColors.primary
                                  : AppColors.freeHomeNeon)
                              .withValues(alpha: proHome ? 0.012 : 0.045),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.82],
                      ),
                    ),
                  ),
                ),
                ListView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    proHome ? 28 : 32,
                    24,
                    kDebugMode ? 100 : 56,
                  ),
                  children: [
            ValueListenableBuilder<String>(
              valueListenable: widget.subscriptionTier,
              builder: (context, tier, _) {
                final isPro = FirestoreUserService.isPremiumTierLabel(tier);
                if (isPro) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: SlideTransition(
                    position: _homeGreetingSlide,
                    child: FadeTransition(
                      opacity: _homeGreetingFade,
                      child: _FreeUserHomeHeader(
                        displayName: widget.displayName,
                      ),
                    ),
                  ),
                );
              },
            ),
            ValueListenableBuilder<String>(
              valueListenable: widget.subscriptionTier,
              builder: (context, tier, _) {
                final isPro = FirestoreUserService.isPremiumTierLabel(tier);
                final adSlotOpen = !widget.dailyLimitReached &&
                    widget.cooldownRemaining <= 0;
                final canTapAds = adSlotOpen &&
                    !widget.grantRewardPending &&
                    !widget.rewardedAdBusy;
                final remaining = math.max(
                  0,
                  CreditsPolicy.maxRewardedAdsForUser(false) - widget.adsToday,
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: AnimatedBuilder(
                        animation: Listenable.merge([
                          _homeCardC,
                          _homeProMarkBounceC,
                          _homeProGlowC,
                          _premiumShineC,
                        ]),
                        builder: (context, _) {
                          final glowOpacity = isPro
                              ? (0.085 +
                                  0.018 *
                                      math.sin(
                                        2 * math.pi * _homeProGlowC.value,
                                      ))
                              : null;
                          return Transform.scale(
                            scale: _homeCardScale.value,
                            alignment: Alignment.center,
                            child: isPro
                                ? ValueListenableBuilder<String?>(
                                    valueListenable: widget.assignedNumber,
                                    builder: (context, assign, _) {
                                      return ValueListenableBuilder<String?>(
                                        valueListenable: widget.numberLineStatus,
                                        builder: (context, lineSt, _) {
                                          return _ProPremiumShineHeroCard(
                                            credits: widget.credits,
                                            proMarkBounceScale:
                                                _homeProMarkScale.value,
                                            proBorderGlowOpacity: glowOpacity,
                                            shine: _premiumShineC,
                                            lineStatusText:
                                                _proHomeLineSubtitle(
                                              assign,
                                              lineSt,
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  )
                                : _FreeMinutesStatusCard(
                                    credits: widget.credits,
                                  ),
                          );
                        },
                      ),
                    ),
                    if (!isPro) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _FreeAdRewardProgressCard(
                          adsToday: widget.adsToday,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _FreeEarnForCallsCta(
                        tapEnabled: canTapAds,
                        dailyLimitReached: widget.dailyLimitReached,
                        onWatch: widget.onWatchPurposeAd,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'More ways to earn',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                          color: AppColors.textMutedOnDark,
                        ),
                      ),
                      const SizedBox(height: 10),
                      PurposeRewardedAdStrip(
                        canTapAd: adSlotOpen,
                        grantRewardPending: widget.grantRewardPending,
                        rewardedAdBusy: widget.rewardedAdBusy,
                        cooldownRemaining: widget.cooldownRemaining,
                        dailyLimitReached: widget.dailyLimitReached,
                        emphasizePurpose: widget.purposeStripEmphasis,
                        showRewardRecommendedBadge:
                            widget.showRewardRecommendedBadge,
                        cooldownPolicySeconds:
                            CreditsPolicy.adRewardCooldownSecondsForUser(
                          isPro,
                        ),
                        onPurposeAd: widget.onWatchPurposeAd,
                        omitCallPurpose: true,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        remaining == 0
                            ? 'No ad spots left today — see you tomorrow'
                            : remaining <= 8
                                ? 'Only $remaining ads left today'
                                : '${CreditsPolicy.creditsPerMinute} credits = 1 min',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                          letterSpacing: 0.05,
                          color: AppColors.textMutedOnDark.withValues(alpha: 0.92),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 4),
                      ValueListenableBuilder<int>(
                        valueListenable: widget.totalCallTalkSeconds,
                        builder: (context, talkSec, _) {
                          return ValueListenableBuilder<int>(
                            valueListenable: widget.outboundCallsTotal,
                            builder: (context, nCalls, _) {
                              return _ProHomeStatsRow(
                                talkValue: _formatTalkHhMm(talkSec),
                                callsValue: nCalls,
                              );
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      ValueListenableBuilder<String?>(
                        valueListenable: widget.assignedNumber,
                        builder: (context, number, _) {
                          return _ProUsNumberLineCard(
                            e164: number,
                            onGetNumber: widget.onGoToNumberTab,
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: SoftPulse(
                          enabled: true,
                          child: FilledButton.icon(
                            onPressed: widget.onGoToDialer,
                            icon: Icon(
                              Icons.call_rounded,
                              color: AppColors.onPrimaryButton,
                            ),
                            label: Text(
                              MonetizationCopy.premiumInstantHeadline,
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                                letterSpacing: -0.2,
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: AppColors.onPrimaryButton,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                              minimumSize: const Size(double.infinity, 54),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: 6,
                              shadowColor:
                                  AppColors.primary.withValues(alpha: 0.42),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      const _ProPremiumBenefitsSection(),
                      const SizedBox(height: 20),
                      _ProReferEarnBanner(
                        onTap: () async {
                          const link = 'https://talkfree.app';
                          await Clipboard.setData(
                            const ClipboardData(text: link),
                          );
                          if (!context.mounted) return;
                          AppSnackBar.show(context,
                            SnackBar(
                              content: Text(
                                'Invite link copied — share with friends!',
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              behavior: SnackBarBehavior.floating,
                              margin: AppTheme.snackBarFloatingMargin(context),
                              duration: AppTheme.snackBarCalmDuration,
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                );
              },
            ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Mockup: two stat pills (talk + calls) — [talkValue] is server lifetime total.
class _ProHomeStatsRow extends StatelessWidget {
  const _ProHomeStatsRow({
    required this.talkValue,
    required this.callsValue,
  });

  final String talkValue;
  final int callsValue;

  @override
  Widget build(BuildContext context) {
    Widget cell({
      required String title,
      required String value,
      String? foot,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: AppColors.surfaceDark.withValues(alpha: 0.92),
            border: Border.all(color: AppColors.cardBorderSubtle),
            boxShadow: AppTheme.fintechCardShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMutedOnDark,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOnDark,
                ),
              ),
              if (foot != null) ...[
                const SizedBox(height: 2),
                Text(
                  foot,
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textDimmed,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          cell(
            title: 'This week',
            value: talkValue,
            foot: 'All time',
          ),
          const SizedBox(width: 10),
          cell(
            title: 'Calls',
            value: '$callsValue',
          ),
        ],
      ),
    );
  }
}

/// Mockup: full-width “US Number” row with flag + check when assigned.
class _ProUsNumberLineCard extends StatelessWidget {
  const _ProUsNumberLineCard({
    required this.e164,
    required this.onGetNumber,
  });

  final String? e164;
  final VoidCallback onGetNumber;

  @override
  Widget build(BuildContext context) {
    final n = (e164 ?? '').trim();
    final has = n.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onGetNumber,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: AppColors.surfaceDark.withValues(alpha: 0.92),
            border: Border.all(color: AppColors.cardBorderSubtle),
            boxShadow: AppTheme.fintechCardShadow,
          ),
          child: Row(
            children: [
              const Text('🇺🇸', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'US Number',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textOnDark,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      has
                          ? n
                          : 'Get a US line for your account',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMutedOnDark,
                      ),
                    ),
                  ],
                ),
              ),
              if (has)
                Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.primary,
                  size: 26,
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textMutedOnDark,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Moving highlight across the Pro home hero (visual only).
class _PremiumCardShinePainter extends CustomPainter {
  _PremiumCardShinePainter(this._t) : super(repaint: _t);

  final Animation<double> _t;

  @override
  void paint(Canvas canvas, Size size) {
    final t = _t.value;
    final bandW = size.width * 0.44;
    final x = -bandW * 0.35 + (size.width + bandW * 0.7) * t;
    final rect = Rect.fromLTWH(x, 0, bandW, size.height);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.045),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0.32, 0.5, 0.68],
      ).createShader(rect);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(rect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PremiumCardShinePainter oldDelegate) =>
      oldDelegate._t.value != _t.value;
}

/// Pro-only home hero — mockup: PRO MEMBER, “Welcome back”, “Included”, phone ring.
class _ProPremiumShineHeroCard extends StatelessWidget {
  const _ProPremiumShineHeroCard({
    required this.credits,
    required this.proMarkBounceScale,
    required this.proBorderGlowOpacity,
    required this.shine,
    required this.lineStatusText,
  });

  final int credits;
  final double proMarkBounceScale;
  final double? proBorderGlowOpacity;
  final Animation<double> shine;
  final String lineStatusText;

  @override
  Widget build(BuildContext context) {
    final glow = proBorderGlowOpacity;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: AppColors.accentGold.withValues(alpha: 0.42),
          width: 1,
        ),
        boxShadow: [
          ...AppTheme.fintechCardShadow,
          if (glow != null)
            BoxShadow(
              color: AppColors.accentGold.withValues(
                alpha: (0.06 + 0.04 * glow).clamp(0.0, 0.14),
              ),
              blurRadius: 20,
              spreadRadius: -4,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.accentGold.withValues(alpha: 0.055),
                      AppColors.cardDark.withValues(alpha: 0.96),
                      AppColors.darkBackgroundDeep.withValues(alpha: 0.93),
                    ],
                    stops: const [0.0, 0.42, 1.0],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.09),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.35, -0.85),
                      radius: 1.05,
                      colors: [
                        Colors.white.withValues(alpha: 0.07),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.55],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: -4,
              top: 48,
              bottom: 120,
              width: 84,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ProHeroWavePainter(),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 56,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.1),
                        Colors.white.withValues(alpha: 0.02),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.42, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 44,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.12),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _PremiumCardShinePainter(shine),
                ),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () {
                  Navigator.of(context).push(
                    PremiumCreditsWalletScreen.createRoute(),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _ProMemberChip(),
                      const SizedBox(height: 14),
                      Text(
                        'Welcome back',
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.45,
                          height: 1.1,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        lineStatusText,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          color: AppColors.textMutedOnDark,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Transform.scale(
                              scale: proMarkBounceScale,
                              alignment: Alignment.centerLeft,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Included',
                                    style: GoogleFonts.poppins(
                                      fontSize: 40,
                                      fontWeight: FontWeight.w800,
                                      height: 1.0,
                                      letterSpacing: -1,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '$credits credits',
                                    style: GoogleFonts.inter(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textDimmed,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const _ProPhoneRingGauge(),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            Navigator.of(context).push(
                              PremiumCreditsWalletScreen.createRoute(),
                            );
                          },
                          child: Text(
                            'Wallet & packs',
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Gold + green ring around handset (mockup Pro hero right).
class _ProPhoneRingGauge extends StatelessWidget {
  const _ProPhoneRingGauge();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      height: 88,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.accentGold.withValues(alpha: 0.48),
                width: 2.5,
              ),
            ),
          ),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.55),
                width: 2.2,
              ),
            ),
            child: Icon(
              Icons.phone_in_talk_rounded,
              color: AppColors.primary,
              size: 32,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProMemberChip extends StatelessWidget {
  const _ProMemberChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.accentGold.withValues(alpha: 0.55),
        ),
        color: AppColors.accentGold.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '♔',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              height: 1.0,
              color: AppColors.accentGold,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'PRO MEMBER',
            style: GoogleFonts.inter(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.85,
              color: AppColors.accentGold,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProHeroFeatureColumn extends StatelessWidget {
  const _ProHeroFeatureColumn({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: AppColors.primary, size: 22),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            height: 1.25,
            letterSpacing: 0.02,
            color: AppColors.textOnDark.withValues(alpha: 0.9),
          ),
        ),
      ],
    );
  }
}

/// Decorative wavy lines — mockup-style green accent on the hero edge.
class _ProHeroWavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final x = 8.0 + i * 11.0;
      final path = Path();
      path.moveTo(x, 0);
      for (var y = 0.0; y <= size.height; y += 4) {
        path.lineTo(x + math.sin(y / 14) * 5.5, y);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ProPremiumBenefitsSection extends StatelessWidget {
  const _ProPremiumBenefitsSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your Premium Benefits',
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
            color: AppColors.textOnDark,
          ),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.72,
          children: const [
            _ProBenefitCell(
              icon: Icons.phone_in_talk_rounded,
              label: 'Lower call\ncost',
            ),
            _ProBenefitCell(
              icon: Icons.shield_rounded,
              label: 'No Ads',
            ),
            _ProBenefitCell(
              icon: Icons.speed_rounded,
              label: 'Faster\nConnection',
            ),
            _ProBenefitCell(
              icon: Icons.headset_mic_rounded,
              label: 'Premium\nSupport',
            ),
          ],
        ),
      ],
    );
  }
}

class _ProBenefitCell extends StatelessWidget {
  const _ProBenefitCell({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surfaceDark.withValues(alpha: 0.85),
        border: Border.all(color: AppColors.cardBorderSubtle),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.primary, size: 22),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: GoogleFonts.inter(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              height: 1.25,
              color: AppColors.textOnDark.withValues(alpha: 0.92),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProReferEarnBanner extends StatelessWidget {
  const _ProReferEarnBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                AppColors.primary.withValues(alpha: 0.32),
                AppColors.cardDark.withValues(alpha: 0.92),
                AppColors.darkBackground,
              ],
              stops: const [0.0, 0.42, 1.0],
            ),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.22),
            ),
            boxShadow: AppTheme.fintechCardShadow,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Icon(
                  Icons.card_giftcard_rounded,
                  color: AppColors.primary.withValues(alpha: 0.95),
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Refer & Earn',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Invite friends to TalkFree',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: AppColors.primary.withValues(alpha: 0.88),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textMutedOnDark,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
