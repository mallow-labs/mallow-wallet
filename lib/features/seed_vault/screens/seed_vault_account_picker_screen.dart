import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../accounts/models/picker_account.dart';
import '../../accounts/widgets/account_picker_card.dart';
import '../../accounts/widgets/import_settings_sheet.dart';
import '../services/seed_vault_connect_bloc.dart';

/// Inline view for selecting which Seed Vault accounts to import.
///
/// Mirrors the seed-phrase and Ledger import layouts: one account card per
/// derivation index ("Account NN") holding its Solana rows — standard always,
/// plus legacy behind the gear-sheet toggle.
///
/// There is no "Show more". Every card here comes from a path Seed Vault
/// already pre-derived, which is why enumerating them costs no approval;
/// reaching further would mean asking the vault to derive a new path, and that
/// can raise a password prompt.
///
/// Expects a [SeedVaultConnectBloc] in the widget tree.
class SeedVaultAccountPickerView extends StatelessWidget {
  const SeedVaultAccountPickerView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: BlocBuilder<SeedVaultConnectBloc, SeedVaultConnectState>(
            builder: (context, state) {
              if (state is SeedVaultImporting) {
                return const Center(child: MallowLoader());
              }
              if (state is! SeedVaultAccountsLoaded) {
                return const SizedBox.shrink();
              }

              final selectedKeys = state.selectedKeys;
              final names = previewAccountNames(
                accounts: state.accounts,
                selectedKeys: selectedKeys,
                baseCounter: state.baseCounter,
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  MallowHeader(
                    title: 'Select accounts',
                    actions: [
                      _SettingsButton(includeLegacy: state.includeLegacy),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Choose which accounts to import from Seed Vault. The keys '
                    'stay in Seed Vault — mallow never sees them.',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView.builder(
                      itemCount: state.accounts.length,
                      itemBuilder: (context, index) {
                        final account = state.accounts[index];
                        return AccountPickerCard(
                          account: account,
                          displayName: names[account.index] ?? 'Account',
                          selectedKeys: selectedKeys,
                          onToggleWallet: (key) => context
                              .read<SeedVaultConnectBloc>()
                              .add(SeedVaultToggleWallet(key)),
                          onToggleAccount: (i) => context
                              .read<SeedVaultConnectBloc>()
                              .add(SeedVaultToggleAccount(i)),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  MallowButton(
                    label: selectedKeys.isEmpty
                        ? 'Select accounts'
                        : 'Import ${selectedKeys.length} account${selectedKeys.length == 1 ? '' : 's'}',
                    onPressed: selectedKeys.isEmpty
                        ? null
                        : () => context.read<SeedVaultConnectBloc>().add(
                            const SeedVaultImportRequested(),
                          ),
                    isFullWidth: true,
                    enabled: selectedKeys.isNotEmpty,
                  ),
                  const SizedBox(height: 32),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Gear button — opens the shared import settings sheet to toggle the legacy
/// Solana derivation-path rows.
///
/// Root is not offered here and has no toggle: Seed Vault does not pre-derive
/// the index-less root path, so a root card would cost a password prompt for an
/// account almost nobody has.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.includeLegacy});

  final bool includeLegacy;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showImportSettingsSheet(
          context,
          includeLegacy: includeLegacy,
          onChanged: (v) => context.read<SeedVaultConnectBloc>().add(
            SeedVaultSetIncludeLegacy(v),
          ),
        ),
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: MallowSvgIcon(
            'assets/icons/settings.svg',
            width: 24,
            height: 24,
          ),
        ),
      ),
    );
  }
}
