part of '../account_menu_drawer.dart';

/// Wallets tab: the session's Accounts, each shown as a single row (generated
/// avatar, name, aggregate balance, and a QR that opens the account's
/// multi-chain receive sheet). Tapping a row activates that account.
///
/// Sourced entirely from [WalletDrawerBloc] — the same loaded state that backs
/// the Profiles tab — so switching to this tab never re-queries or flashes a
/// spinner once the drawer has loaded.
class _WalletsTabContent extends StatelessWidget {
  const _WalletsTabContent({this.onClose, this.onSwitched});

  final VoidCallback? onClose;

  /// Collapses the account list back to the menu after switching, leaving the
  /// surrounding drawer open.
  final VoidCallback? onSwitched;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalletDrawerBloc, WalletDrawerState>(
      builder: (context, state) {
        final accounts = _accounts(state);
        // null = drawer still in its initial load (no account data yet).
        if (accounts == null) {
          return const Center(child: MallowLoader());
        }
        if (accounts.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Text(
                'No wallets yet',
                style: MallowTheme.uiMeta.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ),
          );
        }

        final balances = _balancesByAddress(state);
        // Only the loaded state streams balances in (cached first, then fresh),
        // so a still-unknown balance there means "first load in progress" →
        // show a shimmer. Offline has no pending fetch; it renders $0.00.
        final balancesResolving = state is WalletDrawerLoaded;
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                children: [
                  for (final account in accounts)
                    _AccountRow(
                      account: account,
                      balances: balances,
                      balancesResolving: balancesResolving,
                      onTap: () => _onAccountTap(account),
                    ),
                ],
              ),
            ),
            _EditAddButtons(onClose: onClose),
          ],
        );
      },
    );
  }

  Future<void> _onAccountTap(Account account) async {
    // Switch the active account, then collapse the account list back to the
    // menu — the surrounding drawer stays open.
    await sl<SessionManager>().switchToAccount(account.id);
    onSwitched?.call();
  }

  /// Accounts from the loaded/offline state, or null while still loading.
  List<Account>? _accounts(WalletDrawerState state) => state.maybeWhen(
    loaded: (_, _, _, _, _, accounts) => accounts,
    offline: (_, _, accounts) => accounts,
    orElse: () => null,
  );

  Map<String, double> _balancesByAddress(WalletDrawerState state) {
    final map = <String, double>{};
    state.maybeWhen(
      loaded: (groups, anon, _, _, _, _) {
        for (final g in [...groups, anon]) {
          for (final w in g.wallets) {
            if (w.balanceUsd != null) map[w.address] = w.balanceUsd!;
          }
        }
      },
      orElse: () {},
    );
    return map;
  }
}

/// One account: avatar + name + aggregate balance + QR (opens the account's
/// multi-chain receive sheet). Tapping the row activates the account.
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.balances,
    required this.balancesResolving,
    required this.onTap,
  });

  final Account account;
  final Map<String, double> balances;

  /// True while balances are still streaming in (loaded state). Combined with a
  /// row that has no known balance yet, this drives the loading shimmer.
  final bool balancesResolving;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    // A balance is "known" (cached or freshly fetched) once its address is in
    // the map — even a genuine $0. No known balance for any wallet while still
    // resolving means this is a first-time load: show a shimmer, not $0.00.
    final hasKnownBalance = account.wallets.any(
      (w) => balances.containsKey(w.address),
    );
    final total = account.wallets.fold<double>(
      0,
      (sum, w) => sum + (balances[w.address] ?? 0),
    );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
        ),
        child: Row(
          children: [
            AccountAvatar(seed: account.avatarSeed, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      account.name,
                      style: MallowTheme.uiMeta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  WalletTypeBadge(account.typeBadge),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (balancesResolving && !hasKnownBalance)
              const ShimmerBox(width: 48, height: 12)
            else
              Text(
                formatUsd(total),
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            const SizedBox(width: 8),
            TapTargetExpander(
              child: GestureDetector(
                onTap: () =>
                    showWalletsReceiveSheet(context, wallets: account.wallets),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: MallowSvgIcon(
                      'assets/icons/qr.svg',
                      width: 20,
                      height: 20,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom CTAs — Edit (manage/reorder accounts) + Add (new wallet).
class _EditAddButtons extends StatelessWidget {
  const _EditAddButtons({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: MallowButton(
              label: 'Edit',
              variant: MallowButtonVariant.secondary,
              // Keep the drawer open behind the pushed screen so popping back
              // from the edit flow returns to the still-visible drawer.
              onPressed: () => context.push(AppRoutes.editAccounts),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: MallowButton(
              label: 'Add',
              onPressed: () {
                onClose?.call();
                context.push(AppRoutes.addWalletGlobal);
              },
            ),
          ),
        ],
      ),
    );
  }
}
