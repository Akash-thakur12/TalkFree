import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shown above the context-default rewarded-ad row (dialer → call, number tab → number, etc.).
class RecommendedAdBadge extends StatelessWidget {
  const RecommendedAdBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFFD180).withValues(alpha: 0.98),
            const Color(0xFFFFB74D).withValues(alpha: 1),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF9800).withValues(alpha: 0.38),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('⭐', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 5),
            Text(
              'Recommended',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
                color: const Color(0xFF4E342E),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
