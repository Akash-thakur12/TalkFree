import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../config/credits_policy.dart';
import '../config/razorpay_config.dart';
import '../services/firestore_user_service.dart';
import '../services/grant_reward_service.dart';
import '../services/subscription_payment_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import '../utils/rewarded_ad_grant_flow.dart';
import '../widgets/cooldown_reward_progress_bar.dart';

/// Paid credit packs + optional rewarded ads (premium: +3 call credits per ad via server).
class PremiumCreditsWalletScreen extends StatefulWidget {
  const PremiumCreditsWalletScreen({super.key});

  static const routeName = '/premium-credits-wallet';

  static Route<void> createRoute() {
    return MaterialPageRoute<void>(
      settings: const RouteSettings(name: routeName),
      builder: (_) => const PremiumCreditsWalletScreen(),
    );
  }

  @override
  State<PremiumCreditsWalletScreen> createState() =>
      _PremiumCreditsWalletScreenState();
}

class _PremiumCreditsWalletScreenState extends State<PremiumCreditsWalletScreen> {
  late Razorpay _razorpay;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userSub;
  DocumentSnapshot<Map<String, dynamic>>? _userSnap;
  Timer? _secondTick;

  bool _checkoutOpen = false;
  String? _busyPackId;
  String? _pendingPlanKey;
  bool _adGrantBusy = false;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _onPaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _onPaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _onExternalWallet);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _userSub = FirestoreUserService.watchUserDocument(uid).listen((d) {
        if (mounted) setState(() => _userSnap = d);
      });
    }
    _secondTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _secondTick?.cancel();
    _userSub?.cancel();
    _razorpay.clear();
    super.dispose();
  }

  Future<void> _onPaymentSuccess(PaymentSuccessResponse r) async {
    if (!mounted) return;
    setState(() {
      _checkoutOpen = false;
      _busyPackId = null;
    });
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _pendingPlanKey = null;
      _showError('Not signed in.');
      return;
    }
    final plan = _pendingPlanKey;
    if (plan == null || !plan.startsWith('credit_pack_')) {
      _pendingPlanKey = null;
      return;
    }
    final paymentId = r.paymentId?.trim();
    final orderId = r.orderId?.trim();
    final signature = r.signature?.trim();
    if (paymentId == null ||
        paymentId.isEmpty ||
        orderId == null ||
        orderId.isEmpty ||
        signature == null ||
        signature.isEmpty) {
      _pendingPlanKey = null;
      _showError('Missing verification data. If charged, contact support with receipt.');
      return;
    }
    try {
      final v = await SubscriptionPaymentService.instance.verifyPayment(
        razorpayPaymentId: paymentId,
        razorpayOrderId: orderId,
        razorpaySignature: signature,
      );
      _pendingPlanKey = null;
      if (!mounted) return;
      if (v.idempotent) {
        AppSnackBar.show(
          context,
          SnackBar(
            content: Text(
              'This payment was already applied.',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600),
            ),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
        return;
      }
      final added = v.creditPackCreditsAdded;
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text(
            added > 0
                ? '+$added credits added to your wallet.'
                : 'Credit pack confirmed.',
            style: GoogleFonts.inter(fontWeight: FontWeight.w800),
          ),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
    } on SubscriptionPaymentException catch (e) {
      _pendingPlanKey = null;
      if (!mounted) return;
      _showError('Verification failed: ${e.message}');
    } catch (e) {
      _pendingPlanKey = null;
      if (!mounted) return;
      _showError('Verification error: $e');
    }
  }

  void _onPaymentError(PaymentFailureResponse r) {
    if (!mounted) return;
    _pendingPlanKey = null;
    setState(() {
      _checkoutOpen = false;
      _busyPackId = null;
    });
    if (r.code == Razorpay.PAYMENT_CANCELLED) {
      _showError('Payment cancelled.');
      return;
    }
    _showError(r.message ?? 'Payment failed.');
  }

  void _onExternalWallet(ExternalWalletResponse r) {
    if (!mounted) return;
    AppSnackBar.show(
      context,
      SnackBar(
        content: Text(
          'Complete payment in ${r.walletName ?? "your wallet"}.',
          style: GoogleFonts.inter(),
        ),
        behavior: SnackBarBehavior.floating,
        margin: AppTheme.snackBarFloatingMargin(context),
        duration: AppTheme.snackBarCalmDuration,
      ),
    );
  }

  void _showError(String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Payment', style: GoogleFonts.inter(fontWeight: FontWeight.w800)),
        content: Text(message, style: GoogleFonts.inter()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _startPackCheckout(CreditPackOffer pack) async {
    if (_checkoutOpen || _busyPackId != null || _adGrantBusy) return;
    final key = RazorpayConfig.keyId;
    if (key == null || key.isEmpty) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text(
            'Add RAZORPAY_KEY_ID to .env or --dart-define.',
            style: GoogleFonts.inter(),
          ),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
        ),
      );
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text('Sign in to buy credits.', style: GoogleFonts.inter()),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
        ),
      );
      return;
    }

    setState(() => _busyPackId = pack.packId);
    _pendingPlanKey = pack.planKey;

    SubscriptionOrderResponse order;
    try {
      order = await SubscriptionPaymentService.instance.createCreditsPackOrder(pack.packId);
    } on SubscriptionPaymentException catch (e) {
      _pendingPlanKey = null;
      if (!mounted) return;
      setState(() => _busyPackId = null);
      _showError(e.message.isNotEmpty ? e.message : 'Could not start checkout.');
      return;
    } catch (e) {
      _pendingPlanKey = null;
      if (!mounted) return;
      setState(() => _busyPackId = null);
      _showError('Could not create order: $e');
      return;
    }

    if (order.keyId != key) {
      _pendingPlanKey = null;
      if (!mounted) return;
      setState(() => _busyPackId = null);
      _showError('Razorpay key mismatch: app key must match server.');
      return;
    }

    final planForVerify = order.planKey ?? pack.planKey;
    _pendingPlanKey = planForVerify;

    final options = <String, dynamic>{
      'key': order.keyId,
      'order_id': order.orderId,
      'amount': order.amount,
      'currency': order.currency,
      'name': 'TalkFree',
      'description': 'Call credits · ${pack.rupeesLabel} → ${pack.credits} credits',
      'prefill': <String, String>{
        if (user.email != null && user.email!.isNotEmpty) 'email': user.email!,
        if (user.phoneNumber != null && user.phoneNumber!.isNotEmpty)
          'contact': user.phoneNumber!,
      },
      'theme': <String, String>{'color': '#00C853'},
    };

    if (!mounted) return;
    setState(() {
      _checkoutOpen = true;
      _busyPackId = null;
    });
    try {
      _razorpay.open(options);
    } catch (e) {
      _pendingPlanKey = null;
      setState(() => _checkoutOpen = false);
      if (mounted) _showError('Could not open checkout: $e');
    }
  }

  Future<void> _onWatchAdPremium() async {
    if (_checkoutOpen || _busyPackId != null || _adGrantBusy) return;
    final snap = _userSnap;
    if (snap == null || !snap.exists) return;
    final ad = FirestoreUserService.adRewardStatusFromSnapshot(snap);
    if (ad.dailyLimitReached) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text(
            'Daily ad limit reached — try again tomorrow.',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
        ),
      );
      return;
    }
    if (ad.cooldownRemaining > 0) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text(
            'Wait ${ad.cooldownRemaining}s for the next ad.',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
        ),
      );
      return;
    }
    setState(() => _adGrantBusy = true);
    try {
      await runRewardedAdGrantFlow(
        context: context,
        isPremium: true,
        purpose: GrantRewardPurpose.call,
      );
    } finally {
      if (mounted) setState(() => _adGrantBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = _userSnap;
    final data = snap?.data();
    final usable =
        snap != null && snap.exists ? FirestoreUserService.computeUsableCredits(data) : 0;
    final isPremium =
        snap != null && snap.exists ? FirestoreUserService.isPremiumFromUserData(data) : false;
    final ad = snap != null && snap.exists
        ? FirestoreUserService.adRewardStatusFromSnapshot(snap)
        : (adsToday: 0, cooldownRemaining: 0, dailyLimitReached: false);

    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        title: Text(
          'Call credits',
          style: GoogleFonts.inter(fontWeight: FontWeight.w800),
        ),
        backgroundColor: AppTheme.darkBg,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Balance: $usable credits',
            style: GoogleFonts.inter(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: AppColors.textOnDark,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Packs are paid via Razorpay. Ads are optional and grant server-side only.',
            style: GoogleFonts.inter(
              fontSize: 13,
              height: 1.35,
              color: AppColors.textMutedOnDark,
            ),
          ),
          const SizedBox(height: 28),
          _sectionTitle('1. Buy credits'),
          const SizedBox(height: 12),
          ...CreditsPolicy.creditPackOffers.map((p) => _PackCard(
                pack: p,
                busy: _busyPackId == p.packId,
                onBuy: () => _startPackCheckout(p),
              )),
          const SizedBox(height: 32),
          _sectionTitle('2. Watch ad (optional)'),
          const SizedBox(height: 10),
          if (!isPremium)
            Text(
              'Rewarded call-credit ads are on Home / Dialer for free accounts. '
              'Upgrade to Pro for optional +${CreditsPolicy.creditsPerRewardedAdForUser(true)} credits per ad here.',
              style: GoogleFonts.inter(
                fontSize: 13,
                height: 1.4,
                color: AppColors.textMutedOnDark,
              ),
            )
          else ...[
            Text(
              'Pro: watch one ad for +${CreditsPolicy.creditsPerRewardedAdForUser(true)} call credits (server). '
              'Separate from packs — no purchase required.',
              style: GoogleFonts.inter(
                fontSize: 13,
                height: 1.4,
                color: AppColors.textMutedOnDark,
              ),
            ),
            const SizedBox(height: 14),
            if (ad.dailyLimitReached)
              Text(
                'Daily ad limit reached.',
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textMutedOnDark,
                ),
              )
            else if (ad.cooldownRemaining > 0) ...[
              Text(
                'Wait ${ad.cooldownRemaining}s',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 8),
              CooldownRewardProgressBar(
                remainingSeconds: ad.cooldownRemaining,
                totalCooldownSeconds:
                    CreditsPolicy.adRewardCooldownSecondsForUser(true),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: (_adGrantBusy ||
                      _checkoutOpen ||
                      _busyPackId != null ||
                      ad.dailyLimitReached ||
                      ad.cooldownRemaining > 0)
                  ? null
                  : _onWatchAdPremium,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimaryButton,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_adGrantBusy) ...[
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                  ] else
                    const Icon(Icons.play_circle_rounded, size: 22),
                  if (!_adGrantBusy) const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      _adGrantBusy
                          ? 'Working…'
                          : 'Watch ad → +${CreditsPolicy.creditsPerRewardedAdForUser(true)} credits',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.2,
        color: AppColors.textOnDark,
      ),
    );
  }
}

class _PackCard extends StatelessWidget {
  const _PackCard({
    required this.pack,
    required this.busy,
    required this.onBuy,
  });

  final CreditPackOffer pack;
  final bool busy;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: busy ? null : onBuy,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${pack.rupeesLabel} · ${pack.credits} credits',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        pack.packId == 'small'
                            ? 'Starter top-up'
                            : pack.packId == 'medium'
                                ? 'Best value'
                                : 'Power bundle',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: AppColors.textMutedOnDark,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.arrow_forward_ios_rounded,
                      size: 16, color: AppColors.primary.withValues(alpha: 0.9)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
