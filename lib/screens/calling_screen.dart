import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:twilio_voice/twilio_voice.dart';

import '../config/credits_policy.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../config/voice_backend_config.dart';
import '../services/call_service.dart';
import '../widgets/voip_gate_dialog.dart';
import '../services/firestore_user_service.dart';
import '../services/call_live_billing_service.dart';
import '../services/twilio_voip_facade.dart';
import '../utils/app_snackbar.dart';
import '../utils/monetization_copy.dart';
import '../utils/user_facing_service_error.dart';
import '../widgets/premium_ios_dial_pad.dart' show premiumDialCallGreen;

/// Why [CallingScreen] closed — drives dialer messaging (credit vs VoIP) and interstitial rules.
enum CallingScreenExitReason {
  /// User hang up, remote end, or normal disconnect with billing sync.
  ok,
  /// Balance too low to place or continue the call.
  insufficientCredits,
  /// VoIP/SDK, web, token, network, or permissions — not a credit issue.
  voipFailure,
}

/// Returned when [CallingScreen] closes; [syncedBalance] is set after disconnect via Firestore fetch.
class CallingScreenResult {
  const CallingScreenResult({
    required this.exitReason,
    this.syncedBalance,
    this.serverBillingPending = false,
  });

  final CallingScreenExitReason exitReason;

  /// Authoritative usable credits from Firestore (e.g. after call end).
  final int? syncedBalance;

  /// True if the call connected but Firestore still matched the pre-call balance after waiting
  /// for Twilio `/call-status` (webhook delay or misconfiguration).
  final bool serverBillingPending;
}

class CallingScreen extends StatefulWidget {
  const CallingScreen({
    super.key,
    required this.user,
    required this.dialE164,
  });

  final User user;
  final String dialE164;

  @override
  State<CallingScreen> createState() => _CallingScreenState();
}

String _formatMmSs(int totalSeconds) {
  final s = totalSeconds < 0 ? 0 : totalSeconds;
  final m = s ~/ 60;
  final r = s % 60;
  return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
}

