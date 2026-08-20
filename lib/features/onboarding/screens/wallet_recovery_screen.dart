import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/security/app_lock_bloc.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';

/// Recovery screen shown when iOS Keychain has a recoverable mnemonic but the
/// database was wiped (uninstall + reinstall). Lets the user restore or start
/// fresh. Only shown when a legacy mnemonic exists — otherwise the notifier
/// auto-clears stale Keychain data and sends the user to onboarding.
class WalletRecoveryScreen extends StatefulWidget {
  const WalletRecoveryScreen({super.key});

  @override
  State<WalletRecoveryScreen> createState() => _WalletRecoveryScreenState();
}

class _WalletRecoveryScreenState extends State<WalletRecoveryScreen> {
  bool _isLoading = false;

  Future<void> _restoreWallet() async {
    setState(() => _isLoading = true);

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
        restored = await walletRepo.restoreFromGraph(graphJson);
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

  Future<void> _startFresh() async {
    setState(() => _isLoading = true);

    try {
      final storage = sl<SecureWalletStorage>();
      final authNotifier = sl<AuthStateNotifier>();

      await storage.clearAll();

      authNotifier.clearStaleKeychain();
      await authNotifier.onLogout();

      if (mounted) context.go(AppRoutes.welcome);
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, 'Reset failed: $e');
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
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
                  context.mallowColors.textPrimary,
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
                  color: context.mallowColors.textPrimary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              Text(
                'We found a previous wallet on this device. '
                'Would you like to restore it or start fresh?',
                style: MallowTheme.uiBody.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              Text(
                'Starting fresh will permanently erase the stored wallet data.',
                style: MallowTheme.uiMeta.copyWith(
                  color: context.mallowColors.textSecondary.withValues(
                    alpha: 0.7,
                  ),
                ),
              ),
              const Spacer(flex: 3),
              if (_isLoading)
                const Center(child: MallowLoader())
              else ...[
                MallowButton(
                  label: 'Restore wallet',
                  onPressed: _restoreWallet,
                  isFullWidth: true,
                ),
                const SizedBox(height: 12),
                MallowButton(
                  label: 'Start fresh',
                  onPressed: _startFresh,
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
}
