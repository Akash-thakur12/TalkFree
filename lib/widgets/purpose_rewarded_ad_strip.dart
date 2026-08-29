import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/credits_policy.dart';
import '../services/grant_reward_service.dart' show GrantRewardPurpose;
import '../theme/app_colors.dart';
import '../utils/monetization_copy.dart';
import 'cooldown_reward_progress_bar.dart';
import 'recommended_ad_badge.dart';

/// Three rewarded-ad CTAs (call / number / OTP) — same behavior as Home strip.
class PurposeRewardedAdStrip extends StatefulWidget {
  const PurposeRewardedAdStrip({
    super.key,
    required this.canTapAd,
    required this.grantRewardPending,
    required this.rewardedAdBusy,
    required this.cooldownRemaining,
    required this.dailyLimitReached,
    required this.emphasizePurpose,
    required this.showRewardRecommendedBadge,
    required this.cooldownPolicySeconds,
    required this.onPurposeAd,
    this.subtitleCallIsPremium = false,
    this.omitCallPurpose = false,
  });

  final bool canTapAd;
  final bool grantRewardPending;
  final bool rewardedAdBusy;
  final int cooldownRemaining;
  final bool dailyLimitReached;
  final GrantRewardPurpose emphasizePurpose;
  final bool showRewardRecommendedBadge;
  final int cooldownPolicySeconds;
  final Future<void> Function(GrantRewardPurpose purpose) onPurposeAd;
  final bool subtitleCallIsPremium;
  final bool omitCallPurpose;

  @override
  State<PurposeRewardedAdStrip> createState() => _PurposeRewardedAdStripState();
}

class _PurposeRewardedAdStripState extends State<PurposeRewardedAdStrip> {
  /// Whichever row the user last triggered — only that row shows a spinner.
  GrantRewardPurpose? _loadingFor;

  bool get _cooldownGate =>
      widget.cooldownRemaining > 0 &&
      !widget.dailyLimitReached &&
      !widget.rewardedAdBusy;

