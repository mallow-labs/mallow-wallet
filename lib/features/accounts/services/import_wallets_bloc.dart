import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:ledger_solana/ledger_solana.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/crypto/derivation.dart';
import '../../../core/models/account.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/security/redacted.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/token_repository.dart';
import '../models/picker_account.dart';

import '../../../shared/utils/chain.dart';
export '../models/picker_account.dart'
    show PickerAccount, PickerWallet, previewAccountNames;

part 'import_wallets_bloc.freezed.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

@freezed
abstract class ImportWalletsEvent with _$ImportWalletsEvent {
  const factory ImportWalletsEvent.loadAddresses(String seedPhraseId) =
      _LoadAddresses;
  // SECURITY: the phrase is wrapped so freezed's generated `toString()` masks
  // it — see [Redacted]. Registering a BlocObserver must never turn this event
  // into a seed leak.
  const factory ImportWalletsEvent.loadFromMnemonic(Redacted<String> mnemonic) =
      _LoadFromMnemonic;
  const factory ImportWalletsEvent.showMore() = _ShowMore;
  const factory ImportWalletsEvent.toggleWallet(String key) = _ToggleWallet;
  const factory ImportWalletsEvent.toggleAccount(int index) = _ToggleAccount;
  const factory ImportWalletsEvent.setIncludeLegacy(bool include) =
      _SetIncludeLegacy;
  const factory ImportWalletsEvent.importSelected() = _ImportSelected;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@freezed
abstract class ImportWalletsState with _$ImportWalletsState {
  const factory ImportWalletsState.initial() = _Initial;
  const factory ImportWalletsState.loading() = _Loading;
  const factory ImportWalletsState.loaded({
    required String seedPhraseId,
    required List<PickerAccount> accounts,
    @Default({}) Set<String> selectedKeys,
    @Default(false) bool includeLegacy,
    @Default(false) bool isImporting,
    @Default(false) bool isLoadingMore,
    @Default(0) int loadingMoreCount,
    // Next global account number when the picker opened; the live `Account NN`
    // preview numbers selected cards ascending from here. See
    // [previewAccountNames].
    @Default(1) int baseCounter,
  }) = ImportWalletsLoaded;
  const factory ImportWalletsState.imported(List<WalletInfo> wallets) =
      _Imported;
  const factory ImportWalletsState.error(String message) = _Error;
}

// ---------------------------------------------------------------------------
// BLoC
// ---------------------------------------------------------------------------

@injectable
class ImportWalletsBloc extends Bloc<ImportWalletsEvent, ImportWalletsState> {
  ImportWalletsBloc(
    this._walletRepo,
    this._tokenRepo,
    this._portfolioRepo,
    this._prefs,
    this._secureStorage,
    this._session,
  ) : super(const ImportWalletsState.initial()) {
    on<_LoadAddresses>(_onLoadAddresses);
    on<_LoadFromMnemonic>(_onLoadFromMnemonic);
    on<_ShowMore>(_onShowMore);
    on<_ToggleWallet>(_onToggleWallet);
    on<_ToggleAccount>(_onToggleAccount);
    on<_SetIncludeLegacy>(_onSetIncludeLegacy);
    on<_ImportSelected>(_onImportSelected);
  }

  final WalletRepository _walletRepo;
  final TokenRepository _tokenRepo;
  final PortfolioRepository _portfolioRepo;
  final PreferencesService _prefs;
  final SecureWalletStorage _secureStorage;
  final SessionManager _session;

  /// Held in memory when creating from a new mnemonic (not yet persisted).
  String? _pendingMnemonic;
  String _seedPhraseId = '';
  static const _batchSize = 5;

  /// Chains the user has switched off in Active Networks; their derived
  /// addresses are hidden from the picker. Solana can never be disabled.
  /// Refreshed from storage on each [_load] so a toggle change takes effect
  /// the next time the picker opens.
  Set<Chain> _disabledChains = const {};

  Future<void> _onLoadAddresses(
    _LoadAddresses event,
    Emitter<ImportWalletsState> emit,
  ) async {
    _seedPhraseId = event.seedPhraseId;
    await _load(emit);
  }

