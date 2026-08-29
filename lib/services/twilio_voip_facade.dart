import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:twilio_voice/twilio_voice.dart';

import '../config/voice_backend_config.dart';
import 'twilio_token_client.dart';

/// Registers device + Twilio Voice SDK using a JWT from the Render server ([VoiceBackendConfig.tokenUri]).
class TwilioVoipFacade {
  TwilioVoipFacade._();
  static final TwilioVoipFacade instance = TwilioVoipFacade._();

  String? _lastIdentity;

  static const String _kCallingAccountDisabled =
      'Calling account disabled: enable TalkFree’s phone account for VoIP in Android '
      '(Settings → Calling accounts / SIMs, or use Open calling settings in the app).';

  /// Runs once after the user hits [DashboardScreen] (Android) so the **Calling accounts**
  /// / Telecom step is not first shown mid-call. If the in-system toggle is off, the OS
  /// “Calling accounts” screen is opened. Swallows errors (logs in debug only).
  Future<void> warmUpAndroidVoiceAtAppLaunch(String firebaseUid) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (firebaseUid.trim().isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != firebaseUid) return;

    try {
      final creds = await TwilioTokenClient.fetchAccessToken();
      if (kDebugMode) {
        debugPrint(
          'Twilio Voice (launch warm-up): ${VoiceBackendConfig.baseUrl}/token, '
          'identity=${creds.identity}',
        );
      }
      final deviceToken = await FirebaseMessaging.instance.getToken();
      final ok = await TwilioVoice.instance.setTokens(
        accessToken: creds.accessToken,
        deviceToken: deviceToken,
      );
      if (ok != true) return;
      _lastIdentity = creds.identity;
      await _androidTelecomAndCallPermissions(
        onCallingAccountDisabled: const _OnCallingAccount(
          openSystemSettings: true,
          throwStateError: false,
        ),
      );
      await TwilioVoice.instance.requestMicAccess();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('warmUpAndroidVoiceAtAppLaunch: $e\n$st');
      }
    }
  }

  /// Fetches access token from `${VoiceBackendConfig.baseUrl}/token`, then [TwilioVoice.instance.setTokens].
  Future<void> registerForOutgoingCalls(String firebaseUid) async {
    if (firebaseUid.trim().isEmpty) {
      throw StateError('registerForOutgoingCalls: empty Firebase uid');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != firebaseUid) {
      throw StateError('registerForOutgoingCalls: not signed in as this user');
    }

    final creds = await TwilioTokenClient.fetchAccessToken();

    if (kDebugMode) {
      debugPrint(
        'Twilio Voice: token from ${VoiceBackendConfig.baseUrl}/token, '
        'identity=${creds.identity}, jwtLen=${creds.accessToken.length}',
      );
    }

    String? deviceToken;
    if (!kIsWeb && Platform.isAndroid) {
      deviceToken = await FirebaseMessaging.instance.getToken();
    }

    final ok = await TwilioVoice.instance.setTokens(
      accessToken: creds.accessToken,
      deviceToken: deviceToken,
    );
    if (ok != true) {
      throw StateError(
        'Voice calling could not be enabled. Check your connection and app permissions, then try again.',
      );
    }
    if (Platform.isAndroid) {
      // Don’t open system UI here — [CallingScreen] opens on catch so it isn’t duplicated.
      await _androidTelecomAndCallPermissions(
        onCallingAccountDisabled: const _OnCallingAccount(
          openSystemSettings: false,
          throwStateError: true,
        ),
      );
    }
    await TwilioVoice.instance.requestMicAccess();
    _lastIdentity = creds.identity;
  }

  /// [registerPhoneAccount] needs READ_PHONE_NUMBERS; order matches Twilio Voice Android plugin.
  Future<void> _androidTelecomAndCallPermissions({
    required _OnCallingAccount onCallingAccountDisabled,
  }) async {
    await TwilioVoice.instance.requestReadPhoneStatePermission();
    await TwilioVoice.instance.requestReadPhoneNumbersPermission();
    await TwilioVoice.instance.registerPhoneAccount();
    if (!await TwilioVoice.instance.isPhoneAccountEnabled()) {
      if (onCallingAccountDisabled.openSystemSettings) {
        try {
          await TwilioVoice.instance.openPhoneAccountSettings();
        } catch (_) {
          // Best-effort — user can enable from app later.
        }
      }
      if (onCallingAccountDisabled.throwStateError) {
        throw StateError(_kCallingAccountDisabled);
      }
    }
    await TwilioVoice.instance.requestCallPhonePermission();
    await TwilioVoice.instance.requestManageOwnCallsPermission();
  }

  String get registeredIdentity {
    final id = _lastIdentity;
    if (id == null) {
      throw StateError('registerForOutgoingCalls first');
    }
    return id;
  }

  Future<bool?> placePstnCall(String toE164) async {
    final from = registeredIdentity;
    final result = await TwilioVoice.instance.call.place(from: from, to: toE164);
    if (kDebugMode && result != true) {
      debugPrint('TwilioVoice.place returned $result (from=$from to=$toE164)');
    }
    return result;
  }

  Future<bool?> hangUp() => TwilioVoice.instance.call.hangUp();

  /// Available after ringing / connect (see Twilio Voice plugin).
  Future<String?> getActiveCallSid() => TwilioVoice.instance.call.getSid();

  Stream<CallEvent> get callEvents => TwilioVoice.instance.callEventsListener;
}

class _OnCallingAccount {
  const _OnCallingAccount({
    required this.openSystemSettings,
    required this.throwStateError,
  });

  final bool openSystemSettings;
  final bool throwStateError;
}
