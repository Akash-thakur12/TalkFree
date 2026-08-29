import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';

/// [AnimatedSwitcher] for rewarded-ad title + subtitle (welcome / streak / normal).
class RewardCtaAnimatedLabel extends StatelessWidget {
  const RewardCtaAnimatedLabel({
    super.key,
    required this.title,
    required this.subtitle,
    this.titleFontSize = 18,
    this.subtitleFontSize = 12,
    this.subtitleLetterSpacing,
    this.gap = 6,
  });

  final String title;
  final String subtitle;
  final double titleFontSize;
  final double subtitleFontSize;
  final double? subtitleLetterSpacing;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 1.015, end: 1.0).animate(
              CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeOutCubic,
              ),
            ),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<String>('$title|$subtitle'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: titleFontSize,
                fontWeight: FontWeight.w900,
                height: 1.22,
                letterSpacing: -0.15,
              ),
            ),
            SizedBox(height: gap),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: subtitleFontSize,
                fontWeight: FontWeight.w600,
                letterSpacing: subtitleLetterSpacing ?? 0.1,
                height: 1.35,
                color: AppColors.onPrimaryButton.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
