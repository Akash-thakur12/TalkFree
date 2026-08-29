import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/credits_policy.dart';
import '../services/firestore_user_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../utils/app_strings.dart';
import 'subscription_screen.dart';

/// High-end About / App Info — neon green on black; list scroll + light effects for smooth frames.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const double _logoSize = 136;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        backgroundColor: AppTheme.darkBg,
        elevation: 0,
        foregroundColor: Colors.white,
        title: Text(
          'App Info',
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w600,
            fontSize: 18,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: true,
      ),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, pkgSnap) {
          final versionLabel = pkgSnap.data?.version ?? '1.0.0';

          return ListView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: EdgeInsets.fromLTRB(20, 8, 20, 28 + bottom),
            children: [
              const Center(child: _PulseLogoHeader()),
              const SizedBox(height: 22),
              Center(child: _AppNameGlow()),
              const SizedBox(height: 28),
              if (uid == null)
                _PitchProgressCard(
                  adsWatched: 0,
                  maxAds: CreditsPolicy.numberUnlockAdsRequired,
                  onProTap: () => _openPro(context),
                )
              else
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirestoreUserService.watchUserDocument(uid),
                  builder: (context, snap) {
                    final doc = snap.data;
                    final n = FirestoreUserService.numberAdsProgressFromUserData(
                      doc?.data(),
                    );
                    return _PitchProgressCard(
                      adsWatched: n,
                      maxAds: CreditsPolicy.numberUnlockAdsRequired,
                      onProTap: () => _openPro(context),
                    );
                  },
                ),
              const SizedBox(height: 24),
              _StatsRow(version: versionLabel),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  'Made with ❤️ for Privacy',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                    color: AppColors.textMutedOnDark.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openPro(BuildContext context) {
    Navigator.of(context).push<void>(SubscriptionScreen.createRoute());
  }
}

/// Logo (larger tile) + soft neon halo + [TweenAnimationBuilder] pulse (no AnimationController).
class _PulseLogoHeader extends StatefulWidget {
  const _PulseLogoHeader();

  @override
  State<_PulseLogoHeader> createState() => _PulseLogoHeaderState();
}

class _PulseLogoHeaderState extends State<_PulseLogoHeader> {
  bool _grow = true;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey<bool>(_grow),
      tween: Tween<double>(
        begin: _grow ? 1.0 : 1.04,
        end: _grow ? 1.04 : 1.0,
      ),
      duration: const Duration(milliseconds: 1600),
      curve: Curves.easeInOut,
      onEnd: () {
        if (mounted) setState(() => _grow = !_grow);
      },
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: SizedBox(
        width: 168,
        height: 168,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 152,
              height: 152,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: 0.14),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.35),
                    blurRadius: 28,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
            Container(
              width: AboutScreen._logoSize,
              height: AboutScreen._logoSize,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                color: AppColors.splashStage,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.22),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(8),
              child: Image.asset(
                'assets/logo.png',
                fit: BoxFit.contain,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppNameGlow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Text(
      AppStrings.appName,
      textAlign: TextAlign.center,
      style: GoogleFonts.poppins(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.3,
        height: 1.15,
        color: Colors.white,
        shadows: [
          Shadow(
            color: AppColors.primary.withValues(alpha: 0.9),
            blurRadius: 14,
          ),
          Shadow(
            color: AppColors.primary.withValues(alpha: 0.45),
            blurRadius: 28,
          ),
        ],
      ),
    );
  }
}

class _PitchProgressCard extends StatelessWidget {
  const _PitchProgressCard({
    required this.adsWatched,
    required this.maxAds,
    required this.onProTap,
  });

  final int adsWatched;
  final int maxAds;
  final VoidCallback onProTap;

  @override
  Widget build(BuildContext context) {
    final progress = maxAds > 0 ? (adsWatched / maxAds).clamp(0.0, 1.0) : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFF0A1628),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Get a Private US Line for FREE',
            style: GoogleFonts.poppins(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.15,
              color: Colors.white.withValues(alpha: 0.96),
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                valueColor: AlwaysStoppedAnimation<Color>(
                  AppColors.primary.withValues(alpha: 0.95),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$adsWatched / $maxAds ads',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.primary.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              style: GoogleFonts.inter(
                fontSize: 14,
                height: 1.45,
                color: AppColors.textMutedOnDark.withValues(alpha: 0.92),
              ),
              children: [
                TextSpan(
                  text:
                      'Watch $maxAds Ads to unlock your private number or ',
                ),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: GestureDetector(
                    onTap: onProTap,
                    child: Text(
                      'Skip the line with Pro.',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        height: 1.45,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: AppColors.primary.withValues(alpha: 0.6),
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

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatCell(
            icon: Icons.verified_outlined,
            label: 'Version',
            value: version,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCell(
            icon: Icons.lock_outline_rounded,
            label: 'Secure',
            value: 'Encryption',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCell(
            icon: Icons.bolt_rounded,
            label: 'Fast',
            value: 'Servers',
          ),
        ),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF0A1628),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.primary, size: 22),
          const SizedBox(height: 6),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: AppColors.textMutedOnDark,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              height: 1.2,
              color: Colors.white.withValues(alpha: 0.92),
            ),
          ),
        ],
      ),
    );
  }
}
