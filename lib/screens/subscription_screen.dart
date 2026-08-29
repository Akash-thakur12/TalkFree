import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../config/credits_policy.dart';
import '../config/razorpay_config.dart';
import 'settings_screen.dart';
import '../services/subscription_payment_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import '../widgets/glass_panel.dart';
import '../widgets/premium_activation_overlay.dart';
import 'premium_credits_wallet_screen.dart';

const Color _kPlanAccentDaily = Color(0xFF9D5CFF);
const Color _kPlanAccentMonthly = Color(0xFFFF8A35);

/// Premium subscription plans + Razorpay Checkout (see also `premium_screen.dart`).
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key, this.embedInShell = false});

  /// When true, no [Scaffold]/[AppBar] — shown inside [DashboardScreen] shell.
  final bool embedInShell;

  static const routeName = '/subscription';

  static Route<void> createRoute() {
    return MaterialPageRoute<void>(
      settings: const RouteSettings(name: routeName),
      builder: (_) => const SubscriptionScreen(),
    );
  }

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  late Razorpay _razorpay;
  bool _checkoutOpen = false;

  /// While creating a Razorpay order — only that plan’s CTA shows a spinner.
  String? _busyPlanKey;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _onPaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _onPaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _onExternalWallet);
  }

  @override
  void dispose() {
    _razorpay.clear();
    super.dispose();
  }

  Future<void> _onPaymentSuccess(PaymentSuccessResponse r) async {
    if (!mounted) return;
    setState(() {
      _checkoutOpen = false;
      _busyPlanKey = null;
    });
    if (FirebaseAuth.instance.currentUser == null) {
      _showPaymentFailedDialog('Not signed in. Your payment may still be valid — sign in and contact support.');
      return;
    }
    final plan = _pendingPlanKey;
    if (plan == null) return;
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
      _showPaymentFailedDialog(
        'Missing payment verification data. If you were charged, contact support with your receipt.',
      );
      return;
    }
    try {
      final paidPlan = plan;
      final v = await SubscriptionPaymentService.instance.verifyPayment(
        razorpayPaymentId: paymentId,
        razorpayOrderId: orderId,
        razorpaySignature: signature,
      );
      _pendingPlanKey = null;
      if (!mounted) return;
      if (paidPlan == 'starter_credits') {
        AppSnackBar.show(context,
          SnackBar(
            content: Text(
              v.starterCreditsAdded > 0
                  ? '+${v.starterCreditsAdded} credits added to your wallet.'
                  : 'Starter pack confirmed.',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600).copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 0,
              ),
            ),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
        Navigator.of(context).maybePop();
        return;
      }
      if (v.welcomeBonusCredits > 0 && !v.idempotent) {
        await PremiumActivationOverlay.show(
          context,
          bonusCredits: v.welcomeBonusCredits,
        );
      }
      if (!mounted) return;
      AppSnackBar.show(context,
        SnackBar(
          content: Text(
            'Premium is active — enjoy faster, cheaper calling.',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      Navigator.of(context).maybePop();
    } on SubscriptionPaymentException catch (e) {
      _pendingPlanKey = null;
      if (!mounted) return;
      _showPaymentFailedDialog(
        'Payment could not be verified: ${e.message}',
      );
    } catch (e) {
      _pendingPlanKey = null;
      if (!mounted) return;
      _showPaymentFailedDialog(
        'Payment succeeded but verification failed: $e',
      );
    }
  }

  void _onPaymentError(PaymentFailureResponse r) {
    if (!mounted) return;
    _pendingPlanKey = null;
    setState(() {
      _checkoutOpen = false;
      _busyPlanKey = null;
    });
    final code = r.code;
    if (code == Razorpay.PAYMENT_CANCELLED) {
      _showPaymentFailedDialog('Payment cancelled.');
      return;
    }
    _showPaymentFailedDialog(r.message ?? 'Payment failed. Please try again.');
  }

  void _onExternalWallet(ExternalWalletResponse r) {
    if (!mounted) return;
    AppSnackBar.show(context,
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

  String? _pendingPlanKey;

  Future<void> _startCheckout(_PlanCheckout plan) async {
    if (_checkoutOpen || _busyPlanKey != null) return;

    final key = RazorpayConfig.keyId;
    if (key == null || key.isEmpty) {
      if (!mounted) return;
      AppSnackBar.show(context,
        SnackBar(
          content: Text(
            'Add RAZORPAY_KEY_ID to project root .env (copy .env.example), then flutter run. '
            'Or: flutter run --dart-define=RAZORPAY_KEY_ID=rzp_test_xxx',
            style: GoogleFonts.inter(),
          ),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      AppSnackBar.show(context,
        SnackBar(
          content: Text('Sign in to subscribe.', style: GoogleFonts.inter()),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      return;
    }

    setState(() => _busyPlanKey = plan.planKey);
    _pendingPlanKey = plan.planKey;

    SubscriptionOrderResponse order;
    try {
      order = await SubscriptionPaymentService.instance
          .createSubscriptionOrder(plan.planKey);
    } on SubscriptionPaymentException catch (e) {
      if (!mounted) return;
      _pendingPlanKey = null;
      setState(() => _busyPlanKey = null);
      _showPaymentFailedDialog(
        e.message.isNotEmpty
            ? e.message
            : 'Could not start checkout (HTTP ${e.statusCode}).',
      );
      return;
    } catch (e) {
      if (!mounted) return;
      _pendingPlanKey = null;
      setState(() => _busyPlanKey = null);
      _showPaymentFailedDialog('Could not create order: $e');
      return;
    }

    if (order.keyId != key) {
      if (!mounted) return;
      _pendingPlanKey = null;
      setState(() => _busyPlanKey = null);
      _showPaymentFailedDialog(
        'Razorpay key mismatch: app .env RAZORPAY_KEY_ID must match server RAZORPAY_KEY_ID.',
      );
      return;
    }

    final options = <String, dynamic>{
      'key': order.keyId,
      'order_id': order.orderId,
      'amount': order.amount,
      'currency': order.currency,
      'name': 'TalkFree Pro',
      'description': '${plan.ui.name} — ${plan.ui.periodLabel}',
      'prefill': <String, String>{
        if (user.email != null && user.email!.isNotEmpty) 'email': user.email!,
        if (user.phoneNumber != null && user.phoneNumber!.isNotEmpty)
          'contact': user.phoneNumber!,
      },
      'theme': <String, String>{'color': '#00C853'},
    };

    setState(() {
      _checkoutOpen = true;
      _busyPlanKey = null;
    });
    try {
      _razorpay.open(options);
    } catch (e) {
      _pendingPlanKey = null;
      setState(() => _checkoutOpen = false);
      if (mounted) {
        _showPaymentFailedDialog('Could not open checkout: $e');
      }
    }
  }

  void _showPaymentFailedDialog(String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: (Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Icon(Icons.payments_rounded, color: AppTheme.neonGreen.withValues(alpha: 0.95)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Payment Failed',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          content: Text(
            message,
            style: GoogleFonts.inter(
              fontSize: 14,
              height: 1.45,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
                style: FilledButton.styleFrom(
                backgroundColor: AppTheme.neonGreen,
                foregroundColor: AppColors.darkBackground,
              ),
              child: Text(
                'OK',
                style: GoogleFonts.inter(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final yearly = _planCheckouts.firstWhere((p) => p.planKey == 'yearly');
    final starter = _planCheckouts.firstWhere((p) => p.planKey == 'starter_credits');
    final others = _planCheckouts
        .where((p) => p.planKey != 'yearly' && p.planKey != 'starter_credits')
        .toList(growable: false);

    final canvasColor = widget.embedInShell
        ? const Color(0xFF020A10)
        : AppTheme.darkBg;

    final list = ListView(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 44),
      children: [
        const _GoProHero(),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).push(PremiumCreditsWalletScreen.createRoute());
          },
          icon: Icon(
            Icons.shopping_bag_outlined,
            color: AppColors.primary.withValues(alpha: 0.95),
          ),
          label: Text(
            'Credit packs — ₹49 / ₹99 / ₹199',
            style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textOnDark,
            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.55)),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
          ),
        ),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.12,
              height: 1.35,
              color: AppColors.textMutedOnDark,
            ),
            children: [
              const TextSpan(text: 'Save ~'),
              TextSpan(
                text: '70%',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: AppColors.accentGold,
                ),
              ),
              const TextSpan(text: ' with yearly'),
            ],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        const _ProFeatureGrid(),
        const SizedBox(height: 18),
        Text(
          'Starter pack',
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.35,
            color: AppColors.textDimmed,
          ),
        ),
        const SizedBox(height: 10),
        _PlanGlassCard(
          plan: starter.ui,
          highlight: false,
          accentColor: AppColors.primary,
          ctaLabel: 'BUY CREDITS',
          loading: _busyPlanKey == starter.planKey,
          onTap: (_checkoutOpen || _busyPlanKey != null)
              ? null
              : () => _startCheckout(starter),
        ),
        const SizedBox(height: 22),
        _PlanGlassCard(
          plan: yearly.ui,
          highlight: true,
          ctaLabel: 'BUY YEARLY',
          loading: _busyPlanKey == yearly.planKey,
          onTap: (_checkoutOpen || _busyPlanKey != null)
              ? null
              : () => _startCheckout(yearly),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 14,
              color: Theme.of(context)
                  .colorScheme
                  .onSurfaceVariant
                  .withValues(alpha: 0.65),
            ),
            const SizedBox(width: 6),
            Text(
              'Cancel anytime',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.35,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          'Other plans',
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.35,
            color: AppColors.textDimmed,
          ),
        ),
        const SizedBox(height: 10),
        ...others.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PlanGlassCard(
              plan: p.ui,
              highlight: false,
              accentColor: switch (p.planKey) {
                'daily' => _kPlanAccentDaily,
                'weekly' => AppColors.primary,
                'monthly' => _kPlanAccentMonthly,
                _ => AppColors.primary,
              },
              loading: _busyPlanKey == p.planKey,
              onTap: (_checkoutOpen || _busyPlanKey != null)
                  ? null
                  : () => _startCheckout(p),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'You\'re saving ${CreditsPolicy.creditsSavedPerMinuteVsFree} credits/min with Pro',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          RazorpayConfig.hasKeyId
              ? 'Secure checkout · ${RazorpayConfig.currency}'
              : 'Add RAZORPAY_KEY_ID to enable checkout (${RazorpayConfig.currency}).',
          style: GoogleFonts.inter(
            fontSize: 11,
            height: 1.35,
            color: Theme.of(context)
                .colorScheme
                .onSurfaceVariant
                .withValues(alpha: 0.65),
          ),
        ),
      ],
    );

    final body = ColoredBox(color: canvasColor, child: list);

    if (widget.embedInShell) {
      return body;
    }
    return Scaffold(
      backgroundColor: canvasColor,
      appBar: AppBar(
        title: Text(
          'Go Pro',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w800,
            color: AppColors.accentGold,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Material(
              color: AppColors.cardDark,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  final u = FirebaseAuth.instance.currentUser;
                  if (u == null) return;
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(user: u),
                    ),
                  );
                },
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.cardBorderSubtle),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(
                      Icons.settings_outlined,
                      size: 20,
                      color: AppColors.textMutedOnDark,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: body,
    );
  }
}

class _GoProHero extends StatelessWidget {
  const _GoProHero();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 4),
        Center(
          child: Container(
            width: 88,
            height: 88,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.cardDark,
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.accentGold.withValues(alpha: 0.58),
                width: 1.5,
              ),
            ),
            child: Icon(
              Icons.workspace_premium_rounded,
              color: AppColors.accentGold,
              size: 44,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'Go ',
                style: GoogleFonts.inter(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                  height: 1.05,
                  color: AppColors.textOnDark,
                ),
              ),
              TextSpan(
                text: 'Pro',
                style: GoogleFonts.inter(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                  height: 1.05,
                  color: AppColors.accentGold,
                ),
              ),
            ],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Unlock premium calling experience',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.35,
            color: AppColors.textMutedOnDark,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.flash_on_rounded,
              size: 15,
              color: AppColors.accentGold.withValues(alpha: 0.88),
            ),
            const SizedBox(width: 6),
            Text(
              'Instant activation',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.12,
                color: AppColors.accentGold.withValues(alpha: 0.92),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProFeatureGrid extends StatelessWidget {
  const _ProFeatureGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.42,
      children: [
        const _FeatureMiniCard(
          text: 'Faster calling worldwide',
          icon: Icons.phone_in_talk_rounded,
        ),
        const _FeatureMiniCard(
          text: 'No ads, ever',
          icon: Icons.block_rounded,
        ),
        _FeatureMiniCard(
          text: 'Private US number included',
          leading: Text(
            '🇺🇸',
            style: GoogleFonts.inter(fontSize: 18),
          ),
        ),
        const _FeatureMiniCard(
          text: 'No waiting — SMS & chat',
          icon: Icons.chat_bubble_rounded,
        ),
      ],
    );
  }
}

