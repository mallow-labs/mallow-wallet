import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ledger_solana/ledger_solana.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/models/account.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/seed_vault_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart';
import '../../accounts/models/picker_account.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/token_repository.dart';

const _tag = 'SeedVaultConnect';

// ---------------------------------------------------------------------------
// Derivation-path parsing
// ---------------------------------------------------------------------------

/// The (index, scheme) a Seed Vault derivation-path URI names, or null when the
/// path is not one this app can offer as an importable Solana account.
///
/// Seed Vault reports paths as URIs — `bip32:/m'/44'/501'/0'/0'`, or the
/// `bip44:` form where hardening is implicit — so this normalizes both by
/// stripping the scheme and the hardening marks and reading the levels.
///
/// Returns null for:
/// - the bare `m/44'/501'` root path (two levels). Seed Vault does not
///   pre-derive it, [seedVaultDerivationPath] refuses to build it, and a card
///   for it would cost the user a password prompt for an account almost nobody
///   has;
/// - any non-Solana or otherwise unrecognized shape. Dropping it is right:
///   Seed Vault has exactly one signing purpose, so anything that is not a
///   Solana account here is something this app cannot sign with.
({int index, SolanaDerivationScheme scheme})? parseSeedVaultSolanaPath(
  String uri,
) {
  final colon = uri.indexOf(':');
  final path = colon >= 0 ? uri.substring(colon + 1) : uri;

  final levels = <int>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty) continue;
    // Strip the hardening mark before anything else: the master segment is
    // reported as `m'`, not `m`, so testing for a bare `m` first silently
    // rejects every path the vault actually reports.
    final level = segment.replaceAll("'", '').replaceAll('h', '');
    if (level == 'm') continue;
    final value = int.tryParse(level);
    if (value == null) return null;
    levels.add(value);
  }

  // Two levels is the bare root path, which is deliberately not offered.
  if (levels.length < 3) return null;
  if (levels[0] != 44 || levels[1] != 501) return null;
  if (levels.length == 3) {
    return (index: levels[2], scheme: SolanaDerivationScheme.legacy);
  }
  if (levels.length == 4 && levels[3] == 0) {
    return (index: levels[2], scheme: SolanaDerivationScheme.standard);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// Written by hand rather than generated: this bloc's states carry no copyWith
/// and no unions beyond the ones below, and hand-writing keeps the feature
/// buildable without a codegen pass.
sealed class SeedVaultConnectEvent {
  const SeedVaultConnectEvent();
}

/// Run the whole gate chain: availability, permission, authorization,
/// enumeration. Dispatched once when the screen opens, and again by "Try
/// again" after a permission denial or a cancelled approval.
class SeedVaultStarted extends SeedVaultConnectEvent {
  const SeedVaultStarted();
}

/// Toggle whether the legacy derivation-path rows are shown (the gear-sheet
/// "Show legacy Solana accounts" switch).
class SeedVaultSetIncludeLegacy extends SeedVaultConnectEvent {
  const SeedVaultSetIncludeLegacy(this.include);
  final bool include;
}

/// Toggle a single wallet row by its [PickerWallet.key].
class SeedVaultToggleWallet extends SeedVaultConnectEvent {
  const SeedVaultToggleWallet(this.key);
  final String key;
}

/// Toggle every selectable wallet in the card at [index] (header "select all").
class SeedVaultToggleAccount extends SeedVaultConnectEvent {
  const SeedVaultToggleAccount(this.index);
  final int index;
}

class SeedVaultImportRequested extends SeedVaultConnectEvent {
  const SeedVaultImportRequested();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

sealed class SeedVaultConnectState {
  const SeedVaultConnectState();
}

class SeedVaultInitial extends SeedVaultConnectState {
  const SeedVaultInitial();
}

/// Waiting on the OS: the permission dialog, the approval Activity, or the
/// content-provider read behind them.
class SeedVaultPreparing extends SeedVaultConnectState {
  const SeedVaultPreparing();
}

/// This device has no Seed Vault implementation.
///
/// The entry rows are gated on the same check, so reaching this means the
/// device changed under us (or someone deep-linked the route). The screen says
/// so rather than showing an empty picker.
class SeedVaultUnavailable extends SeedVaultConnectState {
  const SeedVaultUnavailable();
}

/// `ACCESS_SEED_VAULT` was refused.
///
/// A permanent denial and a first refusal are indistinguishable through the
/// channel (both answer `false`), so the screen offers both ways back — retry
/// and the OS settings hand-off — rather than guessing which one applies.
class SeedVaultPermissionDenied extends SeedVaultConnectState {
  const SeedVaultPermissionDenied();
}

class SeedVaultAccountsLoaded extends SeedVaultConnectState {
  const SeedVaultAccountsLoaded({
    required this.accounts,
    required this.includeLegacy,
    required this.selectedKeys,
    required this.baseCounter,
  });

  final List<PickerAccount> accounts;
  final bool includeLegacy;
  final Set<String> selectedKeys;

  /// Next global account number when the picker opened; the live `Account NN`
  /// preview numbers selected cards ascending from here.
  final int baseCounter;
}

class SeedVaultImporting extends SeedVaultConnectState {
  const SeedVaultImporting();
}

class SeedVaultImported extends SeedVaultConnectState {
  const SeedVaultImported(this.wallets);
  final List<WalletInfo> wallets;
}

class SeedVaultConnectError extends SeedVaultConnectState {
  const SeedVaultConnectError(this.message);
  final String message;
}

// ---------------------------------------------------------------------------
// BLoC
// ---------------------------------------------------------------------------

/// The Seed Vault import flow: availability → permission → authorization →
/// enumeration → pick → persist.
///
/// The peer of `LedgerConnectBloc`, and deliberately shaped like it: the same
/// [PickerAccount] cards, the same ascending import order so the previewed
/// `Account NN` names are the ones actually assigned, and the same
/// active-Profile guard around the post-import session switch.
///
/// 🛑 Auth tokens are never persisted. Each enumerated row carries the token of
/// the seed that holds it, and they live only as long as this bloc — a stored
/// token is a stale token waiting to fail, since it changes on every
/// deauthorize/re-authorize.
class SeedVaultConnectBloc
    extends Bloc<SeedVaultConnectEvent, SeedVaultConnectState> {
  SeedVaultConnectBloc(
    this._seedVault,
    this._walletRepo,
    this._tokenRepo,
    this._portfolioRepo,
    this._prefs,
  ) : super(const SeedVaultInitial()) {
    on<SeedVaultStarted>(_onStarted);
    on<SeedVaultSetIncludeLegacy>(_onSetIncludeLegacy);
    on<SeedVaultToggleWallet>(_onToggleWallet);
    on<SeedVaultToggleAccount>(_onToggleAccount);
    on<SeedVaultImportRequested>(_onImport);
  }

  final SeedVaultService _seedVault;
  final WalletRepository _walletRepo;
  final TokenRepository _tokenRepo;
  final PortfolioRepository _portfolioRepo;
  final PreferencesService _prefs;

  /// Every account the vault reported this session, keyed by
  /// [PickerWallet.key]. Holds the auth token and account id each row needs at
  /// import time; dropped with the bloc.
  final _vaultRowByKey = <String, SeedVaultAccount>{};

  /// Selected wallets keyed by [PickerWallet.key], held across re-renders so
  /// the legacy toggle doesn't drop an existing selection.
  final _selectedByKey = <String, PickerWallet>{};

  List<PickerAccount> _lastAccounts = const [];
  bool _includeLegacy = false;
  int _baseAccountNumber = 1;

  /// The rows the vault reported, before the legacy filter. Kept so the gear
  /// toggle re-renders without another content-provider read.
  List<SeedVaultAccount> _vaultAccounts = const [];
  Set<String> _existingAddresses = const {};
  Map<int, String> _importedNames = const {};

  Iterable<PickerWallet> get _visibleWallets =>
      _lastAccounts.expand((a) => a.wallets);

  Set<String> get _selectedKeys =>
      Set.unmodifiable(_selectedByKey.keys.toSet());

  // ---------------------------------------------------------------------------
  // Gates
  // ---------------------------------------------------------------------------

  Future<void> _onStarted(
    SeedVaultStarted event,
    Emitter<SeedVaultConnectState> emit,
  ) async {
    emit(const SeedVaultPreparing());

    if (!await _seedVault.isAvailable()) {
      emit(const SeedVaultUnavailable());
      return;
    }

    try {
      if (!await _seedVault.hasPermission() &&
          !await _seedVault.requestPermission()) {
        // Permanently denied, or refused this time — the channel cannot tell
        // us which, so the screen offers both ways back.
        emit(const SeedVaultPermissionDenied());
        return;
      }

      _includeLegacy = _prefs.showLegacySolanaImport;

      // Enumerate first. Reading the content provider raises no Seed Vault UI,
      // so a user who already authorized a seed reaches the picker without an
      // approval screen; only a device with nothing authorized pays for one.
      var rows = await _seedVault.listAccounts();
      if (rows.isEmpty) {
        await _seedVault.authorizeSeed();
        rows = await _seedVault.listAccounts();
      }
      if (rows.isEmpty) {
        emit(
          const SeedVaultConnectError(
            'No Seed Vault accounts were found on this device.',
          ),
        );
        return;
      }

      _vaultAccounts = rows;
      _baseAccountNumber = await _walletRepo.peekNextAccountNumber();
      _existingAddresses = (await _walletRepo.getAllWallets())
          .map((w) => w.address)
          .toSet();

      // Stored names of already-imported Seed Vault accounts, keyed by
      // derivation index, so a user-edited name shows in the picker instead of
      // `Account NN`.
      //
      // `seedVault` only — deliberately not the Ledger `hardware` kind. A name
      // here means "this index already has an account, so importing it consumes
      // no new account number". `_ensureSeedVaultAccount` resolves by kind *and*
      // index, so a Ledger account at the same index does not satisfy it and the
      // import still allocates a number — borrowing that account's name would
      // preview a name the import never assigns and shift every card below it.
      _importedNames = {
        for (final a in await _walletRepo.getAccountViews())
          if (a.kind == AccountKind.seedVault && a.derivationIndex != null)
            a.derivationIndex!: a.name,
      };

      _rebuildCards();
      _emitAccountsLoaded(emit);

      final enriched = await _enrichAccounts(_lastAccounts);
      _lastAccounts = enriched;
      _emitAccountsLoaded(emit);
    } on SeedVaultUnavailableException {
      emit(const SeedVaultUnavailable());
    } on SeedVaultPermissionDeniedException {
      emit(const SeedVaultPermissionDenied());
    } on SeedVaultApprovalCancelledException {
      emit(const SeedVaultConnectError('Seed Vault approval was cancelled.'));
    } catch (e) {
      AppLogger.error(_tag, 'could not load Seed Vault accounts', e);
      emit(SeedVaultConnectError(AppFailure.from(e).message));
    }
  }

  Future<void> _onSetIncludeLegacy(
    SeedVaultSetIncludeLegacy event,
    Emitter<SeedVaultConnectState> emit,
  ) async {
    await _prefs.setShowLegacySolanaImport(event.include);
    if (_includeLegacy == event.include) return;
    _includeLegacy = event.include;
    _rebuildCards();
    _emitAccountsLoaded(emit);
    // The newly-visible legacy rows have no activity chips yet; the standard
    // rows keep the counts they already have.
    _lastAccounts = await _enrichAccounts(_lastAccounts);
    _emitAccountsLoaded(emit);
  }

  // ---------------------------------------------------------------------------
  // Cards
  // ---------------------------------------------------------------------------

  /// Group the vault's rows into one [PickerAccount] per derivation index.
  ///
  /// Every row the vault reports is a *pre-derived* account, so there is no
  /// "Show more": deriving beyond what is here means [
  /// SeedVaultService.requestPublicKeys], which can raise a password prompt.
  void _rebuildCards() {
    _vaultRowByKey.clear();

    final byIndex = <int, List<PickerWallet>>{};
    for (final row in _vaultAccounts) {
      final parsed = parseSeedVaultSolanaPath(row.derivationPath);
      // Unparseable and root paths are dropped — see [parseSeedVaultSolanaPath].
      if (parsed == null) continue;
      if (parsed.scheme == SolanaDerivationScheme.legacy && !_includeLegacy) {
        continue;
      }
      final wallet = PickerWallet(
        accountIndex: parsed.index,
        chain: Chain.solana,
        address: row.address,
        alreadyImported: _existingAddresses.contains(row.address),
        scheme: parsed.scheme,
      );
      // A duplicate key means two authorized seeds pre-derived the same path.
      // First seed wins, matching the service's own resolution order, so the
      // card and the row that will sign for it agree.
      if (_vaultRowByKey.containsKey(wallet.key)) continue;
      _vaultRowByKey[wallet.key] = row;
      byIndex.putIfAbsent(parsed.index, () => []).add(wallet);
    }

    final indices = byIndex.keys.toList()..sort();
    _lastAccounts = [
      for (final index in indices)
        PickerAccount(
          index: index,
          importedName: _importedNames[index],
          wallets: _sortRows(byIndex[index]!),
        ),
    ];
    _pruneSelection();
  }

  /// Standard before legacy inside a card, matching the seed-phrase and Ledger
  /// pickers. The vault's own row order is not guaranteed.
  static List<PickerWallet> _sortRows(List<PickerWallet> rows) =>
      [...rows]..sort((a, b) {
        int rank(PickerWallet w) =>
            w.scheme == SolanaDerivationScheme.standard ? 0 : 1;
        return rank(a).compareTo(rank(b));
      });

  void _pruneSelection() {
    final validKeys = _visibleWallets.map((w) => w.key).toSet();
    _selectedByKey.removeWhere((key, _) => !validKeys.contains(key));
  }

  void _emitAccountsLoaded(Emitter<SeedVaultConnectState> emit) {
    emit(
      SeedVaultAccountsLoaded(
        accounts: _lastAccounts,
        includeLegacy: _includeLegacy,
        selectedKeys: _selectedKeys,
        baseCounter: _baseAccountNumber,
      ),
    );
  }

  void _onToggleWallet(
    SeedVaultToggleWallet event,
    Emitter<SeedVaultConnectState> emit,
  ) {
    if (_selectedByKey.containsKey(event.key)) {
      _selectedByKey.remove(event.key);
    } else {
      final wallet = _visibleWallets
          .where((w) => w.key == event.key)
          .firstOrNull;
      if (wallet == null) return;
      _selectedByKey[event.key] = wallet;
    }
    _emitAccountsLoaded(emit);
  }

  void _onToggleAccount(
    SeedVaultToggleAccount event,
    Emitter<SeedVaultConnectState> emit,
  ) {
    final account = _lastAccounts
        .where((a) => a.index == event.index)
        .firstOrNull;
    if (account == null) return;

    final selectable = account.wallets
        .where((w) => !w.alreadyImported && !w.addressPending)
        .toList();
    if (selectable.isEmpty) return;

    final allSelected = selectable.every(
      (w) => _selectedByKey.containsKey(w.key),
    );
    for (final w in selectable) {
      if (allSelected) {
        _selectedByKey.remove(w.key);
      } else {
        _selectedByKey[w.key] = w;
      }
    }
    _emitAccountsLoaded(emit);
  }

  // ---------------------------------------------------------------------------
  // Enrichment
  // ---------------------------------------------------------------------------

  Future<List<PickerAccount>> _enrichAccounts(List<PickerAccount> accounts) =>
      Future.wait(
        accounts.map((a) async {
          final wallets = await Future.wait(a.wallets.map(_enrichWallet));
          return a.withWallets(wallets);
        }),
      );

  Future<PickerWallet> _enrichWallet(PickerWallet w) async {
    if (!w.enrichable || w.alreadyImported) return w;
    if (w.artworkCount != null && w.balanceUsd != null) return w;
    // Balance and artwork count are independent network calls — run them
    // concurrently. Each falls back to 0 when unavailable so a row does not
    // shimmer forever.
    final usdFuture = _loadBalanceUsd(w.address);
    final artworksFuture = _portfolioRepo
        .artworkCountForOwner(w.address)
        .catchError((_) => 0);
    final usd = await usdFuture;
    final artworks = await artworksFuture;
    return w.copyWith(artworkCount: artworks, balanceUsd: usd);
  }

  Future<double> _loadBalanceUsd(String address) async {
    try {
      var tokens = await _tokenRepo.getCachedBalances(address);
      if (tokens.isEmpty) {
        tokens = await _tokenRepo.getTokenBalances(address);
        await _tokenRepo.cacheBalances(address, tokens);
      }
      return _tokenRepo.calculateTotalValue(tokens);
    } catch (_) {
      return 0;
    }
  }

  // ---------------------------------------------------------------------------
  // Import
  // ---------------------------------------------------------------------------

  /// Per-row wallet name, matching the seed-phrase and Ledger import naming.
  /// Seed Vault rows are always Solana — it defines exactly one signing
  /// purpose.
  static String _walletName(SolanaDerivationScheme scheme) => switch (scheme) {
    SolanaDerivationScheme.standard => 'Solana',
    SolanaDerivationScheme.legacy => 'Solana (legacy)',
    SolanaDerivationScheme.root => 'Solana (root)',
  };

  Future<void> _onImport(
    SeedVaultImportRequested event,
    Emitter<SeedVaultConnectState> emit,
  ) async {
    if (_selectedByKey.isEmpty) return;

    emit(const SeedVaultImporting());

    try {
      final wallets = <WalletInfo>[];

      // Create accounts in ascending derivation-index order so the global
      // `Account NN` numbers assigned match the picker's ascending preview,
      // regardless of the order the user tapped the rows.
      final selectedAscending = _selectedByKey.values.toList()
        ..sort((a, b) => a.accountIndex.compareTo(b.accountIndex));

      for (final selected in selectedAscending) {
        final scheme = selected.scheme ?? SolanaDerivationScheme.standard;
        final wallet = await _walletRepo.addSeedVaultWallet(
          selected.address,
          _walletName(scheme),
          derivationIndex: selected.accountIndex,
          derivationScheme: scheme,
        );
        wallets.add(wallet);
        await _markAsUserWallet(selected.key);
      }

      _selectedByKey.clear();

      // Switch the session to the imported account so the drawer/home header
      // show its name. Skipped when the active Profile already links one of
      // these addresses: importing the Seed Vault backing of a wallet the
      // Profile already holds must leave the user on that Profile rather than
      // silently moving them into a different one.
      final session = sl<SessionManager>();
      if (wallets.isNotEmpty &&
          !session.activeProfileContainsAnyAddress(
            wallets.map((w) => w.address),
          )) {
        await session.switchToWallet(wallets.last.id);
      }

      emit(SeedVaultImported(wallets));
      _trackImported();
    } on DuplicateWalletException {
      emit(const SeedVaultConnectError('One or more wallets already exist'));
      _trackImportFailed(FailureReason.unknown);
    } on GraphSyncException {
      // Importing an address a view-only wallet already holds supersedes that
      // wallet, and pruning it from the recovery graph is the commit point of
      // its removal. Named here so the user reads the reason instead of the raw
      // keystore error AppFailure.from would put in the message.
      emit(
        const SeedVaultConnectError(
          'Could not update recovery data. Please try again.',
        ),
      );
      _trackImportFailed(FailureReason.unknown);
    } catch (e) {
      final failure = AppFailure.from(e);
      emit(SeedVaultConnectError(failure.message));
      _trackImportFailed(FailureReason.fromAppFailureKind(failure.kind));
    }
  }

  /// Flag the imported account as one the user holds — the SDK convention that
  /// lets other wallets on the device discover it.
  ///
  /// Best-effort on purpose: the wallet row is already persisted by the time
  /// this runs, so failing the whole import over a discovery hint would throw
  /// away a wallet the user successfully imported.
  Future<void> _markAsUserWallet(String key) async {
    final row = _vaultRowByKey[key];
    if (row == null || row.isUserWallet) return;
    try {
      await _seedVault.markAsUserWallet(
        authToken: row.authToken,
        accountId: row.accountId,
      );
    } catch (e) {
      AppLogger.warn(_tag, 'could not flag the account as a user wallet: $e');
    }
  }

  /// Fire `Wallet Imported` once the selected accounts are persisted. Guarded
  /// on registration so unit tests (no DI container) skip it.
  void _trackImported() {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImported,
        properties: {
          AnalyticsProp.chain: AnalyticsChain.fromChain(Chain.solana).wire,
          AnalyticsProp.method: 'seed_vault',
        },
      ),
    );
  }

  void _trackImportFailed(FailureReason reason) {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImportFailed,
        properties: {
          AnalyticsProp.method: 'seed_vault',
          AnalyticsProp.reason: reason.wire,
        },
      ),
    );
  }
}
