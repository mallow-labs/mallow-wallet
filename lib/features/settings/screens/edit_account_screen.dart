import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/derivation.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/services/avatar_pool_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../accounts/services/account_wallet_bloc.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/token_repository.dart';
import '../../seed_vault/widgets/manage_in_seed_vault_row.dart';
import '../../receive/sheets/chain_visuals.dart';
import '../widgets/settings_page_scaffold.dart';

import '../../../shared/utils/chain.dart';

const _maxNameLength = 32;

/// What removing [account] destroys, in the user's words. Key material goes
/// with the wallet rows and cannot be recovered from the app: an imported
/// wallet's private key always, and the seed phrase itself once this account
/// holds its last wallets. Both deletions are irreversible on the device, so
/// the confirmation has to name the one the user is about to trigger.
///
/// An account whose wallets are all of one type — the branches below only
/// speak for a whole account, since a mixed one loses more than any single
/// sentence covers.
bool _allOfType(Account account, WalletType type) =>
    account.wallets.isNotEmpty &&
    account.wallets.every((w) => w.walletType == type);

/// The warning that fits any account: it names no key material this device may
/// not actually hold.
const _genericAccountRemovalMessage =
    'This account and all of its wallets will be removed from your '
    'device. Make sure you have backed up your recovery phrase before '
    'proceeding.';

/// Shared with the account list, which asks the same question on a swipe.
///
/// A read failure falls back to [_genericAccountRemovalMessage] rather than
/// escaping: one call site is a `Dismissible.confirmDismiss` and the other a
/// button handler, so an unhandled async error here reaches the zone instead
/// of the user — and takes the confirmation with it.
Future<String> accountRemovalMessage(
  WalletRepository repo,
  Account account,
) async {
  try {
    if (_allOfType(account, WalletType.importedKey)) {
      return 'This account and its private key will be removed from this '
          'device. Make sure you have a copy of the private key — it cannot be '
          'recovered from the app.';
    }
    if (_allOfType(account, WalletType.social)) {
      // The stored keys go too, but signing in with the same account derives
      // them again — there is no phrase to back up here.
      return 'This account and its stored keys will be removed from this '
          'device. You can add it back by signing in with the same account '
          'again.';
    }
    if (_allOfType(account, WalletType.ledger)) {
      // Nothing signable is stored here; the rows point at the device.
      return 'This account and its wallets will be removed from this device. '
          'The keys stay on your Ledger.';
    }
    if (_allOfType(account, WalletType.seedVault)) {
      // Same shape as the Ledger branch, and it has to be its own arm: without
      // it a Seed Vault account falls through to the seed-phrase branch below,
      // which tells the user to back up a recovery phrase this app has never
      // held. The keys are in the device's Seed Vault and stay there.
      return 'This account and its wallets will be removed from this device. '
          'The keys stay in Seed Vault.';
    }
    if (_allOfType(account, WalletType.viewOnly)) {
      return 'This watch-only account will be removed from this device. No '
          'keys are stored for it.';
    }
    final walletIds = account.wallets.map((w) => w.id).toSet();
    final seedPhraseIds = {
      for (final w in account.wallets)
        if (w.seedPhraseId != null) w.seedPhraseId!,
    };
    for (final seedPhraseId in seedPhraseIds) {
      final siblings = await repo.getWalletsForSeedPhrase(seedPhraseId);
      if (siblings.every((w) => walletIds.contains(w.id))) {
        var seedName = 'its recovery phrase';
        for (final seed in await repo.getAllSeedPhrases()) {
          if (seed.id == seedPhraseId) {
            seedName = '"${seed.name}"';
            break;
          }
        }
        return 'This account holds the last wallets of $seedName. Removing it '
            'deletes that recovery phrase from this device. Make sure you have '
            'it written down — it cannot be recovered from the app.';
      }
    }
  } catch (e) {
    AppLogger.error(
      'EditAccountScreen',
      'could not read what this removal destroys',
      e,
    );
  }
  return _genericAccountRemovalMessage;
}

