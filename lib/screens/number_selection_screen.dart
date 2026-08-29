import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lottie/lottie.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

import '../models/virtual_number.dart';
import '../services/browse_inventory_client.dart';
import '../services/browse_number_purchase_service.dart';
import '../services/firestore_user_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/user_facing_service_error.dart';
import '../widgets/scale_on_press.dart';
import 'virtual_number_claim_flow.dart';

/// Mockup-aligned canvas (deep navy-black).
const Color _kNumberSelectCanvas = Color(0xFF020A10);

enum _BrowseCountry {
  us,
  ca,
}

extension on _BrowseCountry {
  String get apiCode => this == _BrowseCountry.us ? 'US' : 'CA';
  String get displayName =>
      this == _BrowseCountry.us ? 'United States' : 'Canada';
  String get flagEmoji => this == _BrowseCountry.us ? '🇺🇸' : '🇨🇦';
}

/// Arguments for [Navigator.pushNamed] → [NumberSelectionScreen.routeName].
class NumberSelectionRouteArgs {
  const NumberSelectionRouteArgs({
    required this.userUid,
    required this.userCredits,
  });

  final String userUid;
  final int userCredits;
}

class NumberSelectionScreen extends StatefulWidget {
  const NumberSelectionScreen({
    super.key,
    required this.userUid,
    required this.userCredits,
  });

  /// Registered in [MaterialApp.onGenerateRoute] in `main.dart`.
  static const String routeName = '/number-selection';

  /// Builds the [MaterialPageRoute] for [routeName] (uses [settings.arguments]).
  static Route<void> createRoute(RouteSettings settings) {
    final args = settings.arguments;
    final uid = args is NumberSelectionRouteArgs ? args.userUid : '';
    final credits = args is NumberSelectionRouteArgs ? args.userCredits : 0;
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => NumberSelectionScreen(
        userUid: uid,
        userCredits: credits,
      ),
    );
  }

  final String userUid;
  final int userCredits;

  @override
  State<NumberSelectionScreen> createState() => _NumberSelectionScreenState();
}

class _NumberSelectionScreenState extends State<NumberSelectionScreen> {
  _BrowseCountry _browseCountry = _BrowseCountry.us;

  List<VirtualNumber> _numbers = [];
  String? _nextPageUri;
  /// True when a regional fetch hit the per-region page cap but Twilio may still have more.
  bool _inventoryTruncated = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _activateBusy = false;
  Object? _error;

  VirtualNumber? _selectedNumber;

  @override
  void initState() {
    super.initState();
    _fetch(reset: true);
  }

