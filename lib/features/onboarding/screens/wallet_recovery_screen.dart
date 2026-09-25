import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sentry_flutter/sentry_flutter.dart' show SentryLevel;

import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/security/app_lock_bloc.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/services/app_reset_service.dart';
import '../../../core/services/sentry_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_checkbox.dart';

/// Recovery screen shown when the Keychain holds a recoverable wallet but the
/// database has none — after an uninstall + reinstall on iOS, and after the
/// database was quarantined or re-keyed. Lets the user restore or start fresh.
/// Only shown when something recoverable exists — otherwise the notifier
/// clears the stale session keys and sends the user to onboarding.
///
/// The app is un-authenticated here (AppLock booted `noPinSet` against an
/// empty DB), so this is the one place a user can wipe before proving they
/// hold the phrase. Start fresh therefore expands an in-place gate — copy,
/// checkbox, armed button — instead of acting on one tap. It is deliberately
/// *not* gated on the surviving PIN/biometric: a user who forgot the PIN must
/// still be able to start over with the phrase.
class WalletRecoveryScreen extends StatefulWidget {
  const WalletRecoveryScreen({super.key, this.resetService});

  /// Test seam; production builds the service from the locator.
  @visibleForTesting
  final AppResetService? resetService;

  @override
  State<WalletRecoveryScreen> createState() => _WalletRecoveryScreenState();
}

class _WalletRecoveryScreenState extends State<WalletRecoveryScreen> {
  bool _isLoading = false;

  /// Start fresh was tapped: the gate (copy + checkbox + armed button) is shown.
  bool _showEraseGate = false;
  bool _phraseSavedConfirmed = false;

  /// Set after a restore aborted; shown above the buttons until the next try.
  String? _restoreError;

  /// The abort itself, kept so the partial-restore offer can be shown only
  /// when something on this device actually is readable.
  RestoreAborted? _aborted;

