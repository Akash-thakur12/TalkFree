import 'package:flutter/material.dart';

/// Very subtle breathing scale — primary CTAs only; disable while loading.
class SoftPulse extends StatefulWidget {
  const SoftPulse({
    super.key,
    required this.child,
    this.enabled = true,
    /// Stronger pulse when the user’s last grant purpose matches this screen’s default (repeat habit).
    this.pulseBoost = false,
  });

  final Widget child;
  final bool enabled;
  final bool pulseBoost;

  @override
  State<SoftPulse> createState() => _SoftPulseState();
}

class _SoftPulseState extends State<SoftPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant SoftPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      _c.repeat(reverse: true);
    } else if (!widget.enabled && oldWidget.enabled) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_c.value);
        final amp = widget.pulseBoost ? 0.0085 : 0.004;
        final s = 1.0 + amp * t;
        return Transform.scale(scale: s, alignment: Alignment.center, child: child);
      },
      child: widget.child,
    );
  }
}
