import 'package:flutter/material.dart';

import '../config/credits_policy.dart';
import '../theme/app_colors.dart';

/// Thin track (3px) showing linear progress toward the next reward window.
class CooldownRewardProgressBar extends StatelessWidget {
  const CooldownRewardProgressBar({
    super.key,
    required this.remainingSeconds,
    this.totalCooldownSeconds,
  });

  final int remainingSeconds;

  /// Full cooldown length for this tier (defaults to free-tier policy).
  final int? totalCooldownSeconds;

  @override
  Widget build(BuildContext context) {
    final t = totalCooldownSeconds ?? CreditsPolicy.adRewardCooldownSeconds;
    final progress =
        t <= 0 ? 0.0 : ((t - remainingSeconds) / t).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fillW = constraints.maxWidth * progress;
        return ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Container(
                height: 5,
                width: double.infinity,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                height: 5,
                width: fillW,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primary.withValues(alpha: 0.72),
                      AppColors.primary,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