class _FeatureMiniCard extends StatelessWidget {
  const _FeatureMiniCard({
    required this.text,
    this.icon,
    this.leading,
  }) : assert(icon != null || leading != null);

  final String text;
  final IconData? icon;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const Spacer(),
              if (leading != null)
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary.withValues(alpha: 0.14),
                  ),
                  child: leading,
                )
              else
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary.withValues(alpha: 0.14),
                  ),
                  child: Icon(
                    icon,
                    size: 17,
                    color: AppColors.primary,
                  ),
                ),
            ],
          ),
          const Spacer(),
          Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.3,
              color: AppColors.textOnDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanData {
  const _PlanData({
    required this.name,
    required this.price,
    required this.periodLabel,
    required this.benefits,
  });

  final String name;
  final String price;
  final String periodLabel;
  final List<String> benefits;
}

/// Maps UI plan → Firestore `premium_plan_type` + Razorpay amount (INR paise or USD cents).
class _PlanCheckout {
  const _PlanCheckout({
    required this.planKey,
    required this.ui,
    required this.amountInrPaise,
    required this.amountUsdCents,
  });

  final String planKey;
  final _PlanData ui;
  final int amountInrPaise;
  final int amountUsdCents;

  int amountSmallestUnit(String currency) {
    switch (currency.toUpperCase()) {
      case 'USD':
        return amountUsdCents;
      case 'INR':
      default:
        return amountInrPaise;
    }
  }
}

