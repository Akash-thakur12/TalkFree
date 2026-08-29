import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

const double _kPlanCardRadius = 14;

/// Persisted in SharedPreferences as `talkfree_use_case`.
abstract final class TalkFreeUseCaseKeys {
  TalkFreeUseCaseKeys._();

  static const String international = 'international_calls';
  static const String otpSocial = 'otp_social';
}

/// "Choose Your Plan" — matches premium reference (white selected vs dark card).
class ChoosePlanScreen extends StatefulWidget {
  const ChoosePlanScreen({
    super.key,
    required this.onFinished,
  });

  /// Called with selected use-case key when user taps Continue or closes (close uses default).
  final Future<void> Function(String useCaseKey) onFinished;

  @override
  State<ChoosePlanScreen> createState() => _ChoosePlanScreenState();
}

class _ChoosePlanScreenState extends State<ChoosePlanScreen> {
  int _selected = 0;
  bool _busy = false;

  Future<void> _complete(String key) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onFinished(key);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _PlanBackdrop(),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 4, 12, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Choose Your Plan',
                              style: GoogleFonts.montserrat(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                                color: AppTheme.neonGreen,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'To get the best deal, tell us what you plan to use our app for.',
                              style: GoogleFonts.montserrat(
                                fontSize: 15,
                                height: 1.45,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).colorScheme.onSurface
                                    .withValues(alpha: 0.92),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _busy
                              ? null
                              : () => _complete(
                                    TalkFreeUseCaseKeys.international,
                                  ),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppTheme.neonGreen
                                    .withValues(alpha: 0.55),
                              ),
                            ),
                            child: Icon(
                              Icons.close_rounded,
                              size: 22,
                              color: AppTheme.neonGreen,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Text(
                            'Select One Option',
                            style: GoogleFonts.montserrat(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.neonGreen,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        _PlanOptionCard(
                          selected: _selected == 0,
                          icon: Icons.phone_in_talk_outlined,
                          title: 'International Calls & Texting',
                          subtitle:
                              'Manage calls, send SMS, and MMS all from one app.',
                          onTap: () => setState(() => _selected = 0),
                        ),
                        const SizedBox(height: 14),
                        _PlanOptionCard(
                          selected: _selected == 1,
                          icon: Icons.chat_bubble_outline_rounded,
                          title: 'OTP Verification for Social Apps',
                          subtitle:
                              'SMS Verification for WhatsApp, Telegram and other services.',
                          onTap: () => setState(() => _selected = 1),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _complete(
                                _selected == 0
                                    ? TalkFreeUseCaseKeys.international
                                    : TalkFreeUseCaseKeys.otpSocial,
                              ),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.neonGreen,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            AppTheme.neonGreen.withValues(alpha: 0.45),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(_kPlanCardRadius),
                        ),
                        elevation: 0,
                      ),
                      child: _busy
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
                            )
                          : Text(
                              'Continue',
                              style: GoogleFonts.montserrat(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanOptionCard extends StatelessWidget {
  const _PlanOptionCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = Border.all(
      color: selected
          ? AppTheme.neonGreen.withValues(alpha: 0.85)
          : Colors.transparent,
      width: selected ? 1.2 : 0,
    );

    if (selected) {
      return Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_kPlanCardRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_kPlanCardRadius),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_kPlanCardRadius),
              border: border,
            ),
            child: _PlanCardContent(
              icon: icon,
              title: title,
              subtitle: subtitle,
              titleColor: const Color(0xFF111111),
              subtitleColor: const Color(0xFF6B6B6B),
              iconColor: const Color(0xFF111111),
            ),
          ),
        ),
      );
    }

    return Material(
      color: (Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface).withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(_kPlanCardRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_kPlanCardRadius),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kPlanCardRadius),
            border: Border.all(
              color: const Color(0xFF2A2A2A),
              width: 1,
            ),
          ),
          child: _PlanCardContent(
            icon: icon,
            title: title,
            subtitle: subtitle,
            titleColor: const Color(0xFF8A8A8A),
            subtitleColor: const Color(0xFF5C5C5C),
            iconColor: const Color(0xFF6E6E6E),
          ),
        ),
      ),
    );
  }
}

class _PlanCardContent extends StatelessWidget {
  const _PlanCardContent({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.titleColor,
    required this.subtitleColor,
    required this.iconColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color titleColor;
  final Color subtitleColor;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 36, color: iconColor),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.montserrat(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: GoogleFonts.montserrat(
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: subtitleColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Dark gradient + faint silhouettes (couple on phones).
class _PlanBackdrop extends StatelessWidget {
  const _PlanBackdrop();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppTheme.darkBg,
                AppColors.surfaceDark,
                AppColors.darkBackgroundDeep,
              ],
              stops: const [0.0, 0.4, 1.0],
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _CoupleSilhouettePainter(),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppTheme.darkBg.withValues(alpha: 0.2),
                AppColors.darkBackgroundDeep.withValues(alpha: 0.92),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CoupleSilhouettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.textOnDark.withValues(alpha: 0.045)
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final cy = h * 0.42;

    void person(double cx, bool phoneRaised) {
      final body = Path()
        ..addOval(Rect.fromCircle(center: Offset(cx, cy - h * 0.08), radius: w * 0.06))
        ..addRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx, cy + h * 0.02),
              width: w * 0.14,
              height: h * 0.22,
            ),
            Radius.circular(w * 0.03),
          ),
        );
      canvas.drawPath(body, paint);
      final armY = cy + h * 0.02;
      final phoneRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(
            cx + w * (phoneRaised ? 0.1 : -0.09),
            armY + (phoneRaised ? -h * 0.04 : h * 0.02),
          ),
          width: w * 0.04,
          height: h * 0.07,
        ),
        const Radius.circular(3),
      );
      canvas.drawRRect(phoneRect, paint);
    }

    person(w * 0.38, true);
    person(w * 0.62, false);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
