import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// **TalkFree Pro Master Theme** — canonical neon-black tokens.
///
/// Single source of truth for raw values is [AppColors]; use these names in new
/// code for readability. Prefer [AppTheme] tokens in UI code.
abstract final class TalkFreeProMasterTheme {
  TalkFreeProMasterTheme._();

  static const Color neonGreen = AppColors.primary;
  static const Color darkBg = AppColors.darkBackground;
  static const Color surfaceCard = AppColors.cardDark;
  static const Color mutedText = AppColors.textMutedOnDark;
  static const Color pureWhite = AppColors.textOnDark;
}
