import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/credits_policy.dart';
import '../services/firestore_user_service.dart';
import '../services/grant_reward_service.dart' show GrantRewardPurpose;
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/purpose_rewarded_ad_strip.dart';
import 'number_selection_screen.dart';

/// Deep navy inbox canvas (mockup).
const Color _inboxCanvasBg = Color(0xFF020A10);

/// OTP / SMS inbox — screenshot-aligned dark cards + blue promo strip.
class InboxScreen extends StatelessWidget {
  const InboxScreen({
    super.key,
    required this.user,
    this.onWatchPurposeAd,
    this.rewardedAdBusy = false,
    this.grantRewardPending = false,
    this.cooldownRemaining = 0,
    this.dailyLimitReached = false,
    this.showRewardRecommendedBadge = true,
    this.emphasizeRewardPurpose = GrantRewardPurpose.otp,
    this.repeatHabitPulseBoost = false,
  });

  final User user;
  final Future<void> Function(GrantRewardPurpose purpose)? onWatchPurposeAd;
  final bool rewardedAdBusy;
  final bool grantRewardPending;
  final int cooldownRemaining;
  final bool dailyLimitReached;
  final bool showRewardRecommendedBadge;
  final GrantRewardPurpose emphasizeRewardPurpose;
  final bool repeatHabitPulseBoost;

  static DateTime _messageTime(Map<String, dynamic> data) {
    for (final key in ['createdAt', 'timestamp', 'receivedAt', 'date']) {
      final v = data[key];
      if (v is Timestamp) return v.toDate().toLocal();
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static String _messageBody(Map<String, dynamic> data) {
    for (final key in ['body', 'text', 'message', 'Body']) {
      final v = data[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        return v.toString();
      }
    }
    return '';
  }

  static String _messageFrom(Map<String, dynamic> data) {
    for (final key in ['from', 'fromNumber', 'From', 'sender']) {
      final v = data[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        return v.toString();
      }
    }
    return 'Message';
  }

  static bool _messageUnread(Map<String, dynamic> data, int sortedIndex) {
    for (final key in ['read', 'isRead', 'seen']) {
      if (!data.containsKey(key)) continue;
      final v = data[key];
      if (v is bool) return !v;
    }
    return sortedIndex == 0;
  }

  static String _formatRelativeTime(DateTime t) {
    if (t.millisecondsSinceEpoch == 0) return '';
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.isNegative) return '';
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24 &&
        now.day == t.day &&
        now.month == t.month &&
        now.year == t.year) {
      return '${diff.inHours}h ago';
    }
    if (diff.inHours < 48) {
      final y = DateTime(now.year, now.month, now.day)
          .difference(DateTime(t.year, t.month, t.day))
          .inDays;
      if (y == 1) return 'Yesterday';
    }
    return '${t.day}/${t.month}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _inboxCanvasBg,
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirestoreUserService.watchUserDocument(user.uid),
        builder: (context, userSnap) {
          final isPremium = FirestoreUserService.isPremiumFromUserData(
            userSnap.data?.data(),
          );
          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirestoreUserService.watchInboxMessages(user.uid),
            builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load inbox.\n${snap.error}',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: AppColors.textMutedOnDark,
                    height: 1.4,
                  ),
                ),
              ),
            );
          }

          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.primary,
              ),
            );
          }

          final docs = snap.data?.docs ?? [];
          final sorted = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(
            docs,
          )..sort((a, b) {
              final ta = _messageTime(a.data());
              final tb = _messageTime(b.data());
              return tb.compareTo(ta);
            });

          if (sorted.isEmpty) {
            return _InboxEmptyMockup(
              user: user,
              isPremium: isPremium,
              onWatchPurposeAd: isPremium ? null : onWatchPurposeAd,
              rewardedAdBusy: rewardedAdBusy,
              grantRewardPending: grantRewardPending,
              cooldownRemaining: cooldownRemaining,
              dailyLimitReached: dailyLimitReached,
              showRewardRecommendedBadge: showRewardRecommendedBadge,
              emphasizeRewardPurpose: emphasizeRewardPurpose,
              repeatHabitPulseBoost: repeatHabitPulseBoost,
            );
          }

          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Messages',
                        style: GoogleFonts.inter(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.55,
                          height: 1.1,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isPremium
                            ? 'TalkFree Pro · secured SMS on your private line'
                            : 'OTP and verifications from your US number',
                        style: GoogleFonts.inter(
                          fontSize: isPremium ? 12 : 13,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                          color: isPremium
                              ? AppColors.textMutedOnDark.withValues(alpha: 0.78)
                              : AppColors.textMutedOnDark.withValues(alpha: 0.92),
                        ),
                      ),
                      if (!isPremium) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Free tier: bank ${CreditsPolicy.otpAdsRequiredPerSms} rewarded ads (OTP purpose) to send one SMS — no credits.',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            height: 1.4,
                            color: AppColors.textDimmed,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _InboxPromoBanner(
                          onUnlock: () async {
                            final doc =
                                await FirestoreUserService.watchUserDocument(
                              user.uid,
                            ).first;
                            final credits =
                                FirestoreUserService.usableCreditsFromSnapshot(
                                    doc);
                            if (!context.mounted) return;
                            await Navigator.of(context).pushNamed(
                              NumberSelectionScreen.routeName,
                              arguments: NumberSelectionRouteArgs(
                                userUid: user.uid,
                                userCredits: credits,
                              ),
                            );
                          },
                        ),
                      ],
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final doc = sorted[i];
                      final data = doc.data();
                      final body = _messageBody(data);
                      final from = _messageFrom(data);
                      final t = _messageTime(data);
                      final timeLabel = _formatRelativeTime(t);
                      final unread = _messageUnread(data, i);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _InboxMessageRow(
                          from: from,
                          body: body.isEmpty ? '(Empty message)' : body,
                          timeLabel: timeLabel,
                          emphasizeUnread: unread,
                        ),
                      );
                    },
                    childCount: sorted.length,
                  ),
                ),
              ),
            ],
          );
            },
          );
        },
      ),
    );
  }
}

