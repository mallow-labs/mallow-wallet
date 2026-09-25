import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/seed_vault_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/permission_settings_sheet.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/token_repository.dart';
import '../services/seed_vault_connect_bloc.dart';
import 'seed_vault_account_picker_screen.dart';

/// Import wallets held in the device's Seed Vault.
///
/// Hosts the flow's [SeedVaultConnectBloc] and renders whichever gate the flow
/// is currently stuck on — availability, permission, approval — or the account
/// picker once accounts are enumerated.
class SeedVaultImportScreen extends StatelessWidget {
  const SeedVaultImportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SeedVaultConnectBloc(
        sl<SeedVaultService>(),
        sl<WalletRepository>(),
        sl<TokenRepository>(),
        sl<PortfolioRepository>(),
        sl<PreferencesService>(),
      )..add(const SeedVaultStarted()),
      child: const _SeedVaultFlowBody(),
    );
  }
}

class _SeedVaultFlowBody extends StatelessWidget {
  const _SeedVaultFlowBody();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SeedVaultConnectBloc, SeedVaultConnectState>(
      listener: (context, state) {
        if (state is SeedVaultImported) {
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
        } else if (state is SeedVaultConnectError) {
          AppSnackBar.show(context, state.message);
        }
      },
      builder: (context, state) {
        if (state is SeedVaultAccountsLoaded || state is SeedVaultImporting) {
          return const SeedVaultAccountPickerView();
        }
        return _GateView(state: state);
      },
    );
  }
}

/// Everything before the picker: the loader and the two dead ends the flow can
/// legitimately reach.
class _GateView extends StatelessWidget {
  const _GateView({required this.state});

  final SeedVaultConnectState state;

  void _retry(BuildContext context) =>
      context.read<SeedVaultConnectBloc>().add(const SeedVaultStarted());

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
              const MallowHeader(title: 'Seed Vault'),
              const SizedBox(height: 24),
              Expanded(child: _body(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final colors = context.mallowColors;
    return switch (state) {
      SeedVaultUnavailable() => const _Message(
        text:
            'This device does not have Seed Vault, so there is nothing to '
            'import from it.',
      ),
      SeedVaultPermissionDenied() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'mallow needs access to Seed Vault to read the accounts it holds. '
            'The keys never leave Seed Vault.',
            style: MallowTheme.uiBodyRelaxed.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          MallowButton(
            label: 'Open Settings',
            isFullWidth: true,
            // The channel answers `false` for both a fresh refusal and a
            // permanent one, so the settings hand-off is offered either way —
            // a permanently denied permission cannot be re-requested, and
            // guessing wrong would leave the user on a dead end.
            onPressed: () =>
                showPermissionSettingsSheet(context, AppPermission.seedVault),
          ),
          const SizedBox(height: 12),
          MallowButton(
            label: 'Try again',
            variant: MallowButtonVariant.secondary,
            isFullWidth: true,
            onPressed: () => _retry(context),
          ),
        ],
      ),
      SeedVaultConnectError(:final message) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: MallowTheme.uiBodyRelaxed.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          MallowButton(
            label: 'Try again',
            isFullWidth: true,
            onPressed: () => _retry(context),
          ),
        ],
      ),
      _ => const Center(child: MallowLoader(size: 24)),
    };
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: MallowTheme.uiBodyRelaxed.copyWith(
      color: context.mallowColors.textSecondary,
    ),
  );
}
