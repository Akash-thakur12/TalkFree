import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';

/// Short-lived monetization visuals: floating +N and ad-reward fanfare (no new packages).
abstract final class EngagementOverlays {
  EngagementOverlays._();

  /// Top-right style float for credit deltas (optional reuse).
  static void showFloatingCreditDelta(
    BuildContext context, {
    required int delta,
    Duration hold = const Duration(milliseconds: 2200),
  }) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _FloatingDeltaLayer(
        delta: delta,
        onDone: () {
          entry.remove();
        },
        hold: hold,
      ),
    );
    overlay.insert(entry);
  }

  /// Center burst + confetti-ish dots after a rewarded ad.
  static void showAdRewardFanfare(
    BuildContext context, {
    required int creditsAdded,
    int streakBonus = 0,
    int streakDays = 0,
    bool welcomeFirstAd = false,
    bool isPremium = false,
  }) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _AdFanfareLayer(
        creditsAdded: creditsAdded,
        streakBonus: streakBonus,
        streakDays: streakDays,
        welcomeFirstAd: welcomeFirstAd,
        isPremium: isPremium,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  /// Short center “toast” after a purpose reward (number / OTP / small call nudges).
  static void showRewardMicroToast(
    BuildContext context, {
    required String headline,
    String? subline,
    Duration hold = const Duration(milliseconds: 1650),
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _RewardMicroToastLayer(
        headline: headline,
        subline: subline,
        hold: hold,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }
}

class _RewardMicroToastLayer extends StatefulWidget {
  const _RewardMicroToastLayer({
    required this.headline,
    required this.subline,
    required this.hold,
    required this.onDone,
  });

  final String headline;
  final String? subline;
  final Duration hold;
  final VoidCallback onDone;

  @override
  State<_RewardMicroToastLayer> createState() => _RewardMicroToastLayerState();
}

class _RewardMicroToastLayerState extends State<_RewardMicroToastLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    HapticFeedback.lightImpact();
    _c.forward();
    Future<void>.delayed(widget.hold, () async {
      if (!mounted) return;
      await _c.reverse();
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Material(
        color: Colors.transparent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.14),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final t = _curve.value.clamp(0.0, 1.0);
                return Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.88 + 0.12 * t,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 28),
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: AppColors.cardDark,
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.45),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.22),
                              blurRadius: 22,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.headline,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.35,
                                color: Colors.white,
                                height: 1.15,
                              ),
                            ),
                            if (widget.subline != null &&
                                widget.subline!.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                widget.subline!,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                  color: Colors.white.withValues(alpha: 0.78),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FloatingDeltaLayer extends StatefulWidget {
  const _FloatingDeltaLayer({
    required this.delta,
    required this.onDone,
    required this.hold,
  });

  final int delta;
  final VoidCallback onDone;
  final Duration hold;

  @override
  State<_FloatingDeltaLayer> createState() => _FloatingDeltaLayerState();
}

class _FloatingDeltaLayerState extends State<_FloatingDeltaLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _y = Tween<double>(begin: 12, end: 0).animate(
    CurvedAnimation(parent: _c, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _o = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.0, 0.45, curve: Curves.easeIn),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
    Future<void>.delayed(widget.hold, () {
      if (!mounted) return;
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + 56;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: top,
          right: 20,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                return Transform.translate(
                  offset: Offset(0, _y.value),
                  child: Opacity(
                    opacity: _o.value.clamp(0.0, 1.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: AppColors.primary.withValues(alpha: 0.22),
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.55),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.35),
                            blurRadius: 18,
                            spreadRadius: 0,
                          ),
                        ],
                      ),
                      child: Text(
                        '+${widget.delta}',
                        style: GoogleFonts.poppins(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _AdFanfareLayer extends StatefulWidget {
  const _AdFanfareLayer({
    required this.creditsAdded,
    required this.streakBonus,
    required this.streakDays,
    required this.welcomeFirstAd,
    this.isPremium = false,
    required this.onDone,
  });

  final int creditsAdded;
  final int streakBonus;
  final int streakDays;
  final bool welcomeFirstAd;
  final bool isPremium;
  final VoidCallback onDone;

  @override
  State<_AdFanfareLayer> createState() => _AdFanfareLayerState();
}

class _AdFanfareLayerState extends State<_AdFanfareLayer>
    with SingleTickerProviderStateMixin {
  /// Card scale + credit “pop” + streak stagger (~200ms) + Continue scale-in.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 880),
  );
  late final Animation<double> _cardScale;
  late final Animation<double> _creditPop;
  late final Animation<double> _streakReveal;
  late final Animation<double> _continuePop;
  /// ~250ms after start — does not change other curve timings.
  late final Animation<double> _welcomeHintOpacity;

  @override
  void initState() {
    super.initState();
    _cardScale = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(
        parent: _c,
        curve: const Interval(0.0, 0.40, curve: Curves.easeOutCubic),
      ),
    );
    _creditPop = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.08)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 28,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.08, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 22,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 50,
      ),
    ]).animate(_c);
    _streakReveal = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.227, 1.0, curve: Curves.easeOut),
    );
    _continuePop = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(
        parent: _c,
        curve: const Interval(0.40, 1.0, curve: Curves.easeOutCubic),
      ),
    );
    _welcomeHintOpacity = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.284, 1.0, curve: Curves.easeOut),
    );
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _dismiss() => widget.onDone();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final rnd = math.Random(42);
    const n = 16;
    final particles = List.generate(n, (i) {
      final ang = rnd.nextDouble() * math.pi * 2;
      final dist = 36.0 + rnd.nextDouble() * 118;
      return (dx: math.cos(ang) * dist, dy: math.sin(ang) * dist, c: i);
    });

    final streakLine = widget.streakBonus > 0 && widget.streakDays > 0
        ? '🔥 Streak Day ${widget.streakDays} → +${widget.streakBonus} BONUS'
        : (widget.streakDays > 0
            ? '🔥 Streak Day ${widget.streakDays} — keep going!'
            : '🔥 Start your streak today');
    final bonusLine = widget.streakBonus > 0
        ? 'Bonus credits added to your balance.'
        : 'Next milestone unlocks more bonus credits.';

    return Material(
      color: Colors.transparent,
      child: SizedBox.expand(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _dismiss,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                  ),
                ),
              ),
            ),
            Center(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  return Transform.scale(
                    scale: _cardScale.value,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 28),
                      padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: AppColors.cardDark,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 24,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.welcomeFirstAd) ...[
                            Text(
                              '🎉 Welcome!',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          Transform.scale(
                            alignment: Alignment.center,
                            scale: _creditPop.value,
                            child: Text(
                              widget.welcomeFirstAd && !widget.isPremium
                                  ? '+${widget.creditsAdded} FREE Credits'
                                  : '+${widget.creditsAdded} Credits 🎉',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                                color: AppColors.primary,
                                letterSpacing: -0.8,
                                height: 1.05,
                              ),
                            ),
                          ),
                          Opacity(
                            opacity: _streakReveal.value,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(height: 12),
                                Text(
                                  streakLine,
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.inter(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white.withValues(alpha: 0.98),
                                    height: 1.25,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  bonusLine,
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (widget.welcomeFirstAd)
                            Opacity(
                              opacity: _welcomeHintOpacity.value,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Text(
                                  'Keep going to unlock bigger bonuses 🔥',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    height: 1.3,
                                    color:
                                        Colors.white.withValues(alpha: 0.72),
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 18),
                          Transform.scale(
                            alignment: Alignment.center,
                            scale: _continuePop.value,
                            child: SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _dismiss,
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: AppColors.onPrimaryButton,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  elevation: 0,
                                ),
                                child: Text(
                                  'Continue',
                                  style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            ...particles.map((p) {
              return Positioned(
                left: size.width / 2 +
                    p.dx * _c.value -
                    4 +
                    (p.c % 3) * 2.0 * (1 - _c.value),
                top: size.height / 2 + p.dy * _c.value - 4,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (1.0 - _c.value).clamp(0.0, 1.0),
                    child: Container(
                      width: 5 + (p.c % 4).toDouble(),
                      height: 5 + (p.c % 3).toDouble(),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: [
                          AppColors.primary,
                          AppColors.primary,
                          Colors.amber.shade200,
                        ][p.c % 3].withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
