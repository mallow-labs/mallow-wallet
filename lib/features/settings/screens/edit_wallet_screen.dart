import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../accounts/services/account_wallet_bloc.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../seed_vault/widgets/manage_in_seed_vault_row.dart';
import '../widgets/settings_page_scaffold.dart';

/// Screen for editing (renaming) or removing a wallet.
class EditWalletScreen extends StatefulWidget {
  const EditWalletScreen({required this.walletId, super.key});

  final String walletId;

  @override
  State<EditWalletScreen> createState() => _EditWalletScreenState();
}

class _EditWalletScreenState extends State<EditWalletScreen> {
  final _controller = TextEditingController();
  String _originalName = '';
  bool _loading = true;

  /// The loaded row. Kept because the "Manage in Seed Vault" affordance is
  /// type- and address-dependent, and the screen otherwise holds only the name.
  WalletInfo? _wallet;

  /// A removal is in flight. The repository returns null for "no wallet row
  /// matched", which this screen reads as "no wallets remain" and turns into a
  /// logout — so a second tap landing while the first removal is still awaiting
  /// would sign the user out of a device that still holds wallets.
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _loadWallet();
  }

  Future<void> _loadWallet() async {
    final wallet = await sl<WalletRepository>().getWalletById(widget.walletId);
    if (!mounted) return;
    if (wallet == null) {
      context.pop();
      return;
    }
    setState(() {
      _wallet = wallet;
      _originalName = wallet.name;
      _controller.text = wallet.name;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canContinue {
    final text = _controller.text.trim();
    return text.isNotEmpty && text != _originalName;
  }

  Future<void> _onContinue() async {
    final newName = _controller.text.trim();
    if (newName.isEmpty || newName == _originalName) return;

    await sl<WalletRepository>().renameWallet(widget.walletId, newName);
    if (!mounted) return;
    sl<AccountWalletBloc>().add(const AccountWalletEvent.load());
    DrawerSignal.reloadDrawerOnReturn = true;
    context.pop();
  }

  /// The warning that fits any wallet: it names no key material this device
  /// may not actually hold.
  static const _genericRemovalMessage =
      'This wallet will be removed from your device. '
      'Make sure you have backed up your recovery phrase '
      'before proceeding.';

  /// What this removal destroys, in the user's words. Key material goes with
  /// the wallet row and cannot be recovered from the app: an imported wallet's
  /// private key always, and the seed phrase itself once the last wallet
  /// derived from it is gone. Both deletions are irreversible on this device,
  /// so the sheet has to name the one the user is about to trigger. A wallet
  /// whose key never was on the device — Ledger, Seed Vault, watch-only — must
  /// not be warned about backing up a phrase it does not have.
  ///
  /// A read failure falls back to [_genericRemovalMessage] rather than
  /// escaping: this runs inside a button handler, where an unhandled async
  /// error reaches the zone instead of the user, and the removal it was about
  /// to confirm would simply never be offered.
  Future<String> _removalMessage(
    WalletRepository repo,
    WalletInfo wallet,
  ) async {
    try {
      if (wallet.walletType == WalletType.importedKey) {
        return 'This wallet and its private key will be removed from this '
            'device. Make sure you have a copy of the private key — it cannot '
            'be recovered from the app.';
      }
      if (wallet.walletType == WalletType.social) {
        // The stored key goes too, but signing in with the same account
        // derives it again — there is no phrase to back up here.
        return 'This wallet and its stored key will be removed from this '
            'device. You can add it back by signing in with the same account '
            'again.';
      }
      if (wallet.walletType == WalletType.ledger) {
        // Nothing signable is stored here; the row is a pointer to the device.
        return 'This wallet will be removed from this device. The key stays '
            'on your Ledger.';
      }
      if (wallet.walletType == WalletType.seedVault) {
        // Same shape as the Ledger branch, and it has to be its own arm:
        // without it a Seed Vault wallet falls through to the seed-phrase
        // branch below, which tells the user to back up a recovery phrase this
        // app has never held. The key is in the device's Seed Vault and stays
        // there.
        return 'This wallet will be removed from this device. The key stays '
            'in Seed Vault.';
      }
      if (wallet.walletType == WalletType.viewOnly) {
        return 'This watch-only wallet will be removed from this device. No '
            'key is stored for it.';
      }
      final seedPhraseId = wallet.seedPhraseId;
      if (seedPhraseId != null) {
        final siblings = await repo.getWalletsForSeedPhrase(seedPhraseId);
        if (siblings.length == 1) {
          var seedName = 'its recovery phrase';
          for (final seed in await repo.getAllSeedPhrases()) {
            if (seed.id == seedPhraseId) {
              seedName = '"${seed.name}"';
              break;
            }
          }
          return 'This is the last wallet of $seedName. Removing it deletes '
              'that recovery phrase from this device. Make sure you have it '
              'written down — it cannot be recovered from the app.';
        }
      }
    } catch (e) {
      AppLogger.error(
        'EditWalletScreen',
        'could not read what this removal destroys',
        e,
      );
    }
    return _genericRemovalMessage;
  }

  Future<void> _onRemoveWallet() async {
    if (_removing) return;
    setState(() => _removing = true);
    try {
      final repo = sl<WalletRepository>();
      // Read the row before the sheet: it decides what the warning has to say,
      // and it carries the address the in-memory ownership proof is keyed by —
      // after the removal there is no row left to read it from (the on-disk
      // copy is deleted by the repository).
      final removed = await repo.getWalletById(widget.walletId);
      if (!mounted) return;
      if (removed == null) {
        context.pop();
        return;
      }
      final message = await _removalMessage(repo, removed);
      if (!mounted) return;

      final confirmed = await showConfirmSheet(
        context,
        title: 'Remove wallet?',
        message: message,
        confirmLabel: 'Remove',
        destructive: true,
      );

      if (confirmed != true || !mounted) return;

      // Open decision, deliberately not implemented: removing the last wallet
      // of a Seed Vault seed could also drop this app's authorization for that
      // seed, so it stops lingering in the user's Seed Vault settings. It is
      // not obviously right — the user may be removing one wallet and keeping
      // another from the same seed — so nothing here deauthorizes anything.

      final String? replacementId;
      try {
        replacementId = await sl<WalletManager>().removeWallet(widget.walletId);
      } on GraphSyncException {
        // The recovery-graph write is the commit point of a removal; when it
        // fails nothing has been deleted.
        if (mounted) {
          AppSnackBar.show(
            context,
            'Could not update recovery data. Nothing was removed.',
            type: AppSnackBarType.error,
          );
        }
        return;
      }
      sl<AuthService>().forgetWalletSig(removed.address);

      if (!mounted) return;

      if (replacementId == null) {
        // No wallets remain — clear selection and let router redirect to
        // welcome
        await sl<WalletManager>().clearWalletSelection();
        await sl<AuthStateNotifier>().onLogout();
      } else {
        // Switch to replacement wallet (fires onWalletChanged → re-auth)
        await sl<WalletManager>().switchWalletById(replacementId);
        if (!mounted) return;
        sl<AccountWalletBloc>().add(const AccountWalletEvent.load());
        context.pop();
      }
    } finally {
      // Re-arm only while the screen is still here — a refused removal or a
      // cancelled sheet. The paths that succeed take the screen away.
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Edit wallet',
      showDivider: false,
      child: _loading
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MallowSectionLabel(label: 'Update your wallet name'),
                  const SizedBox(height: MallowTheme.spacingMd),
                  MallowPillField(
                    controller: _controller,
                    onChanged: (_) => setState(() {}),
                    suffix: _controller.text.isNotEmpty
                        ? TapTargetExpander(
                            child: GestureDetector(
                              onTap: () {
                                _controller.clear();
                                setState(() {});
                              },
                              behavior: HitTestBehavior.opaque,
                              child: MallowSvgIcon(
                                'assets/icons/x.svg',
                                width: 18,
                                height: 18,
                                color: context.mallowColors.textSecondary,
                              ),
                            ),
                          )
                        : null,
                  ),
                  if (_wallet?.walletType == WalletType.seedVault) ...[
                    const SizedBox(height: 24),
                    ManageInSeedVaultRow(addresses: [_wallet!.address]),
                  ],
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _removing ? null : _onRemoveWallet,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.mallowColors.error,
                        foregroundColor: context.mallowColors.textOnAccent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: MallowTheme.spacingLg,
                          vertical: MallowTheme.spacingMd,
                        ),
                        minimumSize: const Size(88, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            MallowTheme.radiusFull,
                          ),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        'Remove wallet',
                        style: MallowTheme.uiBody.copyWith(
                          color: context.mallowColors.textOnAccent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  MallowButton(
                    label: 'Continue',
                    isFullWidth: true,
                    enabled: _canContinue,
                    onPressed: _onContinue,
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }
}