/// Edit a single account: rename it, pick a generated (DiceBear) avatar from a
/// candidate grid, or remove the account entirely.
class EditAccountScreen extends StatefulWidget {
  const EditAccountScreen({required this.accountId, super.key});

  final String accountId;

  @override
  State<EditAccountScreen> createState() => _EditAccountScreenState();
}

class _EditAccountScreenState extends State<EditAccountScreen> {
  final _controller = TextEditingController();
  String _originalName = '';
  String _originalSeed = '';
  String _selectedSeed = '';
  List<String> _candidateSeeds = const [];
  bool _loading = true;

  /// A removal is in flight. `removeAccount` returns null for "nothing
  /// matched", which this screen reads as "no wallets remain" and turns into a
  /// logout — so a second tap landing while the first removal is still awaiting
  /// would sign the user out of a device that still holds wallets.
  bool _removing = false;

  /// The fully-loaded account, kept so the toggle section can read its wallets,
  /// seed phrase, and derivation index.
  Account? _account;

  /// Standard addresses derived at the account's index — the fallback shown for
  /// chains that don't currently have a wallet (the "off" rows).
  AccountAddresses? _derived;

  /// Staged per-chain toggle changes, holding only chains whose desired state
  /// differs from what's currently on the account. Nothing is persisted until
  /// the user taps Done — backing out discards these. See [_onContinue].
  final Map<Chain, bool> _desiredEnabled = {};

  /// Best-effort Solana enrichment, keyed by address.
  final Map<String, int> _artworksByAddress = {};
  final Map<String, double> _usdByAddress = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final accounts = await sl<WalletRepository>().getAccountViews();
    Account? account;
    for (final a in accounts) {
      if (a.id == widget.accountId) {
        account = a;
        break;
      }
    }
    if (!mounted) return;
    if (account == null) {
      context.pop();
      return;
    }

    // The candidate grid is drawn from a persistent, evenly-coloured pool that
    // excludes every avatar already assigned to an account — so a previously
    // chosen avatar is never re-offered and is replaced by a fresh one.
    final inUse = {
      for (final a in accounts)
        if (a.avatarSeed.isNotEmpty) a.avatarSeed,
    };
    final pool = await sl<AvatarPoolService>().candidates(inUse: inUse);
    if (!mounted) return;

