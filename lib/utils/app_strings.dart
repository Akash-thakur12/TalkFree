/// User-facing copy (splash, onboarding, etc.).
abstract final class AppStrings {
  AppStrings._();

  /// Shown in system UI / task switcher where [MaterialApp.title] is used.
  static const String appName = 'TalkFree';

  /// Brand line — About, marketing.
  static const String brandTagline =
      'Your Second Identity. Total Privacy. Zero Trace.';

  /// Splash — subtitle (matches marketing mockup casing).
  static const String splashTagline = 'Call Smart. Pay Less.';

  /// Splash — short status while auth / prefs load.
  static const String splashStatus = 'Getting your line ready…';
}