  Future<void> _onLoadFromMnemonic(
    _LoadFromMnemonic event,
    Emitter<ImportWalletsState> emit,
  ) async {
    // If this phrase is already on the device, fold it into its existing seed so
    // prior imports derive against the wallet graph and surface as already-
    // imported (toggled on, locked) instead of fresh, selectable rows. Only a
    // genuinely new phrase is held in memory and persisted on import.
    final mnemonic = event.mnemonic.value;
    final existingId = await _walletRepo.findSeedPhraseIdForMnemonic(mnemonic);
    if (existingId != null) {
      _seedPhraseId = existingId;
    } else {
      _pendingMnemonic = mnemonic;
    }
    await _load(emit);
  }

  Future<void> _load(Emitter<ImportWalletsState> emit) async {
    emit(const ImportWalletsState.loading());
    final includeLegacy = _prefs.showLegacySolanaImport;
    _disabledChains = await _loadDisabledChains();
    try {
      final indices = [for (var i = 0; i < _batchSize; i++) i];
      final (addrs, already, names) = await _derive(indices, includeLegacy);
      final accounts = _buildAccounts(addrs, already, includeLegacy, names);
      final baseCounter = await _walletRepo.peekNextAccountNumber();

      // Pre-select the first account on a phrase with no prior imports, to
      // nudge the common case. When the phrase already has imported wallets the
      // user is adding more, so start with nothing selected.
      final phraseHasImports = accounts.any((a) => a.isImported);
      final selectedKeys = <String>{
        if (!phraseHasImports && accounts.isNotEmpty)
          for (final w in accounts.first.wallets)
            if (!w.alreadyImported) w.key,
      };

      emit(
        ImportWalletsState.loaded(
          seedPhraseId: _seedPhraseId,
          accounts: accounts,
          selectedKeys: selectedKeys,
          includeLegacy: includeLegacy,
          baseCounter: baseCounter,
        ),
      );

      await _enrichAndMerge(emit, accounts);
    } catch (e) {
      AppLogger.debug(
        'ImportWalletsBloc',
        'Load failed: ${AppFailure.from(e).message}',
      );
      emit(
        const ImportWalletsState.error(
          'Could not load addresses. Please try again.',
        ),
      );
    }
  }

  Future<void> _onShowMore(
    _ShowMore event,
    Emitter<ImportWalletsState> emit,
  ) async {
    final current = state;
    if (current is! ImportWalletsLoaded) return;
    if (current.isLoadingMore) return;

    final nextStart = current.accounts.length;
    emit(current.copyWith(isLoadingMore: true, loadingMoreCount: _batchSize));

    try {
      final indices = [
        for (var i = nextStart; i < nextStart + _batchSize; i++) i,
      ];
      final (addrs, already, names) = await _derive(
        indices,
        current.includeLegacy,
      );
      final newAccounts = _buildAccounts(
        addrs,
        already,
        current.includeLegacy,
        names,
      );

      final afterDerive = state;
      if (afterDerive is! ImportWalletsLoaded) return;
      emit(
        afterDerive.copyWith(
          accounts: [...afterDerive.accounts, ...newAccounts],
          loadingMoreCount: 0,
          isLoadingMore: false,
        ),
      );

      await _enrichAndMerge(emit, newAccounts);
    } catch (e) {
      AppLogger.debug(
        'ImportWalletsBloc',
        'Show more failed: ${AppFailure.from(e).message}',
      );
      final s = state;
      if (s is ImportWalletsLoaded) {
        emit(s.copyWith(isLoadingMore: false, loadingMoreCount: 0));
      }
    }
  }

  void _onToggleWallet(_ToggleWallet event, Emitter<ImportWalletsState> emit) {
    final current = state;
    if (current is! ImportWalletsLoaded) return;
    final selected = Set<String>.from(current.selectedKeys);
    if (selected.contains(event.key)) {
      selected.remove(event.key);
    } else {
      selected.add(event.key);
    }
    emit(current.copyWith(selectedKeys: selected));
  }

  void _onToggleAccount(
    _ToggleAccount event,
    Emitter<ImportWalletsState> emit,
  ) {
    final current = state;
    if (current is! ImportWalletsLoaded) return;
    final account = current.accounts.firstWhere(
      (a) => a.index == event.index,
      orElse: () => const PickerAccount(index: -1, wallets: []),
    );
    if (account.index == -1) return;

    final selectable = account.wallets
        .where((w) => !w.alreadyImported && !w.addressPending)
        .toList();
    if (selectable.isEmpty) return;

    final selected = Set<String>.from(current.selectedKeys);
    final allSelected = selectable.every((w) => selected.contains(w.key));
    if (allSelected) {
      selected.removeAll(selectable.map((w) => w.key));
    } else {
      selected.addAll(selectable.map((w) => w.key));
    }
    emit(current.copyWith(selectedKeys: selected));
  }