  @override
  void didUpdateWidget(covariant PurposeRewardedAdStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dailyLimitReached && !widget.dailyLimitReached) {
      setState(() => _loadingFor = null);
    }
  }

  void _handleRowTap(GrantRewardPurpose purpose) {
    final slotOpen = widget.canTapAd &&
        !widget.grantRewardPending &&
        !widget.rewardedAdBusy &&
        !widget.dailyLimitReached;
    if (!slotOpen || _loadingFor != null) return;

    HapticFeedback.lightImpact();
    setState(() => _loadingFor = purpose);
    widget.onPurposeAd(purpose).whenComplete(() {
      if (!mounted) return;
      setState(() {
        if (_loadingFor == purpose) {
          _loadingFor = null;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final globalTap = widget.canTapAd &&
        !widget.grantRewardPending &&
        !widget.rewardedAdBusy &&
        !widget.dailyLimitReached;

    if (widget.dailyLimitReached) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AppColors.surfaceDark.withValues(alpha: 0.92),
          border: Border.all(color: AppColors.cardBorderSubtle),
        ),
        child: Text(
          'Daily ad limit reached — back tomorrow.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.textMutedOnDark,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_cooldownGate) ...[
          Text(
            'Wait ${widget.cooldownRemaining}s to watch next ad',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 8),
          CooldownRewardProgressBar(
            remainingSeconds: widget.cooldownRemaining,
            totalCooldownSeconds: widget.cooldownPolicySeconds,
          ),
          const SizedBox(height: 6),
          Text(
            MonetizationCopy.cooldownGoProHint,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              height: 1.4,
              letterSpacing: 0.02,
              color: AppColors.textMutedOnDark.withValues(alpha: 0.58),
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (!widget.omitCallPurpose) ...[
          RepaintBoundary(
            child: _PurposeRewardButton(
              globalTap: globalTap,
              loadingFor: _loadingFor,
              purpose: GrantRewardPurpose.call,
              isPrimary: widget.emphasizePurpose == GrantRewardPurpose.call,
              showRewardRecommendedBadge: widget.showRewardRecommendedBadge,
              icon: Icons.bolt_rounded,
              label: 'Watch ad → Get call credits',
              subtitle: CreditsPolicy.rewardAdEmotionalSubtitleCall(
                widget.subtitleCallIsPremium,
              ),
              onRowTap: () => _handleRowTap(GrantRewardPurpose.call),
            ),
          ),
          const SizedBox(height: 10),
        ],
        RepaintBoundary(
          child: _PurposeRewardButton(
            globalTap: globalTap,
            loadingFor: _loadingFor,
            purpose: GrantRewardPurpose.number,
            isPrimary: widget.emphasizePurpose == GrantRewardPurpose.number,
            showRewardRecommendedBadge: widget.showRewardRecommendedBadge,
            icon: Icons.phone_android_rounded,
            label: 'Watch ad → Unlock number',
            subtitle: CreditsPolicy.rewardAdEmotionalSubtitleNumber(),
            onRowTap: () => _handleRowTap(GrantRewardPurpose.number),
          ),
        ),
        const SizedBox(height: 10),
        RepaintBoundary(
          child: _PurposeRewardButton(
            globalTap: globalTap,
            loadingFor: _loadingFor,
            purpose: GrantRewardPurpose.otp,
            isPrimary: widget.emphasizePurpose == GrantRewardPurpose.otp,
            showRewardRecommendedBadge: widget.showRewardRecommendedBadge,
            icon: Icons.sms_outlined,
            label: 'Watch ad → Send SMS',
            subtitle: CreditsPolicy.rewardAdEmotionalSubtitleOtp(),
            onRowTap: () => _handleRowTap(GrantRewardPurpose.otp),
          ),
        ),
      ],
    );
  }
}

class _PurposeRewardButton extends StatelessWidget {
  const _PurposeRewardButton({
    required this.globalTap,
    required this.loadingFor,
    required this.purpose,
    required this.isPrimary,
    required this.showRewardRecommendedBadge,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onRowTap,
  });

  final bool globalTap;
  final GrantRewardPurpose? loadingFor;
  final GrantRewardPurpose purpose;
  final bool isPrimary;
  final bool showRewardRecommendedBadge;
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onRowTap;

  @override
  Widget build(BuildContext context) {
    final isThisRowLoading = loadingFor == purpose;
    final waitingOnOther = loadingFor != null && !isThisRowLoading;
    final isGreyed =
        !isThisRowLoading && (!globalTap || waitingOnOther);
    final canStartTap = globalTap && loadingFor == null;

    final Color iconColor;
    final Color titleColor;
    final Color subtitleColor;
    if (isGreyed) {
      iconColor = AppColors.textMutedOnDark;
      titleColor = AppColors.textMutedOnDark;
      subtitleColor = AppColors.textMutedOnDark.withValues(alpha: 0.88);
    } else if (isPrimary) {
      iconColor = AppColors.onPrimaryButton;
      titleColor = AppColors.onPrimaryButton;
      subtitleColor = AppColors.onPrimaryButton.withValues(alpha: 0.88);
    } else {
      iconColor = AppColors.primary;
      titleColor = AppColors.textOnDark;
      subtitleColor = AppColors.textMutedOnDark;
    }
    final loaderColor = isPrimary
        ? AppColors.onPrimaryButton
        : AppColors.primary;

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                    color: subtitleColor,
                  ),
                ),
              ],
            ),
          ),
          if (isThisRowLoading)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 2),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: loaderColor.withValues(alpha: 0.95),
                ),
              ),
            ),
        ],
      ),
    );

    Widget withRecommended(Widget inner) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isPrimary && showRewardRecommendedBadge) ...[
            const Center(child: RecommendedAdBadge()),
            const SizedBox(height: 6),
          ] else if (isPrimary) ...[
            const SizedBox(height: 4),
          ],
          inner,
        ],
      );
    }

    final BoxDecoration dec;
    if (isGreyed) {
      dec = BoxDecoration(
        color: AppColors.surfaceDark.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.cardBorderSubtle,
        ),
      );
    } else if (isPrimary) {
      dec = BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(14),
      );
    } else {
      dec = BoxDecoration(
        color: AppColors.surfaceDark.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.4),
        ),
      );
    }

    final target = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canStartTap ? onRowTap : null,
        child: DecoratedBox(
          decoration: dec,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            child: content,
          ),
        ),
      ),
    );

    return withRecommended(
      SizedBox(
        width: double.infinity,
        child: target,
      ),
    );
  }
}
