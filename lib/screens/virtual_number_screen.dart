import 'dart:async' show Timer;
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/credits_policy.dart';
import '../services/assign_free_number_service.dart';
import '../services/assign_number_service.dart' show AssignNumberException;
import '../services/firestore_user_service.dart';
import '../services/grant_reward_service.dart' show GrantRewardPurpose;
import '../utils/rewarded_ad_grant_flow.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import '../utils/us_phone_format.dart';
import '../widgets/glass_panel.dart';
import '../widgets/lease_ring_painter.dart';
import '../widgets/purpose_rewarded_ad_strip.dart';
import 'number_selection_screen.dart';
import 'subscription_screen.dart';

/// Route args for [VirtualNumberScreen].
class VirtualNumberRouteArgs {
  const VirtualNumberRouteArgs({
    required this.userUid,
    required this.userCredits,
    this.onPurposeRewardAd,
  });

  final String userUid;
  final int userCredits;
  final Future<void> Function(GrantRewardPurpose purpose)? onPurposeRewardAd;
}

/// "The Store" — unlock 2nd line, ad progress, subscription plans (buy = UI only).
///
/// Browse / claim from the list: opens [NumberSelectionScreen]; confirm + premium
/// provision live in [VirtualNumberClaimFlow].
class VirtualNumberScreen extends StatefulWidget {
  const VirtualNumberScreen({
    super.key,
    required this.userUid,
    required this.userCredits,
    this.onPurposeRewardAd,
    this.rewardedAdBusy = false,
    this.grantRewardPending = false,
    this.cooldownRemaining = 0,
    this.rewardDailyLimitReached = false,
    this.emphasizeRewardPurpose = GrantRewardPurpose.number,
    this.repeatHabitPulseBoost = false,
    this.embedInShell = false,
    this.showRecommendedBadge = true,
  });

  static const String routeName = '/virtual-number';

  static Route<void> createRoute(RouteSettings settings) {
    final args = settings.arguments;
    final uid = args is VirtualNumberRouteArgs ? args.userUid : '';
    final credits = args is VirtualNumberRouteArgs ? args.userCredits : 0;
    final onPurpose =
        args is VirtualNumberRouteArgs ? args.onPurposeRewardAd : null;
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => VirtualNumberScreen(
        userUid: uid,
        userCredits: credits,
        onPurposeRewardAd: onPurpose,
      ),
    );
  }

  final String userUid;
  final int userCredits;
  /// When set (e.g. from dashboard), wires the same rewarded-ad pipeline as Home.
  final Future<void> Function(GrantRewardPurpose purpose)? onPurposeRewardAd;
  final bool rewardedAdBusy;
  final bool grantRewardPending;
  final int cooldownRemaining;
  final bool rewardDailyLimitReached;
  final GrantRewardPurpose emphasizeRewardPurpose;
  final bool repeatHabitPulseBoost;
  /// When true, no [Scaffold]/[AppBar] — used inside [DashboardScreen] bottom shell.
  final bool embedInShell;

  /// “⭐ Recommended” above the unlock CTA (same gating as Home/Dialer).
  final bool showRecommendedBadge;

  @override
  State<VirtualNumberScreen> createState() => _VirtualNumberScreenState();

  static String? _readAssigned(Map<String, dynamic>? data) {
    if (data == null) return null;
    for (final key in ['assigned_number', 'virtual_number', 'allocatedNumber', 'number']) {
      final v = data[key];
      if (v is String) {
        final t = v.trim();
        if (t.isNotEmpty && t != 'none') return t;
      }
    }
    return null;
  }

}

class _VirtualNumberScreenState extends State<VirtualNumberScreen> {
  bool _claiming = false;
  bool _standaloneAdBusy = false;
  Timer? _leaseTicker;

  void _syncLeaseTicker(String? assigned, DateTime? leaseExp) {
    final has = assigned != null && assigned.trim().isNotEmpty;
    final need = has && leaseExp != null;
    if (need) {
      _leaseTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _leaseTicker?.cancel();
      _leaseTicker = null;
    }
  }