class _CallingScreenState extends State<CallingScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  /// Elapsed call time (MM:SS) — 1 Hz while connected (isolated from full-screen rebuilds).
  Timer? _elapsedTimer;
  final ValueNotifier<int> _elapsedNotifier = ValueNotifier<int>(0);
  /// Live UI: −1 credit every [CreditsPolicy.connectedLiveCreditIntervalSec] while connected.
  Timer? _liveCreditTicker;
  /// Local balance preview (isolated from full-screen rebuilds).
  final ValueNotifier<int?> _creditsNotifier = ValueNotifier<int?>(null);
  StreamSubscription<CallEvent>? _callSub;
  String _statusLine = 'Connecting...';
  bool _remoteEndedHandled = false;
  bool _connectedCreditTimerStarted = false;
  /// Firestore usable credits at dial (before connect). Used to wait for server billing after hangup.
  int? _creditsAtSessionStart;
  /// Twilio Call SID — required for POST /call-live-tick and /sync-call-billing.
  String? _activeCallSid;
  /// Tier-2 settlement in progress — shows a light overlay so the 5s window does not feel frozen.
  bool _finalizingBill = false;
  /// Cached at dial — affects live tick cadence, grace window, and [CallService] enforcement.
  bool _isPremium = false;

  /// Premium-only: hang up after [CreditsPolicy.premiumCallGraceSeconds] once balance hits 0.
  Timer? _graceHangupTimer;

  /// Premium grace UX — “Grace mode active” chip while the grace timer runs.
  final ValueNotifier<bool> _graceModeActive = ValueNotifier<bool>(false);

  /// Premium: at most one grace window per call; a second zero-balance event ends the call.
  bool _premiumGraceConsumed = false;

  /// Free tier: show Pro benefit snack once per connected session when balance is low.
  bool _inCallPremiumBenefitNudgeShown = false;

  late final AnimationController _callVisualPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  late final AnimationController _creditPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// Cached so the 1 Hz timer subtree does not re-resolve fonts every tick.
  late final TextStyle _elapsedTimerTextStyle;

  @override
  void initState() {
    super.initState();
    _elapsedTimerTextStyle = GoogleFonts.poppins(
      fontSize: 56,
      fontWeight: FontWeight.w300,
      color: Colors.white,
      letterSpacing: 0.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrap());
    });
  }

  void _onElapsedTick(Timer _) {
    if (!mounted) return;
    if (kDebugMode && _elapsedNotifier.value == 0) {
      debugPrint('DEBUG: _elapsedTimer first tick (1 Hz) — call is Connected');
    }
    _elapsedNotifier.value++;
  }

  void _onLiveCreditTick(Timer timer) {
    if (!mounted) return;
    final sid = _activeCallSid;
    if (sid == null || sid.isEmpty) return;
    if (kDebugMode) {
      debugPrint(
        'DEBUG: _liveCreditTicker → POST /call-live-tick amount '
        '${CreditsPolicy.connectedLiveCreditPerTick}',
      );
    }
    // Chain only — no await in this path so the periodic callback returns immediately
    // after scheduling work; billing order unchanged (POST then Firestore read).
    CallLiveBillingService.instance
        .postLiveTick(
          callSid: sid,
          amount: CreditsPolicy.connectedLiveCreditPerTick,
        )
        .then((bool ok) async {
          if (!mounted) return null;
          if (!ok && kDebugMode) {
            debugPrint('DEBUG: call-live-tick failed (will retry on next tick)');
          }
          try {
            return await FirestoreUserService.fetchUsableCredits(widget.user.uid);
          } catch (_) {
            return null;
          }
        })
        .then((int? display) {
          if (display == null || !mounted) return;
          _creditsNotifier.value = display;
          _creditPulse.forward(from: 0);
          if (!_isPremium &&
              !_inCallPremiumBenefitNudgeShown &&
              display > 0 &&
              display <= CreditsPolicy.lowCreditWarningThreshold) {
            _inCallPremiumBenefitNudgeShown = true;
            AppSnackBar.show(
              context,
              SnackBar(
                margin: AppTheme.snackBarFloatingMargin(context),
                elevation: 0,
                backgroundColor: AppColors.cardDark.withValues(alpha: 0.94),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                content: Text(
                  MonetizationCopy.inCallLowCreditsProBenefit(
                    premiumCreditsPerMin: CreditsPolicy.creditsPerMinutePremium,
                  ),
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    height: 1.35,
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                ),
                behavior: SnackBarBehavior.floating,
                duration: AppTheme.snackBarCalmDuration,
              ),
            );
          }
          if (display <= 0) {
            if (_isPremium) {
              _beginPremiumGraceIfNeeded(timer);
            } else {
              timer.cancel();
              _liveCreditTicker = null;
              unawaited(_autoHangupLowCredits());
            }
          }
        })
        .catchError((Object e, StackTrace st) {
          if (kDebugMode) {
            debugPrint('DEBUG: live-tick chain: $e');
          }
        });
  }

  void _beginPremiumGraceIfNeeded(Timer timer) {
    if (_premiumGraceConsumed) {
      timer.cancel();
      _liveCreditTicker = null;
      _graceHangupTimer?.cancel();
      _graceHangupTimer = null;
      _graceModeActive.value = false;
      unawaited(_autoHangupLowCredits());
      return;
    }
    if (_graceHangupTimer != null) return;
    _premiumGraceConsumed = true;
    timer.cancel();
    _liveCreditTicker = null;
    _graceHangupTimer = Timer(
      Duration(seconds: CreditsPolicy.premiumCallGraceSeconds),
      () {
        _graceHangupTimer = null;
        _graceModeActive.value = false;
        if (!mounted) return;
        unawaited(_autoHangupLowCredits());
      },
    );
    _graceModeActive.value = true;
  }

  void _cancelConnectedTimers() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _liveCreditTicker?.cancel();
    _liveCreditTicker = null;
    _graceHangupTimer?.cancel();
    _graceHangupTimer = null;
    _graceModeActive.value = false;
  }

  Future<void> _startConnectedCreditTimer() async {
    if (kDebugMode) {
      debugPrint(
        'DEBUG: _startConnectedCreditTimer() entered — '
        'alreadyStarted=$_connectedCreditTimerStarted mounted=$mounted',
      );
    }
    if (_connectedCreditTimerStarted || !mounted) {
      if (kDebugMode) {
        debugPrint(
          'DEBUG: _startConnectedCreditTimer() skipped (duplicate connect or unmounted)',
        );
      }
      return;
    }
    _connectedCreditTimerStarted = true;
    _premiumGraceConsumed = false;
    _inCallPremiumBenefitNudgeShown = false;
    _graceModeActive.value = false;

    final credits = await FirestoreUserService.fetchUsableCredits(
      widget.user.uid,
    );
    if (!mounted) return;

    var sid = _activeCallSid ?? '';
    for (var i = 0; i < 50 && sid.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      final g = await TwilioVoipFacade.instance.getActiveCallSid();
      if (g != null && g.isNotEmpty) {
        sid = g;
        _activeCallSid = g;
        CallService.instance.setActiveCallSid(g);
      }
    }

    if (sid.isEmpty) {
      if (kDebugMode) {
        debugPrint('DEBUG: No CallSid yet — elapsed only, no live billing ticks');
      }
      _creditsNotifier.value = credits;
      _cancelConnectedTimers();
      _elapsedNotifier.value = 0;
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), _onElapsedTick);
      return;
    }

    if (kDebugMode) {
      debugPrint(
        'DEBUG: Connected → first /call-live-tick after '
        '${_isPremium ? "${CreditsPolicy.premiumLiveTickPeriodMs}ms (premium)" : "${CreditsPolicy.connectedLiveCreditIntervalSec}s (free)"} '
        '(settlement reconciles Twilio duration)',
      );
    }

    _creditsNotifier.value = credits;
    _creditPulse.forward(from: 0);

    _cancelConnectedTimers();
    _elapsedNotifier.value = 0;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), _onElapsedTick);
    if (_isPremium) {
      _liveCreditTicker = Timer.periodic(
        CreditsPolicy.premiumLiveTickPeriod,
        _onLiveCreditTick,
      );
    } else {
      _liveCreditTicker = Timer.periodic(
        Duration(seconds: CreditsPolicy.connectedLiveCreditIntervalSec),
        _onLiveCreditTick,
      );
    }
    if (kDebugMode) {
      debugPrint(
        'DEBUG: Started _elapsedTimer (1s) + _liveCreditTicker (premium=$_isPremium)',
      );
    }
  }

  Future<void> _autoHangupLowCredits() async {
    if (!mounted) return;
    if (_remoteEndedHandled) return;
    _remoteEndedHandled = true;
    _cancelConnectedTimers();
    CallService.instance.stopBilling();
    await _callSub?.cancel();
    _callSub = null;
    try {
      await TwilioVoipFacade.instance.hangUp();
    } catch (_) {}
    if (mounted) {
      AppSnackBar.show(
        context,
        SnackBar(
          content: const Text('Not enough credits'),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      await _popWithFirestoreSync(
        exitReason: CallingScreenExitReason.insufficientCredits,
      );
    }
  }

  /// After hangup: [CallLiveBillingService.runFinalSettlementWindow] (5s Tier-2 sync) then Firestore read
  /// so the dialer does not flash the pre-call balance. Twilio `/call-status` still settles if the app died.
  Future<void> _popWithFirestoreSync({
    required CallingScreenExitReason exitReason,
  }) async {
    if (!mounted) return;
    setState(() => _finalizingBill = true);
    int? synced;
    var serverBillingPending = false;
    try {
      final settled = await _fetchUsableCreditsAfterCallSettles();
      synced = settled.balance;
      serverBillingPending = settled.serverBillingPending;
      // Balance comes from server billing + Firestore; do not client-write credits.
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _finalizingBill = false);
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      CallingScreenResult(
        exitReason: exitReason,
        syncedBalance: synced,
        serverBillingPending: serverBillingPending,
      ),
    );
  }

  Future<({int? balance, bool serverBillingPending})>
      _fetchUsableCreditsAfterCallSettles() async {
    final uid = widget.user.uid;
    final baseline = _creditsAtSessionStart;
    final sid = _activeCallSid;

    if (baseline == null || !_connectedCreditTimerStarted) {
      try {
        final v = await FirestoreUserService.fetchUsableCredits(uid);
        return (balance: v, serverBillingPending: false);
      } catch (_) {
        return (balance: null, serverBillingPending: false);
      }
    }

    if (sid != null && sid.isNotEmpty) {
      if (!mounted) {
        return (balance: null, serverBillingPending: false);
      }
      await CallLiveBillingService.instance.runFinalSettlementWindow(
        callSid: sid,
        window: const Duration(seconds: 5),
      );
      if (kDebugMode) {
        debugPrint('DEBUG: Tier-2 settlement window (5s) finished for $sid');
      }
    }

    const maxAttempts = 8;
    const delay = Duration(milliseconds: 400);
    int? last;

    for (var i = 0; i < maxAttempts; i++) {
      if (!mounted) {
        return (balance: last, serverBillingPending: false);
      }
      try {
        last = await FirestoreUserService.fetchUsableCredits(uid);
      } catch (_) {
        if (i == maxAttempts - 1) {
          return (balance: last, serverBillingPending: true);
        }
        await Future<void>.delayed(delay);
        continue;
      }

      if (last < baseline) {
        return (balance: last, serverBillingPending: false);
      }
      if (i < maxAttempts - 1) {
        await Future<void>.delayed(delay);
      }
    }

    final pending = last != null && last >= baseline;
    if (pending && kDebugMode) {
      debugPrint(
        'DEBUG: Balance still ≥ pre-call after sync — check Render / Twilio /call-status',
      );
    }
    return (balance: last, serverBillingPending: pending);
  }

  /// Shown when [TwilioVoipFacade.placePstnCall] does not return true (permissions, phone account, Twilio config).
  Future<void> _showVoipStartFailedHelp() async {
    if (!mounted) return;
    var alreadyLeftCallingScreen = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.cardDark,
          title: Text(
            'Could not start VoIP call',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          content: SingleChildScrollView(
            child: Text(
              'The call could not start. Check:\n\n'
              '• Microphone & Phone permissions for TalkFree.\n'
              '• Android: enable TalkFree as a calling account (ConnectionService) if asked.\n'
              '• Try again in a moment with a stable internet connection.',
              style: GoogleFonts.inter(
                fontSize: 14,
                height: 1.45,
                color: Colors.white70,
              ),
            ),
          ),
          actions: [
            if (!kIsWeb && Platform.isAndroid)
              TextButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  if (!mounted) return;
                  alreadyLeftCallingScreen = true;
                  Navigator.of(context).pop(
                    const CallingScreenResult(
                      exitReason: CallingScreenExitReason.voipFailure,
                    ),
                  );
                  await TwilioVoice.instance.openPhoneAccountSettings();
                },
                child: const Text('Calling account'),
              ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                if (!mounted) return;
                  alreadyLeftCallingScreen = true;
                  Navigator.of(context).pop(
                    const CallingScreenResult(
                      exitReason: CallingScreenExitReason.voipFailure,
                    ),
                  );
                  await openAppSettings();
              },
              child: const Text('App permissions'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    if (mounted && !alreadyLeftCallingScreen) {
      Navigator.of(context).pop(
        const CallingScreenResult(
          exitReason: CallingScreenExitReason.voipFailure,
        ),
      );
    }
  }

  /// Twilio exposes Call SID after ringing; needed for server-side [TerminateCallService].
  Future<void> _pollActiveCallSid() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      final sid = await TwilioVoipFacade.instance.getActiveCallSid();
      if (sid != null && sid.isNotEmpty) {
        CallService.instance.setActiveCallSid(sid);
        setState(() => _activeCallSid = sid);
        return;
      }
    }
  }

  Future<void> _bootstrap() async {
    if (kIsWeb) {
      if (!mounted) return;
      Navigator.of(context).pop(
        const CallingScreenResult(
          exitReason: CallingScreenExitReason.voipFailure,
        ),
      );
      return;
    }

    final c = await FirestoreUserService.fetchUsableCredits(widget.user.uid);
    final premium = await FirestoreUserService.fetchIsPremium(widget.user.uid);
    if (!mounted) return;
    _isPremium = premium;
    _creditsAtSessionStart = c;
    if (c < CreditsPolicy.minCreditsToStartCallFor(premium)) {
      _cancelConnectedTimers();
      Navigator.of(context).pop(
        const CallingScreenResult(
          exitReason: CallingScreenExitReason.insufficientCredits,
        ),
      );
      return;
    }

    StreamSubscription<CallEvent>? sub;
    try {
      await TwilioVoipFacade.instance.registerForOutgoingCalls(widget.user.uid);
      if (!mounted) return;

      setState(() => _statusLine = 'Connecting...');

      sub = TwilioVoipFacade.instance.callEvents.listen((event) {
        if (!mounted) return;
        final status = event.name;
        if (kDebugMode) {
          debugPrint('DEBUG: Call Status is $status');
        }
        switch (event) {
          case CallEvent.ringing:
            setState(() => _statusLine = 'Calling...');
            break;
          case CallEvent.connected:
            if (kDebugMode) {
              debugPrint(
                'DEBUG: CallEvent.connected → UI Connected + '
                '_startConnectedCreditTimer() (local −credits + timers)',
              );
            }
            setState(() => _statusLine = 'Connected');
            unawaited(_startConnectedCreditTimer());
            break;
          case CallEvent.reconnecting:
            setState(() => _statusLine = 'Connecting...');
            break;
          case CallEvent.reconnected:
            if (kDebugMode) {
              debugPrint(
                'DEBUG: CallEvent.reconnected → UI Connected + '
                '_startConnectedCreditTimer()',
              );
            }
            setState(() => _statusLine = 'Connected');
            unawaited(_startConnectedCreditTimer());
            break;
          case CallEvent.callEnded:
          case CallEvent.declined:
            unawaited(_onRemoteEnded());
            break;
          default:
            break;
        }
      });
      _callSub = sub;

      final ok = await TwilioVoipFacade.instance.placePstnCall(widget.dialE164);
      if (!mounted) return;
      if (ok != true) {
        await sub.cancel();
        _callSub = null;
        if (mounted) {
          await _showVoipStartFailedHelp();
        }
        return;
      }

      unawaited(_pollActiveCallSid());

      if (kDebugMode) {
        debugPrint(
          'DEBUG: placePstnCall ok → CallService.startBilling(); '
          'live pulses use POST /call-live-tick, final settle: /sync-call-billing + Twilio /call-status',
        );
      }
      CallService.instance.startBilling(
        uid: widget.user.uid,
        twilioCallSid: null,
        hangUpActiveCall: () async {
          await TwilioVoipFacade.instance.hangUp();
        },
        onInsufficientCredits: () {
          if (!mounted) return;
          unawaited(_onInsufficientFromBilling());
        },
        onError: (_) {},
        enforceBalanceChecks: !_isPremium,
      );
    } catch (e, _) {
      await sub?.cancel();
      _callSub = null;
      if (!mounted) return;
      final msg = e.toString();
      final callingAccount = msg.contains('Calling account disabled');
      if (callingAccount) {
        // Not a runtime permission — OEM "Calling accounts" toggle. Open system UI directly;
        // runtime mic/phone were already requested on the dialer.
        if (mounted) {
          AppSnackBar.show(
            context,
            SnackBar(
              content: const Text(
                'Turn on TalkFree in Calling accounts — the settings screen will open.',
              ),
              behavior: SnackBarBehavior.floating,
              margin: AppTheme.snackBarFloatingMargin(context),
              duration: const Duration(seconds: 5),
            ),
          );
          try {
            await TwilioVoice.instance.openPhoneAccountSettings();
          } catch (_) {}
        }
        if (!mounted) return;
      }
      final tokenOrServer = !callingAccount &&
          (msg.contains('token') ||
              msg.contains('Token') ||
              msg.contains('HTTP') ||
              msg.contains(VoiceBackendConfig.baseUrl) ||
              msg.contains('setTokens'));
      if (tokenOrServer) {
        if (!mounted) return;
        await showVoipGateDialog(
          context,
          title: 'Voice service',
          message:
              'Could not connect to the voice service. Check your internet connection '
              'and try again. If this keeps happening, try again later.',
          icon: Icons.cloud_sync_rounded,
          primaryLabel: 'OK',
          openSettingsOnPrimary: false,
        );
        if (!mounted) return;
      } else if (!callingAccount) {
        if (!mounted) return;
        await showVoipGateDialog(
          context,
          title: 'Call setup failed',
          message: userFacingServiceError(msg),
          icon: Icons.error_outline_rounded,
          primaryLabel: 'OK',
          openSettingsOnPrimary: false,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        const CallingScreenResult(
          exitReason: CallingScreenExitReason.voipFailure,
        ),
      );
    }
  }

  Future<void> _onInsufficientFromBilling() async {
    _cancelConnectedTimers();
    await _callSub?.cancel();
    _callSub = null;
    if (mounted) {
      AppSnackBar.show(
        context,
        SnackBar(
          content: const Text('Not enough credits'),
          behavior: SnackBarBehavior.floating,
          margin: AppTheme.snackBarFloatingMargin(context),
          duration: AppTheme.snackBarCalmDuration,
        ),
      );
      await _popWithFirestoreSync(
        exitReason: CallingScreenExitReason.insufficientCredits,
      );
    }
  }

  Future<void> _onRemoteEnded() async {
    if (_remoteEndedHandled) return;
    _remoteEndedHandled = true;
    if (!mounted) return;
    _cancelConnectedTimers();
    CallService.instance.stopBilling();
    await _callSub?.cancel();
    _callSub = null;
    if (mounted) {
      await _popWithFirestoreSync(exitReason: CallingScreenExitReason.ok);
    }
  }

  @override
  void dispose() {
    _graceModeActive.dispose();
    _elapsedNotifier.dispose();
    _creditsNotifier.dispose();
    _callVisualPulse.dispose();
    _creditPulse.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _cancelConnectedTimers();
    _callSub?.cancel();
    CallService.instance.stopBilling();
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(TwilioVoipFacade.instance.hangUp());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(CallService.instance.syncAfterAppResumed());
      final sid = _activeCallSid;
      if (sid != null && sid.isNotEmpty) {
        unawaited(CallLiveBillingService.instance.flushPendingTicksForCall(sid));
      }
    }
  }

  Future<void> _endCall() async {
    _cancelConnectedTimers();
    CallService.instance.stopBilling();
    await _callSub?.cancel();
    _callSub = null;
    try {
      await TwilioVoipFacade.instance.hangUp();
    } catch (_) {}
    if (mounted) {
      await _popWithFirestoreSync(exitReason: CallingScreenExitReason.ok);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          backgroundColor: AppTheme.darkBg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  RepaintBoundary(
                    child: _ActiveCallPulseHeader(controller: _callVisualPulse),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    widget.dialE164,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _statusLine,
                    style: GoogleFonts.poppins(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70,
                    ),
                  ),
                  if (_isPremium)
                    _GraceModeSlot(listenable: _graceModeActive),
                  if (!kIsWeb &&
                      Platform.isAndroid &&
                      (_statusLine == 'Connected' || _statusLine == 'Calling...')) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        'This call uses TalkFree internet calling — not the cellular dialer. '
                        'Some phones show the system Phone bar on top; hang up here to end the call.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          height: 1.4,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ],
                  ValueListenableBuilder<int?>(
                    valueListenable: _creditsNotifier,
                    builder: (context, credits, _) {
                      if (credits == null) return const SizedBox.shrink();
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 20),
                          RepaintBoundary(
                            child: _NeonCreditsBalance(
                              credits: credits,
                              pulse: _creditPulse,
                              isPremium: _isPremium,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const Spacer(),
                  ValueListenableBuilder<int>(
                    valueListenable: _elapsedNotifier,
                    builder: (context, elapsedSec, _) {
                      return Text(
                        _formatMmSs(elapsedSec),
                        style: _elapsedTimerTextStyle,
                      );
                    },
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 72,
                    child: FilledButton.icon(
                      onPressed: _endCall,
                      icon: const Icon(Icons.call_end_rounded, size: 26),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFC62828),
                        foregroundColor: Colors.white,
                        elevation: 4,
                        shadowColor: Colors.red.withValues(alpha: 0.45),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      label: Text(
                        'Hang up',
                        style: GoogleFonts.poppins(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
        if (_finalizingBill)
          Positioned.fill(
            child: Material(
              color: Colors.black.withValues(alpha: 0.45),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Color(0xFF00C853),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Finalizing bill…',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Syncing with server',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Live balance — brand green, subtle motion (no neon glow).
/// Premium: softer tick pulse + cross-fade on value changes for a steadier feel.
class _NeonCreditsBalance extends StatelessWidget {
  const _NeonCreditsBalance({
    required this.credits,
    required this.pulse,
    this.isPremium = false,
  });

  final int credits;
  final Animation<double> pulse;
  final bool isPremium;

  static const Color _green = Color(0xFF00C853);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final u = Curves.easeOutCubic.transform(pulse.value);
        final amp = isPremium ? 0.0085 : 0.04;
        final scale = 1.0 + amp * (1.0 - u);
        final textStyle = GoogleFonts.poppins(
          fontSize: isPremium ? 25 : 24,
          fontWeight: FontWeight.w800,
          color: _green,
          letterSpacing: 0,
          height: 1.2,
          fontFeatures: const [FontFeature.tabularFigures()],
          shadows: const [
            Shadow(
              color: Color(0x66000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        );
        final childW = isPremium
            ? AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                transitionBuilder: (Widget w, Animation<double> a) {
                  final curved = CurvedAnimation(
                    parent: a,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeOutCubic,
                  );
                  return FadeTransition(
                    opacity: curved,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.05),
                        end: Offset.zero,
                      ).animate(curved),
                      child: w,
                    ),
                  );
                },
                child: Padding(
                  key: ValueKey<int>(credits),
                  padding: EdgeInsets.zero,
                  child: Text(
                    '$credits credits',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: textStyle,
                  ),
                ),
              )
            : Text(
                '$credits credits',
                key: ValueKey<int>(credits),
                textAlign: TextAlign.center,
                maxLines: 2,
                style: textStyle,
              );
        return Transform.scale(
          scale: scale,
          child: childW,
        );
      },
    );
  }
}

/// Delays grace chip in/out slightly so the transition feels calm (presentation only).
class _GraceModeSlot extends StatefulWidget {
  const _GraceModeSlot({required this.listenable});

  final ValueListenable<bool> listenable;

  @override
  State<_GraceModeSlot> createState() => _GraceModeSlotState();
}

class _GraceModeSlotState extends State<_GraceModeSlot> {
  bool _visible = false;
  int _scheduleGen = 0;

  void _onGraceChanged() {
    final on = widget.listenable.value;
    final gen = ++_scheduleGen;
    if (on) {
      Future<void>.delayed(const Duration(milliseconds: 100), () {
        if (!mounted || gen != _scheduleGen) return;
        if (widget.listenable.value) setState(() => _visible = true);
      });
    } else {
      Future<void>.delayed(const Duration(milliseconds: 85), () {
        if (!mounted || gen != _scheduleGen) return;
        if (!widget.listenable.value) setState(() => _visible = false);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_onGraceChanged);
    if (widget.listenable.value) _onGraceChanged();
  }

  @override
  void didUpdateWidget(covariant _GraceModeSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_onGraceChanged);
      widget.listenable.addListener(_onGraceChanged);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onGraceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (Widget child, Animation<double> a) {
        final curved = CurvedAnimation(
          parent: a,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      child: _visible
          ? Padding(
              key: const ValueKey<String>('grace_show'),
              padding: const EdgeInsets.only(top: 10),
              child: const _GraceModeChip(),
            )
          : const SizedBox.shrink(key: ValueKey<String>('grace_hide')),
    );
  }
}

/// Premium-only: subtle chip while post-zero grace is active.
class _GraceModeChip extends StatelessWidget {
  const _GraceModeChip();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.96,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: AppColors.accentGold.withValues(alpha: 0.065),
          border: Border.all(
            color: AppColors.accentGold.withValues(alpha: 0.18),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x18000000),
              blurRadius: 14,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            '⚡ Grace mode active',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.02,
              color: AppColors.accentGold.withValues(alpha: 0.82),
            ),
          ),
        ),
      ),
    );
  }
}

/// Neon green expanding rings + center icon for active-call screen.
class _ActiveCallPulseHeader extends StatelessWidget {
  const _ActiveCallPulseHeader({required this.controller});

  final Animation<double> controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        return SizedBox(
          height: 120,
          width: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                _ring(t, i),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      premiumDialCallGreen.withValues(alpha: 0.28),
                      premiumDialCallGreen.withValues(alpha: 0.05),
                    ],
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x59000000),
                      blurRadius: 18,
                      spreadRadius: 0,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.phone_in_talk_rounded,
                  color: premiumDialCallGreen.withValues(alpha: 0.98),
                  size: 38,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _ring(double t, int index) {
    final phase = (t + index * 0.28) % 1.0;
    return Transform.scale(
      scale: 0.42 + phase * 0.9,
      child: Opacity(
        opacity: (1.0 - phase) * 0.75,
        child: Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: premiumDialCallGreen.withValues(alpha: 0.5),
              width: 1.5,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 10,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
