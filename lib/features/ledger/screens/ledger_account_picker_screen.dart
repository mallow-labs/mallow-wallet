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
import '../services/ledger_connect_bloc.dart';

import '../../../shared/utils/chain.dart';

/// Number of skeleton cards shown while the first batch of addresses derives.
const _kInitialSkeletonCount = 5;

/// Inline view for selecting which Ledger-derived accounts to import.
///
/// Mirrors the seed-phrase import layout: one account card per derivation index
/// ("Account NN") holding its Solana rows — standard always, plus legacy/root
/// behind the gear-sheet toggle — with a single "Show more" at the bottom.
///
/// Expects a [LedgerConnectBloc] in the widget tree (provided by
/// [LedgerScanScreen]'s BlocProvider).
class LedgerAccountPickerView extends StatefulWidget {
  const LedgerAccountPickerView({super.key});

  @override
  State<LedgerAccountPickerView> createState() =>
      _LedgerAccountPickerViewState();
}

class _LedgerAccountPickerViewState extends State<LedgerAccountPickerView> {
  /// Cache the last-loaded cards so the list stays visible during re-derivation.
  List<PickerAccount> _lastAccounts = const [];

  /// Cache the global-counter base alongside the cards, for the live preview.
  int _baseCounter = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: BlocBuilder<LedgerConnectBloc, LedgerConnectState>(
            builder: (context, state) {
              final isLoading = state.maybeWhen(
                loadingAccounts: (_) => true,
                orElse: () => false,
              );
              final isImporting = state.maybeWhen(
                importing: () => true,
                orElse: () => false,
              );

              if (isImporting) {
                return const Center(child: MallowLoader());
              }

              // Update cached data when cards arrive.
              state.maybeWhen(
                accountsLoaded: (device, accounts, includeLegacy, _, _, base) {
                  _lastAccounts = accounts;
                  _baseCounter = base;
                },
                orElse: () {},
              );

              final accounts = _lastAccounts;
              final selectedKeys = state.maybeWhen(
                accountsLoaded: (_, _, _, sel, _, _) => sel,
                orElse: () => const <String>{},
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  MallowHeader(
                    title: 'Select accounts',
                    actions: [_SettingsButton(state: state)],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Choose which accounts to import from your Ledger.',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: isLoading && accounts.isEmpty
                        ? ListView.builder(
                            itemCount: _kInitialSkeletonCount,
                            itemBuilder: (context, _) =>
                                const SkeletonAccountCard(),
                          )
                        : _buildAccountList(
                            context,
                            accounts,
                            selectedKeys,
                            isLoading,
                          ),
                  ),
                  const SizedBox(height: 16),
                  MallowButton(
                    label: selectedKeys.isEmpty
                        ? 'Select accounts'
                        : 'Import ${selectedKeys.length} account${selectedKeys.length == 1 ? '' : 's'}',
                    onPressed: selectedKeys.isEmpty
                        ? null
                        : () {
                            context.read<LedgerConnectBloc>().add(
                              const LedgerConnectEvent.importAccounts(),
                            );
                          },
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

  Widget _buildAccountList(
    BuildContext context,
    List<PickerAccount> accounts,
    Set<String> selectedKeys,
    bool isLoading,
  ) {
    final names = previewAccountNames(
      accounts: accounts,
      selectedKeys: selectedKeys,
      baseCounter: _baseCounter,
    );
    // While re-deriving with cards already on screen, append one skeleton card
    // to signal the next batch is loading; "Show more" sits at the very bottom.
    final extraSkeletons = isLoading ? 1 : 0;
    final total = accounts.length + extraSkeletons + 1;

    return ListView.builder(
      itemCount: total,
      itemBuilder: (context, index) {
        if (index == total - 1) {
          return ShowMoreRow(
            enabled: !isLoading,
            onTap: () => context.read<LedgerConnectBloc>().add(
              const LedgerConnectEvent.showMore(),
            ),
          );
        }
        if (index >= accounts.length) {
          return const SkeletonAccountCard();
        }
        return AccountPickerCard(
          account: accounts[index],
          displayName: names[accounts[index].index] ?? 'Account',
          selectedKeys: selectedKeys,
          onToggleWallet: (key) => context.read<LedgerConnectBloc>().add(
            LedgerConnectEvent.toggleWallet(key),
          ),
          onToggleAccount: (i) => context.read<LedgerConnectBloc>().add(
            LedgerConnectEvent.toggleAccount(i),
          ),
        );
      },
    );
  }
}

/// Gear button — opens the shared import settings sheet to toggle the
/// legacy/root Solana derivation-path cards.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.state});

  final LedgerConnectState state;

  @override
  Widget build(BuildContext context) {
    final loaded = state is LedgerAccountsLoaded
        ? state as LedgerAccountsLoaded
        : null;
    // Legacy/root derivation paths are a Solana-only concept; the Ethereum
    // app derives a single standard path, so there is nothing to configure.
    if (loaded != null && loaded.chain != Chain.solana) {
      return const SizedBox.shrink();
    }
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: loaded == null
            ? null
            : () => showImportSettingsSheet(
                context,
                includeLegacy: loaded.includeLegacy,
                onChanged: (v) => context.read<LedgerConnectBloc>().add(
                  LedgerConnectEvent.setIncludeLegacy(v),
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