  Future<void> _fetch({required bool reset, bool loadMore = false}) async {
    if (loadMore) {
      if (_nextPageUri == null || _nextPageUri!.isEmpty || _loadingMore) {
        return;
      }
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _loading = true;
        _error = null;
        if (reset) {
          _numbers = [];
          _nextPageUri = null;
          _inventoryTruncated = false;
          _selectedNumber = null;
        }
      });
    }

    try {
      final cc = _browseCountry.apiCode;
      if (loadMore) {
        final page = await BrowseInventoryClient.instance.fetchLocalPage(
          country: cc,
          pageSize: 1000,
          nextPage: _nextPageUri,
        );
        if (!mounted) return;
        final seen = _numbers.map((n) => n.e164).toSet();
        final extra = <VirtualNumber>[];
        for (final n in page.numbers) {
          if (seen.add(n.e164)) extra.add(n);
        }
        final combined = [..._numbers, ...extra]
          ..sort((a, b) => a.country.compareTo(b.country));
        final more = page.nextPage?.trim();
        final prevSel = _selectedNumber;
        final newSel = prevSel != null &&
                combined.any((n) => n.e164 == prevSel.e164)
            ? prevSel
            : null;
        setState(() {
          _numbers = combined;
          _loadingMore = false;
          _nextPageUri =
              (more != null && more.isNotEmpty) ? more : null;
          _inventoryTruncated = false;
          _selectedNumber = newSel;
        });
      } else {
        final agg = await BrowseInventoryClient.instance.fetchMergedInventoryByRegion(
          country: cc,
          pageSize: 1000,
        );
        if (!mounted) return;
        final sorted = List<VirtualNumber>.from(agg.numbers)
          ..sort((a, b) => a.country.compareTo(b.country));
        final more = agg.nextPage?.trim();
        final prevSel = _selectedNumber;
        final newSel = prevSel != null &&
                sorted.any((n) => n.e164 == prevSel.e164)
            ? prevSel
            : null;
        setState(() {
          _numbers = sorted;
          _loading = false;
          _nextPageUri =
              (more != null && more.isNotEmpty) ? more : null;
          _inventoryTruncated = agg.truncatedByPageCap;
          _selectedNumber = newSel;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (loadMore) {
          _loadingMore = false;
        } else {
          _error = e;
          _loading = false;
        }
      });
    }
  }

  void _onBrowseCountryChanged(_BrowseCountry next) {
    if (next == _browseCountry) return;
    setState(() {
      _browseCountry = next;
      _selectedNumber = null;
    });
    _fetch(reset: true);
  }

  void _onSelectNumber(VirtualNumber vn) {
    HapticFeedback.selectionClick();
    setState(() => _selectedNumber = vn);
  }

  Future<void> _onReserveNumber(int credits, bool isPremium) async {
    final vn = _selectedNumber;
    if (vn == null || _activateBusy) return;
    HapticFeedback.lightImpact();
    await _activate(vn, credits, isPremium);
  }

  void _retryFetch() => _fetch(reset: true);

  Future<void> _onLoadMore() => _fetch(reset: false, loadMore: true);

  Future<void> _activate(
    VirtualNumber vn,
    int liveCredits,
    bool isPremium,
  ) async {
    if (_activateBusy) return;
    setState(() => _activateBusy = true);
    try {
      final confirmed = await VirtualNumberClaimFlow.showClaimNumberConfirmation(
        context,
        vn.phoneNumber,
      );
      if (!confirmed || !mounted) return;

      if (isPremium) {
        await VirtualNumberClaimFlow.executePremiumProvisionFromBrowse(
          context,
          vn.e164,
        );
        return;
      }

      if (liveCredits < vn.price) {
        if (!mounted) return;
        AppSnackBar.show(
          context,
          SnackBar(
            content: Text('Not enough credits (${vn.price} required).'),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
        return;
      }

      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: 20),
              Expanded(child: Text('Processing…')),
            ],
          ),
        ),
      );

      try {
        await BrowseNumberPurchaseService.instance.purchaseNumber(
          phoneE164: vn.e164,
          price: vn.price,
        );

        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pop();

        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            icon: Icon(
              Icons.check_circle_rounded,
              color: Colors.green.shade600,
              size: 48,
            ),
            title: const Text('Success'),
            content: Text(
              'Your new number is ${vn.phoneNumber}.\n'
              'It has been saved to your profile.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.neonGreen,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
                child: const Text('Great'),
              ),
            ],
          ),
        );

        if (!mounted) return;
        Navigator.of(context).pop();
      } on BrowseNumberPurchaseException catch (e) {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        if (!mounted) return;
        AppSnackBar.show(
          context,
          SnackBar(
            content: Text(
              e.statusCode == 402
                  ? 'Insufficient credits. Earn more and try again.'
                  : e.message,
            ),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: AppTheme.snackBarCalmDuration,
          ),
        );
      } catch (e) {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        if (!mounted) return;
        AppSnackBar.show(
          context,
          SnackBar(
            content: Text(_activateErrorMessage(e)),
            behavior: SnackBarBehavior.floating,
            margin: AppTheme.snackBarFloatingMargin(context),
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _activateBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: _kNumberSelectCanvas,
      appBar: AppBar(
        backgroundColor: _kNumberSelectCanvas,
        foregroundColor: AppColors.textOnDark,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Choose Your Number',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            letterSpacing: -0.3,
            color: AppColors.textOnDark,
          ),
        ),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirestoreUserService.watchUserDocument(widget.userUid),
        builder: (context, creditSnap) {
          final credits = creditSnap.hasData
              ? FirestoreUserService.usableCreditsFromSnapshot(creditSnap.data!)
              : widget.userCredits;
          final userData =
              creditSnap.hasData ? creditSnap.data!.data() : null;
          final isPremium =
              FirestoreUserService.isPremiumFromUserData(userData);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: _BalanceHeroCard(credits: credits),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select a country',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textOnDark,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.cardDark,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _BrowseCountryRow(
                            flagEmoji: _BrowseCountry.us.flagEmoji,
                            title: _BrowseCountry.us.displayName,
                            dialCode: '+1',
                            selected: _browseCountry == _BrowseCountry.us,
                            onTap: () =>
                                _onBrowseCountryChanged(_BrowseCountry.us),
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          _BrowseCountryRow(
                            flagEmoji: _BrowseCountry.ca.flagEmoji,
                            title: _BrowseCountry.ca.displayName,
                            dialCode: '+1',
                            selected: _browseCountry == _BrowseCountry.ca,
                            onTap: () =>
                                _onBrowseCountryChanged(_BrowseCountry.ca),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: _buildNumbersBody(
                  theme,
                  colorScheme,
                  credits,
                  isPremium,
                ),
              ),
              if (_numbers.isNotEmpty)
                _ReserveNumberBar(
                  enabled: _selectedNumber != null &&
                      !_activateBusy &&
                      (isPremium ||
                          credits >= VirtualNumber.defaultPrice),
                  busy: _activateBusy,
                  onPressed: () => _onReserveNumber(credits, isPremium),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildNumbersBody(
    ThemeData theme,
    ColorScheme colorScheme,
    int credits,
    bool isPremium,
  ) {
    if (_loading && _numbers.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
        ),
      );
    }
    if (_error != null && _numbers.isEmpty) {
      return _NumbersLoadError(
        error: _error!,
        onRetry: _retryFetch,
      );
    }
    if (!_loading && _numbers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 48,
                color: AppColors.textMutedOnDark,
              ),
              const SizedBox(height: 12),
              Text(
                'No numbers available right now. Try again in a moment or pick the other country.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                  color: AppColors.textMutedOnDark,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _retryFetch,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final extra = (_loadingMore ? 1 : 0) +
        (!_loadingMore && _nextPageUri != null ? 1 : 0);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      itemCount: _numbers.length + extra,
      itemBuilder: (context, index) {
        if (index < _numbers.length) {
          final vn = _numbers[index];
          return Padding(
            padding: EdgeInsets.only(
              bottom: index < _numbers.length - 1 ? 12 : 0,
            ),
            child: _NumberListCard(
              virtualNumber: vn,
              isSelected: _selectedNumber?.e164 == vn.e164,
              selectionLocked: _activateBusy,
              onSelect: () => _onSelectNumber(vn),
            ),
          );
        }
        final after = index - _numbers.length;
        if (_loadingMore && after == 0) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (_nextPageUri != null && !_loadingMore) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_inventoryTruncated)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Very large catalog — tap below to fetch the next batch.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                FilledButton.tonal(
                  onPressed: _onLoadMore,
                  child: const Text('Load more numbers'),
                ),
              ],
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}

class _BalanceHeroCard extends StatelessWidget {
  const _BalanceHeroCard({required this.credits});

  final int credits;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: AppColors.cardDark,
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.45),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.18),
            blurRadius: 24,
            spreadRadius: 0,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -12,
            top: -4,
            child: Icon(
              Icons.account_balance_wallet_outlined,
              size: 96,
              color: Colors.white.withValues(alpha: 0.04),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Row(
              children: [
                SizedBox(
                  width: 52,
                  height: 52,
                  child: Lottie.asset(
                    AppTheme.lottieMoney,
                    fit: BoxFit.contain,
                    repeat: true,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your balance',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textMutedOnDark,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$credits credits',
                        style: GoogleFonts.inter(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.6,
                          height: 1.05,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text.rich(
                        TextSpan(
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                            color: AppColors.textMutedOnDark,
                          ),
                          children: [
                            const TextSpan(text: 'Activation costs '),
                            TextSpan(
                              text: '${VirtualNumber.defaultPrice} credits',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textOnDark,
                              ),
                            ),
                            const TextSpan(text: ' each'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowseCountryRow extends StatelessWidget {
  const _BrowseCountryRow({
    required this.flagEmoji,
    required this.title,
    required this.dialCode,
    required this.selected,
    required this.onTap,
  });

  final String flagEmoji;
  final String title;
  final String dialCode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.1)
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: selected
                    ? Container(
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.06),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Text(
                  flagEmoji,
                  style: const TextStyle(fontSize: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: AppColors.textOnDark,
                  ),
                ),
              ),
              Text(
                dialCode,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? AppColors.primary.withValues(alpha: 0.95)
                      : AppColors.textMutedOnDark,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: AppColors.textMutedOnDark.withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NumbersLoadError extends StatelessWidget {
  const _NumbersLoadError({
    required this.error,
    required this.onRetry,
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final raw = '$error';
    final msg = userFacingServiceError(raw);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Could not load numbers',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              msg,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReserveNumberBar extends StatelessWidget {
  const _ReserveNumberBar({
    required this.enabled,
    required this.busy,
    required this.onPressed,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final onPrimary = AppColors.onPrimaryButton;

    return Material(
      color: _kNumberSelectCanvas,
      elevation: 0,
      child: Container(
        decoration: BoxDecoration(
          color: _kNumberSelectCanvas,
          border: Border(
            top: BorderSide(color: AppColors.cardBorderSubtle),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 28,
              offset: const Offset(0, -10),
              spreadRadius: -6,
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ScaleOnPress(
                  minScale: 0.98,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: AppTheme.fintechPrimaryCtaShadow,
                    ),
                    child: FilledButton(
                      onPressed: (enabled && !busy) ? onPressed : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 54),
                        backgroundColor: AppTheme.neonGreen,
                        foregroundColor: onPrimary,
                        disabledBackgroundColor:
                            AppTheme.neonGreen.withValues(alpha: 0.32),
                        disabledForegroundColor:
                            onPrimary.withValues(alpha: 0.65),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                        shadowColor: Colors.transparent,
                      ),
                      child: busy
                          ? SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: onPrimary,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.shield_rounded,
                                  size: 22,
                                  color: enabled
                                      ? onPrimary
                                      : onPrimary.withValues(alpha: 0.65),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  'Reserve this number',
                                  style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    letterSpacing: 0.1,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 22,
                                  color: enabled
                                      ? onPrimary
                                      : onPrimary.withValues(alpha: 0.65),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 14,
                      color: AppColors.textDimmed,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Your number will be reserved securely.',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textDimmed,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberListCard extends StatelessWidget {
  const _NumberListCard({
    required this.virtualNumber,
    required this.isSelected,
    required this.selectionLocked,
    required this.onSelect,
  });

  final VirtualNumber virtualNumber;
  final bool isSelected;
  final bool selectionLocked;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: selectionLocked
            ? null
            : () {
                onSelect();
              },
        borderRadius: BorderRadius.circular(18),
        splashColor: AppTheme.neonGreen.withValues(alpha: 0.12),
        highlightColor: AppTheme.neonGreen.withValues(alpha: 0.06),
        child: Ink(
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primary.withValues(alpha: 0.08)
                : AppColors.cardDark,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isSelected
                  ? AppColors.primary.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: 0.08),
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.phone_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            virtualNumber.isoCountryCode == 'CA'
                                ? '🇨🇦'
                                : '🇺🇸',
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            virtualNumber.isoCountryCode == 'CA'
                                ? 'Canada'
                                : 'United States',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textMutedOnDark,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        virtualNumber.phoneNumber,
                        style: GoogleFonts.inter(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                          height: 1.15,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        virtualNumber.country,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                          color: AppColors.textMutedOnDark,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${virtualNumber.price} cr',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _NumberSelectRadio(
                      selected: isSelected,
                      dimmed: selectionLocked,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberSelectRadio extends StatelessWidget {
  const _NumberSelectRadio({
    required this.selected,
    required this.dimmed,
  });

  final bool selected;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final border = selected
        ? AppTheme.neonGreen
        : Colors.white.withValues(alpha: dimmed ? 0.2 : 0.35);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppTheme.neonGreen : Colors.transparent,
        border: Border.all(color: border, width: 2),
      ),
      child: selected
          ? Icon(
              Icons.check_rounded,
              size: 18,
              color: AppColors.onPrimaryButton,
            )
          : null,
    );
  }
}

String _activateErrorMessage(Object e) {
  return userFacingServiceError('Something went wrong: $e');
}


