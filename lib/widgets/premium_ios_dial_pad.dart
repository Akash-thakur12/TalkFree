import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Dark fintech dial shell — keys align to [AppColors.cardDark] family.
const Color premiumDialBackground = AppTheme.darkBg;
const Color premiumDialKeyFill = AppColors.cardDark;
Color get premiumDialCallGreen => AppColors.primary;

TextStyle eliteDialDigitStyle(double fontSize) => GoogleFonts.inter(
      fontSize: fontSize,
      fontWeight: FontWeight.w300,
      color: Colors.white,
      height: 1.0,
      letterSpacing: 0.5,
    );

TextStyle eliteDialLettersStyle(double fontSize) => GoogleFonts.inter(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.15,
      color: Colors.white.withValues(alpha: 0.38),
      height: 1.0,
    );

class PremiumDialKeyData {
  const PremiumDialKeyData(this.digit, this.letters);
  final String digit;
  final String letters;
}

class PremiumIosDialKey extends StatefulWidget {
  const PremiumIosDialKey({
    super.key,
    required this.data,
    required this.onPressed,
    this.onLongPress,
    this.height = 56,
    this.emphasizeBorder = false,
  });

  final PremiumDialKeyData data;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final double height;
  final bool emphasizeBorder;

  @override
  State<PremiumIosDialKey> createState() => _PremiumIosDialKeyState();
}

