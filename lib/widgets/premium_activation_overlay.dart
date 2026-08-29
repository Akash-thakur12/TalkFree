import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';

/// Full-screen celebration after premium purchase (auto-dismiss ~2s).
class PremiumActivationOverlay extends StatefulWidget {
  const PremiumActivationOverlay({
    super.key,
    required this.bonusCredits,
    this.onDismiss,
  });

  final int bonusCredits;
  final VoidCallback? onDismiss;

  static Future<void> show(
    BuildContext context, {
    required int bonusCredits,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'premium',
      barrierColor: Colors.black.withValues(alpha: 0.72),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return PremiumActivationOverlay(
          bonusCredits: bonusCredits,
          onDismiss: () => Navigator.of(ctx).pop(),
        );
      },
      transitionBuilder: (context, anim, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<PremiumActivationOverlay> createState() =>
      _PremiumActivationOverlayState();
}

class _PremiumActivationOverlayState extends State<PremiumActivationOverlay> {
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      widget.onDismiss?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 28, 22, 26),
            decoration: BoxDecoration(
              color: AppColors.cardDark,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: AppColors.accentGold.withValues(alpha: 0.45),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 28,
                  offset: Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "You're now Premium 👑",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '+${widget.bonusCredits} credits added',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accentGold,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '⚡ Faster calling unlocked',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
