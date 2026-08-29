import 'package:dots_indicator/dots_indicator.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:introduction_screen/introduction_screen.dart';
import 'package:lottie/lottie.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/system_ui.dart';
import '../widgets/glass_panel.dart';

/// Premium navy → near-black (matches dashboard hero gradient spec).
const Color _kBgTop = Color(0xFF0A1628);
const Color _kBgBottom = Color(0xFF050A12);

/// Bundled map (page 1).
const String _lottieMap = 'assets/lottie/global_map.json';

/// First-launch onboarding (before login). Driven by [TalkFreeRoot].
class TalkFreeValueIntroScreen extends StatefulWidget {
  const TalkFreeValueIntroScreen({
    super.key,
    required this.onDone,
  });

  final Future<void> Function() onDone;

  @override
  State<TalkFreeValueIntroScreen> createState() =>
      _TalkFreeValueIntroScreenState();
}

class _TalkFreeValueIntroScreenState extends State<TalkFreeValueIntroScreen> {
  final GlobalKey<IntroductionScreenState> _introKey =
      GlobalKey<IntroductionScreenState>();

  bool _finishing = false;
  int _pageIndex = 0;

  @override
  void initState() {
    super.initState();
    applyTalkFreeDarkNavigationChrome();
  }

  static const int _kPageCount = 3;

  DotsDecorator get _dotsDecorator => DotsDecorator(
        color: Colors.white.withValues(alpha: 0.22),
        activeColor: AppColors.primary.withValues(alpha: 0.95),
        size: const Size(8, 8),
        activeSize: const Size(26, 9),
        activeShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(5),
        ),
        spacing: const EdgeInsets.symmetric(horizontal: 4),
      );

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await widget.onDone();
    if (mounted) setState(() => _finishing = false);
  }

  static PageDecoration _pageDecoration() {
    return PageDecoration(
      pageColor: Colors.transparent,
      titleTextStyle: GoogleFonts.inter(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        height: 1.2,
        letterSpacing: -0.4,
        color: AppColors.textOnDark,
      ),
      bodyTextStyle: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        height: 1.5,
        color: AppColors.textMutedOnDark,
      ),
      titlePadding: const EdgeInsets.only(bottom: 12),
      bodyPadding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      contentMargin: const EdgeInsets.symmetric(horizontal: 20),
      imagePadding: const EdgeInsets.only(bottom: 20),
      imageFlex: 5,
      bodyFlex: 3,
    );
  }

  Widget _lottieHero(
    BuildContext context,
    String asset,
    String semanticLabel, {
    required double height,
  }) {
    final compact = MediaQuery.sizeOf(context).shortestSide < 360;
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: GlassPanel(
          borderRadius: 28,
          padding: EdgeInsets.fromLTRB(12, 12, 12, compact ? 12 : 20),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: Semantics(
              label: semanticLabel,
              child: Lottie.asset(
                asset,
                fit: BoxFit.contain,
                repeat: true,
                frameRate: FrameRate.max,
                errorBuilder: (context, error, _) => Icon(
                  Icons.auto_awesome_rounded,
                  size: 88,
                  color: AppColors.primary.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deco = _pageDecoration();
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final screenH = MediaQuery.sizeOf(context).height;
    final lottieHeight = screenH < 620 ? 160.0 : (screenH < 700 ? 190.0 : 220.0);

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_kBgTop, _kBgBottom],
        ),
      ),
      child: IntroductionScreen(
        key: _introKey,
        /// Inset scaffold so footer clears status bar, notches, and home indicator.
        safeAreaList: const [true, true, true, true],
        globalBackgroundColor: Colors.transparent,
        onChange: (i) => setState(() => _pageIndex = i),
        showSkipButton: true,
        skip: Text(
          'Skip',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
        onSkip: _finish,
        next: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Next',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.95),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.arrow_forward_rounded,
              color: Colors.white.withValues(alpha: 0.95),
              size: 22,
            ),
          ],
        ),
        onDone: _finish,
        overrideDone: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: SizedBox(
            width: double.infinity,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _finishing ? null : _finish,
                borderRadius: BorderRadius.circular(28),
                child: GlassPanel(
                  borderRadius: 28,
                  padding: EdgeInsets.symmetric(
                    vertical: shortest < 360 ? 14 : 16,
                  ),
                  child: Center(
                    child: _finishing
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: Colors.white.withValues(alpha: 0.95),
                            ),
                          )
                        : Text(
                            'Get Started',
                            style: GoogleFonts.inter(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                              color: Colors.white.withValues(alpha: 0.98),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
        baseBtnStyle: TextButton.styleFrom(
          foregroundColor: Colors.white.withValues(alpha: 0.9),
        ),
        dotsDecorator: _dotsDecorator,
        customProgress: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: DotsIndicator(
              dotsCount: _kPageCount,
              position: _pageIndex.toDouble(),
              decorator: _dotsDecorator,
              onTap: (pos) =>
                  _introKey.currentState?.animateScroll(pos.toInt()),
            ),
          ),
        ),
        /// Balanced flex: middle column must stay wide enough for [DotsIndicator]
        /// (1:1:8 squeezed dots on narrow phones and caused horizontal overflow).
        skipOrBackFlex: 2,
        dotsFlex: 3,
        nextFlex: 5,
        controlsPadding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        globalHeader: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'TalkFree',
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: Colors.white.withValues(alpha: 0.95),
                ),
              ),
              Text(
                '${_pageIndex + 1}/3',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
        ),
        pages: [
          PageViewModel(
            title: 'Private US Lines',
            body:
                'Get a dedicated US number for SMS & Calls.',
            image: _lottieHero(
              context,
              _lottieMap,
              'Map and US connectivity',
              height: lottieHeight,
            ),
            decoration: deco,
          ),
          PageViewModel(
            title: 'Crystal Clear Audio',
            body:
                'Experience high-quality VoIP calling worldwide.',
            image: _lottieHero(
              context,
              AppTheme.lottiePhoneCall,
              'High-quality calling',
              height: lottieHeight,
            ),
            decoration: deco,
          ),
          PageViewModel(
            title: 'Zero Ads with Pro',
            body:
                'Upgrade to Pro for an ad-free premium experience.',
            image: _lottieHero(
              context,
              AppTheme.lottieMoney,
              'Premium Pro',
              height: lottieHeight,
            ),
            decoration: deco,
          ),
        ],
      ),
    );
  }
}
