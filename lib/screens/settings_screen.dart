import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Settings: single action — sign out (with confirmation). Auth state drives [TalkFreeRoot] → login.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.user,
  });

  final User user;

  Future<void> _confirmSignOut(BuildContext context) async {
    final ok = await showDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => AlertDialog(
            backgroundColor: (Theme.of(context).cardTheme.color ??
                Theme.of(context).colorScheme.surface),
            title: Text(
              'Log out?',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            content: Text(
              'You will need to sign in again to use TalkFree.',
              style: GoogleFonts.inter(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.inter(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Yes, log out'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !context.mounted) return;
    await AuthService().signOut();
    // Remove the Settings route so login isn’t hidden behind a stale screen
    // (otherwise Back would only then reveal the login screen).
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        backgroundColor: AppTheme.darkBg,
        elevation: 0,
        foregroundColor: Colors.white,
        title: Text(
          'Settings',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: true,
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(20, 24, 20, 24 + bottom),
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.cardDark,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.06),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
              leading: Icon(
                Icons.logout_rounded,
                color: AppColors.danger.withValues(alpha: 0.95),
              ),
              title: Text(
                'Sign out',
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.danger,
                ),
              ),
              subtitle: Text(
                user.isAnonymous
                    ? 'End this guest session on this device'
                    : 'Return to the login screen',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.85),
                  height: 1.35,
                ),
              ),
              onTap: () => _confirmSignOut(context),
            ),
          ),
        ],
      ),
    );
  }
}
