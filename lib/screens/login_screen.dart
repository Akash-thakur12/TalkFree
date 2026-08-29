import 'dart:math' as math;
import 'dart:ui';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lottie/lottie.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth_service.dart';
import '../config/legal_urls.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/system_ui.dart';
import '../utils/app_snackbar.dart';
import '../utils/app_strings.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _LoginPending { none, google, guest }

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  _LoginPending _pending = _LoginPending.none;

  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 28),
  )..repeat();

  late final AnimationController _lines = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  )..repeat();

  late final AnimationController _textStagger = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    applyTalkFreeDarkNavigationChrome();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textStagger.forward();
    });
  }

  @override
  void dispose() {
    _drift.dispose();
    _lines.dispose();
    _textStagger.dispose();
    super.dispose();
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _onGoogleSignIn() async {
    if (_pending != _LoginPending.none) return;
    setState(() => _pending = _LoginPending.google);
    try {
      await AuthService().signInWithGoogle();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final msg = e.code == 'credential-already-in-use'
          ? 'This Google account is already registered. Sign out, then use Sign in with Google, or pick another Google account.'
          : 'Sign-in failed: ${e.message ?? e.code}';
      AppSnackBar.show(
        context,
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(
          context,
          SnackBar(
            content: Text('Sign-in failed: $e'),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = _LoginPending.none);
    }
  }

  Future<void> _continueWithoutSignIn() async {
    if (_pending != _LoginPending.none) return;
    setState(() => _pending = _LoginPending.guest);
    try {
      await AuthService().signInAnonymously();
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        AppSnackBar.show(
          context,
          SnackBar(
            content: Text(
              e.message?.contains('administrator') == true
                  ? 'Enable Anonymous sign-in in Firebase Console.'
                  : 'Guest sign-in failed: ${e.message ?? e.code}',
            ),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(
          context,
          SnackBar(
            content: Text('Guest sign-in failed: $e'),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = _LoginPending.none);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _drift,
              builder: (context, _) {
                final t = _drift.value * math.pi * 2;
                return Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(math.cos(t) * 0.45, math.sin(t) * 0.35),
                      end: Alignment(-math.cos(t * 0.9) * 0.4, 1.0),
                      colors: [
                        AppTheme.darkBg,
                        const Color(0xFF061238),
                        const Color(0xFF040A1A),
                        const Color(0xFF020A14),
                      ],
                      stops: const [0.0, 0.35, 0.72, 1.0],
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _drift,
              builder: (context, _) {
                final t = _drift.value * math.pi * 2;
                return Transform.translate(
                  offset: Offset(math.sin(t) * 14, math.cos(t * 0.85) * 10),
                  child: Opacity(
                    opacity: 0.42,
                    child: Lottie.asset(
                      'assets/lottie/global_map.json',
                      fit: BoxFit.cover,
                      repeat: true,
                      frameRate: FrameRate.max,
                      errorBuilder: (context, error, _) =>
                          const SizedBox.expand(),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _lines,
              builder: (context, _) {
                return CustomPaint(
                  painter: _LoginNeonConnectionsPainter(
                    progress: _lines.value,
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 32),
                        _LoginGlassCard(
                          pending: _pending,
                          textStagger: _textStagger,
                          onGoogle: _onGoogleSignIn,
                          onAnonymous: _continueWithoutSignIn,
                          onOpenTerms: () => _openUrl(LegalUrls.termsOfUse),
                          onOpenPrivacy: () => _openUrl(LegalUrls.privacyPolicy),
                        ),
                        const SizedBox(height: 28),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginGlassCard extends StatelessWidget {
  const _LoginGlassCard({
    required this.pending,
    required this.textStagger,
    required this.onGoogle,
    required this.onAnonymous,
    required this.onOpenTerms,
    required this.onOpenPrivacy,
  });

  final _LoginPending pending;
  final Animation<double> textStagger;
  final VoidCallback onGoogle;
  final VoidCallback onAnonymous;
  final VoidCallback onOpenTerms;
  final VoidCallback onOpenPrivacy;

  static const _headlines = [
    AppStrings.appName,
    AppStrings.splashTagline,
  ];

  @override
  Widget build(BuildContext context) {
    const radius = 28.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: AppColors.splashAccent.withValues(alpha: 0.14),
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.1),
                AppColors.splashAccent.withValues(alpha: 0.04),
                Colors.white.withValues(alpha: 0.05),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.splashAccent.withValues(alpha: 0.12),
                blurRadius: 28,
                spreadRadius: -4,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 28,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: SizedBox(
                  width: 144,
                  height: 144,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  AppColors.primary.withValues(alpha: 0.28),
                                  AppColors.primary.withValues(alpha: 0.05),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.4, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: ClipOval(
                          child: SizedBox(
                            width: 136,
                            height: 136,
                            child: Image.asset(
                              'assets/splash_mark.png',
                              fit: BoxFit.cover,
                              alignment: Alignment.center,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              for (var i = 0; i < _headlines.length; i++)
                _StaggeredLine(
                  controller: textStagger,
                  index: i,
                  lineCount: _headlines.length,
                  child: Text(
                    _headlines[i],
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: i == 0 ? 26 : 15,
                      fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                      height: 1.35,
                      color: i == 0
                          ? Colors.white.withValues(alpha: 0.96)
                          : AppColors.textMutedOnDark.withValues(alpha: 0.92),
                    ),
                  ),
                ),
              const SizedBox(height: 28),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: pending != _LoginPending.none ? null : onGoogle,
                  borderRadius: BorderRadius.circular(18),
                  splashColor: Colors.white.withValues(alpha: 0.15),
                  splashFactory: InkRipple.splashFactory,
                  child: Ink(
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: AppColors.splashAccent.withValues(alpha: 0.16),
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withValues(alpha: 0.14),
                          AppColors.splashAccent.withValues(alpha: 0.08),
                          Colors.white.withValues(alpha: 0.06),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.splashAccent.withValues(alpha: 0.1),
                          blurRadius: 18,
                          spreadRadius: -2,
                        ),
                      ],
                    ),
                    child: Center(
                      child: pending == _LoginPending.google
                          ? SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: AppColors.splashAccent.withValues(alpha: 0.95),
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.g_mobiledata_rounded,
                                  size: 32,
                                  color: Colors.white.withValues(alpha: 0.95),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Continue with Google',
                                  style: GoogleFonts.inter(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                    color: Colors.white.withValues(alpha: 0.95),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: pending != _LoginPending.none ? null : onAnonymous,
                  borderRadius: BorderRadius.circular(18),
                  splashColor: AppColors.splashAccent.withValues(alpha: 0.12),
                  splashFactory: InkRipple.splashFactory,
                  child: Ink(
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: AppColors.splashAccent.withValues(alpha: 0.14),
                      ),
                      color: Colors.white.withValues(alpha: 0.04),
                    ),
                    child: Center(
                      child: pending == _LoginPending.guest
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: AppColors.splashAccent.withValues(alpha: 0.9),
                              ),
                            )
                          : Text(
                              'Continue without signing in',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.15,
                                color: Colors.white.withValues(alpha: 0.88),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'By continuing, you agree to our',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  height: 1.4,
                  color: AppColors.textMutedOnDark,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: onOpenTerms,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Terms',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.splashAccent.withValues(alpha: 0.95),
                        decoration: TextDecoration.underline,
                        decorationColor: AppColors.splashAccent.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  Text(
                    '&',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppColors.textMutedOnDark,
                    ),
                  ),
                  TextButton(
                    onPressed: onOpenPrivacy,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Privacy',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.splashAccent.withValues(alpha: 0.95),
                        decoration: TextDecoration.underline,
                        decorationColor: AppColors.splashAccent.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StaggeredLine extends StatelessWidget {
  const _StaggeredLine({
    required this.controller,
    required this.index,
    required this.lineCount,
    required this.child,
  });

  final Animation<double> controller;
  final int index;
  final int lineCount;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = index / (lineCount + 1);
    final end = ((index + 1) / (lineCount + 1)).clamp(0.05, 1.0);
    final anim = CurvedAnimation(
      parent: controller,
      curve: Interval(
        start,
        end,
        curve: Curves.easeOutCubic,
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: index == lineCount - 1 ? 0 : 10),
      child: AnimatedBuilder(
        animation: anim,
        builder: (context, _) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.2),
              end: Offset.zero,
            ).animate(anim),
            child: FadeTransition(
              opacity: anim,
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// Neon “call paths” over the map — subtle, slow pulse.
class _LoginNeonConnectionsPainter extends CustomPainter {
  _LoginNeonConnectionsPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paths = <Path>[
      Path()
        ..moveTo(w * 0.08, h * 0.35)
        ..quadraticBezierTo(w * 0.42, h * 0.12, w * 0.88, h * 0.28),
      Path()
        ..moveTo(w * 0.12, h * 0.62)
        ..quadraticBezierTo(w * 0.48, h * 0.45, w * 0.9, h * 0.55),
      Path()
        ..moveTo(w * 0.18, h * 0.82)
        ..quadraticBezierTo(w * 0.52, h * 0.68, w * 0.86, h * 0.78),
      Path()
        ..moveTo(w * 0.05, h * 0.48)
        ..quadraticBezierTo(w * 0.38, h * 0.22, w * 0.72, h * 0.42),
    ];

    for (var i = 0; i < paths.length; i++) {
      final phase = (progress + i * 0.22) % 1.0;
      final a = 0.08 + 0.12 * (1 - phase);
      final paint = Paint()
        ..color = AppColors.splashAccent.withValues(alpha: a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1 + phase * 0.4
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(paths[i], paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LoginNeonConnectionsPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
