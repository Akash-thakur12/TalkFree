import 'package:flutter/material.dart';

/// TalkFree design tokens — screenshot-aligned fintech dark UI.
abstract final class AppColors {
  AppColors._();

  /// Primary accent — vibrant green (matches marketing / shell screenshots).
  static const Color primary = Color(0xFF00C853);

  /// Free home background — mockup *ditto* (#0B0E11).
  static const Color freeHomeCanvas = Color(0xFF0B0E11);

  /// Free home neon accent — progress, borders, home tab (#4ADE80).
  static const Color freeHomeNeon = Color(0xFF4ADE80);

  /// Soft blue/purple glows behind glass cards.
  static const Color freeHomeGlowViolet = Color(0xFF5B3FC4);
  static const Color freeHomeGlowBlue = Color(0xFF2D4AE8);

  /// Text & icons on solid [primary] fills (dark on green CTA).
  static const Color onPrimaryButton = Color(0xFF0D0D0D);

  /// Blue — inbox promo banner, links.
  static const Color inboxBannerBlue = Color(0xFF4A78FF);

  /// Teal — free home “CALL CREDITS” label (mockup glass card accent).
  static const Color freeCardTealLabel = Color(0xFF2DD4BF);

  /// Gold — premium / Go Pro only (**#F5B300**).
  static const Color accentGold = Color(0xFFF5B300);

  /// Splash / legacy blue slot.
  static const Color splashAccent = Color(0xFF2563EB);

  static const Color splashNeon = primary;

  static const Color splashMidnight = Color(0xFF000000);
  static const Color splashHorizonDeep = Color(0xFF0C0E12);
  static const Color splashGradientTop = splashMidnight;
  static const Color splashGradientBottom = splashHorizonDeep;
  static const Color splashStage = Color(0xFF16181D);
  static const Color splashStageTop = splashMidnight;
  static const Color splashStageBottom = splashHorizonDeep;

  /// App scaffold — deep navy-black (**#0A0B12**).
  static const Color darkBackground = Color(0xFF0A0B12);
  static const Color darkBackgroundDeep = Color(0xFF050608);

  /// Cards / elevated rows (**#12141C**).
  static const Color surfaceDark = Color(0xFF12141C);
  static const Color cardDark = Color(0xFF12141C);

  /// 1px card outline — `rgba(255,255,255,0.06)`.
  static const Color cardBorderSubtle = Color(0x0FFFFFFF);

  static const Color textOnDark = Color(0xFFFFFFFF);

  /// Secondary / timestamps / inactive nav (**#8A8D9B**).
  static const Color textMutedOnDark = Color(0xFF8A8D9B);

  /// Tertiary / legal / de-emphasized (**#6B7280**).
  static const Color textDimmed = Color(0xFF6B7280);

  static const Color lightBackground = Color(0xFFF8FAFC);
  static const Color textOnLight = Color(0xFF0F172A);
  static const Color textMutedOnLight = Color(0xFF64748B);

  static const Color danger = Color(0xFFEF4444);

  /// Legacy alias — prefer [onPrimaryButton] on green buttons.
  static const Color onPrimary = Color(0xFFFFFFFF);
}
