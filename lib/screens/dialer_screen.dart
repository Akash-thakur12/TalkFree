import 'dart:async' show unawaited;

import 'dart:ui' show FontFeature, ImageFilter;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:country_picker/country_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/credits_policy.dart';
import '../utils/app_snackbar.dart';
import '../utils/monetization_copy.dart';
import '../services/ad_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../services/call_service.dart';
import '../services/firestore_user_service.dart';
import '../services/grant_reward_service.dart';
import '../widgets/cooldown_reward_progress_bar.dart';
import '../widgets/recommended_ad_badge.dart';
import '../utils/voip_runtime_permissions.dart';
import '../widgets/premium_ios_dial_pad.dart';
import '../widgets/soft_pulse.dart';
import 'call_success_screen.dart';
import 'calling_screen.dart';
import 'subscription_screen.dart';

/// Mockup canvas — [AppColors.freeHomeCanvas] (#0B0E11); used for embed + keypad strip.
const Color _dialerCanvasBg = AppColors.freeHomeCanvas;

/// Pro badge purple (dialer country card).
const Color _dialerProPurple = Color(0xFF6B46C1);

class DialerScreen extends StatefulWidget {
  const DialerScreen({
    super.key,
    required this.user,
    this.isPremium = false,
    this.onEarnMinutes,
    this.rewardedAdBusy = false,
    this.cooldownRemaining = 0,
    this.rewardDailyLimitReached = false,
    required this.outboundCallsTotal,
    this.onOpenHistory,
    this.onOpenSettings,
    this.embedInShell = false,
    this.emphasizeRewardPurpose = GrantRewardPurpose.call,
    this.repeatHabitPulseBoost = false,
    this.showRecommendedBadge = true,
  });

  final User user;
  /// Opens call history (e.g. top-left “History” when embedded in shell).
  final VoidCallback? onOpenHistory;
  /// Settings (embed header gear); [DashboardScreen] opens [SettingsScreen].
  final VoidCallback? onOpenSettings;
  /// Hides the large credits card when [onOpenHistory] shows credits in the header row.
  final bool embedInShell;
  /// Pro subscribers: lower per-minute cost in billing (no per-minute credit UI here).
  final bool isPremium;
  final Future<void> Function(GrantRewardPurpose purpose)? onEarnMinutes;
  final bool rewardedAdBusy;
  final int cooldownRemaining;
  /// Daily ad cap from Firestore (10 free / 25 Pro per UTC day).
  final bool rewardDailyLimitReached;
  /// When > 0, first-call hint is hidden ([DashboardScreen] passes server total).
  final ValueNotifier<int> outboundCallsTotal;

  /// Which rewarded-ad row reads as the “default” choice (dialer → call).
  final GrantRewardPurpose emphasizeRewardPurpose;

  /// Stronger strip pulse when last grant matches this screen’s default purpose.
  final bool repeatHabitPulseBoost;

  /// “⭐ Recommended” on the primary row (hidden after onboarding unless confused).
  final bool showRecommendedBadge;

