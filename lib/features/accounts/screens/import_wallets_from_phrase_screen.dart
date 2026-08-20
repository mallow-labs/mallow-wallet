import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/account.dart';
import '../../../core/router/app_router.dart';
import '../../../core/security/redacted.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../home/widgets/drawer_signal.dart';
import '../services/import_wallets_bloc.dart';
import '../widgets/account_picker_card.dart';
import '../widgets/import_settings_sheet.dart';

import '../../../shared/utils/chain.dart';

/// Number of skeleton account cards shown while the first batch of addresses
/// derives — matches the first derivation batch size for a smooth handoff.
const _kInitialSkeletonCount = 5;

/// Multi-chain account picker — one card per derivation index, each with its
/// Solana / Tezos / Ethereum wallet rows (and legacy Solana rows when enabled).
class ImportWalletsFromPhraseScreen extends StatelessWidget {
  const ImportWalletsFromPhraseScreen({
    this.seedPhraseId,
    this.mnemonic,
    super.key,
  }) : assert(
         seedPhraseId != null || mnemonic != null,
         'Either seedPhraseId or mnemonic must be provided',
       );

  /// Existing seed phrase ID (for adding wallets to an existing seed phrase).
  final String? seedPhraseId;

  /// Raw mnemonic (for new seed phrases — persisted only on import).
  final String? mnemonic;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final bloc = sl<ImportWalletsBloc>();
        if (mnemonic != null) {
          bloc.add(ImportWalletsEvent.loadFromMnemonic(Redacted(mnemonic!)));
        } else {
          bloc.add(ImportWalletsEvent.loadAddresses(seedPhraseId!));
        }
        return bloc;
      },
      child: const _ImportWalletsBody(),
    );
  }
}

class _ImportWalletsBody extends StatelessWidget {
  const _ImportWalletsBody();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: BlocConsumer<ImportWalletsBloc, ImportWalletsState>(
            listener: (context, state) {
              state.maybeWhen(
                imported: (wallets) {
                  AppSnackBar.show(
                    context,
                    'Imported ${wallets.length} wallet(s)',
                  );
                  DrawerSignal.showAccountsOnNextOpen = true;
                  _switchToFirstImported(context, wallets);
                },
                orElse: () {},
              );
            },
            builder: (context, state) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  MallowHeader(
                    title: 'Import wallets from phrase',
                    actions: [_SettingsButton(state: state)],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Select the accounts you wish to import',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(child: _buildList(context, state)),
                  const SizedBox(height: 16),
                  _buildImportButton(context, state),
                  const SizedBox(height: 32),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Make the first just-imported account the active session before returning
  /// home, so the user lands on what they imported rather than the previously
  /// active account. Falls back to a plain navigation when there's nothing to
  /// switch to (e.g. every selection was already imported).
  void _switchToFirstImported(BuildContext context, List<WalletInfo> wallets) {
    final router = GoRouter.of(context);
    final session = sl<SessionManager>();
    final firstAccountId = wallets.isEmpty ? null : wallets.first.accountId;
    // Nothing to switch to, or the active Profile already contains one of the
    // just-imported wallets (e.g. a read-only linked wallet now imported for
    // real) — keep the user where they are instead of switching accounts.
    if (firstAccountId == null ||
        session.activeProfileContainsAnyAddress(
          wallets.map((w) => w.address),
        )) {
      router.go(AppRoutes.home);
      return;
    }
    // Results are ordered Solana-first within each account, so prefer the
    // first account's Solana wallet as the signer — a multi-Solana account
    // then won't prompt the picker for this implicit switch.
    final preferred = wallets.firstWhere(
      (w) => w.accountId == firstAccountId && w.chainEnum == Chain.solana,
      orElse: () => wallets.first,
    );
    session
        .switchToAccount(
          firstAccountId,
          preferredWalletId: preferred.chainEnum == Chain.solana
              ? preferred.id
              : null,
        )
        .whenComplete(() => router.go(AppRoutes.home));
  }

  Widget _buildList(BuildContext context, ImportWalletsState state) {
    if (state is ImportWalletsLoaded) {
      final accounts = state.accounts;
      final names = previewAccountNames(
        accounts: accounts,
        selectedKeys: state.selectedKeys,
        baseCounter: state.baseCounter,
      );
      final extraSkeletons = state.isLoadingMore ? 1 : 0;
      final totalRows = accounts.length + extraSkeletons + 1;

      return ListView.builder(
        itemCount: totalRows,
        itemBuilder: (context, index) {
          if (index == totalRows - 1) {
            return ShowMoreRow(
              enabled: !state.isLoadingMore,
              onTap: () => context.read<ImportWalletsBloc>().add(
                const ImportWalletsEvent.showMore(),
              ),
            );
          }
          if (index >= accounts.length) {
            return const SkeletonAccountCard();
          }
          return AccountPickerCard(
            account: accounts[index],
            displayName: names[accounts[index].index] ?? 'Account',
            selectedKeys: state.selectedKeys,
            onToggleWallet: (key) => context.read<ImportWalletsBloc>().add(
              ImportWalletsEvent.toggleWallet(key),
            ),
            onToggleAccount: (i) => context.read<ImportWalletsBloc>().add(
              ImportWalletsEvent.toggleAccount(i),
            ),
          );
        },
      );
    }

    return state.maybeWhen(
      // While the first batch of addresses derives, show skeleton cards with
      // shimmer placeholders where the addresses will land — not a spinner.
      loading: () => ListView.builder(
        itemCount: _kInitialSkeletonCount,
        itemBuilder: (context, index) => const SkeletonAccountCard(),
      ),
      error: (msg) => Center(child: Text(msg)),
      orElse: () => const SizedBox.shrink(),
    );
  }

  Widget _buildImportButton(BuildContext context, ImportWalletsState state) {
    if (state is ImportWalletsLoaded) {
      final hasSelection = state.selectedKeys.isNotEmpty;
      final isImporting = state.isImporting;
      return MallowButton(
        label: isImporting ? 'Importing...' : 'Import wallets',
        onPressed: hasSelection && !isImporting
            ? () => context.read<ImportWalletsBloc>().add(
                const ImportWalletsEvent.importSelected(),
              )
            : null,
        isFullWidth: true,
        enabled: hasSelection && !isImporting,
        isLoading: isImporting,
      );
    }
    return const MallowButton(
      label: 'Import wallets',
      onPressed: null,
      isFullWidth: true,
      enabled: false,
    );
  }
}

/// Gear button — opens the legacy-Solana settings sheet.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.state});

  final ImportWalletsState state;

  @override
  Widget build(BuildContext context) {
    final loaded = state is ImportWalletsLoaded
        ? state as ImportWalletsLoaded
        : null;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: loaded == null
            ? null
            : () => showImportSettingsSheet(
                context,
                includeLegacy: loaded.includeLegacy,
                onChanged: (v) => context.read<ImportWalletsBloc>().add(
                  ImportWalletsEvent.setIncludeLegacy(v),
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
