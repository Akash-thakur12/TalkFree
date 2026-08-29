import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Deep charcoal → black gradient plus a faint globe / network watermark.
class PremiumBackdrop extends StatelessWidget {
  const PremiumBackdrop({
    super.key,
    required this.child,
    this.showGlobe = true,
  });

  final Widget child;
  final bool showGlobe;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppTheme.darkBg,
            AppColors.surfaceDark,
            AppColors.darkBackgroundDeep,
          ],
          stops: const [0.0, 0.42, 1.0],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showGlobe)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GlobeWatermarkPainter(),
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

class _GlobeWatermarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * 0.5, size.height * 0.28);
    final r = size.width * 0.55;
    final line = Paint()
      ..color = AppTheme.neonGreen.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var i = 0; i < 6; i++) {
      final ry = r * (0.35 + i * 0.12);
      final rect = Rect.fromCenter(center: c, width: r * 2, height: ry * 2);
      canvas.drawOval(rect, line);
    }

    for (var deg = 0; deg < 180; deg += 36) {
      final a = deg * math.pi / 180;
      final p = Path()
        ..moveTo(c.dx + r * math.cos(a), c.dy + r * 0.2 * math.sin(a))
        ..lineTo(c.dx - r * math.cos(a), c.dy - r * 0.2 * math.sin(a));
      canvas.drawPath(p, line);
    }

    final dots = Paint()
      ..color = AppColors.textOnDark.withValues(alpha: 0.05)
      ..style = PaintingStyle.fill;
    final random = math.Random(42);
    for (var i = 0; i < 48; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height * 0.55;
      canvas.drawCircle(Offset(x, y), 1.2, dots);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