/// Plan card `price` strings are INR for user-facing copy; checkout amount uses [amountSmallestUnit] for [RazorpayConfig.currency].
const _planCheckouts = <_PlanCheckout>[
  _PlanCheckout(
    planKey: 'starter_credits',
    ui: _PlanData(
      name: 'Starter Pack',
      price: '₹59',
      periodLabel: 'one-time',
      benefits: [
        '${CreditsPolicy.starterPackCredits} credits',
        'Instant calling for ₹59',
        'Call right away',
        'No subscription',
      ],
    ),
    amountInrPaise: 5900,
    amountUsdCents: 99,
  ),
  _PlanCheckout(
    planKey: 'daily',
    ui: _PlanData(
      name: 'Daily',
      price: '₹83',
      periodLabel: 'per day',
      benefits: ['No Ads', 'Bonus Credits', 'Private Number'],
    ),
    amountInrPaise: 8300,
    amountUsdCents: 99,
  ),
  _PlanCheckout(
    planKey: 'weekly',
    ui: _PlanData(
      name: 'Weekly',
      price: '₹415',
      periodLabel: 'per week',
      benefits: ['No Ads', 'Bonus Credits', 'Private Number'],
    ),
    amountInrPaise: 41500,
    amountUsdCents: 499,
  ),
  _PlanCheckout(
    planKey: 'monthly',
    ui: _PlanData(
      name: 'Monthly',
      price: '₹349',
      periodLabel: 'per month',
      benefits: ['No Ads', 'Bonus Credits', 'Private Number'],
    ),
    amountInrPaise: 34900,
    amountUsdCents: 499,
  ),
  _PlanCheckout(
    planKey: 'yearly',
    ui: _PlanData(
      name: 'Yearly',
      price: '₹1149',
      periodLabel: 'per year',
      benefits: ['No Ads', 'Bonus Credits', 'Private Number', 'Best value'],
    ),
    amountInrPaise: 114900,
    amountUsdCents: 12999,
  ),
];

