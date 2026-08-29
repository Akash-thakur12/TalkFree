import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Call bubble + dialpad mark, beige on transparent (login / splash hero).
class TalkFreeLogo extends StatelessWidget {
  const TalkFreeLogo({super.key, this.size = 112});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TalkFreeLogoPainter(color: AppTheme.neonGreen),
        size: Size(size, size),
      ),
    );
  }
}

class _TalkFreeLogoPainter extends CustomPainter {
  _TalkFreeLogoPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.042
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final bubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.06, h * 0.1, w * 0.78, h * 0.58),
      Radius.circular(w * 0.11),
    );
    canvas.drawRRect(bubble, stroke);

    final tail = Path()
      ..moveTo(w * 0.18, h * 0.66)
      ..quadraticBezierTo(w * 0.06, h * 0.78, w * 0.12, h * 0.9)
      ..quadraticBezierTo(w * 0.2, h * 0.82, w * 0.28, h * 0.68)
      ..close();
    canvas.drawPath(tail, stroke);

    final cx = w * 0.45;
    final cy = h * 0.32;
    final gap = w * 0.13;
    final r = w * 0.034;
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        canvas.drawCircle(
          Offset(cx + (col - 1) * gap, cy + (row - 1) * gap),
          r,
          fill,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TalkFreeLogoPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
