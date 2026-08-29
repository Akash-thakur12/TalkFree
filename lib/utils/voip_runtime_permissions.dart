import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/app_theme.dart';
import 'app_snackbar.dart';
import '../widgets/voip_gate_dialog.dart';

bool _isGranted(PermissionStatus s) =>
    s.isGranted || s.isLimited || s.isProvisional;

/// Requests mic (+ Android phone) with the **system** permission sheet first.
/// Opens **app** Settings only when the user chose "Don't ask again" / permanently denied
/// (or iOS restricted).
Future<bool> ensureVoipRuntimePermissions(BuildContext context) async {
  if (kIsWeb) return false;
  if (!context.mounted) return false;

  if (Platform.isIOS) {
    return _requestOne(
      context,
      permission: Permission.microphone,
      label: 'Microphone',
      rationale:
          'TalkFree needs microphone access for VoIP calls. Allow when the system asks.',
    );
  }

  if (!await _requestOne(
    context,
    permission: Permission.microphone,
    label: 'Microphone',
    rationale:
        'TalkFree needs microphone access for VoIP calls. Allow when the system asks.',
  )) {
    return false;
  }

  if (!context.mounted) return false;
  return _requestOne(
    context,
    permission: Permission.phone,
    label: 'Phone',
    rationale:
        'Android needs Phone access so TalkFree can place internet calls. Allow when the system asks.',
  );
}

Future<bool> _requestOne(
  BuildContext context, {
  required Permission permission,
  required String label,
  required String rationale,
}) async {
  var status = await permission.status;
  if (_isGranted(status)) return true;

  status = await permission.request();
  if (_isGranted(status)) return true;
  if (!context.mounted) return false;

  if (status.isPermanentlyDenied || status.isRestricted) {
    await showVoipGateDialog(
      context,
      title: '$label access blocked',
      message:
          'TalkFree cannot use $label because it was denied with "Don\'t ask again" or blocked in '
          'system settings.\n\nOpen Settings → Permissions for TalkFree and enable $label.',
      icon: Icons.settings_rounded,
      primaryLabel: 'Open Settings',
      openSettingsOnPrimary: true,
    );
    return false;
  }

  AppSnackBar.show(
    context,
    SnackBar(
      content: Text(rationale),
      behavior: SnackBarBehavior.floating,
      margin: AppTheme.snackBarFloatingMargin(context),
      duration: AppTheme.snackBarCalmDuration,
    ),
  );
  return false;
}