class _InboxEmptyMockup extends StatelessWidget {
  const _InboxEmptyMockup({
    required this.user,
    this.isPremium = false,
    this.onWatchPurposeAd,
    this.rewardedAdBusy = false,
    this.grantRewardPending = false,
    this.cooldownRemaining = 0,
    this.dailyLimitReached = false,
    this.showRewardRecommendedBadge = true,
    this.emphasizeRewardPurpose = GrantRewardPurpose.otp,
    this.repeatHabitPulseBoost = false,
  });

  final User user;
  final bool isPremium;
  final Future<void> Function(GrantRewardPurpose purpose)? onWatchPurposeAd;
  final bool rewardedAdBusy;
  final bool grantRewardPending;
  final int cooldownRemaining;
  final bool dailyLimitReached;
  final bool showRewardRecommendedBadge;
  final GrantRewardPurpose emphasizeRewardPurpose;
  final bool repeatHabitPulseBoost;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Messages',
              style: GoogleFonts.inter(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.55,
                height: 1.1,
                color: AppColors.textOnDark,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
            decoration: BoxDecoration(
              color: const Color(0xFF0C141C).withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.06),
              ),
              boxShadow: AppTheme.fintechCardShadow,
            ),
            child: Column(
              children: [
                const _InboxEmptyHeroArt(),
                const SizedBox(height: 22),
                Text.rich(
                  TextSpan(
                    style: GoogleFonts.inter(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.45,
                      height: 1.15,
                    ),
                    children: [
                      TextSpan(
                        text: 'Your inbox is ',
                        style: TextStyle(color: AppColors.textOnDark),
                      ),
                      TextSpan(
                        text: 'ready!',
                        style: TextStyle(color: AppColors.primary),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  isPremium
                      ? 'Messages for your private line will appear here.'
                      : 'Watch rewarded ads here for OTP sends, or use Home / Dialer for call credits and number unlock.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    height: 1.55,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textMutedOnDark,
                  ),
                ),
                const SizedBox(height: 22),
                const _InboxEmptyFeatureRow(),
                if (!isPremium && onWatchPurposeAd != null) ...[
                  const SizedBox(height: 24),
                  Builder(
                    builder: (context) {
                      final adSlotOpen =
                          !dailyLimitReached && cooldownRemaining <= 0;
                      return PurposeRewardedAdStrip(
                        canTapAd: adSlotOpen,
                        grantRewardPending: grantRewardPending,
                        rewardedAdBusy: rewardedAdBusy,
                        cooldownRemaining: cooldownRemaining,
                        dailyLimitReached: dailyLimitReached,
                        emphasizePurpose: emphasizeRewardPurpose,
                        showRewardRecommendedBadge:
                            showRewardRecommendedBadge,
                        cooldownPolicySeconds:
                            CreditsPolicy.adRewardCooldownSecondsForUser(
                          isPremium,
                        ),
                        subtitleCallIsPremium: isPremium,
                        onPurposeAd: onWatchPurposeAd!,
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  const SizedBox(height: 8),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_rounded,
                      size: 14,
                      color: AppColors.primary.withValues(alpha: 0.85),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Private numbers receive SMS instantly after activation.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          height: 1.45,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textDimmed,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InboxEmptyHeroArt extends StatelessWidget {
  const _InboxEmptyHeroArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 190,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppColors.primary.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.75],
                  ),
                ),
              ),
            ),
          ),
          for (var i = 0; i < 8; i++)
            Positioned(
              left: 28.0 + (i % 4) * 52.0,
              top: 20.0 + (i ~/ 4) * 70.0,
              child: Icon(
                Icons.star_rounded,
                size: 6 + (i % 3) * 2.0,
                color: AppColors.primary.withValues(alpha: 0.15 + (i % 3) * 0.06),
              ),
            ),
          Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 128,
                height: 104,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF1A6B5C).withValues(alpha: 0.95),
                      const Color(0xFF0D3D35).withValues(alpha: 0.98),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.28),
                      blurRadius: 24,
                      spreadRadius: -4,
                      offset: const Offset(0, 10),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 18,
                      child: Icon(
                        Icons.mail_rounded,
                        size: 64,
                        color: const Color(0xFF4EE4C8),
                      ),
                    ),
                    Positioned(
                      bottom: 22,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _dot(),
                            const SizedBox(width: 3),
                            _dot(),
                            const SizedBox(width: 3),
                            _dot(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 8,
                right: -4,
                child: Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE53935),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    '1',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dot() {
    return Container(
      width: 4,
      height: 4,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _InboxEmptyFeatureRow extends StatelessWidget {
  const _InboxEmptyFeatureRow();

  @override
  Widget build(BuildContext context) {
    Widget chip(IconData icon, String line1, String line2) {
      return Expanded(
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.darkBackground.withValues(alpha: 0.9),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Icon(icon, color: AppColors.primary, size: 22),
            ),
            const SizedBox(height: 8),
            Text(
              line1,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                height: 1.25,
                color: AppColors.textOnDark,
              ),
            ),
            Text(
              line2,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                height: 1.2,
                color: AppColors.textMutedOnDark,
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        chip(
          Icons.bolt_rounded,
          'Instant SMS',
          'after activation',
        ),
        const SizedBox(width: 8),
        chip(
          Icons.shield_rounded,
          '100% Private',
          'and secure',
        ),
        const SizedBox(width: 8),
        chip(
          Icons.savings_rounded,
          'Rewarded ads',
          'call · number · SMS',
        ),
      ],
    );
  }
}

class _InboxPromoBanner extends StatelessWidget {
  const _InboxPromoBanner({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onUnlock,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.cardDark,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.inboxBannerBlue.withValues(alpha: 0.52),
              width: 1.1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Icon(
                Icons.bolt_rounded,
                color: AppColors.inboxBannerBlue,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Reply faster with your US number',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.28,
                    letterSpacing: -0.1,
                    color: AppColors.inboxBannerBlue,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Unlock',
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  letterSpacing: 0.15,
                  color: AppColors.inboxBannerBlue,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.inboxBannerBlue.withValues(alpha: 0.95),
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InboxMessageRow extends StatelessWidget {
  const _InboxMessageRow({
    required this.from,
    required this.body,
    required this.timeLabel,
    this.emphasizeUnread = false,
  });

  final String from;
  final String body;
  final String timeLabel;
  final bool emphasizeUnread;

  @override
  Widget build(BuildContext context) {
    final borderColor = emphasizeUnread
        ? AppColors.primary.withValues(alpha: 0.42)
        : Colors.white.withValues(alpha: 0.06);
    final tileBg = emphasizeUnread
        ? AppColors.primary.withValues(alpha: 0.06)
        : AppColors.cardDark;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
        },
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            color: tileBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.darkBackground,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Icon(
                      Icons.chat_bubble_outline_rounded,
                      color: AppColors.textMutedOnDark,
                      size: 22,
                    ),
                  ),
                  if (emphasizeUnread)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: tileBg,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      from,
                      style: GoogleFonts.inter(
                        fontWeight: emphasizeUnread
                            ? FontWeight.w800
                            : FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.textOnDark,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        height: 1.35,
                        fontWeight:
                            emphasizeUnread ? FontWeight.w600 : FontWeight.w500,
                        color: emphasizeUnread
                            ? AppColors.textOnDark.withValues(alpha: 0.88)
                            : AppColors.textMutedOnDark,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (timeLabel.isNotEmpty)
                Text(
                  timeLabel,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight:
                        emphasizeUnread ? FontWeight.w700 : FontWeight.w500,
                    color: emphasizeUnread
                        ? AppColors.primary
                        : AppColors.textMutedOnDark,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