  Future<void> _onSetIncludeLegacy(
    _SetIncludeLegacy event,
    Emitter<ImportWalletsState> emit,
  ) async {
    await _prefs.setShowLegacySolanaImport(event.include);
    final current = state;
    if (current is! ImportWalletsLoaded) return;
    if (current.includeLegacy == event.include) return;

    // Turning legacy off needs no derivation — the standard rows are already
    // shown, so just drop the legacy/root rows and prune their selections.
    if (!event.include) {
      final filtered = [
        for (final a in current.accounts)
          a.withWallets(a.wallets.where((w) => w.scheme == null).toList()),
      ];
      final validKeys = {
        for (final a in filtered)
          for (final w in a.wallets) w.key,
      };
      emit(
        current.copyWith(
          accounts: filtered,
          includeLegacy: false,
          selectedKeys: current.selectedKeys.intersection(validKeys),
        ),
      );
      return;
    }

    // Turning legacy on: surface shimmer placeholders for the legacy/root
    // addresses immediately, then re-derive and swap in the real rows. Existing
    // (non-legacy) selections are preserved by key; legacy rows start unselected
    // for the user to opt into.
    final count = current.accounts.length;
    if (count == 0) {
      emit(current.copyWith(includeLegacy: true));
      return;
    }
    emit(
      current.copyWith(
        includeLegacy: true,
        accounts: [
          for (final a in current.accounts)
            a.withWallets(_withLegacyPlaceholders(a.wallets, a.index)),
        ],
      ),
    );
    try {
      final indices = [for (var i = 0; i < count; i++) i];
      final (addrs, already, names) = await _derive(indices, true);
      final rebuilt = _buildAccounts(addrs, already, true, names);
      final validKeys = {
        for (final a in rebuilt)
          for (final w in a.wallets) w.key,
      };
      final after = state;
      if (after is! ImportWalletsLoaded) return;
      emit(
        after.copyWith(
          accounts: rebuilt,
          includeLegacy: true,
          selectedKeys: after.selectedKeys.intersection(validKeys),
        ),
      );
      await _enrichAndMerge(emit, rebuilt);
    } catch (e) {
      AppLogger.debug(
        'ImportWalletsBloc',
        'Toggle legacy failed: ${AppFailure.from(e).message}',
      );
      // Roll back the placeholder rows so the picker doesn't strand shimmers.
      final after = state;
      if (after is ImportWalletsLoaded) {
        emit(after.copyWith(accounts: current.accounts));
      }
    }
  }

  /// Insert pending legacy (every index) and root (index 0 only) Solana
  /// placeholder rows right after the standard Solana row, mirroring the row
  /// set [_buildAccounts] produces with legacy enabled. Their addresses derive
  /// asynchronously, so they render as shimmer placeholders until swapped in.
  List<PickerWallet> _withLegacyPlaceholders(
    List<PickerWallet> wallets,
    int index,
  ) {
    return [
      for (final w in wallets) ...[
        w,
        if (w.chain == Chain.solana && w.scheme == null) ...[
          PickerWallet(
            accountIndex: index,
            chain: Chain.solana,
            scheme: SolanaDerivationScheme.legacy,
            address: '',
            alreadyImported: false,
            addressPending: true,
          ),
          if (index == 0)
            PickerWallet(
              accountIndex: index,
              chain: Chain.solana,
              scheme: SolanaDerivationScheme.root,
              address: '',
              alreadyImported: false,
              addressPending: true,
            ),
        ],
      ],
    ];
  }