class _PremiumIosDialKeyState extends State<PremiumIosDialKey>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 105),
  );
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 0.936)
      .animate(
        CurvedAnimation(
          parent: _c,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        ),
      );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _playPressAnimAsync() async {
    await _c.forward();
    if (mounted) await _c.reverse();
  }

  void _playPressAnim() {
    unawaited(_playPressAnimAsync());
  }

  void _tap() {
    HapticFeedback.selectionClick();
    widget.onPressed();
    _playPressAnim();
  }

  void _longPress() {
    if (widget.onLongPress == null) return;
    HapticFeedback.mediumImpact();
    widget.onLongPress!();
    _playPressAnim();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.height * 0.5;
    return ScaleTransition(
      scale: _scale,
      child: RepaintBoundary(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tap,
          onLongPress: widget.onLongPress == null ? null : _longPress,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              final p = CurvedAnimation(
                parent: _c,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeOutCubic,
              ).value;
              return Container(
                width: double.infinity,
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(r),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(
                            const Color(0xFF1A1C24),
                            const Color(0xFF22252E),
                            Curves.easeOutCubic.transform(p),
                          ) ??
                          const Color(0xFF1D1F27),
                      const Color(0xFF12141C),
                      Color.lerp(
                            const Color(0xFF0E1016),
                            const Color(0xFF14161E),
                            Curves.easeOutCubic.transform(p),
                          ) ??
                          const Color(0xFF0E1016),
                    ],
                    stops: const [0.0, 0.48, 1.0],
                  ),
                  border: Border.all(
                    color: widget.emphasizeBorder
                        ? AppColors.freeHomeNeon.withValues(alpha: 0.75)
                        : Color.lerp(
                            AppColors.cardBorderSubtle,
                            Colors.white.withValues(alpha: 0.11),
                            p,
                          )!,
                    width: widget.emphasizeBorder ? 1.6 : 1.0,
                  ),
                  boxShadow: [
                    if (widget.emphasizeBorder) ...[
                      BoxShadow(
                        color: AppColors.freeHomeNeon.withValues(alpha: 0.28),
                        blurRadius: 12,
                        spreadRadius: 0,
                      ),
                    ],
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.55),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                      spreadRadius: -2,
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(r),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Align(
                        alignment: Alignment.topCenter,
                        child: FractionallySizedBox(
                          heightFactor: 0.5,
                          widthFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white
                                      .withValues(alpha: 0.04 + p * 0.03),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.13),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.data.digit,
                              style: eliteDialDigitStyle(
                                (widget.height * 0.48).clamp(22.0, 30.0),
                              ),
                            ),
                            if (widget.data.letters.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.data.letters,
                                style: eliteDialLettersStyle(
                                  (widget.height * 0.17).clamp(7.0, 9.0),
                                ),
                              ),
                            ] else
                              SizedBox(
                                height:
                                    (widget.height * 0.2).clamp(7.0, 11.0),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class PremiumIosDialPad extends StatelessWidget {
  const PremiumIosDialPad({
    super.key,
    required this.onDigit,
    this.horizontalPadding = 20,
    this.gap = 14,
    this.keyHeight = 56,
    this.emphasisDigit,
  });

  final ValueChanged<String> onDigit;
  final double horizontalPadding;
  final double gap;
  final double keyHeight;
  /// Optional: e.g. '0' for neon ring on free-dialer mockup.
  final String? emphasisDigit;

  static const List<List<PremiumDialKeyData>> _rows = [
    [
      PremiumDialKeyData('1', ''),
      PremiumDialKeyData('2', 'ABC'),
      PremiumDialKeyData('3', 'DEF'),
    ],
    [
      PremiumDialKeyData('4', 'GHI'),
      PremiumDialKeyData('5', 'JKL'),
      PremiumDialKeyData('6', 'MNO'),
    ],
    [
      PremiumDialKeyData('7', 'PQRS'),
      PremiumDialKeyData('8', 'TUV'),
      PremiumDialKeyData('9', 'WXYZ'),
    ],
    [
      PremiumDialKeyData('*', ''),
      PremiumDialKeyData('0', '+'),
      PremiumDialKeyData('#', ''),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final innerW = constraints.maxWidth - horizontalPadding * 2;
        final keyW = (innerW - gap * 2) / 3;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var ri = 0; ri < _rows.length; ri++) ...[
                if (ri > 0) SizedBox(height: gap),
                Row(
                  children: [
                    for (var ci = 0; ci < 3; ci++) ...[
                      if (ci > 0) SizedBox(width: gap),
                      SizedBox(
                        width: keyW,
                        height: keyHeight,
                        child: PremiumIosDialKey(
                          height: keyHeight,
                          data: _rows[ri][ci],
                          emphasizeBorder:
                              emphasisDigit == _rows[ri][ci].digit,
                          onPressed: () => onDigit(_rows[ri][ci].digit),
                          onLongPress: _rows[ri][ci].digit == '0'
                              ? () => onDigit('+')
                              : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class PremiumIosCallButton extends StatefulWidget {
  const PremiumIosCallButton({
    super.key,
    required this.onPressed,
    this.busy = false,
    this.horizontalMargin = 24,
    this.diameter = 94,
  });

  final VoidCallback? onPressed;
  final bool busy;
  final double horizontalMargin;
  final double diameter;

  @override
  State<PremiumIosCallButton> createState() => _PremiumIosCallButtonState();
}

class _PremiumIosCallButtonState extends State<PremiumIosCallButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 105),
  );
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 0.956)
      .animate(
        CurvedAnimation(
          parent: _c,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        ),
      );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _tap() async {
    if (widget.busy || widget.onPressed == null) return;
    HapticFeedback.mediumImpact();
    await _c.forward();
    await _c.reverse();
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.busy && widget.onPressed != null;
    final diameter = widget.diameter;
    final iconSize = (diameter * (40 / 94)).clamp(28.0, 40.0);
    final topSheenH = (diameter * (34 / 94)).clamp(24.0, 34.0);
    final busySize = (diameter * (28 / 94)).clamp(22.0, 28.0);
    final outerShadow = BoxDecoration(
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: premiumDialCallGreen.withValues(alpha: 0.14),
          blurRadius: 18,
          spreadRadius: -2,
          offset: const Offset(0, 7),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 22,
          spreadRadius: -4,
          offset: const Offset(0, 12),
        ),
      ],
    );

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.horizontalMargin),
        child: ScaleTransition(
          scale: _scale,
          child: Material(
            color: Colors.transparent,
            elevation: 0,
            shadowColor: Colors.transparent,
            child: InkWell(
              onTap: enabled ? _tap : null,
              customBorder: const CircleBorder(),
              splashColor: Colors.white.withValues(alpha: 0.18),
              highlightColor: Colors.white.withValues(alpha: 0.07),
              child: Container(
                width: diameter,
                height: diameter,
                decoration: outerShadow,
                child: ClipOval(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color.lerp(
                                    premiumDialCallGreen,
                                    Colors.white,
                                    0.06,
                                  ) ??
                                  premiumDialCallGreen,
                              premiumDialCallGreen,
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: topSheenH,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withValues(alpha: 0.065),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Material(
                        color: Colors.transparent,
                        child: Center(
                          child: widget.busy
                              ? SizedBox(
                                  width: busySize,
                                  height: busySize,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  Icons.call_rounded,
                                  color: Colors.white.withValues(alpha: 0.98),
                                  size: iconSize,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