  @override
  void dispose() {
    _leaseTicker?.cancel();
    super.dispose();
  }

  Future<void> _claimUsNumber(
    BuildContext context,
    int numberAdProgress,
    bool isPremium,
    int credits,
  ) async {
    final minAds = CreditsPolicy.numberUnlockAdsRequired;
    final eligible = isPremium || numberAdProgress >= minAds;
    if (!eligible || _claiming) return;
    if (isPremium) {
      await Navigator.of(context).pushNamed<void>(
        NumberSelectionScreen.routeName,
        arguments: NumberSelectionRouteArgs(
          userUid: widget.userUid,
          userCredits: credits,
        ),
      );
      return;
    }
    setState(() => _claiming = true);
    try {
      final r = await AssignFreeNumberService.instance.requestAssignFreeNumber(
        planType: 'monthly',
      );
      if (!context.mounted) return;
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text(
            r.alreadyAssigned
                ? 'Your line: ${r.assignedNumber}'
                : 'Your number is ready! ${r.assignedNumber}',
            style: GoogleFonts.inter(),
          ),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
    } on AssignNumberException catch (e) {
      if (context.mounted) {
        AppSnackBar.show(
          context,
          SnackBar(
            content: Text(e.message, style: GoogleFonts.inter()),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final streamBody = StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirestoreUserService.watchUserDocument(widget.userUid),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Text(
                'Could not load profile.\n${snap.error}',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            );
          }

          // First Firestore snapshot not yet received — don't paint the "no number"
          // branch (Watch Ad / Claim, etc.): it flashes for users who already have a line.
          if (!snap.hasData) {
            return Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: AppColors.darkBackground,
                    ),
                  ),
                ),
                Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2.5,
                  ),
                ),
              ],
            );
          }

          final data = snap.data!.data();
          final assigned = VirtualNumberScreen._readAssigned(data);
          final numberAdProgress =
              FirestoreUserService.numberAdsProgressFromUserData(data);
          final isPremium = FirestoreUserService.isPremiumFromUserData(data);
          final leaseExp = FirestoreUserService.numberLeaseExpiryFromUserData(data);
          final planType = FirestoreUserService.numberPlanTypeFromUserData(data);
          final credits =
              FirestoreUserService.usableCreditsFromSnapshot(snap.data!);
          final canClaim = isPremium ||
              numberAdProgress >= CreditsPolicy.numberUnlockAdsRequired;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            _syncLeaseTicker(assigned, leaseExp);
          });

          return Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: isPremium ? null : AppColors.darkBackground,
                    gradient: isPremium
                        ? LinearGradient(
                            begin: Alignment.topRight,
                            end: Alignment.bottomLeft,
                            colors: [
                              AppColors.accentGold.withValues(alpha: 0.04),
                              AppColors.darkBackground,
                              AppColors.darkBackgroundDeep,
                            ],
                          )
                        : null,
                  ),
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (assigned != null) ...[
                      _AssignedLineGlassCard(
                        number: assigned,
                        leaseExpiry: leaseExp,
                        planType: planType,
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.center,
                        child: TextButton.icon(
                          onPressed: () {
                            Navigator.of(context).pushNamed(
                              NumberSelectionScreen.routeName,
                              arguments: NumberSelectionRouteArgs(
                                userUid: widget.userUid,
                                userCredits: widget.userCredits,
                              ),
                            );
                          },
                          icon: Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: AppColors.primary.withValues(alpha: 0.9),
                          ),
                          label: Text(
                            'Browse or change number',
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                    ] else ...[
                      _NumberUnlockPromoCard(
                        numberAdProgress: numberAdProgress,
                        isPremium: isPremium,
                        requiredAds: CreditsPolicy.numberUnlockAdsRequired,
                      ),
                      if (!isPremium && !canClaim) ...[
                        const SizedBox(height: 18),
                        Builder(
                          builder: (context) {
                            final parentHandles =
                                widget.onPurposeRewardAd != null;
                            final rewardedBusy = parentHandles
                                ? widget.rewardedAdBusy
                                : _standaloneAdBusy;
                            final grantPending = parentHandles
                                ? widget.grantRewardPending
                                : false;
                            final adSlotOpen = !widget.rewardDailyLimitReached &&
                                widget.cooldownRemaining <= 0;
                            return PurposeRewardedAdStrip(
                              canTapAd: adSlotOpen,
                              grantRewardPending: grantPending,
                              rewardedAdBusy: rewardedBusy,
                              cooldownRemaining: widget.cooldownRemaining,
                              dailyLimitReached:
                                  widget.rewardDailyLimitReached,
                              emphasizePurpose:
                                  widget.emphasizeRewardPurpose,
                              showRewardRecommendedBadge:
                                  widget.showRecommendedBadge,
                              cooldownPolicySeconds: CreditsPolicy
                                  .adRewardCooldownSecondsForUser(
                                isPremium,
                              ),
                              subtitleCallIsPremium: isPremium,
                              onPurposeAd: (purpose) async {
                                if (widget.onPurposeRewardAd != null) {
                                  await widget.onPurposeRewardAd!(purpose);
                                  return;
                                }
                                setState(() => _standaloneAdBusy = true);
                                try {
                                  await runRewardedAdGrantFlow(
                                    context: context,
                                    isPremium: isPremium,
                                    purpose: purpose,
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(
                                      () => _standaloneAdBusy = false,
                                    );
                                  }
                                }
                              },
                            );
                          },
                        ),
                        Align(
                          alignment: Alignment.center,
                          child: TextButton(
                            onPressed: () {
                              Navigator.of(context).push<void>(
                                SubscriptionScreen.createRoute(),
                              );
                            },
                            child: Text(
                              'Unlock faster with Pro',
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (isPremium || canClaim) ...[
                        const SizedBox(height: 18),
                        _VmActivateGradientButton(
                          enabled: canClaim && !_claiming,
                          busy: _claiming,
                          onPressed: () => _claimUsNumber(
                            context,
                            numberAdProgress,
                            isPremium,
                            credits,
                          ),
                        ),
                      ],
                      if (!canClaim && !isPremium)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            'Watch ${CreditsPolicy.numberUnlockAdsRequired} rewarded ads to unlock your US line — or go Pro to pick a number instantly.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              height: 1.4,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: isPremium
                            ? Center(
                                child: TextButton.icon(
                                  onPressed: () {
                                    Navigator.of(context).pushNamed(
                                      NumberSelectionScreen.routeName,
                                      arguments: NumberSelectionRouteArgs(
                                        userUid: widget.userUid,
                                        userCredits: credits,
                                      ),
                                    );
                                  },
                                  icon: Icon(
                                    Icons.search_rounded,
                                    size: 18,
                                    color: AppColors.textMutedOnDark,
                                  ),
                                  label: Text(
                                    'Browse all numbers',
                                    style: GoogleFonts.inter(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: AppColors.textMutedOnDark,
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 18),
                      const _NumberFeatureGrid(),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
    );
    if (widget.embedInShell) {
      return streamBody;
    }
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        backgroundColor: AppTheme.darkBg,
        elevation: 0,
        title: Text(
          'My Number',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w800,
            fontSize: 20,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        iconTheme: IconThemeData(
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
      body: streamBody,
    );
  }
}

double _leaseFracVm(DateTime now, DateTime expiry, String? planType) {
  final leaseMs = CreditsPolicy.leaseDurationMsForPlanType(planType);
  final leftMs = expiry.difference(now).inMilliseconds;
  if (leftMs <= 0) return 0;
  return (leftMs / leaseMs).clamp(0.0, 1.0);
}

String _leaseCaptionVm(DateTime now, DateTime? expiry) {
  if (expiry == null) return 'No expiry set';
  final left = expiry.difference(now);
  if (left.inSeconds <= 0) return 'Expired';
  if (left.inDays >= 1) return '${left.inDays}d left';
  if (left.inHours >= 1) return '${left.inHours}h left';
  return '${left.inMinutes}m left';
}

class _AssignedLineGlassCard extends StatelessWidget {
  const _AssignedLineGlassCard({
    required this.number,
    required this.leaseExpiry,
    required this.planType,
  });

  final String number;
  final DateTime? leaseExpiry;
  final String? planType;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final exp = leaseExpiry;
    final frac = (exp != null) ? _leaseFracVm(now, exp, planType) : 1.0;
    final arcColor = leaseRingForegroundColor(now, exp);

    return GlassPanel(
      borderRadius: AppTheme.radiusLg,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_rounded,
                color: AppColors.textMutedOnDark.withValues(alpha: 0.95),
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Your 2nd line',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(200, 200),
                    painter: LeaseRingPainter(
                      progress: frac,
                      trackColor: Colors.white.withValues(alpha: 0.12),
                      foregroundColor: arcColor,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(
                        formatUsPhoneForDisplay(number),
                        textAlign: TextAlign.center,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _leaseCaptionVm(now, exp),
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: arcColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberUnlockPromoCard extends StatelessWidget {
  const _NumberUnlockPromoCard({
    required this.numberAdProgress,
    required this.isPremium,
    required this.requiredAds,
  });

  final int numberAdProgress;
  final bool isPremium;
  final int requiredAds;

  double get _progress {
    if (isPremium) return 1.0;
    if (requiredAds <= 0) return 0;
    return (numberAdProgress / requiredAds).clamp(0.0, 1.0);
  }

  int get _percent => (_progress * 100).round();

  int get _adsRemaining =>
      math.max(0, requiredAds - numberAdProgress).clamp(0, requiredAds);

  bool get _finalStretchUrgency =>
      !isPremium &&
      _progress >= 0.9 &&
      _adsRemaining > 0 &&
      numberAdProgress < requiredAds;

  bool get _almostUnlockedUrgency =>
      !isPremium &&
      _progress >= 0.7 &&
      _progress < 0.9 &&
      _adsRemaining > 0 &&
      numberAdProgress < requiredAds;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: const Color(0xFF121A26).withValues(alpha: 0.96),
        border: Border.all(color: AppColors.cardBorderSubtle),
        boxShadow: AppTheme.fintechCardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.5),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.phone_in_talk_rounded,
                    color: AppColors.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Unlock your number',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                          height: 1.2,
                          letterSpacing: -0.32,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isPremium
                            ? 'Pro member — pick and activate instantly.'
                            : 'Watch rewarded ads on Home — number unlock is separate from call credits.',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          height: 1.45,
                          color: AppColors.textMutedOnDark,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isPremium
                            ? 'Your line is ready when you are.'
                            : 'Every ad brings you closer.',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          color: AppColors.primary.withValues(alpha: 0.92),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const _VmShieldLockBadge(),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: AppColors.surfaceDark.withValues(alpha: 0.92),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_rounded,
                    size: 14,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Secure & Private Number',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.15,
                      color: AppColors.primary.withValues(alpha: 0.95),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Colors.black.withValues(alpha: 0.22),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Unlock progress',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.35,
                          color: AppColors.textMutedOnDark,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '$_percent%',
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.4,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary.withValues(alpha: 0.2),
                        ),
                        child: Icon(
                          Icons.star_rounded,
                          size: 17,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _ThreeSegmentProgressBar(progress: _progress),
                  const SizedBox(height: 12),
                  if (!isPremium) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: _progress.clamp(0.0, 1.0),
                        minHeight: 10,
                        backgroundColor:
                            Colors.white.withValues(alpha: 0.08),
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '$numberAdProgress / $requiredAds ads watched',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                        color: AppColors.primary.withValues(alpha: 0.98),
                      ),
                    ),
                    if (_adsRemaining > 0) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Only $_adsRemaining ads left to unlock 🔥',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                          color: AppColors.textOnDark.withValues(alpha: 0.92),
                        ),
                      ),
                    ],
                    if (_finalStretchUrgency) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: const Color(0xFF00E676).withValues(alpha: 0.12),
                          border: Border.all(
                            color: const Color(0xFF69F0AE)
                                .withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          '🚀 Final stretch — only $_adsRemaining ads to go!',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            height: 1.3,
                            color: const Color(0xFFB9F6CA),
                          ),
                        ),
                      ),
                    ] else if (_almostUnlockedUrgency) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: const Color(0xFFFF6D00).withValues(alpha: 0.16),
                          border: Border.all(
                            color: const Color(0xFFFF9100)
                                .withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          '🔥 Almost unlocked — just $_adsRemaining ads left!',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            height: 1.3,
                            color: const Color(0xFFFFE0B2),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                  Text(
                    isPremium
                        ? 'You can activate immediately.'
                        : 'Each ad moves the bar — one reward per ad.',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      color: AppColors.textDimmed,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VmShieldLockBadge extends StatelessWidget {
  const _VmShieldLockBadge();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 88,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            bottom: 2,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.2),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary.withValues(alpha: 0.38),
                  AppColors.primary.withValues(alpha: 0.1),
                ],
              ),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.45),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.shield_rounded,
                  size: 42,
                  color: AppColors.primary.withValues(alpha: 0.95),
                ),
                Icon(
                  Icons.lock_rounded,
                  size: 17,
                  color: AppColors.textOnDark,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreeSegmentProgressBar extends StatelessWidget {
  const _ThreeSegmentProgressBar({required this.progress});

  final double progress;

  double _segFill(int i) {
    final start = i / 3;
    final end = (i + 1) / 3;
    if (progress <= start) return 0;
    if (progress >= end) return 1;
    return (progress - start) / (end - start);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(3, (i) {
        final f = _segFill(i);
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < 2 ? 8 : 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 12,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Colors.white.withValues(alpha: 0.07),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: f,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                AppColors.primary.withValues(alpha: 0.78),
                                AppColors.primary,
                              ],
                            ),
                          ),
                          child: const SizedBox(height: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _VmActivateGradientButton extends StatelessWidget {
  const _VmActivateGradientButton({
    required this.enabled,
    required this.busy,
    required this.onPressed,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final active = enabled && !busy;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: active ? AppTheme.fintechPrimaryCtaShadow : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
        onTap: active ? onPressed : null,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: active
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF00E676),
                      Color(0xFF00C853),
                      Color(0xFF69F0AE),
                    ],
                    stops: [0.0, 0.45, 1.0],
                  )
                : null,
            color: active ? null : const Color(0xFF2C3238),
          ),
          padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: AppColors.onPrimaryButton.withValues(alpha: 0.95),
                  ),
                )
              else ...[
                Icon(
                  Icons.rocket_launch_rounded,
                  color: active
                      ? AppColors.onPrimaryButton
                      : Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant
                          .withValues(alpha: 0.45),
                  size: 22,
                ),
                const SizedBox(width: 10),
                Text(
                  'ACTIVATE MY NUMBER',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: 0.75,
                    color: active
                        ? AppColors.onPrimaryButton
                        : Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.45),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _NumberFeatureGrid extends StatelessWidget {
  const _NumberFeatureGrid();

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
          ),
          child: Column(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(height: 8),
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
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 3,
                style: GoogleFonts.inter(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w500,
                  height: 1.25,
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
          icon: Icons.shield_rounded,
          iconColor: AppColors.primary,
          title: '100% Private',
          subtitle: 'Your number is safe with us',
        ),
        const SizedBox(width: 8),
        cell(
          icon: Icons.bolt_rounded,
          iconColor: AppColors.inboxBannerBlue,
          title: 'Quick Unlock',
          subtitle: 'Watch more ads to unlock faster',
        ),
        const SizedBox(width: 8),
        cell(
          icon: Icons.verified_rounded,
          iconColor: const Color(0xFFB794F6),
          title: 'Trusted by 10K+',
          subtitle: 'Join satisfied users',
        ),
      ],
    );
  }
}
