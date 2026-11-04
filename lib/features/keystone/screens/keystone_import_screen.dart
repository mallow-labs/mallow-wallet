import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:keystone_ur/keystone_ur.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/token_repository.dart';
import '../services/keystone_connect_bloc.dart';
import '../widgets/ur_scanner_view.dart';
import 'keystone_account_picker_screen.dart';

/// Import wallets from a Keystone by scanning the codes it shows.
///
/// Hosts the flow's [KeystoneConnectBloc]: the scanner with instructions
/// first, then the account picker once a code decodes, and back to the scanner
/// for each further code the user scans.
class KeystoneImportScreen extends StatelessWidget {
  const KeystoneImportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => KeystoneConnectBloc(
        sl<WalletRepository>(),
        sl<TokenRepository>(),
        sl<PortfolioRepository>(),
      ),
      child: const _KeystoneFlowBody(),
    );
  }
}

class _KeystoneFlowBody extends StatelessWidget {
  const _KeystoneFlowBody();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<KeystoneConnectBloc, KeystoneConnectState>(
      listener: (context, state) {
        if (state is KeystoneImported) {
          final authNotifier = sl<AuthStateNotifier>();
          if (!authNotifier.hasCompletedOnboarding) {
            authNotifier.onWalletCreated();
            context.go(AppRoutes.biometricSetup);
          } else {
            sl<WalletManager>().notifyWalletDataChanged();
            AppSnackBar.show(context, 'Wallet imported');
            DrawerSignal.showAccountsOnNextOpen = true;
            context.go(AppRoutes.home);
          }
        } else if (state is KeystoneConnectError) {
          AppSnackBar.show(context, state.message);
          context.read<KeystoneConnectBloc>().add(
            const KeystoneRescanRequested(),
          );
        }
      },
      builder: (context, state) => switch (state) {
        KeystoneAccountsLoaded() ||
        KeystoneImporting() ||
        // The page stays mounted during its exit; success must not restart
        // the camera while navigation is completing.
        KeystoneImported() => const KeystoneAccountPickerView(),
        final KeystoneScanning scanning => _ScanView(state: scanning),
        KeystoneConnectError() => const _ScanView(state: KeystoneScanning()),
      },
    );
  }
}

/// Instructions and the scanner for the device's codes.
class _ScanView extends StatelessWidget {
  const _ScanView({required this.state});

  final KeystoneScanning state;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bloc = context.read<KeystoneConnectBloc>();
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const MallowHeader(title: 'Keystone'),
              const SizedBox(height: 16),
              const _Steps(),
              const SizedBox(height: 20),
              UrScannerView(
                // Reset even for the same refusal, keeping the camera alive.
                generation: state.generation,
                expectedTypes: kKeystoneImportTypes,
                error: state.error,
                hint:
                    state.notice ??
                    'Point the camera at the code on your Keystone.',
                unexpectedTypeError:
                    "That's not a Keystone account code. On your Keystone, "
                    'open Connect Software Wallet and choose Solflare or '
                    'MetaMask.',
                onScanned: (UR ur) async {
                  bloc.add(KeystoneExportScanned(ur));
                  return null;
                },
              ),
              const SizedBox(height: 20),
              Text(
                'Your keys stay on the Keystone. mallow only reads the public '
                'addresses, and every transaction is signed on the device.',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              if (state.error != null) ...[
                const SizedBox(height: 16),
                MallowButton(
                  label: 'Scan again',
                  variant: MallowButtonVariant.secondary,
                  isFullWidth: true,
                  // Clears the refusal and keeps the codes already scanned.
                  onPressed: () =>
                      bloc.add(const KeystoneScanAnotherRequested()),
                ),
              ],
              if (state.canReturn) ...[
                const SizedBox(height: 8),
                MallowButton(
                  label: 'Back to accounts',
                  variant: MallowButtonVariant.secondary,
                  isFullWidth: true,
                  onPressed: () =>
                      bloc.add(const KeystoneBackToAccountsRequested()),
                ),
              ],
              if (state.canStartOver) ...[
                const SizedBox(height: 8),
                MallowButton(
                  label: 'Start over',
                  variant: MallowButtonVariant.text,
                  isFullWidth: true,
                  onPressed: () => bloc.add(const KeystoneRescanRequested()),
                ),
              ],
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// How to get a code onto the Keystone's screen.
///
/// Names Solflare because the device has no generic entry, and Solflare's
/// entry exports the standard Solana path (`m/44'/501'/i'/0'`) — the one every
/// other wallet uses. Other entries default to the legacy path; the import
/// accepts those too, it just shows them as legacy accounts.
///
/// Backpack's code carries both chains. Solflare's carries no Ethereum key
/// and MetaMask's no Solana accounts, so with those Ethereum is a second code;
/// codes can be scanned in either order.
class _Steps extends StatelessWidget {
  const _Steps();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final style = MallowTheme.uiBodyRelaxed.copyWith(
      color: colors.textSecondary,
    );
    const steps = [
      'Unlock your Keystone and tap Connect Software Wallet.',
      'For Solana, choose Solflare or Backpack. For Ethereum, choose '
          'MetaMask or Backpack.',
      'Scan the code your Keystone shows. You can scan the other one after '
          'it.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('${i + 1}. $step', style: style),
          ),
      ],
    );
  }
}