  @override
  State<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends State<DialerScreen>
    with TickerProviderStateMixin {
  /// Raw dial payload (digits / DTMF / optional leading +); country code prefix is separate UI.
  final TextEditingController _dialController = TextEditingController();
  final FocusNode _dialFocusNode = FocusNode();

  void _onDialTextChanged() {
    if (mounted) setState(() {});
  }

  bool _callBusy = false;
  /// True while opening / showing the in-call screen — neon pulsing overlay.
  bool _apiConnecting = false;
  /// Only this rewarded-ad row shows a loading indicator (full-screen dialer).
  GrantRewardPurpose? _rewardedAdPurposeLoading;
  late Country _country;

  late final AnimationController _connectPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  String get _display => _dialController.text;

  @override
  void initState() {
    super.initState();
    _country = Country.parse('IN');
    _dialController.addListener(_onDialTextChanged);
  }

  @override
  void dispose() {
    _dialController.removeListener(_onDialTextChanged);
    _dialController.dispose();
    _dialFocusNode.dispose();
    _connectPulse.dispose();
    super.dispose();
  }

  void _append(String ch) {
    HapticFeedback.lightImpact();
    final v = _dialController.value;
    final t = v.text;
    final s = v.selection;
    final start = s.isValid ? s.start.clamp(0, t.length) : t.length;
    final end = s.isValid ? s.end.clamp(0, t.length) : t.length;
    final newText = t.replaceRange(start, end, ch);
    final newOffset = start + ch.length;
    _dialController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
    _dialFocusNode.requestFocus();
  }

  void _backspace() {
    HapticFeedback.selectionClick();
    final v = _dialController.value;
    final t = v.text;
    if (t.isEmpty) return;
    final s = v.selection;
    if (s.isValid && s.start != s.end) {
      final a = s.start.clamp(0, t.length);
      final b = s.end.clamp(0, t.length);
      final newText = t.replaceRange(a, b, '');
      _dialController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: a),
      );
    } else {
      final i = (s.isValid ? s.start : t.length).clamp(0, t.length);
      if (i <= 0) return;
      final newText = t.replaceRange(i - 1, i, '');
      _dialController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: i - 1),
      );
    }
    _dialFocusNode.requestFocus();
  }

  void _clearNumber() {
    if (_dialController.text.isEmpty) return;
    HapticFeedback.mediumImpact();
    _dialController.clear();
    _dialFocusNode.requestFocus();
  }

  /// Microphone + (Android) Phone — system prompts first; app Settings only if permanently denied.
  Future<bool> _ensureCallPermissionsForVoip() async {
    if (kIsWeb) {
      if (!mounted) return false;
      AppSnackBar.show(context,
        SnackBar(
          content: const Text('VoIP calls are not supported in this browser.'),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      return false;
    }

    if (!mounted) return false;
    return ensureVoipRuntimePermissions(context);
  }

  Future<void> _showLowCreditsForCall() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.darkBg,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final bottom = MediaQuery.paddingOf(ctx).bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + bottom),
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.38),
                    ),
                  ),
                  child: Text(
                    '🎯 Pick your reward  •  1 ad = 1 benefit',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.15,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                MonetizationCopy.outOfCreditsTitle,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.onEarnMinutes != null
                    ? 'Pick one reward per ad — or go Pro for faster, cheaper minutes.'
                    : 'Add credits in Premium to keep calling.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  height: 1.4,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 18),
              if (widget.onEarnMinutes != null) ...[
                if (_rewardAdCooldownOnly) ...[
                  _rewardAdCooldownBanner(),
                  CooldownRewardProgressBar(
                    remainingSeconds: widget.cooldownRemaining,
                    totalCooldownSeconds:
                        CreditsPolicy.adRewardCooldownSecondsForUser(
                      widget.isPremium,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _freeDialPurposeButton(
                  purpose: GrantRewardPurpose.call,
                  label: 'Watch Ad for Call Credits',
                  subtitle: CreditsPolicy.rewardAdEmotionalSubtitleCall(
                    widget.isPremium,
                  ),
                  isEmphasized:
                      widget.emphasizeRewardPurpose == GrantRewardPurpose.call,
                  preInvoke: () => Navigator.of(ctx).pop(),
                ),
                const SizedBox(height: 12),
                _freeDialPurposeButton(
                  purpose: GrantRewardPurpose.number,
                  label: 'Watch Ad for Number Unlock',
                  subtitle: CreditsPolicy.rewardAdEmotionalSubtitleNumber(),
                  isEmphasized:
                      widget.emphasizeRewardPurpose ==
                          GrantRewardPurpose.number,
                  preInvoke: () => Navigator.of(ctx).pop(),
                ),
                const SizedBox(height: 12),
                _freeDialPurposeButton(
                  purpose: GrantRewardPurpose.otp,
                  label: 'Watch Ad for SMS OTP',
                  subtitle: CreditsPolicy.rewardAdEmotionalSubtitleOtp(),
                  isEmphasized:
                      widget.emphasizeRewardPurpose == GrantRewardPurpose.otp,
                  preInvoke: () => Navigator.of(ctx).pop(),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).push<void>(
                      SubscriptionScreen.createRoute(),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textOnDark,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'Go Pro',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ] else ...[
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).push<void>(
                      SubscriptionScreen.createRoute(),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimaryButton,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    'View plans',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
          ),
        );
      },
    );
  }

  /// In-app VoIP only: [TwilioVoipFacade] + [CallingScreen] (neon in-call UI).
  /// Does **not** use [url_launcher], `tel:` URIs, or the system phone app — stays inside TalkFree.
  Future<void> _onCall() async {
    if (_callBusy) return;

    final to = formatDialInputToE164(
      _display,
      defaultCallingCode: _country.phoneCode,
    );
    if (to.isEmpty) {
      AppSnackBar.show(context,
        SnackBar(
          content: const Text('Enter a phone number'),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      return;
    }

    final allDigits = to.replaceAll(RegExp(r'\D'), '');
    final rawDigits = _display.replaceAll(RegExp(r'\D'), '');
    final trimmed = _display.trim();
    final tooShort = trimmed.startsWith('+')
        ? allDigits.length < 11
        : rawDigits.length < 10;
    if (tooShort) {
      AppSnackBar.show(context,
        SnackBar(
          content: const Text(
            'Enter a complete number for the selected country.',
          ),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      return;
    }

    final usable = await FirestoreUserService.fetchUsableCredits(widget.user.uid);
    if (!mounted) return;
    if (usable < CreditsPolicy.minCreditsToStartCallFor(widget.isPremium)) {
      await _showLowCreditsForCall();
      return;
    }

    final allowed = await _ensureCallPermissionsForVoip();
    if (!allowed || !mounted) return;

    setState(() {
      _callBusy = true;
      _apiConnecting = true;
    });
    _connectPulse.repeat();
    try {
      if (!mounted) return;

      // Outbound calls use Twilio Voice SDK only ([CallingScreen.placePstnCall]).
      // Do not call server GET /call here — it started a duplicate PSTN leg and could
      // confuse the SDK or Twilio (two outbound attempts).

      final result = await Navigator.of(context).push<CallingScreenResult?>(
        PageRouteBuilder<CallingScreenResult?>(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (_, animation, secondaryAnimation) => CallingScreen(
            user: widget.user,
            dialE164: to,
          ),
          transitionsBuilder: (_, animation, _, child) {
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              ),
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.04),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
                child: child,
              ),
            );
          },
        ),
      );
      if (!mounted) return;
      final r = result;
      if (r == null) return;
      if (r.exitReason == CallingScreenExitReason.ok && !widget.isPremium) {
        unawaited(AdService.instance.loadAndShowInterstitialAd());
        if (mounted) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => CallSuccessScreen(syncedBalance: r.syncedBalance),
            ),
          );
        }
      }
      if (!mounted) return;
      if (r.exitReason == CallingScreenExitReason.voipFailure) {
        AppSnackBar.show(context,
          SnackBar(
            content: const Text(
              'Call failed. Check internet or permissions',
            ),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      } else if (r.exitReason == CallingScreenExitReason.insufficientCredits) {
        await _showLowCreditsForCall();
      } else if (r.serverBillingPending) {
        final b = r.syncedBalance;
        AppSnackBar.show(context,
          SnackBar(
            content: Text(
              b != null
                  ? 'Balance still shows $b credits — updates can take a moment. '
                      'If it looks wrong, try again in a little while.'
                  : 'Credits usually update shortly after the call. If not, try again later.',
            ),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      } else if (r.syncedBalance != null &&
          !(r.exitReason == CallingScreenExitReason.ok && !widget.isPremium)) {
        AppSnackBar.show(context,
          SnackBar(
            content: Text(
              'Balance: ${r.syncedBalance} credits',
              style: GoogleFonts.inter(
                letterSpacing: 0,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      }
    } finally {
      _connectPulse.stop();
      _connectPulse.reset();
      if (mounted) {
        setState(() {
          _callBusy = false;
          _apiConnecting = false;
        });
      }
    }
  }

  void _openCountryPicker() {
    HapticFeedback.selectionClick();
    showCountryPicker(
      context: context,
      showPhoneCode: true,
      favorite: const ['IN', 'US', 'GB', 'CA', 'AU', 'AE'],
      countryListTheme: CountryListThemeData(
        bottomSheetHeight: MediaQuery.sizeOf(context).height * 0.88,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
        backgroundColor: AppTheme.darkBg,
        textStyle: GoogleFonts.inter(
          color: Colors.white.withValues(alpha: 0.94),
          fontSize: 16,
        ),
        searchTextStyle: GoogleFonts.inter(color: Colors.white),
        inputDecoration: InputDecoration(
          filled: true,
          fillColor: AppColors.cardDark,
          labelText: 'Search',
          labelStyle: GoogleFonts.inter(color: Colors.white54),
          hintText: 'Country or code',
          hintStyle: GoogleFonts.inter(color: Colors.white38),
          prefixIcon: Icon(
            Icons.search_rounded,
            color: premiumDialCallGreen.withValues(alpha: 0.9),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: premiumDialCallGreen.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
      onSelect: (Country country) {
        HapticFeedback.selectionClick();
        setState(() => _country = country);
      },
    );
  }

  bool get _freePurposeAdsDisabled =>
      widget.rewardedAdBusy ||
      widget.rewardDailyLimitReached ||
      widget.cooldownRemaining > 0;

  bool get _rewardAdCooldownOnly =>
      widget.cooldownRemaining > 0 &&
      !widget.rewardDailyLimitReached &&
      !widget.rewardedAdBusy;

  Widget _rewardAdCooldownBanner() {
    if (!_rewardAdCooldownOnly) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        'Wait ${widget.cooldownRemaining}s to watch next ad',
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: AppColors.primary,
        ),
      ),
    );
  }

  Widget _freeDialPurposeButton({
    required GrantRewardPurpose purpose,
    required String label,
    required String subtitle,
    required bool isEmphasized,
    VoidCallback? preInvoke,
  }) {
    final disabled =
        _freePurposeAdsDisabled || widget.onEarnMinutes == null;
    final showLoading = _rewardedAdPurposeLoading == purpose;
    final canStartTap = !disabled && _rewardedAdPurposeLoading == null;
    final waitingOther = _rewardedAdPurposeLoading != null && !showLoading;
    final isGreyed = !showLoading && (disabled || waitingOther);

    void onRowTap() {
      if (!canStartTap) return;
      HapticFeedback.lightImpact();
      preInvoke?.call();
      setState(() => _rewardedAdPurposeLoading = purpose);
      unawaited(
        widget.onEarnMinutes!(purpose).whenComplete(() {
          if (!mounted) return;
          setState(() {
            if (_rewardedAdPurposeLoading == purpose) {
              _rewardedAdPurposeLoading = null;
            }
          });
        }),
      );
    }

    final Color textColor;
    final Color loaderColor;
    final BoxDecoration dec;
    if (isGreyed) {
      textColor = AppColors.textMutedOnDark;
      loaderColor = AppColors.primary;
      dec = BoxDecoration(
        color: AppColors.surfaceDark.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorderSubtle),
      );
    } else if (isEmphasized) {
      textColor = AppColors.onPrimaryButton;
      loaderColor = AppColors.onPrimaryButton;
      dec = BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(14),
      );
    } else {
      textColor = AppColors.textOnDark;
      loaderColor = AppColors.primary;
      dec = BoxDecoration(
        color: AppColors.surfaceDark.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.42),
        ),
      );
    }

    final cta = RepaintBoundary(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canStartTap ? onRowTap : null,
          child: DecoratedBox(
            decoration: dec,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.15,
                        color: textColor,
                      ),
                    ),
                  ),
                  if (showLoading) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: loaderColor.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isEmphasized && widget.showRecommendedBadge) ...[
          const Center(child: RecommendedAdBadge()),
          const SizedBox(height: 6),
        ] else if (isEmphasized) ...[
          const SizedBox(height: 4),
        ],
        SizedBox(width: double.infinity, child: cta),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.textMutedOnDark,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final compactDial = MediaQuery.sizeOf(context).height < 700;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Scaffold(
              backgroundColor: _dialerCanvasBg,
              body: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: FirestoreUserService.watchUserDocument(
                          widget.user.uid,
                        ),
                        builder: (context, creditSnap) {
                          final c = creditSnap.hasData
                              ? FirestoreUserService.usableCreditsFromSnapshot(
                                  creditSnap.data!,
                                )
                              : 0;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (widget.embedInShell) ...[
                                if (!widget.isPremium)
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(0, 2, 0, 8),
                                    child: Row(
                                      children: [
                                        const Spacer(),
                                        if (widget.onOpenHistory != null)
                                          TextButton(
                                            onPressed: widget.onOpenHistory,
                                            style: TextButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 6,
                                              ),
                                            ),
                                            child: Text(
                                              'History',
                                              style: GoogleFonts.inter(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                                color: AppColors
                                                    .textMutedOnDark,
                                              ),
                                            ),
                                          ),
                                        if (widget.onOpenSettings != null)
                                          IconButton(
                                            tooltip: 'Settings',
                                            onPressed: widget.onOpenSettings,
                                            icon: Icon(
                                              Icons.settings_outlined,
                                              size: 22,
                                              color: AppColors.textMutedOnDark,
                                            ),
                                          ),
                                      ],
                                    ),
                                  )
                                else
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(0, 2, 0, 8),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Text(
                                          'Dialer',
                                          style: GoogleFonts.inter(
                                            fontSize: 24,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.5,
                                            height: 1.1,
                                            color: AppColors.textOnDark,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 11,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: Border.all(
                                              color: AppColors.accentGold
                                                  .withValues(alpha: 0.6),
                                            ),
                                            color: AppColors.cardDark,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.auto_awesome_rounded,
                                                size: 15,
                                                color: AppColors.accentGold,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                'PRO',
                                                style: GoogleFonts.inter(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w900,
                                                  letterSpacing: 0.4,
                                                  color: AppColors.accentGold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const Spacer(),
                                        if (widget.onOpenHistory != null)
                                          Material(
                                            color: Colors.transparent,
                                            child: InkWell(
                                              onTap: widget.onOpenHistory,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              child: Ink(
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(999),
                                                  color: AppColors.cardDark,
                                                  border: Border.all(
                                                    color: Colors.white
                                                        .withValues(
                                                      alpha: 0.1,
                                                    ),
                                                  ),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 7,
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.history_rounded,
                                                      size: 17,
                                                      color: AppColors
                                                          .textMutedOnDark,
                                                    ),
                                                    const SizedBox(width: 5),
                                                    Text(
                                                      'History',
                                                      style: GoogleFonts.inter(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 13,
                                                        color: AppColors
                                                            .textOnDark,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (widget.onOpenSettings != null) ...[
                                          if (widget.onOpenHistory != null)
                                            const SizedBox(width: 2),
                                          IconButton(
                                            tooltip: 'Settings',
                                            onPressed: widget.onOpenSettings,
                                            icon: Icon(
                                              Icons.settings_outlined,
                                              size: 22,
                                              color: AppColors.textMutedOnDark,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                              ],
                              if (widget.embedInShell &&
                                  !widget.isPremium &&
                                  widget.onEarnMinutes != null) ...[
                                if (_rewardAdCooldownOnly) ...[
                                  _rewardAdCooldownBanner(),
                                  CooldownRewardProgressBar(
                                    remainingSeconds: widget.cooldownRemaining,
                                    totalCooldownSeconds: CreditsPolicy
                                        .adRewardCooldownSecondsForUser(
                                      widget.isPremium,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                SoftPulse(
                                  enabled: !widget.rewardedAdBusy &&
                                      !widget.rewardDailyLimitReached &&
                                      widget.cooldownRemaining <= 0,
                                  pulseBoost: widget.repeatHabitPulseBoost,
                                  child: _FreeDialerEmbedCreditsCard(
                                    credits: c,
                                    onWatchAd: () {
                                      if (_freePurposeAdsDisabled) return;
                                      unawaited(
                                        widget.onEarnMinutes!(
                                            GrantRewardPurpose.call),
                                      );
                                    },
                                    adDisabled: _freePurposeAdsDisabled,
                                    showCoolDownBanner: false,
                                    cooldownRemaining: widget.cooldownRemaining,
                                    cooldownTotal: CreditsPolicy
                                        .adRewardCooldownSecondsForUser(
                                      widget.isPremium,
                                    ),
                                  ),
                                ),
                              ],
                              if (!widget.embedInShell)
                                _GlassCreditsCard(
                                  credits: c,
                                  isPremium: widget.isPremium,
                                ),
                              if (!widget.embedInShell &&
                                  !widget.isPremium &&
                                  widget.onEarnMinutes != null) ...[
                                const SizedBox(height: 12),
                                SoftPulse(
                                  enabled: !widget.rewardedAdBusy &&
                                      !widget.rewardDailyLimitReached &&
                                      widget.cooldownRemaining <= 0,
                                  pulseBoost: widget.repeatHabitPulseBoost,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (_rewardAdCooldownOnly) ...[
                                        _rewardAdCooldownBanner(),
                                        CooldownRewardProgressBar(
                                          remainingSeconds:
                                              widget.cooldownRemaining,
                                          totalCooldownSeconds:
                                              CreditsPolicy
                                                  .adRewardCooldownSecondsForUser(
                                            widget.isPremium,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                      ] else ...[
                                        Text(
                                          'Pick one reward per ad',
                                          textAlign: TextAlign.center,
                                          style: GoogleFonts.inter(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.textMutedOnDark,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                      _freeDialPurposeButton(
                                        purpose: GrantRewardPurpose.call,
                                        label: 'Watch ad → Get call credits',
                                        subtitle:
                                            CreditsPolicy.rewardAdEmotionalSubtitleCall(
                                          widget.isPremium,
                                        ),
                                        isEmphasized: widget
                                                .emphasizeRewardPurpose ==
                                            GrantRewardPurpose.call,
                                      ),
                                      const SizedBox(height: 8),
                                      _freeDialPurposeButton(
                                        purpose: GrantRewardPurpose.number,
                                        label: 'Watch ad → Unlock number',
                                        subtitle: CreditsPolicy
                                            .rewardAdEmotionalSubtitleNumber(),
                                        isEmphasized: widget
                                                .emphasizeRewardPurpose ==
                                            GrantRewardPurpose.number,
                                      ),
                                      const SizedBox(height: 8),
                                      _freeDialPurposeButton(
                                        purpose: GrantRewardPurpose.otp,
                                        label: 'Watch ad → Send SMS',
                                        subtitle: CreditsPolicy
                                            .rewardAdEmotionalSubtitleOtp(),
                                        isEmphasized: widget
                                                .emphasizeRewardPurpose ==
                                            GrantRewardPurpose.otp,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: widget.embedInShell && widget.isPremium
                          ? Row(
                              children: [
                                _DialCompactGoldCountry(
                                  country: _country,
                                  onOpen: _openCountryPicker,
                                ),
                                const Spacer(),
                              ],
                            )
                          : widget.embedInShell && !widget.isPremium
                              ? Row(
                                  children: [
                                    _DialFreeCountryPill(
                                      country: _country,
                                      onOpen: _openCountryPicker,
                                    ),
                                    const Spacer(),
                                  ],
                                )
                              : _CountryPickerTile(
                                  country: _country,
                                  isPremium: widget.isPremium,
                                  rateLine: widget.isPremium
                                      ? 'Pro: ${CreditsPolicy.creditsPerMinuteForUser(true)} credits/min · ⚡ faster routing'
                                      : 'Rate: ${CreditsPolicy.creditsPerMinuteForUser(false)} credits/min',
                                  onOpen: _openCountryPicker,
                                ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: widget.embedInShell && widget.isPremium
                                ? Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      _DialerNumberLine(
                                        phoneCode: _country.phoneCode,
                                        controller: _dialController,
                                        focusNode: _dialFocusNode,
                                        compactDial: compactDial,
                                        showFooterHint: false,
                                        cursorColor: AppColors.primary,
                                      ),
                                      Positioned(
                                        right: 0,
                                        top: 0,
                                        child: Text(
                                          'GOLD',
                                          style: GoogleFonts.inter(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.8,
                                            color: AppColors.accentGold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : widget.embedInShell && !widget.isPremium
                                    ? Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 12,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1A1D24),
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        ),
                                        child: _DialerNumberLine(
                                          phoneCode: _country.phoneCode,
                                          controller: _dialController,
                                          focusNode: _dialFocusNode,
                                          compactDial: compactDial,
                                          showFooterHint: false,
                                          cursorColor: AppColors.freeHomeNeon,
                                        ),
                                      )
                                    : _DialerNumberLine(
                                        phoneCode: _country.phoneCode,
                                        controller: _dialController,
                                        focusNode: _dialFocusNode,
                                        compactDial: compactDial,
                                      ),
                          ),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: _DialerDeleteIconButton(
                              enabled: _display.isNotEmpty,
                              compact: compactDial,
                              accent: widget.embedInShell && !widget.isPremium
                                  ? AppColors.freeHomeNeon
                                  : AppColors.primary,
                              onTap: _backspace,
                              onLongPress: _clearNumber,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.embedInShell && widget.isPremium)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                        child: StreamBuilder<
                            DocumentSnapshot<Map<String, dynamic>>>(
                          stream: FirestoreUserService.watchUserDocument(
                            widget.user.uid,
                          ),
                          builder: (context, snap) {
                            final cr = snap.hasData
                                ? FirestoreUserService
                                    .usableCreditsFromSnapshot(snap.data!)
                                : 0;
                            return _PremiumDialerStatusRow(credits: cr);
                          },
                        ),
                      ),
                    const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                    ColoredBox(
                      color: _dialerCanvasBg,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          12,
                          10,
                          12,
                          6 + MediaQuery.viewPaddingOf(context).bottom,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              height: 1,
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(1),
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.transparent,
                                    Colors.white.withValues(alpha: 0.12),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                            if (widget.embedInShell) ...[
                              if (widget.isPremium)
                                Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    10,
                                    8,
                                    12,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(22),
                                    border: Border.all(
                                      color: AppColors.accentGold
                                          .withValues(alpha: 0.5),
                                      width: 1.2,
                                    ),
                                    color: _dialerCanvasBg,
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.accentGold
                                            .withValues(alpha: 0.06),
                                        blurRadius: 20,
                                        spreadRadius: 0,
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      PremiumIosDialPad(
                                        onDigit: _append,
                                        horizontalPadding:
                                            compactDial ? 10 : 12,
                                        gap: compactDial ? 8 : 10,
                                        keyHeight: compactDial ? 44 : 50,
                                      ),
                                      SizedBox(
                                        height: compactDial ? 12 : 14,
                                      ),
                                      _EmbedWideCallButton(
                                        busy: _callBusy,
                                        onPressed: _onCall,
                                        proStyle: true,
                                      ),
                                    ],
                                  ),
                                )
                              else
                                Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    4,
                                    6,
                                    4,
                                    4,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(22),
                                    border: Border.all(
                                      color: AppColors.freeHomeNeon
                                          .withValues(alpha: 0.2),
                                      width: 1.1,
                                    ),
                                    color: _dialerCanvasBg,
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.freeHomeNeon
                                            .withValues(alpha: 0.04),
                                        blurRadius: 16,
                                        spreadRadius: 0,
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      PremiumIosDialPad(
                                        onDigit: _append,
                                        horizontalPadding:
                                            compactDial ? 10 : 12,
                                        gap: compactDial ? 8 : 10,
                                        keyHeight: compactDial ? 44 : 52,
                                        emphasisDigit: '0',
                                      ),
                                      SizedBox(
                                        height: compactDial ? 12 : 16,
                                      ),
                                      _EmbedWideCallButton(
                                        busy: _callBusy,
                                        onPressed: _onCall,
                                        proStyle: false,
                                      ),
                                    ],
                                  ),
                                ),
                              if (widget.isPremium) ...[
                                const SizedBox(height: 10),
                                Text(
                                  'Priority routing.',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.2,
                                    color: AppColors.textDimmed,
                                  ),
                                ),
                              ],
                            ] else
                              ClipRect(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    PremiumIosDialPad(
                                      onDigit: _append,
                                      horizontalPadding:
                                          compactDial ? 14 : 16,
                                      gap: compactDial ? 8 : 10,
                                      keyHeight: compactDial ? 44 : 52,
                                    ),
                                    SizedBox(
                                      height: compactDial ? 12 : 16,
                                    ),
                                    _DialerCallWithFlankDots(
                                      busy: _callBusy,
                                      onPressed: _onCall,
                                      callButtonDiameter:
                                          compactDial ? 76.0 : 82.0,
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        if (_apiConnecting)
          Positioned.fill(
            child: AbsorbPointer(
              child: _DialerConnectingOverlay(
                pulse: _connectPulse,
              ),
            ),
          ),
      ],
    );
  }
}

/// Free-tier embed credits card (reference: green border, FREE, min, ad icon).
class _FreeDialerEmbedCreditsCard extends StatelessWidget {
  const _FreeDialerEmbedCreditsCard({
    required this.credits,
    required this.onWatchAd,
    required this.adDisabled,
    this.showCoolDownBanner = false,
    this.cooldownRemaining = 0,
    this.cooldownTotal = 45,
  });

  final int credits;
  final VoidCallback onWatchAd;
  final bool adDisabled;
  final bool showCoolDownBanner;
  final int cooldownRemaining;
  final int cooldownTotal;

  static const int _goalMin = 10;

  @override
  Widget build(BuildContext context) {
    final goalCredits = _goalMin * CreditsPolicy.creditsPerMinute;
    final balanceMin = credits ~/ CreditsPolicy.creditsPerMinute;
    final progress = goalCredits <= 0
        ? 0.0
        : (credits / goalCredits).clamp(0.0, 1.0);
    final n = AppColors.freeHomeNeon;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4, bottom: 2),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: n.withValues(alpha: 0.65), width: 1.2),
        color: AppColors.cardDark.withValues(alpha: 0.92),
        boxShadow: [
          BoxShadow(
            color: n.withValues(alpha: 0.12),
            blurRadius: 12,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showCoolDownBanner) ...[
            Text(
              'Next ad in ${cooldownRemaining}s',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: n,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: n.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.phone_in_talk_rounded,
                  color: n,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'FREE',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: n,
                    ),
                  ),
                  Text(
                    'Call credits',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textOnDark,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                '$balanceMin min',
                style: GoogleFonts.poppins(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(n),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(
              height: 1,
              thickness: 1,
              color: Colors.white.withValues(alpha: 0.07),
            ),
          ),
          Row(
            children: [
              Text(
                'Call credits',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: AppColors.textMutedOnDark,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: adDisabled ? null : onWatchAd,
                icon: Icon(
                  Icons.ondemand_video_rounded,
                  color: adDisabled
                      ? AppColors.textDimmed
                      : n,
                  size: 22,
                ),
                tooltip: 'Watch ad for credits',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PremiumDialerStatusRow extends StatelessWidget {
  const _PremiumDialerStatusRow({required this.credits});

  final int credits;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.cardDark.withValues(alpha: 0.55),
        border: Border.all(
          color: AppColors.accentGold.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: AppColors.accentGold,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Pro rate: lower per-minute',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.1,
                    color: AppColors.accentGold,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Included balance · $credits credits',
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.05,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DialCompactGoldCountry extends StatelessWidget {
  const _DialCompactGoldCountry({
    required this.country,
    required this.onOpen,
  });

  final Country country;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppColors.accentGold.withValues(alpha: 0.7),
              width: 1.2,
            ),
            color: const Color(0xFF121A26).withValues(alpha: 0.95),
            boxShadow: [
              BoxShadow(
                color: AppColors.accentGold.withValues(alpha: 0.05),
                blurRadius: 10,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(country.flagEmoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Text(
                '+${country.phoneCode}',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.textMutedOnDark,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Free mockup: flag + code pill, grey/neon border (not gold).
class _DialFreeCountryPill extends StatelessWidget {
  const _DialFreeCountryPill({
    required this.country,
    required this.onOpen,
  });

  final Country country;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final b = AppColors.freeHomeNeon.withValues(alpha: 0.38);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: const Color(0xFF1A1D24),
            border: Border.all(color: b, width: 1.1),
            boxShadow: [
              BoxShadow(
                color: AppColors.freeHomeNeon.withValues(alpha: 0.06),
                blurRadius: 8,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(country.flagEmoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Text(
                '+${country.phoneCode}',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.textMutedOnDark,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmbedWideCallButton extends StatelessWidget {
  const _EmbedWideCallButton({
    required this.busy,
    required this.onPressed,
    this.proStyle = true,
  });

  final bool busy;
  final VoidCallback? onPressed;
  /// Pro mockup: white circle + gold ring + black handset. Free: flat black icons on green.
  final bool proStyle;

  @override
  Widget build(BuildContext context) {
    final ok = !busy && onPressed != null;
    final fill = proStyle ? AppColors.primary : AppColors.freeHomeNeon;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: fill.withValues(alpha: proStyle ? 0.3 : 0.32),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: fill,
          borderRadius: BorderRadius.circular(32),
          child: InkWell(
            onTap: ok ? onPressed : null,
            borderRadius: BorderRadius.circular(32),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (busy)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: AppColors.onPrimaryButton,
                      ),
                    )
                  else ...[
                    if (proStyle) ...[
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.all(
                            color: AppColors.accentGold,
                            width: 2,
                          ),
                        ),
                        child: Icon(
                          Icons.call_rounded,
                          color: AppColors.onPrimaryButton,
                          size: 22,
                        ),
                      ),
                    ] else
                      Icon(
                        Icons.call_rounded,
                        color: AppColors.onPrimaryButton,
                        size: 30,
                      ),
                    const SizedBox(width: 12),
                    Text(
                      'Call',
                      style: GoogleFonts.inter(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: AppColors.onPrimaryButton,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Call button flanked by subtle dot rows (mockup).
class _DialerCallWithFlankDots extends StatelessWidget {
  const _DialerCallWithFlankDots({
    required this.busy,
    required this.onPressed,
    this.callButtonDiameter = 94,
  });

  final bool busy;
  final VoidCallback? onPressed;
  final double callButtonDiameter;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: _dialerFlankDots()),
          PremiumIosCallButton(
            busy: busy,
            onPressed: onPressed,
            horizontalMargin: 10,
            diameter: callButtonDiameter,
          ),
          Expanded(child: _dialerFlankDots()),
        ],
      ),
    );
  }

  Widget _dialerFlankDots() {
    return LayoutBuilder(
      builder: (context, c) {
        final n = 14;
        final dotW = (c.maxWidth / n).clamp(2.0, 5.0);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(
            n,
            (i) => Container(
              width: dotW,
              height: dotW,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.12 + (i % 3) * 0.04),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Full-screen dim + neon green pulsing rings while [CallingScreen] opens (Twilio Voice SDK).
class _DialerConnectingOverlay extends StatelessWidget {
  const _DialerConnectingOverlay({required this.pulse});

  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.52),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: pulse,
                builder: (context, _) {
                  final t = pulse.value;
                  return SizedBox(
                    width: 112,
                    height: 112,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        for (var i = 0; i < 3; i++)
                          _pulseRing(t, i),
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: premiumDialCallGreen.withValues(alpha: 0.16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.55),
                                blurRadius: 22,
                                spreadRadius: -2,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.phone_in_talk_rounded,
                            color: premiumDialCallGreen.withValues(alpha: 0.98),
                            size: 28,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 22),
              Text(
                'Connecting…',
                style: GoogleFonts.inter(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: premiumDialCallGreen.withValues(alpha: 0.95),
                  shadows: const [
                    Shadow(
                      color: Color(0x66000000),
                      blurRadius: 10,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Reaching your TalkFree server',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pulseRing(double t, int index) {
    final phase = ((t + index * 0.28) % 1.0);
    final scale = 0.45 + phase * 0.95;
    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: (1.0 - phase) * 0.85,
        child: Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: premiumDialCallGreen.withValues(alpha: 0.5),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 16,
                spreadRadius: -2,
                offset: const Offset(0, 8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassCreditsCard extends StatelessWidget {
  const _GlassCreditsCard({
    required this.credits,
    this.isPremium = false,
  });

  final int credits;
  final bool isPremium;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        color: AppColors.cardDark,
      ),
      child: isPremium
          ? Text(
              'Lower call cost (Pro)',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textOnDark,
              ),
            )
          : Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Credits: ',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                  TextSpan(
                    text: '$credits',
                    style: GoogleFonts.poppins(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                      letterSpacing: -0.5,
                      color: AppColors.textOnDark,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _CountryPickerTile extends StatelessWidget {
  const _CountryPickerTile({
    required this.country,
    required this.isPremium,
    required this.rateLine,
    required this.onOpen,
  });

  final Country country;
  final bool isPremium;
  final String rateLine;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(18),
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.05),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.45),
              width: 1.2,
            ),
            color: const Color(0xFF121A26).withValues(alpha: 0.95),
            boxShadow: AppTheme.fintechCardShadow,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                country.flagEmoji,
                style: const TextStyle(fontSize: 30),
              ),
              const SizedBox(width: 10),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(alpha: 0.18),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.45),
                  ),
                ),
                child: Icon(
                  Icons.phone_in_talk_rounded,
                  color: AppColors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      country.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textOnDark,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '+${country.phoneCode}',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMutedOnDark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (isPremium)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: _dialerProPurple.withValues(alpha: 0.22),
                          border: Border.all(
                            color: _dialerProPurple.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.workspace_premium_rounded,
                              size: 14,
                              color: _dialerProPurple,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                rateLine,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.1,
                                  color: const Color(0xFFE9D5FF),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Text(
                        rateLine,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                          color: AppColors.textMutedOnDark.withValues(alpha: 0.92),
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.textMutedOnDark,
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Country code prefix + editable dial field (cursor & selection; keypad inserts at caret).
class _DialerNumberLine extends StatelessWidget {
  const _DialerNumberLine({
    required this.phoneCode,
    required this.controller,
    required this.focusNode,
    required this.compactDial,
    this.showFooterHint = true,
    this.cursorColor,
  });

  final String phoneCode;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool compactDial;
  final bool showFooterHint;
  final Color? cursorColor;

  @override
  Widget build(BuildContext context) {
    final fontSize = compactDial ? 22.0 : 28.0;
    final style = GoogleFonts.inter(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.45,
      height: 1.2,
      color: Colors.white.withValues(alpha: 0.96),
      shadows: const [
        Shadow(
          color: Color(0x59000000),
          blurRadius: 10,
          offset: Offset(0, 2),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.center,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: SizedBox(
                  width: constraints.maxWidth,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        '+$phoneCode',
                        style: style,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          keyboardType: TextInputType.none,
                          textInputAction: TextInputAction.done,
                          minLines: 1,
                          maxLines: 2,
                          style: style,
                          strutStyle: StrutStyle(
                            fontSize: fontSize,
                            height: 1.2,
                            forceStrutHeight: true,
                          ),
                          cursorColor: cursorColor ?? premiumDialCallGreen,
                          cursorWidth: 2,
                          cursorHeight: fontSize * 1.08,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            filled: false,
                            isCollapsed: true,
                          ),
                          inputFormatters: const <TextInputFormatter>[
                            _DialerNationalInputFormatter(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (showFooterHint) ...[
          const SizedBox(height: 6),
          Text(
            'Enter number to call',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.textMutedOnDark.withValues(alpha: 0.85),
            ),
          ),
        ],
      ],
    );
  }
}

/// Digits + DTMF `*` / `#`; optional leading `+` for full international entry.
class _DialerNationalInputFormatter extends TextInputFormatter {
  const _DialerNationalInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final sb = StringBuffer();
    final t = newValue.text;
    for (var i = 0; i < t.length; i++) {
      final ch = t[i];
      if (ch == '+' && i == 0) {
        sb.write(ch);
      } else if (RegExp(r'[0-9*#]').hasMatch(ch)) {
        sb.write(ch);
      }
    }
    final cleaned = sb.toString();
    if (cleaned == newValue.text) return newValue;
    var sel = newValue.selection;
    if (!sel.isValid) {
      return TextEditingValue(
        text: cleaned,
        selection: TextSelection.collapsed(offset: cleaned.length),
      );
    }
    var c = sel.extentOffset;
    final delta = newValue.text.length - cleaned.length;
    c -= delta;
    if (c < 0) c = 0;
    if (c > cleaned.length) c = cleaned.length;
    return TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(offset: c),
    );
  }
}

class _DialerDeleteIconButton extends StatefulWidget {
  const _DialerDeleteIconButton({
    required this.enabled,
    required this.compact,
    this.accent = AppColors.primary,
    required this.onTap,
    required this.onLongPress,
  });

  final bool enabled;
  final bool compact;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_DialerDeleteIconButton> createState() =>
      _DialerDeleteIconButtonState();
}

class _DialerDeleteIconButtonState extends State<_DialerDeleteIconButton>
    with TickerProviderStateMixin {
  static const double _size = 50;

  Color get _accent => widget.accent;

  late final AnimationController _tapCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _tapScale = Tween<double>(begin: 1.0, end: 0.88)
      .animate(
        CurvedAnimation(
          parent: _tapCtrl,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        ),
      );

  /// Fluid pulse when long-press clears all digits.
  late final AnimationController _burstCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _burstScale = Tween<double>(begin: 1.0, end: 1.12)
      .animate(
        CurvedAnimation(
          parent: _burstCtrl,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        ),
      );
  late final Animation<double> _glowT = CurvedAnimation(
    parent: _burstCtrl,
    curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
    reverseCurve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
  );

  @override
  void dispose() {
    _tapCtrl.dispose();
    _burstCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (!widget.enabled) return;
    HapticFeedback.lightImpact();
    await _tapCtrl.forward();
    await _tapCtrl.reverse();
    widget.onTap();
  }

  Future<void> _handleLongPress() async {
    if (!widget.enabled) return;
    HapticFeedback.mediumImpact();
    try {
      await _burstCtrl.forward();
      widget.onLongPress();
      HapticFeedback.lightImpact();
      await _burstCtrl.reverse();
    } catch (_) {
      if (_burstCtrl.isAnimating || _burstCtrl.value > 0) {
        await _burstCtrl.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.compact ? 22.0 : 24.0;
    final enabled = widget.enabled;

    Widget buildButton(double tapS, double burstS, double glow) {
      final scale = tapS * burstS;
      const r = 12.0;
      return Transform.scale(
        scale: scale,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(r),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              width: _size,
              height: _size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(r),
                color: const Color(0xFF141A22).withValues(alpha: 0.95),
                border: Border.all(
                  color: _accent.withValues(
                    alpha: enabled ? 0.35 + glow * 0.2 : 0.12,
                  ),
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  borderRadius: BorderRadius.circular(r),
                  onTap: enabled ? _handleTap : null,
                  onLongPress: enabled ? _handleLongPress : null,
                  splashFactory: InkRipple.splashFactory,
                  splashColor: _accent.withValues(alpha: 0.28),
                  highlightColor: _accent.withValues(alpha: 0.1),
                  child: SizedBox(
                    width: _size,
                    height: _size,
                    child: Center(
                      child: Icon(
                        Icons.close_rounded,
                        size: iconSize + 2,
                        color: _accent.withValues(alpha: enabled ? 0.95 : 0.28),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: 'Delete · long-press to clear all',
      child: AnimatedBuilder(
        animation: Listenable.merge([_tapCtrl, _burstCtrl]),
        builder: (context, child) {
          return buildButton(
            _tapScale.value,
            _burstScale.value,
            _glowT.value,
          );
        },
      ),
    );
  }
}