  Future<void> _onImportSelected(
    _ImportSelected event,
    Emitter<ImportWalletsState> emit,
  ) async {
    final current = state;
    if (current is! ImportWalletsLoaded) return;
    if (current.selectedKeys.isEmpty) return;

    emit(current.copyWith(isImporting: true));

    final result = await Result.guard(() async {
      final selections = <WalletImportSelection>[];
      for (final account in current.accounts) {
        for (final w in account.wallets) {
          if (current.selectedKeys.contains(w.key) &&
              !w.alreadyImported &&
              !w.addressPending) {
            selections.add(
              WalletImportSelection(
                index: w.accountIndex,
                chain: w.chain,
                address: w.address,
                scheme: w.scheme,
              ),
            );
          }
        }
      }

      var seedPhraseId = _seedPhraseId;
      if (_pendingMnemonic != null) {
        final seedPhrase = await _walletRepo.createSeedPhrase(
          _pendingMnemonic!,
          autoDerive: false,
        );
        seedPhraseId = seedPhrase.id;
        _seedPhraseId = seedPhraseId;
        _pendingMnemonic = null;
      }

      return _walletRepo.importAccountsFromPhrase(seedPhraseId, selections);
    });

    switch (result) {
      case ResultSuccess(:final value):
        emit(ImportWalletsState.imported(value));
        _trackImported();
      case ResultFailure(:final error):
        AppLogger.debug(
          'ImportWalletsBloc',
          'Import selected failed: ${error.message}',
        );
        emit(
          const ImportWalletsState.error(
            'Could not import wallets. Please try again.',
          ),
        );
        _trackImportFailed(error.kind);
    }
  }

