import 'package:flutter/material.dart';

import '../app_scaffold_messenger.dart';
import '../theme/app_theme.dart';

/// Subtle fade + slight upward settle on SnackBar body (220ms, easeOutCubic).
/// Composes with the scaffold SnackBar height/fade motion.
class CalmSnackBarContent extends StatelessWidget {
  const CalmSnackBarContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 6),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Consistent SnackBar presentation: scaffold timing + calm content motion.
abstract final class AppSnackBar {
  AppSnackBar._();

  static SnackBar wrap(SnackBar snackBar) {
    if (snackBar.content is CalmSnackBarContent) {
      return snackBar;
    }
    return SnackBar(
      key: snackBar.key,
      content: CalmSnackBarContent(child: snackBar.content),
      backgroundColor: snackBar.backgroundColor,
      elevation: snackBar.elevation,
      margin: snackBar.margin,
      padding: snackBar.padding,
      width: snackBar.width,
      shape: snackBar.shape,
      hitTestBehavior: snackBar.hitTestBehavior,
      behavior: snackBar.behavior,
      action: snackBar.action,
      actionOverflowThreshold: snackBar.actionOverflowThreshold,
      showCloseIcon: snackBar.showCloseIcon,
      closeIconColor: snackBar.closeIconColor,
      duration: snackBar.duration,
      persist: snackBar.persist,
      onVisible: snackBar.onVisible,
      dismissDirection: snackBar.dismissDirection,
      clipBehavior: snackBar.clipBehavior,
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context,
    SnackBar snackBar,
  ) {
    return ScaffoldMessenger.of(context).showSnackBar(
      wrap(snackBar),
      snackBarAnimationStyle: AppTheme.snackBarScaffoldMotion,
    );
  }

  /// For [appScaffoldMessengerKey] when no [BuildContext] is available.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showRoot(
    SnackBar snackBar,
  ) {
    final messenger = appScaffoldMessengerKey.currentState;
    if (messenger == null) return null;
    return messenger.showSnackBar(
      wrap(snackBar),
      snackBarAnimationStyle: AppTheme.snackBarScaffoldMotion,
    );
  }
}
