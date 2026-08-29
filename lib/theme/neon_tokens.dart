import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Premium fintech + gaming: soft neon glows and glass radii (TalkFree shell).
abstract final class NeonTokens {
  NeonTokens._();

  static const double radiusCard = 20;
  static const double radiusHero = 24;

  /// Primary neon — use behind glass cards & CTAs.
  /// Soft glow for primary CTAs only (avoid stacking on cards).
  static List<BoxShadow> glowPrimary([double intensity = 1]) {
    final a = 0.14 * intensity;
    return [
      BoxShadow(
        color: AppColors.primary.withValues(alpha: a),
        blurRadius: 18,
        spreadRadius: -2,
        offset: const Offset(0, 8),
      ),
    ];
  }

  static List<BoxShadow> glowSubtleWhite() => [
        BoxShadow(
          color: Colors.white.withValues(alpha: 0.06),
          blurRadius: 20,
          spreadRadius: -2,
          offset: const Offset(0, 8),
        ),
      ];

  /// Radial vignette for scaffold backgrounds.
  static BoxDecoration scaffoldAmbient() {
    return BoxDecoration(
      gradient: RadialGradient(
        center: const Alignment(0, -0.85),
        radius: 1.15,
        colors: [
          AppColors.primary.withValues(alpha: 0.025),
          Colors.transparent,
        ],
        stops: const [0.0, 0.55],
      ),
    );
  }
}
