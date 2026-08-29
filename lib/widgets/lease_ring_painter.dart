import 'dart:math' show pi;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Neon green when ≥7d left, electric blue when 24h–7d, red when &lt;24h or expired.
Color leaseRingForegroundColor(DateTime now, DateTime? expiry) {
  if (expiry == null) return const Color(0xFF00C8FF);
  final left = expiry.difference(now);
  if (left.inSeconds <= 0) return const Color(0xFFFF3838);
  if (left.inHours < 24) return const Color(0xFFFF3B3B);
  if (left.inDays >= 7) return AppTheme.neonGreen;
  return const Color(0xFF00B4FF);
}

/// Circular arc that depletes as [progress] goes from 1 → 0 toward expiry.
class LeaseRingPainter extends CustomPainter {
  LeaseRingPainter({
    required this.progress,
    required this.trackColor,
    required this.foregroundColor,
    this.strokeWidth = 5,
  });

  final double progress;
  final Color trackColor;
  final Color foregroundColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2 - 6;
    final bg = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final fg = Paint()
      ..color = foregroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, r, bg);
    final sweep = 2 * pi * progress.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -pi / 2,
      sweep,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant LeaseRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.foregroundColor != foregroundColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
