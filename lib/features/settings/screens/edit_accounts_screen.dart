import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/wallet_type_badge.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../portfolio/data/wallet_balance_totals.dart';
import '../widgets/settings_page_scaffold.dart';
import 'edit_account_screen.dart';

/// Account-level management: reorder (drag) or open an account to rename it,
/// change its avatar, or remove it. Reached from the drawer's "Edit" button.
class EditAccountsScreen extends StatefulWidget {
  const EditAccountsScreen({super.key});

  @override
  State<EditAccountsScreen> createState() => _EditAccountsScreenState();
}

class _EditAccountsScreenState extends State<EditAccountsScreen> {
  List<Account> _accounts = const [];

  /// See [_AccountEditRow.dismissEpoch].
  int _dismissEpoch = 0;
  Map<String, double> _balances = const {};
  bool _loading = true;

  /// A removal is in flight. `removeAccount` returns null for "nothing
  /// matched", which this screen reads as "no wallets remain" and turns into a
  /// logout — so a second swipe landing while the first removal is still
  /// awaiting would sign the user out of a device that still holds wallets.
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final accounts = await sl<WalletRepository>().getAccountViews();
    final balances = await _loadCachedBalances(accounts);
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _balances = balances;
      _loading = false;
    });
  }

  /// Read the *cached* per-wallet USD totals from the local balance cache —
  /// the same store the drawer paints from. We deliberately do not trigger a
  /// network refresh: the drawer writes its fresh fetches through to this
  /// cache, so these totals mirror whatever the drawer is currently showing.
  Future<Map<String, double>> _loadCachedBalances(
    List<Account> accounts,
  ) async {
    final addresses = {
      for (final a in accounts)
        for (final w in a.wallets) w.address,
    };
    final balances = <String, double>{};
    for (final address in addresses) {
      try {
        // Ethereum and Tezos balances live under their own services, not the
        // Solana TokenRepository. See [cachedWalletTotalUsd].
        final total = await cachedWalletTotalUsd(address);
        if (total != null) {
          balances[address] = total;
        }
      } catch (e) {
        debugPrint('[EditAccounts] cached balance error for $address: $e');
      }
    }
    return balances;
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    setState(() {
      final moved = _accounts.removeAt(oldIndex);
      _accounts.insert(newIndex, moved);
    });
    await sl<WalletRepository>().reorderAccounts(
      _accounts.map((a) => a.id).toList(),
    );
    DrawerSignal.reloadDrawerOnReturn = true;
  }

  /// Remove an account (and all its wallets) after the user confirms the swipe.
  ///
  /// When the removed account held the active signing wallet we reconcile the
  /// session: a Profile that just lost its last held wallet drops back to
  /// Account mode (so its now-orphaned identity leaves the drawer header),
  /// otherwise we re-activate a survivor. When the removed account is unrelated
  /// to the active session we leave the session — and its re-auth — untouched
  /// and just broadcast a data change so the drawer drops the deleted row.
  Future<void> _onRemoveAccount(Account account) async {
    if (_removing) return;
    _removing = true;
    try {
      await _removeAccount(account);
    } finally {
      _removing = false;
    }
  }

  /// Ask before the swipe completes, naming what the removal destroys — an
  /// imported key, or a recovery phrase whose last wallets this account holds.
  /// Both leave the device with the account and cannot be recovered from the
  /// app.
  Future<bool> _confirmRemoveAccount(Account account) async {
    // A removal already in flight owns the list. Letting a second swipe
    // through would dismiss a row this screen has not removed yet, and the
    // handler behind it returns early — leaving a dismissed Dismissible in a
    // list that still holds its account.
    if (_removing) return false;
    final message = await accountRemovalMessage(
      sl<WalletRepository>(),
      account,
    );
    if (!mounted) return false;
    final confirmed = await showConfirmSheet(
      context,
      title: 'Remove account?',
      message: message,
      confirmLabel: 'Remove',
      destructive: true,
    );
    return confirmed == true;
  }

  /// Rebuild the rows under a new key so the one the swipe already dismissed
  /// comes back, and say why it did.
  ///
  /// A dismissed `Dismissible` whose item is still in the list is a framework
  /// error on the next build ("a dismissed Dismissible widget is still part of
  /// the tree"), so every path that leaves the account in [_accounts] has to
  /// come through here.
  void _restoreDismissedRow(String message) {
    if (!mounted) return;
    setState(() => _dismissEpoch++);
    AppSnackBar.show(context, message, type: AppSnackBarType.error);
  }

  Future<void> _removeAccount(Account account) async {
    final repo = sl<WalletRepository>();
    final bool removedActive;
    final String? replacementId;
    try {
      final activeBefore = await repo.getActiveWallet();
      removedActive =
          activeBefore != null &&
          account.wallets.any((w) => w.id == activeBefore.id);
      replacementId = await repo.removeAccount(account.id);
    } on GraphSyncException {
      // The recovery-graph write is the commit point of a removal; when it
      // fails nothing has been deleted, so the row stays in the list.
      _restoreDismissedRow(
        'Could not update recovery data. Nothing was removed.',
      );
      return;
    } catch (e) {
      // Anything else that stops the removal leaves the account in the list
      // too — the reads above included, which is why they are inside the try.
      AppLogger.error('EditAccountsScreen', 'could not remove the account', e);
      _restoreDismissedRow('Could not remove the account. Please try again.');
      return;
    }
    // The in-memory ownership proofs go with the rows; disk is the repo's.
    for (final w in account.wallets) {
      sl<AuthService>().forgetWalletSig(w.address);
    }
    if (!mounted) return;

    setState(() {
      _accounts = _accounts.where((a) => a.id != account.id).toList();
    });
    DrawerSignal.reloadDrawerOnReturn = true;

    if (replacementId == null) {
      // No wallets remain — clear selection and let the router redirect.
      await sl<WalletManager>().clearWalletSelection();
      await sl<AuthStateNotifier>().onLogout();
      return;
    }

    if (removedActive) {
      // Re-resolve the session (may drop an emptied Profile to Account mode)
      // and re-activate a survivor; this fires onWalletChanged → drawer reload.
      await sl<SessionManager>().reconcileAfterRemoval(replacementId);
    } else {
      // Session untouched — broadcast so the live drawer reloads its account
      // list (and any newly-unheld profile group) without a re-auth.
      await sl<WalletManager>().notifyWalletDataChanged();
    }
  }

  Future<void> _onTapAccount(Account account) async {
    await context.push(AppRoutes.editAccountPath(account.id));
    // The edit screen may have renamed / removed / re-avatared the account.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Edit Accounts',
      showDivider: false,
      actions: [
        TapTargetExpander(
          child: GestureDetector(
            onTap: () => context.push(AppRoutes.addWalletGlobal),
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: MallowSvgIcon(
                'assets/icons/plus.svg',
                width: 16,
                height: 16,
              ),
            ),
          ),
        ),
      ],
      child: _loading
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Rearrange or rename your accounts',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      padding: EdgeInsets.zero,
                      onReorderItem: _onReorder,
                      itemCount: _accounts.length,
                      itemBuilder: (context, index) {
                        final account = _accounts[index];
                        return _AccountEditRow(
                          key: ValueKey(account.id),
                          account: account,
                          balances: _balances,
                          dragIndex: index,
                          isOnlyAccount: _accounts.length == 1,
                          dismissEpoch: _dismissEpoch,
                          onTap: () => _onTapAccount(account),
                          confirmRemove: () => _confirmRemoveAccount(account),
                          onRemove: () => _onRemoveAccount(account),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _AccountEditRow extends StatelessWidget {
  const _AccountEditRow({
    required this.account,
    required this.balances,
    required this.dragIndex,
    required this.isOnlyAccount,
    required this.onTap,
    required this.confirmRemove,
    required this.onRemove,
    this.dismissEpoch = 0,
    super.key,
  });

  final Account account;
  final Map<String, double> balances;
  final int dragIndex;

  /// Bumped by the screen when a removal is refused after the swipe finished,
  /// so the already-dismissed Dismissible is rebuilt under a new key instead
  /// of tripping "a dismissed Dismissible widget is still part of the tree".
  final int dismissEpoch;

  /// The last account on the device can't be removed — the device must always
  /// retain at least one account (resetting the app is the only way to clear
  /// everything). When true, the swipe is refused with a message.
  final bool isOnlyAccount;
  final VoidCallback onTap;

  /// Shows the confirmation sheet and reports what the user chose. Owned by
  /// the screen, which reads what the removal would destroy before it asks.
  final Future<bool> Function() confirmRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final total = account.wallets.fold<double>(
      0,
      (sum, w) => sum + (balances[w.address] ?? 0),
    );

    return Dismissible(
      key: ValueKey('dismiss_${account.id}_$dismissEpoch'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: colors.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: MallowSvgIcon(
          'assets/icons/trash.svg',
          width: 20,
          height: 20,
          color: colors.textOnAccent,
        ),
      ),
      confirmDismiss: (_) async {
        if (isOnlyAccount) {
          AppSnackBar.show(context, 'Your device needs at least one account.');
          return false;
        }
        return confirmRemove();
      },
      onDismissed: (_) => onRemove(),
      // Long-press anywhere on the row starts a reorder drag.
      child: ReorderableDelayedDragStartListener(
        index: dragIndex,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: BoxDecoration(
              // Opaque row so the swipe background is only revealed by the
              // slide, not visible through the row.
              color: colors.bgPrimary,
              border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: Center(
                    child: MallowSvgIcon(
                      'assets/icons/dots_line.svg',
                      width: 16,
                      height: 16,
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AccountAvatar(seed: account.avatarSeed, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                      if (account.wallets.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (var i = 0; i < account.wallets.length; i++)
                                Padding(
                                  padding: EdgeInsets.only(
                                    left: i == 0 ? 0 : 4,
                                  ),
                                  child: _AddressPill(
                                    address: truncateAddress(
                                      account.wallets[i].address,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatUsd(total),
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                MallowSvgIcon(
                  'assets/icons/arrow_right.svg',
                  width: 16,
                  height: 16,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A filled pill showing a single truncated wallet address. Rendered in a
/// horizontally scrollable row so accounts with many wallets don't overflow.
class _AddressPill extends StatelessWidget {
  const _AddressPill({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        address,
        style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
      ),
    );
  }
}