  Future<void> _restoreWallet({bool readableOnly = false}) async {
    setState(() {
      _isLoading = true;
      _restoreError = null;
      _aborted = null;
    });

    try {
      final storage = sl<SecureWalletStorage>();
      final authNotifier = sl<AuthStateNotifier>();
      final walletRepo = sl<WalletRepository>();
      // The app-provided AppLock instance (a factory in DI — read the one
      // wired into the widget tree, not a fresh sl() instance).
      final appLock = context.read<AppLockBloc>();

      bool restored = false;

      // Try graph-first recovery (full multi-account restore)
      final graphJson = await storage.loadAccountGraph();
      if (graphJson != null && graphJson.isNotEmpty) {
        final result = await walletRepo.restoreFromGraph(
          graphJson,
          readableOnly: readableOnly,
        );
        switch (result) {
          case RestoreRestored():
            restored = true;
            if (readableOnly) {
              // The entries it skipped are still in the graph and still on
              // this device; the boot restore retries them at every launch.
              await SentryService.captureMessage(
                'restore (readable only): ${result.seedPhrases} seeds, '
                '${result.wallets} wallets restored; '
                '${result.skippedSeedPhrases} seeds, '
                '${result.skippedImportedKeys} keys skipped',
              );
            }
          case RestoreAborted():
            // Nothing was written. A persistent miss means the phrase is the
            // way back; a transient one clears on the next try.
            await SentryService.captureMessage(
              'restore aborted: ${result.missingSeedPhrases}/'
              '${result.totalSeedPhrases} seeds, '
              '${result.missingImportedKeys}/${result.totalImportedKeys} '
              'imported keys unreadable',
              level: SentryLevel.error,
            );
            if (mounted) {
              setState(() {
                _isLoading = false;
                _restoreError = _abortMessage(result);
                _aborted = result;
              });
            }
            return;
          case RestoreFailed():
            // Parse or write failure (rolled back). Fall through to the legacy
            // single-mnemonic path, which is what an old install has.
            restored = false;
        }
      }

      // Fall back to legacy mnemonic recovery
      if (!restored) {
        final mnemonic = await storage.loadMnemonic();
        if (mnemonic == null || mnemonic.isEmpty) {
          if (mounted) {
            AppSnackBar.show(context, 'No wallet data found');
          }
          setState(() => _isLoading = false);
          return;
        }

        await walletRepo.createSeedPhrase(mnemonic);
      }

      authNotifier.clearStaleKeychain();
      authNotifier.onWalletCreated();
      await authNotifier.onOnboardingCompleted();

      // Re-arm the app lock against the now-restored wallet. On a reinstall the
      // PIN hash and biometric flag survive in the Keychain but AppLock booted
      // into `noPinSet` (unlocked) because the DB was empty at cold start.
      // Re-running init now that the DB holds a wallet re-evaluates those
      // surviving credentials and emits `locked`, so the user must clear the
      // PIN/biometric gate before reaching the wallet — restoring is not itself
      // proof of authentication. This also re-establishes background locking.
      appLock.add(const AppLockEvent.init());

      if (mounted) context.go(AppRoutes.home);
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, 'Restore failed: $e');
        setState(() => _isLoading = false);
      }
    }
  }

  static String _abortMessage(RestoreAborted result) {
    final parts = <String>[
      if (result.missingSeedPhrases > 0)
        '${result.missingSeedPhrases} of ${result.totalSeedPhrases} seed '
            'phrase${result.totalSeedPhrases == 1 ? '' : 's'}',
      if (result.missingImportedKeys > 0)
        '${result.missingImportedKeys} of ${result.totalImportedKeys} imported '
            'key${result.totalImportedKeys == 1 ? '' : 's'}',
    ];
    // The partial restore is offered only when something is readable (see the
    // button below), so the copy names it only then — an abort with nothing
    // readable would otherwise send the user looking for a button this screen
    // is deliberately withholding.
    final ways = result.hasReadable
        ? 'Try again, restore only what can be read (the rest stays on this '
              'device and is retried at each launch), or start fresh and '
              'import your recovery phrase.'
        : 'Try again, or start fresh and import your recovery phrase.';
    return 'Some wallet data on this device could not be read '
        '(${parts.join(', ')}). Nothing was changed. $ways';
  }

  Future<void> _startFresh() async {
    setState(() => _isLoading = true);

    final authNotifier = sl<AuthStateNotifier>();
    // The app-provided AppLock instance (a factory in DI — read the one wired
    // into the widget tree, not a fresh sl() instance).
    final appLock = context.read<AppLockBloc>();

    // The same factory reset as Settings → Reset app: secrets by enumeration
    // (the graph is gone after this, so anything not swept now would stay in
    // the Keychain forever), database file, preferences, analytics identity.
    // Best-effort; a partial failure is reported but still routes to Welcome.
    final resetService = widget.resetService ?? AppResetService.fromLocator();
    final failures = await resetService.resetApp(
      reason: ResetReason.startFresh,
    );

    // Drop the in-memory lock state, whatever the wipe reported. The PIN hash
    // the bloc verifies against was just deleted, so a bloc still holding
    // `unlocked(hasPin: true)` raises the LockScreen overlay on the next
    // background and no PIN can clear it. A half-wiped device must not keep a
    // live unlocked state either, so this runs before the failure check.
    appLock.add(const AppLockEvent.reset());

    if (mounted && failures.isNotEmpty) {
      AppSnackBar.show(
        context,
        'Some data could not be erased. Please try again.',
        type: AppSnackBarType.error,
      );
    }

    authNotifier.clearStaleKeychain();
    // Best-effort by contract: the logout drops its in-memory flags and
    // notifies the router whatever the onboarding-flag delete does, so the
    // wiped device always reaches Welcome below.
    await authNotifier.onLogout();

    if (mounted) context.go(AppRoutes.welcome);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(
            left: MallowTheme.spacingLg,
            right: MallowTheme.spacingLg,
            top: MallowTheme.spacingLg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(flex: 2),
              SvgPicture.asset(
                'assets/icons/mallow_icon.svg',
                width: 41,
                colorFilter: ColorFilter.mode(
                  colors.textPrimary,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              Text(
                'Welcome back',
                style: GoogleFonts.newsreader(
                  fontSize: 28,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w500,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              Text(
                'We found a previous wallet on this device. '
                'Would you like to restore it or start fresh?',
                style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
              ),
              if (_restoreError != null) ...[
                const SizedBox(height: MallowTheme.spacingMd),
                Text(
                  _restoreError!,
                  style: MallowTheme.uiMeta.copyWith(color: colors.error),
                ),
              ],
              const Spacer(flex: 3),
              if (_isLoading)
                const Center(child: MallowLoader())
              else if (_showEraseGate)
                _buildEraseGate(colors)
              else ...[
                MallowButton(
                  label: _restoreError == null ? 'Restore wallet' : 'Try again',
                  onPressed: _restoreWallet,
                  isFullWidth: true,
                ),
                // Offered only after an abort, and only when something is
                // readable: the all-or-nothing rule is right by default, but
                // one unreadable entry otherwise blocks every restore forever
                // and the only other action erases the readable seeds too.
                if (_aborted?.hasReadable ?? false) ...[
                  const SizedBox(height: 12),
                  MallowButton(
                    label: 'Restore what can be read',
                    onPressed: () => _restoreWallet(readableOnly: true),
                    variant: MallowButtonVariant.secondary,
                    isFullWidth: true,
                  ),
                ],
                const SizedBox(height: 12),
                MallowButton(
                  label: 'Start fresh',
                  onPressed: () => setState(() => _showEraseGate = true),
                  variant: MallowButtonVariant.secondary,
                  isFullWidth: true,
                ),
              ],
              SizedBox(height: 32 + MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  /// The in-place confirmation Start fresh expands into. Two deliberate
  /// gestures (check, then tap a button that is disabled until checked) stand
  /// between the user and an irreversible wipe; Cancel collapses it.
  Widget _buildEraseGate(MallowColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Erasing removes the stored wallet data from this device. After '
          'that it can only be recovered with its recovery phrase.',
          style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        MallowCheckbox(
          value: _phraseSavedConfirmed,
          onChanged: (v) => setState(() => _phraseSavedConfirmed = v),
          label: 'I have my recovery phrase saved',
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        // Same armed destructive button as Settings → Reset app: dimmed and
        // inert until the checkbox is ticked.
        Semantics(
          button: true,
          enabled: _phraseSavedConfirmed,
          label: 'Erase and start fresh',
          child: GestureDetector(
            onTap: _phraseSavedConfirmed ? _startFresh : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 48,
              decoration: BoxDecoration(
                color: _phraseSavedConfirmed
                    ? colors.error
                    : colors.error.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
              ),
              alignment: Alignment.center,
              child: Text(
                'Erase and start fresh',
                style: MallowTheme.uiBody.copyWith(color: colors.textOnAccent),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        MallowButton(
          label: 'Cancel',
          onPressed: () => setState(() {
            _showEraseGate = false;
            _phraseSavedConfirmed = false;
          }),
          variant: MallowButtonVariant.text,
          isFullWidth: true,
        ),
      ],
    );
  }
}
