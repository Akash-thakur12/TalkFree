import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/firestore_user_service.dart';
import '../theme/app_theme.dart';
import 'dashboard_screen.dart';
import 'intro_screen.dart';
import 'login_screen.dart';
import 'splash/splash_screen.dart';

/// Persists after the first-launch value intro is completed.
const String kFirstLaunchIntroCompleteKey = 'talkfree_first_launch_intro_complete';

/// Root navigator: first launch → [TalkFreeValueIntroScreen] → [LoginScreen];
/// signed-in users → [DashboardScreen] on the **Home** tab (credits, ads, premium).
class TalkFreeRoot extends StatefulWidget {
  const TalkFreeRoot({super.key});

  @override
  State<TalkFreeRoot> createState() => _TalkFreeRootState();
}

class _TalkFreeRootState extends State<TalkFreeRoot> {
  bool _prefsReady = false;
  bool _firstIntroCompleted = false;
  /// Minimum time the branded splash stays visible (2–3s window).
  bool _minSplashElapsed = false;
  StreamSubscription<User?>? _authSub;

  /// One Firestore sync per signed-in [User.uid] + guest flag (re-sync when anonymous → Google link).
  String? _syncedUid;
  bool? _syncedIsGuest;
  Future<void>? _loginSyncFuture;

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_loadPrefs());
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 2500), () {
        if (!mounted) return;
        setState(() => _minSplashElapsed = true);
      }),
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    var done = prefs.getBool(kFirstLaunchIntroCompleteKey) ?? false;
    if (!done) {
      final oldOnboarding = prefs.getBool('talkfree_onboarding_complete') ?? false;
      final oldValueIntro = prefs.getBool('talkfree_value_intro_complete') ?? false;
      done = oldOnboarding || oldValueIntro;
    }
    if (!mounted) return;
    setState(() {
      _firstIntroCompleted = done;
      _prefsReady = true;
    });
  }

  Future<void> _onIntroFinished() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kFirstLaunchIntroCompleteKey, true);
    if (!mounted) return;
    setState(() => _firstIntroCompleted = true);
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      if (_syncedUid != user.uid || _syncedIsGuest != user.isAnonymous) {
        _syncedUid = user.uid;
        _syncedIsGuest = user.isAnonymous;
        _loginSyncFuture = FirestoreUserService.syncUserAfterLogin(user);
      }
      return FutureBuilder<void>(
        future: _loginSyncFuture,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(
              backgroundColor: AppTheme.darkBg,
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Could not sync your account.\n${snap.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            );
          }
          final waitingOnSync = snap.connectionState != ConnectionState.done;
          final showSplash = waitingOnSync || !_minSplashElapsed;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (Widget child, Animation<double> animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );
              return FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.035),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                ),
              );
            },
            child: showSplash
                ? SplashScreen(
                    key: const ValueKey<String>('splash_auth'),
                    showLoader: waitingOnSync,
                  )
                : DashboardScreen(
                    key: ValueKey<String>('dash_${user.uid}'),
                    user: user,
                  ),
          );
        },
      );
    }
    _syncedUid = null;
    _syncedIsGuest = null;
    _loginSyncFuture = null;

    if (!_prefsReady || !_minSplashElapsed) {
      return SplashScreen(showLoader: !_prefsReady);
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.028),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      child: _firstIntroCompleted
          ? const KeyedSubtree(
              key: ValueKey<String>('route_login'),
              child: LoginScreen(),
            )
          : KeyedSubtree(
              key: const ValueKey<String>('route_intro'),
              child: TalkFreeValueIntroScreen(
                onDone: _onIntroFinished,
              ),
            ),
    );
  }
}
