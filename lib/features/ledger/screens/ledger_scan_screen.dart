import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/services/ledger_service.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/token_repository.dart';
import '../../../shared/widgets/loading_indicator.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../services/ledger_connect_bloc.dart';
import 'ledger_account_picker_screen.dart';

/// Screen for discovering, connecting, and importing Ledger wallets.
///
/// Manages the full flow: scan -> connect -> pick accounts -> import.
/// The BLoC is scoped here so all child widgets can access it.
class LedgerScanScreen extends StatelessWidget {
  const LedgerScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => LedgerConnectBloc(
        sl<LedgerService>(),
        sl<WalletRepository>(),
        sl<TokenRepository>(),
        sl<PortfolioRepository>(),
        sl<PreferencesService>(),
      )..add(const LedgerConnectEvent.startScan()),
      child: const _LedgerFlowBody(),
    );
  }
}

class _LedgerFlowBody extends StatelessWidget {
  const _LedgerFlowBody();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<LedgerConnectBloc, LedgerConnectState>(
      listener: (context, state) {
        state.whenOrNull(
          connected: (_) {
            context.read<LedgerConnectBloc>().add(
              const LedgerConnectEvent.loadAccounts(),
            );
          },
          imported: (_) {
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
          },
          error: (message) {
            AppSnackBar.show(context, message);
          },
        );
      },
      builder: (context, state) {
        // Show account picker for all post-connection states.
        final showPicker = state.maybeWhen(
          accountsLoaded: (_, _, _, _, _, _) => true,
          loadingAccounts: (_) => true,
          importing: () => true,
          orElse: () => false,
        );
        if (showPicker) return const LedgerAccountPickerView();
        return _ScanView(state: state);
      },
    );
  }
}

/// The scan/connect portion of the flow.
class _ScanView extends StatelessWidget {
  const _ScanView({required this.state});
  final LedgerConnectState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const MallowHeader(title: 'Connect Ledger'),
              const SizedBox(height: 24),
              Text(
                'Make sure Bluetooth is enabled and the Solana, Ethereum, or Tezos app is open on your Ledger.',
                style: MallowTheme.uiBodyRelaxed.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              state.when(
                initial: () => const SizedBox.shrink(),
                scanning: (devices, active) => _DeviceList(
                  devices: devices,
                  active: active,
                  onRescan: () => context.read<LedgerConnectBloc>().add(
                    const LedgerConnectEvent.startScan(),
                  ),
                ),
                connecting: (device) =>
                    _ConnectingIndicator(label: device.name),
                connected: (_) =>
                    const _ConnectingIndicator(label: 'Loading accounts...'),
                loadingAccounts: (_) => const _ConnectingIndicator(
                  label: 'Discovering accounts...',
                ),
                accountsLoaded: (_, _, _, _, _, _) => const SizedBox.shrink(),
                importing: () =>
                    const _ConnectingIndicator(label: 'Importing...'),
                imported: (_) => const SizedBox.shrink(),
                error: (_) => _RetryButton(
                  onTap: () {
                    context.read<LedgerConnectBloc>().add(
                      const LedgerConnectEvent.startScan(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.devices,
    required this.active,
    required this.onRescan,
  });
  final List<LedgerDevice> devices;
  final bool active;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Center(
          child: Column(
            children: [
              if (active) ...[
                const MallowLoader(size: 24),
                const SizedBox(height: 16),
                Text(
                  'Searching for devices...',
                  style: MallowTheme.uiBody.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              ] else ...[
                Text(
                  'No devices found.',
                  style: MallowTheme.uiBody.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                _RetryButton(onTap: onRescan),
              ],
            ],
          ),
        ),
      );
    }

    return Expanded(
      child: Column(
        children: [
          Expanded(
            child: ListView.separated(
              itemCount: devices.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final device = devices[index];
                return GestureDetector(
                  onTap: () {
                    context.read<LedgerConnectBloc>().add(
                      LedgerConnectEvent.connectDevice(device),
                    );
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: context.mallowColors.bgSurface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        MallowSvgIcon(
                          'assets/icons/bluetooth.svg',
                          width: 20,
                          height: 20,
                          color: context.mallowColors.textSecondary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            device.name,
                            style: MallowTheme.uiBody.copyWith(
                              fontWeight: FontWeight.w500,
                              color: context.mallowColors.textPrimary,
                            ),
                          ),
                        ),
                        MallowSvgIcon(
                          'assets/icons/arrow_right.svg',
                          width: 20,
                          height: 20,
                          color: context.mallowColors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (!active)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _RetryButton(onTap: onRescan),
            ),
        ],
      ),
    );
  }
}

class _ConnectingIndicator extends StatelessWidget {
  const _ConnectingIndicator({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Center(
        child: Column(
          children: [
            const MallowLoader(size: 24),
            const SizedBox(height: 16),
            Text(
              label,
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        onPressed: onTap,
        child: Text(
          'Retry scan',
          style: MallowTheme.uiBody.copyWith(
            fontWeight: FontWeight.w500,
            color: context.mallowColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