  /// Fire `Wallet Imported` once the selected accounts are persisted. This is a
  /// multi-chain import from a single recovery phrase; Solana (the always-on
  /// base chain) is the reported [AnalyticsProp.chain]. Guarded on registration
  /// so unit tests (no DI container) skip it.
  void _trackImported() {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImported,
        properties: {
          AnalyticsProp.chain: AnalyticsChain.solana.wire,
          AnalyticsProp.method: 'seed_phrase',
        },
      ),
    );
  }

  void _trackImportFailed(AppFailureKind kind) {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImportFailed,
        properties: {
          AnalyticsProp.method: 'seed_phrase',
          AnalyticsProp.reason: FailureReason.fromAppFailureKind(kind).wire,
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Derivation + enrichment helpers
  // ---------------------------------------------------------------------------

  /// Derive multi-chain addresses for [indices]. Returns the derived accounts
  /// and the set of addresses already imported. For a brand-new (pending)
  /// mnemonic nothing is imported yet, so the set is empty.
  ///
  /// A chain the user switched off is never derived — the rows are hidden
  /// anyway, and Ethereum in particular costs more per index than the other
  /// chains combined.
  Future<(List<AccountAddresses>, Set<String>, Map<int, String>)> _derive(
    List<int> indices,
    bool includeLegacy,
  ) async {
    final deriveEthereum = !_disabledChains.contains(Chain.ethereum);
    final deriveTezos = !_disabledChains.contains(Chain.tezos);
    if (_pendingMnemonic != null) {
      final accounts =
          await MultiChainDerivation.getMultiChainAddressesAtIndices(
            _pendingMnemonic!,
            indices,
            includeLegacyPaths: includeLegacy,
            deriveEthereum: deriveEthereum,
            deriveTezos: deriveTezos,
          );
      return (accounts, <String>{}, <int, String>{});
    }
    final info = await _walletRepo.deriveAccountsForPicker(
      _seedPhraseId,
      startIndex: indices.first,
      count: indices.length,
      includeLegacy: includeLegacy,
      deriveEthereum: deriveEthereum,
      deriveTezos: deriveTezos,
    );
    return (info.accounts, info.alreadyImported, info.importedNamesByIndex);
  }

  /// Read the user's Active Networks preference for the current session scope
  /// (this profile, or the account). Solana is always on; Tezos and Ethereum
  /// are togglable and default to enabled when unset.
  Future<Set<Chain>> _loadDisabledChains() async {
    final scope = await _session.settingsScopeId();
    final tezosEnabled = await _secureStorage.loadNetworkEnabled(
      Chain.tezos,
      scope: scope,
    );
    final ethEnabled = await _secureStorage.loadNetworkEnabled(
      Chain.ethereum,
      scope: scope,
    );
    return {if (!tezosEnabled) Chain.tezos, if (!ethEnabled) Chain.ethereum};
  }

  List<PickerAccount> _buildAccounts(
    List<AccountAddresses> addrs,
    Set<String> already,
    bool includeLegacy,
    Map<int, String> importedNames,
  ) {
    return addrs.map((a) {
      final wallets = <PickerWallet>[
        PickerWallet(
          accountIndex: a.index,
          chain: Chain.solana,
          address: a.solanaStandard,
          alreadyImported: already.contains(a.solanaStandard),
        ),
        if (includeLegacy && a.solanaLegacy != null)
          PickerWallet(
            accountIndex: a.index,
            chain: Chain.solana,
            scheme: SolanaDerivationScheme.legacy,
            address: a.solanaLegacy!,
            alreadyImported: already.contains(a.solanaLegacy),
          ),
        if (includeLegacy && a.solanaRoot != null)
          PickerWallet(
            accountIndex: a.index,
            chain: Chain.solana,
            scheme: SolanaDerivationScheme.root,
            address: a.solanaRoot!,
            alreadyImported: already.contains(a.solanaRoot),
          ),
        // Null when the chain was skipped at derivation time (switched off in
        // Active Networks) — there is no address to offer.
        if (a.tezos != null)
          PickerWallet(
            accountIndex: a.index,
            chain: Chain.tezos,
            address: a.tezos!,
            alreadyImported: already.contains(a.tezos),
          ),
        if (a.ethereum != null)
          PickerWallet(
            accountIndex: a.index,
            chain: Chain.ethereum,
            address: a.ethereum!,
            alreadyImported: already.contains(a.ethereum),
          ),
      ];
      return PickerAccount(
        index: a.index,
        // Hide chains the user switched off in Active Networks so their
        // addresses are neither shown nor importable. Derivation already skips
        // them; this stays the single point that enforces the policy.
        wallets: wallets
            .where((w) => !_disabledChains.contains(w.chain))
            .toList(),
        importedName: importedNames[a.index],
      );
    }).toList();
  }

  /// Enrich the Solana wallets in [target] accounts and merge into state.
  /// No accounts are selected by default — the user opts in explicitly.
  ///
  /// Each account merges the moment its own network calls settle. Waiting for
  /// the whole batch held every card's activity chip in shimmer behind the
  /// single slowest address.
  ///
  /// Only the enriched counts are merged, onto the rows state holds *now*.
  /// Swapping in the whole pre-enrichment account would re-insert rows a
  /// concurrent legacy toggle already removed — the settings sheet stays open
  /// while enrichment is in flight, so that race is reachable.
  Future<void> _enrichAndMerge(
    Emitter<ImportWalletsState> emit,
    List<PickerAccount> target,
  ) async {
    await Future.wait([
      for (final account in target)
        _enrichAccount(account).then((enriched) {
          final s = state;
          if (s is! ImportWalletsLoaded) return;
          final byKey = {for (final w in enriched.wallets) w.key: w};
          emit(
            s.copyWith(
              accounts: [
                for (final a in s.accounts)
                  if (a.index == enriched.index)
                    a.withWallets([
                      for (final w in a.wallets) _mergeCounts(w, byKey[w.key]),
                    ])
                  else
                    a,
              ],
            ),
          );
        }),
    ]);
  }

  /// Apply [enriched]'s counts to [row]. A row with no counterpart in the
  /// enrichment batch (added after it started) or one still awaiting its
  /// address is left untouched rather than shown as enriched.
  PickerWallet _mergeCounts(PickerWallet row, PickerWallet? enriched) {
    if (enriched == null || row.addressPending) return row;
    return row.copyWith(
      artworkCount: enriched.artworkCount,
      balanceUsd: enriched.balanceUsd,
    );
  }

  Future<PickerAccount> _enrichAccount(PickerAccount account) async {
    final wallets = await Future.wait(account.wallets.map(_enrichWallet));
    return account.withWallets(wallets);
  }

  Future<PickerWallet> _enrichWallet(PickerWallet w) async {
    if (!w.enrichable || w.alreadyImported || w.addressPending) return w;
    // Balance and artwork count are independent network calls — run them
    // concurrently. Each falls back to 0 when unavailable (offline /
    // unauthenticated / endpoint requires auth).
    final usdFuture = _tokenRepo
        .getTokenBalances(w.address)
        .then(_tokenRepo.calculateTotalValue)
        .catchError((_) => 0.0);
    final artworksFuture = _portfolioRepo
        .artworkCountForOwner(w.address)
        .catchError((_) => 0);
    final usd = await usdFuture;
    final artworks = await artworksFuture;
    return w.copyWith(artworkCount: artworks, balanceUsd: usd);
  }
}