/// Yearly: gold rim + glass; other plans: themed calendar rows (mockup-aligned).
class _PlanGlassCard extends StatelessWidget {
  const _PlanGlassCard({
    required this.plan,
    required this.onTap,
    this.highlight = false,
    this.accentColor,
    this.ctaLabel,
    this.loading = false,
  });

  final _PlanData plan;
  final VoidCallback? onTap;
  final bool highlight;
  /// Daily / weekly / monthly accent (ignored when [highlight] is true).
  final Color? accentColor;
  /// Primary plan CTA (e.g. yearly); defaults to "Buy Now" / "Choose".
  final String? ctaLabel;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (highlight) {
      final inner = GlassPanel(
        borderRadius: 16,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        accentNeon: false,
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
                      Row(
                        children: [
                          Icon(
                            Icons.bolt_rounded,
                            size: 16,
                            color: AppColors.accentGold,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'YEARLY',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                              color: AppColors.accentGold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            plan.price,
                            style: GoogleFonts.poppins(
                              fontWeight: FontWeight.w900,
                              fontSize: 36,
                              letterSpacing: -0.85,
                              height: 1.0,
                              color: AppColors.textOnDark,
                            ),
                          ),
                          Text(
                            ' / year',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.06,
                              color: AppColors.textDimmed,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: loading ? null : onTap,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: AppColors.cardDark,
                    foregroundColor: AppColors.accentGold,
                    side: BorderSide(
                      color: AppColors.accentGold.withValues(alpha: 0.75),
                      width: 1.5,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    minimumSize: const Size(112, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: loading
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: AppColors.accentGold.withValues(
                              alpha: 0.95,
                            ),
                          ),
                        )
                      : Text(
                          ctaLabel ?? 'BUY YEARLY',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                            letterSpacing: 0.4,
                          ),
                        ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 10),
              child: Divider(
                height: 1,
                thickness: 1,
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _YearlyFooterCell(
                    icon: Icons.bolt_rounded,
                    label: 'Instant activation',
                  ),
                ),
                Expanded(
                  child: _YearlyFooterCell(
                    icon: Icons.schedule_rounded,
                    label: 'Limited offer ends soon',
                  ),
                ),
                Expanded(
                  child: _YearlyFooterCell(
                    icon: Icons.groups_rounded,
                    label: '10,000+ users upgraded today',
                  ),
                ),
              ],
            ),
          ],
        ),
      );

      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.accentGold.withValues(alpha: 0.68),
            width: 1.2,
          ),
          boxShadow: AppTheme.fintechCardShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(19),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              inner,
              Positioned(
                right: 10,
                top: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.cardDark,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.accentGold.withValues(alpha: 0.7),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    'BEST VALUE',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.45,
                      color: AppColors.accentGold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final accent = accentColor ?? AppColors.primary;
    final ctaText = plan.name == 'Monthly' ? 'Buy Monthly' : 'Choose';

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.withValues(alpha: 0.16),
            border: Border.all(
              color: accent.withValues(alpha: 0.45),
            ),
          ),
          child: Icon(
            Icons.calendar_today_rounded,
            size: 20,
            color: accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                plan.name,
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  letterSpacing: -0.22,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                plan.periodLabel,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDimmed,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'Instant activation',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.28,
                  color: AppColors.accentGold.withValues(alpha: 0.88),
                ),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              plan.price,
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w900,
                fontSize: 22,
                letterSpacing: -0.5,
                height: 1.0,
                color: AppColors.textOnDark,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: loading ? null : onTap,
              style: OutlinedButton.styleFrom(
                foregroundColor: accent,
                side: BorderSide(
                  color: accent.withValues(alpha: 0.85),
                  width: 1.4,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                minimumSize: const Size(92, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: loading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  : Text(
                      ctaText,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
            ),
          ],
        ),
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.cardDark,
          border: Border.all(
            color: accent.withValues(alpha: 0.22),
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: row,
      ),
    );
  }
}

class _YearlyFooterCell extends StatelessWidget {
  const _YearlyFooterCell({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        children: [
          Icon(
            icon,
            size: 15,
            color: AppColors.textMutedOnDark,
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 3,
            style: GoogleFonts.inter(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              height: 1.25,
              letterSpacing: -0.05,
              color: AppColors.textDimmed,
            ),
          ),
        ],
      ),
    );
  }
}
