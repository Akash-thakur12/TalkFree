import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_colors.dart';
import '../../theme/system_ui.dart';
import '../../utils/app_strings.dart';

/// Transparent mark (no launcher plate) — avoids “black box” on dark splash.
const String _kSplashMarkAsset = 'assets/splash_mark.png';

/// Minimal splash — logo, title, status line (no heavy motion).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.showLoader = true});

  final bool showLoader;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    applyTalkFreeSplashNavigationChrome();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _opacity = CurvedAnimation(parent: _intro, curve: Curves.easeOutCubic);
    _intro.forward();
  }

  @override
  void dispose() {
    applyTalkFreeDarkNavigationChrome();
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final logoSize = (size.shortestSide * 0.34).clamp(140.0, 200.0);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: SafeArea(
        child: FadeTransition(
          opacity: _opacity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: logoSize,
                          height: logoSize,
                          child: ClipOval(
                            child: Image.asset(
                              _kSplashMarkAsset,
                              fit: BoxFit.cover,
                              alignment: Alignment.center,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          AppStrings.appName,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                            height: 1.05,
                            color: AppColors.textOnDark,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          AppStrings.splashTagline,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                            color: AppColors.primary.withValues(alpha: 0.95),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          AppStrings.splashStatus,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            height: 1.45,
                            fontWeight: FontWeight.w400,
                            color: AppColors.textMutedOnDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.showLoader)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 28),
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.primary,
                        backgroundColor: AppColors.primary.withValues(alpha: 0.08),
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