    setState(() {
      _account = account;
      _originalName = account!.name;
      _originalSeed = account.avatarSeed;
      _selectedSeed = account.avatarSeed;
      _controller.text = account.name;
      // The current avatar first (so it stays selectable), then the pool.
      _candidateSeeds = [
        if (account.avatarSeed.isNotEmpty) account.avatarSeed,
        ...pool,
      ].take(28).toList();
      _loading = false;
    });
    await _loadToggleData();
  }

  /// Whether this account supports per-chain address toggles. Only `seed`
  /// accounts can re-derive a chain wallet at a fixed index; imported-key /
  /// view-only / social / hardware accounts have no derivation to toggle.
  bool get _supportsToggles =>
      _account != null &&
      _account!.kind == AccountKind.seed &&
      _account!.seedPhraseId != null &&
      _account!.derivationIndex != null;

  /// Derive the standard addresses at this account's index (used to render the
  /// "off" rows), then enrich the Solana row in the background.
  Future<void> _loadToggleData() async {
    if (!_supportsToggles) return;
    try {
      final info = await sl<WalletRepository>().deriveAccountsForPicker(
        _account!.seedPhraseId!,
        startIndex: _account!.derivationIndex!,
        count: 1,
      );
      if (!mounted || info.accounts.isEmpty) return;
      setState(() => _derived = info.accounts.first);
    } catch (_) {
      // Derivation is best-effort — chains with an existing wallet still toggle.
    }
    await _enrichSolana();
  }

  /// The address shown for [chain]: the existing wallet's address when present,
  /// otherwise the freshly-derived standard address. Null until derived.
  String? _addressForChain(Chain chain) {
    final existing = _account?.walletForChain(chain);
    if (existing != null) return existing.address;
    final derived = _derived;
    if (derived == null) return null;
    return switch (chain) {
      Chain.solana => derived.solanaStandard,
      Chain.ethereum => derived.ethereum,
      Chain.tezos => derived.tezos,
    };
  }

  /// Fetch artwork count + USD for the Solana row (mallow only indexes Solana).
  /// Mirrors the import picker's enrichment; failures fall back to zero.
  Future<void> _enrichSolana() async {
    final address = _addressForChain(Chain.solana);
    if (address == null ||
        address.isEmpty ||
        _usdByAddress.containsKey(address)) {
      return;
    }
    final tokenRepo = sl<TokenRepository>();
    final usd = await tokenRepo
        .getTokenBalances(address)
        .then(tokenRepo.calculateTotalValue)
        .catchError((_) => 0.0);
    final artworks = await sl<PortfolioRepository>()
        .artworkCountForOwner(address)
        .catchError((_) => 0);
    if (!mounted) return;
    setState(() {
      _usdByAddress[address] = usd;
      _artworksByAddress[address] = artworks;
    });
  }

  /// Whether [chain] is currently shown as enabled — the staged desired state
  /// if the user touched it, otherwise whether a wallet exists on the account.
  bool _isEnabled(Chain chain) =>
      _desiredEnabled[chain] ?? (_account?.walletForChain(chain) != null);

  /// Stage an enable/disable for [chain]. Nothing is persisted here; the diff is
  /// applied on Done. Refuses to disable the last remaining chain.
  void _onToggleChain(Chain chain, bool enable) {
    final account = _account;
    if (account == null) return;

    if (!enable) {
      const order = [Chain.solana, Chain.tezos, Chain.ethereum];
      final remaining = order.where((c) => c != chain && _isEnabled(c)).length;
      if (remaining == 0) {
        AppSnackBar.show(context, 'An account needs at least one address.');
        return;
      }
    }

    setState(() {
      final actual = account.walletForChain(chain) != null;
      if (enable == actual) {
        _desiredEnabled.remove(chain);
      } else {
        _desiredEnabled[chain] = enable;
      }
    });
  }

  /// The "N artworks  •  \$X" trailing label. Only Solana carries real data;
  /// Ethereum/Tezos aren't indexed, so they read zero (matching the design).
  String _statsLabel(Chain chain, String address) {
    final artworks = chain == Chain.solana
        ? (_artworksByAddress[address] ?? 0)
        : 0;
    final usd = chain == Chain.solana ? (_usdByAddress[address] ?? 0.0) : 0.0;
    final unit = artworks == 1 ? 'artwork' : 'artworks';
    return '$artworks $unit  •  \$${PriceFormatter.formatCompactValue(usd)}';
  }

  /// The chain rows for the toggle section, in Solana → Tezos → Ethereum order.
  /// Rows for chains without a derived/existing address yet are omitted until
  /// derivation completes.
  List<_ChainToggleData> _chainRows() {
    const order = [Chain.solana, Chain.tezos, Chain.ethereum];
    return [
      for (final chain in order)
        if (_addressForChain(chain) case final address?)
          _ChainToggleData(
            chain: chain,
            enabled: _isEnabled(chain),
            address: address,
            statsLabel: _statsLabel(chain, address),
          ),
    ];
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasChanges {
    // Staged address toggles count as changes even with no name/avatar edit.
    if (_desiredEnabled.isNotEmpty) return true;
    final name = _controller.text.trim();
    if (name.isEmpty) return false;
    return name != _originalName || _selectedSeed != _originalSeed;
  }

  Future<void> _onContinue() async {
    final newName = _controller.text.trim();
    final repo = sl<WalletRepository>();
    if (newName.isNotEmpty && newName != _originalName) {
      await repo.renameAccount(widget.accountId, newName);
    }
    if (_selectedSeed != _originalSeed && _selectedSeed.isNotEmpty) {
      await repo.updateAccountAvatarSeed(widget.accountId, _selectedSeed);
    }
    var applied = false;
    try {
      applied = await _applyAddressToggles(repo);
    } catch (e) {
      // The toggles are the only step that runs after the name and avatar have
      // already been written, so an error escaping here would leave the button
      // callback with an unhandled exception: no message, no pop, and a screen
      // still showing a diff that did not land. Treat it as "not applied" so
      // the account is re-read below and the toggles show what is really on it.
      AppLogger.error('EditAccountScreen', 'address toggles failed', e);
      if (!mounted) return;
      AppSnackBar.show(
        context,
        'Could not update your addresses.',
        type: AppSnackBarType.error,
      );
      applied = false;
    }
    // If this is the active session account, refresh its cached copy so the
    // session-backed headers (home header, drawer header) pick up the new
    // name/avatar — they read identity from SessionManager, not the DB.
    await sl<SessionManager>().refreshActiveAccount();
    if (!mounted) return;
    sl<AccountWalletBloc>().add(const AccountWalletEvent.load());
    DrawerSignal.reloadDrawerOnReturn = true;
    if (!applied) {
      // A toggle was refused (the snack bar said so), so this is not a
      // completed save and must not pop like one. The name, avatar and any
      // chain added before the refusal did land, so drop the staged diff and
      // re-read the account: the toggles then show what is really on it.
      setState(_desiredEnabled.clear);
      await _load();
      return;
    }
    context.pop();
  }

  /// Persist the staged per-chain toggles: derive + add newly-enabled chains
  /// (reusing the import path), then remove every newly-disabled one in a
  /// single all-or-nothing repository call. If a removed wallet was the active
  /// one, switch the session to its replacement — this is the only point a
  /// re-auth can fire, mirroring the "Remove account" flow.
  ///
  /// Returns false when a change was refused, so the caller can keep the user
  /// here instead of popping as a successful save. Additions run first and are
  /// not part of the removals' all-or-nothing set: they only ever add a wallet
  /// the user asked for, so keeping one costs nothing. An addition can still
  /// be refused on its own — importing an address a view-only wallet already
  /// holds supersedes that wallet, and pruning it from the recovery graph is
  /// the commit point of its removal — so a [GraphSyncException] there leaves
  /// that chain unadded and stops the rest of the diff.
  Future<bool> _applyAddressToggles(WalletRepository repo) async {
    final account = _account;
    if (account == null || _desiredEnabled.isEmpty) return true;
    final seedPhraseId = account.seedPhraseId;
    final index = account.derivationIndex;
    if (seedPhraseId == null || index == null) return true;

    final activeBefore = await repo.getActiveWallet();

    final removing = <WalletInfo>[];
    for (final entry in _desiredEnabled.entries) {
      final chain = entry.key;
      final existing = account.walletForChain(chain);
      if (entry.value && existing == null) {
        final address = _addressForChain(chain);
        if (address == null || address.isEmpty) continue;
        try {
          await repo.importAccountsFromPhrase(seedPhraseId, [
            WalletImportSelection(index: index, chain: chain, address: address),
          ]);
        } on GraphSyncException {
          // The import superseded a view-only wallet on this address and could
          // not prune it from the recovery graph — the commit point of that
          // removal — so this chain was not added. Stop before the removals
          // rather than deleting wallets on top of a half-applied diff; the
          // caller re-reads the account, so the toggles show what really is on
          // it instead of the edit the user did not get.
          if (mounted) {
            AppSnackBar.show(
              context,
              'Could not update recovery data. The address was not added.',
              type: AppSnackBarType.error,
            );
          }
          return false;
        }
      } else if (!entry.value && existing != null) {
        removing.add(existing);
      }
    }
    if (removing.isEmpty) return true;

    final String? replacementId;
    try {
      replacementId = await repo.removeWallets(removing.map((w) => w.id));
    } on GraphSyncException {
      // One graph write is the commit point for the whole set, so none of
      // these wallets was removed.
      if (mounted) {
        AppSnackBar.show(
          context,
          'Could not update recovery data. Nothing was removed.',
          type: AppSnackBarType.error,
        );
      }
      return false;
    }

    // The in-memory ownership proofs go with the rows; disk is the repo's.
    for (final removed in removing) {
      sl<AuthService>().forgetWalletSig(removed.address);
    }

    final activeRemoved = removing.any((w) => w.id == activeBefore?.id);
    if (activeRemoved && replacementId != null) {
      await sl<WalletManager>().switchWalletById(replacementId);
    }
    return true;
  }

  Future<void> _onRemove() async {
    if (_removing) return;
    setState(() => _removing = true);
    try {
      // The device must always retain at least one account; refuse to remove
      // the last one. (Resetting the app is the only way to clear everything.)
      final accounts = await sl<WalletRepository>().getAccountViews();
      if (!mounted) return;
      if (accounts.length <= 1) {
        AppSnackBar.show(context, 'Your device needs at least one account.');
        return;
      }

      final removedMatch = accounts.where((a) => a.id == widget.accountId);
      if (removedMatch.isEmpty) {
        // The account is already gone — removed from the list screen, or by a
        // toggle that emptied it. There is nothing left to remove and nothing
        // left to edit, so leave rather than sit on a dead button. [_load]
        // pops for the same reason when it can't find the account at all.
        context.pop();
        return;
      }
      final message = await accountRemovalMessage(
        sl<WalletRepository>(),
        removedMatch.first,
      );
      if (!mounted) return;

      final confirmed = await showConfirmSheet(
        context,
        title: 'Remove account?',
        message: message,
        confirmLabel: 'Remove',
        destructive: true,
      );
      if (confirmed != true || !mounted) return;

      // Open decision, deliberately not implemented: removing the last wallet
      // of a Seed Vault seed could also drop this app's authorization for that
      // seed, so it stops lingering in the user's Seed Vault settings. It is
      // not obviously right — the user may be removing one account and keeping
      // another from the same seed on a later import — so nothing here
      // deauthorizes anything.

      // Did this account hold the active signing wallet? Determines whether
      // the session must be reconciled vs. just refreshing the drawer.
      final activeBefore = await sl<WalletRepository>().getActiveWallet();
      final removedActive =
          activeBefore != null &&
          removedMatch.first.wallets.any((w) => w.id == activeBefore.id);

      final String? replacementId;
      try {
        replacementId = await sl<WalletRepository>().removeAccount(
          widget.accountId,
        );
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
      // The in-memory ownership proofs go with the rows; disk is the repo's.
      for (final w in removedMatch.expand((a) => a.wallets)) {
        sl<AuthService>().forgetWalletSig(w.address);
      }
      if (!mounted) return;

      if (replacementId == null) {
        // No wallets remain — clear selection and let the router redirect.
        await sl<WalletManager>().clearWalletSelection();
        await sl<AuthStateNotifier>().onLogout();
      } else {
        if (removedActive) {
          // Re-resolve the session: a Profile that lost its last held wallet
          // drops to Account mode (clearing its now-orphaned identity), else a
          // survivor is activated. Fires onWalletChanged → drawer reload.
          await sl<SessionManager>().reconcileAfterRemoval(replacementId);
        } else {
          // Session untouched — broadcast so the drawer drops the deleted
          // account.
          await sl<WalletManager>().notifyWalletDataChanged();
        }
        if (!mounted) return;
        sl<AccountWalletBloc>().add(const AccountWalletEvent.load());
        DrawerSignal.reloadDrawerOnReturn = true;
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
    final colors = context.mallowColors;
    final remaining = _maxNameLength - _controller.text.length;

    return SettingsPageScaffold(
      title: 'Edit Account',
      showDivider: false,
      child: _loading
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const MallowSectionLabel(
                            label: 'Enter an account name',
                          ),
                          const SizedBox(height: MallowTheme.spacingMd),
                          MallowPillField(
                            controller: _controller,
                            hintText: 'Name',
                            maxLength: _maxNameLength,
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '$remaining characters remaining',
                            style: MallowTheme.uiCaption.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 24),
                          const MallowSectionLabel(
                            label: 'Select an account image',
                          ),
                          const SizedBox(height: MallowTheme.spacingMd),
                          _AvatarGrid(
                            seeds: _candidateSeeds,
                            selected: _selectedSeed,
                            onSelect: (seed) =>
                                setState(() => _selectedSeed = seed),
                          ),
                          if (_supportsToggles) ...[
                            const SizedBox(height: 24),
                            const MallowSectionLabel(label: 'Toggle addresses'),
                            const SizedBox(height: MallowTheme.spacingMd),
                            _ToggleAddressesSection(
                              rows: _chainRows(),
                              onToggle: _onToggleChain,
                            ),
                          ],
                          if (_account?.kind == AccountKind.seedVault) ...[
                            const SizedBox(height: 24),
                            ManageInSeedVaultRow(
                              addresses: [
                                for (final w in _account!.wallets) w.address,
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  MallowButton(
                    label: 'Remove account',
                    variant: MallowButtonVariant.danger,
                    isFullWidth: true,
                    enabled: !_removing,
                    onPressed: _onRemove,
                  ),
                  const SizedBox(height: 12),
                  MallowButton(
                    label: 'Done',
                    isFullWidth: true,
                    enabled: _hasChanges,
                    onPressed: _onContinue,
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }
}

/// Row data for one chain in the "Toggle addresses" section.
class _ChainToggleData {
  const _ChainToggleData({
    required this.chain,
    required this.enabled,
    required this.address,
    required this.statsLabel,
  });

  final Chain chain;
  final bool enabled;
  final String address;
  final String statsLabel;
}

/// The "Toggle addresses" section: one row per chain with a switch that adds
/// (derives) or removes that chain's wallet, plus its address and stats.
class _ToggleAddressesSection extends StatelessWidget {
  const _ToggleAddressesSection({required this.rows, required this.onToggle});

  final List<_ChainToggleData> rows;
  final void Function(Chain chain, bool enable) onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      children: [
        for (final row in rows)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onToggle(row.chain, !row.enabled),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
              ),
              child: Row(
                children: [
                  MallowToggle(
                    value: row.enabled,
                    onChanged: (v) => onToggle(row.chain, v),
                  ),
                  const SizedBox(width: 12),
                  ChainGlyph(
                    chain: row.chain,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      truncateAddress(row.address),
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    row.statsLabel,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A 7-column grid of generated avatars, evenly spaced across the row; the
/// selected one gets an accent ring.
class _AvatarGrid extends StatelessWidget {
  const _AvatarGrid({
    required this.seeds,
    required this.selected,
    required this.onSelect,
  });

  static const _columns = 7;
  static const _spacing = 16.0;

  final List<String> seeds;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fit exactly [_columns] avatars per row with [_spacing] gaps between.
        final cell =
            (constraints.maxWidth - _spacing * (_columns - 1)) / _columns;
        return Wrap(
          spacing: _spacing,
          runSpacing: _spacing,
          children: [
            for (final seed in seeds)
              TapTargetExpander(
                child: GestureDetector(
                  onTap: () => onSelect(seed),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: cell,
                    height: cell,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: seed == selected
                            ? colors.accent
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: AccountAvatar(
                      seed: seed,
                      size: cell - 4,
                      showShimmerPlaceholder: true,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
