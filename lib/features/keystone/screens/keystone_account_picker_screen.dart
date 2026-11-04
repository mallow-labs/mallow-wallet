import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/services/keystone_sign_service.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../accounts/models/picker_account.dart';
import '../../accounts/widgets/account_picker_card.dart';
import '../services/keystone_connect_bloc.dart';

/// Inline view for choosing which accounts of the scanned Keystone codes to
/// import.
///
/// The same account-card layout as the seed-phrase, Ledger and Seed Vault
/// pickers: one card per derivation index, holding that index's Solana rows.
/// Every row the export holds is shown — see [KeystoneConnectBloc] for why
/// there is no legacy toggle.
///
/// Expects a [KeystoneConnectBloc] in the widget tree.
class KeystoneAccountPickerView extends StatelessWidget {
  const KeystoneAccountPickerView({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: BlocBuilder<KeystoneConnectBloc, KeystoneConnectState>(
            builder: (context, state) {
              if (state is KeystoneImporting) {
                return const Center(child: MallowLoader());
              }
              if (state is! KeystoneAccountsLoaded) {
                return const SizedBox.shrink();
              }

              final bloc = context.read<KeystoneConnectBloc>();
              final selectedKeys = state.selectedKeys;
              final names = previewAccountNames(
                accounts: state.accounts,
                selectedKeys: selectedKeys,
                baseCounter: state.baseCounter,
                customNames: state.customNames,
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  const MallowHeader(title: 'Select accounts'),
                  const SizedBox(height: 8),
                  Text(
                    'Choose which accounts to import from Keystone '
                    '${formatMasterFingerprint(state.masterFingerprint)}. '
                    'The keys stay on the device.',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
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
                          onToggleWallet: (key) =>
                              bloc.add(KeystoneToggleWallet(key)),
                          onToggleAccount: (i) =>
                              bloc.add(KeystoneToggleAccount(i)),
                          onRename: (name) => bloc.add(
                            KeystoneRenameAccount(account.index, name),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  MallowButton(
                    label: selectedKeys.isEmpty
                        ? 'Select accounts'
                        : 'Import ${selectedKeys.length} '
                              'account${selectedKeys.length == 1 ? '' : 's'}',
                    onPressed: selectedKeys.isEmpty
                        ? null
                        : () => bloc.add(const KeystoneImportRequested()),
                    isFullWidth: true,
                    enabled: selectedKeys.isNotEmpty,
                  ),
                  const SizedBox(height: 8),
                  MallowButton(
                    label: 'Scan another code',
                    variant: MallowButtonVariant.text,
                    isFullWidth: true,
                    onPressed: () =>
                        bloc.add(const KeystoneScanAnotherRequested()),
                  ),
                  const SizedBox(height: 24),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
