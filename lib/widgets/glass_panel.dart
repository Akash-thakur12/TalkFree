import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Frosted glass: blur + translucent fill + soft border (premium fintech shell).
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = 18,
    this.padding,
    /// Slightly stronger primary-tinted rim (optional accents).
    this.accentNeon = false,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool accentNeon;

  @override
  Widget build(BuildContext context) {
    final borderColor = accentNeon
        ? AppColors.primary.withValues(alpha: 0.22)
        : AppColors.cardBorderSubtle;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: AppTheme.fintechCardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF161820),
                  AppColors.cardDark.withValues(alpha: 0.99),
                  AppColors.darkBackgroundDeep.withValues(alpha: 0.97),
                ],
                stops: const [0.0, 0.52, 1.0],
              ),
              border: Border.all(color: borderColor, width: 1),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
