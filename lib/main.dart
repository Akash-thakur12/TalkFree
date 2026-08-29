import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_env.dart';

import 'app_scaffold_messenger.dart';
import 'theme/app_theme.dart';
import 'screens/app_root.dart';
import 'screens/number_selection_screen.dart';
import 'screens/premium_credits_wallet_screen.dart';
import 'screens/subscription_screen.dart';
import 'screens/virtual_number_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final prefs = await SharedPreferences.getInstance();
    final n = (prefs.getInt('talkfree_app_launch_count') ?? 0) + 1;
    await prefs.setInt('talkfree_app_launch_count', n);
  } catch (e, st) {
    debugPrint('talkfree_app_launch_count: $e\n$st');
  }
  await Firebase.initializeApp();
  await AppEnv.loadDotEnv();
  runApp(const TalkFreeApp());
  // After first frame: native splash clears faster; avoid blocking runApp on the
  // notification permission dialog or AdMob init.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await FirebaseMessaging.instance.requestPermission();
    } catch (e, st) {
      debugPrint('FirebaseMessaging.requestPermission: $e\n$st');
    }
    try {
      await MobileAds.instance.initialize();
    } catch (e, st) {
      debugPrint('MobileAds.initialize failed: $e\n$st');
    }
  });
}

class TalkFreeApp extends StatelessWidget {
  const TalkFreeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: appScaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: 'TalkFree',
      theme: AppTheme.light(),
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: const TalkFreeRoot(),
      onGenerateRoute: (RouteSettings settings) {
        if (settings.name == NumberSelectionScreen.routeName) {
          return NumberSelectionScreen.createRoute(settings);
        }
        if (settings.name == VirtualNumberScreen.routeName) {
          return VirtualNumberScreen.createRoute(settings);
        }
        if (settings.name == SubscriptionScreen.routeName) {
          return SubscriptionScreen.createRoute();
        }
        if (settings.name == PremiumCreditsWalletScreen.routeName) {
          return PremiumCreditsWalletScreen.createRoute();
        }
        return null;
      },
    );
  }
}
