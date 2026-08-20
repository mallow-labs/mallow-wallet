import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:solana/base58.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/crypto/derivation.dart';
import '../../../core/models/account.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/services/ledger_open_app.dart';
import '../../../core/services/ledger_service.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../accounts/models/picker_account.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/token_repository.dart';

import '../../../shared/utils/chain.dart';
part 'ledger_connect_bloc.freezed.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

@freezed
abstract class LedgerConnectEvent with _$LedgerConnectEvent {
  const factory LedgerConnectEvent.startScan() = _StartScan;
  const factory LedgerConnectEvent.stopScan() = _StopScan;
  const factory LedgerConnectEvent.scanFinished() = _ScanFinished;
  const factory LedgerConnectEvent.deviceDiscovered(LedgerDevice device) =
      _DeviceDiscovered;
  const factory LedgerConnectEvent.connectDevice(LedgerDevice device) =
      _ConnectDevice;
  const factory LedgerConnectEvent.disconnect() = _Disconnect;
  const factory LedgerConnectEvent.loadAccounts() = _LoadAccounts;

  /// Toggle whether the legacy + root derivation-path cards are shown (the
  /// gear-sheet "Show legacy Solana accounts" switch).
  const factory LedgerConnectEvent.setIncludeLegacy(bool include) =
      _SetIncludeLegacy;

  /// Derive the next batch of derivation-index account cards.
  const factory LedgerConnectEvent.showMore() = _ShowMore;

  /// Toggle a single wallet row by its [PickerWallet.key].
  const factory LedgerConnectEvent.toggleWallet(String key) = _ToggleWallet;

  /// Toggle every selectable wallet in the path card at [index] (header
  /// "select all").
  const factory LedgerConnectEvent.toggleAccount(int index) = _ToggleAccount;
  const factory LedgerConnectEvent.importAccounts() = _ImportAccounts;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@freezed
abstract class LedgerConnectState with _$LedgerConnectState {
  const factory LedgerConnectState.initial() = _Initial;
  const factory LedgerConnectState.scanning({
    required List<LedgerDevice> devices,
    @Default(true) bool active,
  }) = _Scanning;
  const factory LedgerConnectState.connecting(LedgerDevice device) =
      _Connecting;
  const factory LedgerConnectState.connected(LedgerDevice device) = _Connected;
  const factory LedgerConnectState.loadingAccounts(LedgerDevice device) =
      _LoadingAccounts;
  const factory LedgerConnectState.accountsLoaded({
    required LedgerDevice device,
    required List<PickerAccount> accounts,
    @Default(false) bool includeLegacy,
    @Default({}) Set<String> selectedKeys,
    @Default(Chain.solana) Chain chain,
    // Next global account number when the picker opened; the live `Account NN`
    // preview numbers selected cards ascending from here.
    @Default(1) int baseCounter,
  }) = LedgerAccountsLoaded;
  const factory LedgerConnectState.importing() = _Importing;
  const factory LedgerConnectState.imported(List<WalletInfo> wallets) =
      _Imported;
  const factory LedgerConnectState.error(String message) = _Error;
}

// ---------------------------------------------------------------------------
// BLoC
// ---------------------------------------------------------------------------

@injectable
class LedgerConnectBloc extends Bloc<LedgerConnectEvent, LedgerConnectState> {
  LedgerConnectBloc(
    this._ledgerService,
    this._walletRepo,
    this._tokenRepo,
    this._portfolioRepo,
    this._prefs,
  ) : super(const LedgerConnectState.initial()) {
    on<_StartScan>(_onStartScan);
    on<_StopScan>(_onStopScan);
    on<_ScanFinished>(_onScanFinished);
    on<_DeviceDiscovered>(_onDeviceDiscovered);
    on<_ConnectDevice>(_onConnectDevice);
    on<_Disconnect>(_onDisconnect);
    on<_LoadAccounts>(_onLoadAccounts);
    on<_SetIncludeLegacy>(_onSetIncludeLegacy);
    on<_ShowMore>(_onShowMore);
    on<_ToggleWallet>(_onToggleWallet);
    on<_ToggleAccount>(_onToggleAccount);
    on<_ImportAccounts>(_onImportAccounts);
  }

  final LedgerService _ledgerService;
  final WalletRepository _walletRepo;
  final TokenRepository _tokenRepo;
  final PortfolioRepository _portfolioRepo;
  final PreferencesService _prefs;
  StreamSubscription<LedgerDevice>? _scanSub;
  StreamSubscription<void>? _scanFinishedSub;
  final _discoveredDevices = <LedgerDevice>[];

  /// Whether the legacy + root Solana rows are shown inside each account card
  /// (mirrors the seed-phrase import gear toggle; persisted via
  /// [PreferencesService]).
  bool _includeLegacy = false;

  /// Number of derivation-index account cards to derive; grown by "Show more".
  int _accountCount = 5;

  /// Which chain the import is for, decided by whichever app the user has open
  /// on the device (read on connect). A Ledger runs one app at a time, so a
  /// single session imports Solana, Ethereum, or Tezos accounts, never a mix.
  Chain _activeChain = Chain.solana;

  /// Selected wallets keyed by [PickerWallet.key]. Held while re-deriving so
  /// "Show more" and the legacy toggle don't drop existing selections; pruned
  /// to the visible keys whenever the cards are rebuilt.
  final _selectedByKey = <String, PickerWallet>{};
  LedgerDevice? _lastDevice;
  List<PickerAccount> _lastAccounts = const [];

  /// Next global account number, captured when the cards are first discovered.
  /// Base for the live `Account NN` preview in the picker.
  int _baseAccountNumber = 1;

  /// Number of currently selected accounts (readable from any state).
  int get selectedCount => _selectedByKey.length;

  Set<String> get _selectedKeys =>
      Set.unmodifiable(_selectedByKey.keys.toSet());

  /// All wallets in the currently-visible accounts, flattened.
  Iterable<PickerWallet> get _visibleWallets =>
      _lastAccounts.expand((a) => a.wallets);

  Future<void> _onStartScan(
    _StartScan event,
    Emitter<LedgerConnectState> emit,
  ) async {
    _discoveredDevices.clear();
    emit(
      LedgerConnectState.scanning(
        devices: List.unmodifiable(_discoveredDevices),
      ),
    );

    try {
      await _ledgerService.startScan();
      await _scanSub?.cancel();
      _scanSub = _ledgerService.scannedDevices.listen((device) {
        add(LedgerConnectEvent.deviceDiscovered(device));
      });
      await _scanFinishedSub?.cancel();
      _scanFinishedSub = _ledgerService.scanFinished.listen((_) {
        add(const LedgerConnectEvent.scanFinished());
      });
    } catch (e) {
      emit(LedgerConnectState.error(AppFailure.from(e).message));
    }
  }

  void _onDeviceDiscovered(
    _DeviceDiscovered event,
    Emitter<LedgerConnectState> emit,
  ) {
    if (_discoveredDevices.any((d) => d.id == event.device.id)) return;
    _discoveredDevices.add(event.device);
    emit(
      LedgerConnectState.scanning(
        devices: List.unmodifiable(_discoveredDevices),
      ),
    );
  }

  Future<void> _onStopScan(
    _StopScan event,
    Emitter<LedgerConnectState> emit,
  ) async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _scanFinishedSub?.cancel();
    _scanFinishedSub = null;
    await _ledgerService.stopScan();
  }

  void _onScanFinished(_ScanFinished event, Emitter<LedgerConnectState> emit) {
    // Only update if we're still in the scanning state — if the user already
    // tapped a device, we're connecting and shouldn't fall back to scan UI.
    state.maybeWhen(
      scanning: (devices, active) {
        if (!active) return;
        emit(
          LedgerConnectState.scanning(
            devices: List.unmodifiable(_discoveredDevices),
            active: false,
          ),
        );
      },
      orElse: () {},
    );
  }

  static const _maxConnectRetries = 2;

  Future<void> _onConnectDevice(
    _ConnectDevice event,
    Emitter<LedgerConnectState> emit,
  ) async {
    await _scanSub?.cancel();
    _scanSub = null;
    emit(LedgerConnectState.connecting(event.device));

    for (var attempt = 0; attempt <= _maxConnectRetries; attempt++) {
      try {
        await _ledgerService.connect(event.device);

        // Detect which app is open and route to that chain — no chain picker.
        final openApp = (await _ledgerService.getOpenApp()).openApp;
        if (openApp == LedgerOpenApp.unsupported) {
          emit(
            const LedgerConnectState.error(
              'Open the Solana, Ethereum, or Tezos app on your Ledger, then '
              'try again.',
            ),
          );
          return;
        }
        _activeChain = switch (openApp) {
          LedgerOpenApp.ethereum => Chain.ethereum,
          LedgerOpenApp.tezos => Chain.tezos,
          _ => Chain.solana,
        };

        emit(LedgerConnectState.connected(event.device));
        return;
      } on LedgerStalePairingException {
        emit(
          const LedgerConnectState.error(
            'Bluetooth pairing is out of sync. Go to Settings \u2192 Bluetooth, '
            'tap the info button next to your Ledger, and choose "Forget '
            'This Device". Then try connecting again.',
          ),
        );
        return;
      } on StateError catch (e, st) {
        debugPrint(
          '[LedgerConnect] connect attempt ${attempt + 1} '
          'StateError: $e',
        );
        debugPrint('[LedgerConnect] stackTrace: $st');

        if (attempt < _maxConnectRetries) {
          // Disconnect, pause, and retry — this typically resolves the issue.
          try {
            await _ledgerService.disconnect();
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }

        emit(
          const LedgerConnectState.error(
            'Could not read from Ledger. Unlock your device and try again.',
          ),
        );
      } catch (e, st) {
        debugPrint('[LedgerConnect] connect error: $e');
        debugPrint('[LedgerConnect] stackTrace: $st');
        emit(
          const LedgerConnectState.error(
            'Could not connect. Make sure the Solana, Ethereum, or Tezos app '
            'is open on your Ledger.',
          ),
        );
        return;
      }
    }
  }

  Future<void> _onDisconnect(
    _Disconnect event,
    Emitter<LedgerConnectState> emit,
  ) async {
    await _ledgerService.disconnect();
    emit(const LedgerConnectState.initial());
  }

  Future<void> _onLoadAccounts(
    _LoadAccounts event,
    Emitter<LedgerConnectState> emit,
  ) async {
    _includeLegacy = _prefs.showLegacySolanaImport;
    await _discoverAccounts(emit);
  }

  Future<void> _onSetIncludeLegacy(
    _SetIncludeLegacy event,
    Emitter<LedgerConnectState> emit,
  ) async {
    await _prefs.setShowLegacySolanaImport(event.include);
    if (_includeLegacy == event.include) return;
    _includeLegacy = event.include;
    await _discoverAccounts(emit);
  }

  Future<void> _onShowMore(
    _ShowMore event,
    Emitter<LedgerConnectState> emit,
  ) async {
    _accountCount += 5;
    await _discoverAccounts(emit);
  }

  void _onToggleWallet(_ToggleWallet event, Emitter<LedgerConnectState> emit) {
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
    _ToggleAccount event,
    Emitter<LedgerConnectState> emit,
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

  /// Re-emit the loaded state with the current visible accounts and selection.
  void _emitAccountsLoaded(Emitter<LedgerConnectState> emit) {
    final device = _lastDevice;
    if (device == null) return;
    emit(
      LedgerConnectState.accountsLoaded(
        device: device,
        accounts: _lastAccounts,
        includeLegacy: _includeLegacy,
        selectedKeys: _selectedKeys,
        chain: _activeChain,
        baseCounter: _baseAccountNumber,
      ),
    );
  }

  /// Derive `_accountCount` derivation-index cards for the active chain
  /// (decided by whichever app is open on the device).
  Future<void> _discoverAccounts(Emitter<LedgerConnectState> emit) async {
    final device = _ledgerService.connectedDevice;
    if (device == null) {
      emit(const LedgerConnectState.error('Ledger not connected'));
      return;
    }

    _lastDevice = device;
    emit(LedgerConnectState.loadingAccounts(device));

    try {
      _baseAccountNumber = await _walletRepo.peekNextAccountNumber();
      final existingWallets = await _walletRepo.getAllWallets();
      final existingAddresses = existingWallets.map((w) => w.address).toSet();

      // Stored names of already-imported hardware accounts, keyed by derivation
      // index, so a user-edited name shows in the picker instead of `Account NN`.
      final importedNames = <int, String>{
        for (final a in await _walletRepo.getAccountViews())
          if (a.kind == AccountKind.hardware && a.derivationIndex != null)
            a.derivationIndex!: a.name,
      };

      final accounts = switch (_activeChain) {
        Chain.ethereum => await _deriveEthereumAccounts(
          existingAddresses,
          importedNames,
        ),
        Chain.tezos => await _deriveTezosAccounts(
          existingAddresses,
          importedNames,
        ),
        Chain.solana => await _deriveSolanaAccounts(
          existingAddresses,
          importedNames,
        ),
      };

      _lastAccounts = accounts;
      _pruneSelection();
      _emitAccountsLoaded(emit);

      // Only Solana rows carry activity chips to fill in; Ethereum is
      // display-only, so skip the (no-op) enrichment re-emit for it.
      if (_activeChain == Chain.solana) {
        final enriched = await _enrichAccounts(accounts);
        _lastAccounts = enriched;
        _emitAccountsLoaded(emit);
      }
    } catch (e) {
      emit(LedgerConnectState.error(AppFailure.from(e).message));
    }
  }

  /// Derive Solana cards: standard rows always, plus legacy (every index) and
  /// root (index 0 only) when [_includeLegacy] is on. Mirrors the seed-phrase
  /// import card layout.
  Future<List<PickerAccount>> _deriveSolanaAccounts(
    Set<String> existingAddresses,
    Map<int, String> importedNames,
  ) async {
    final standard = await _ledgerService.discoverAccounts(
      count: _accountCount,
    );
    final legacy = _includeLegacy
        ? await _ledgerService.discoverAccounts(
            count: _accountCount,
            scheme: SolanaDerivationScheme.legacy,
          )
        : const <Uint8List>[];
    // Root is the bare m/44'/501' path — a single index-0-only address.
    final root = _includeLegacy
        ? await _ledgerService.discoverAccounts(
            count: 1,
            scheme: SolanaDerivationScheme.root,
          )
        : const <Uint8List>[];

    PickerWallet wallet(int i, Uint8List pubkey, SolanaDerivationScheme s) {
      final address = base58encode(pubkey.toList());
      return PickerWallet(
        accountIndex: i,
        chain: Chain.solana,
        address: address,
        alreadyImported: existingAddresses.contains(address),
        scheme: s,
      );
    }

    final accounts = <PickerAccount>[];
    for (var i = 0; i < standard.length; i++) {
      accounts.add(
        PickerAccount(
          index: i,
          importedName: importedNames[i],
          wallets: [
            wallet(i, standard[i], SolanaDerivationScheme.standard),
            if (i < legacy.length)
              wallet(i, legacy[i], SolanaDerivationScheme.legacy),
            if (i == 0 && root.isNotEmpty)
              wallet(0, root[0], SolanaDerivationScheme.root),
          ],
        ),
      );
    }
    return accounts;
  }

  /// Derive Ethereum cards: one `m/44'/60'/0'/0/{index}` row per derivation
  /// index. Ethereum has no legacy/root schemes, so each card holds one row.
  Future<List<PickerAccount>> _deriveEthereumAccounts(
    Set<String> existingAddresses,
    Map<int, String> importedNames,
  ) async {
    final derived = await _ledgerService.discoverEthereumAccounts(
      count: _accountCount,
    );

    final accounts = <PickerAccount>[];
    for (var i = 0; i < derived.length; i++) {
      final address = MultiChainDerivation.checksumEthereumAddress(
        derived[i].address,
      );
      accounts.add(
        PickerAccount(
          index: i,
          importedName: importedNames[i],
          wallets: [
            PickerWallet(
              accountIndex: i,
              chain: Chain.ethereum,
              address: address,
              alreadyImported: existingAddresses.contains(address),
            ),
          ],
        ),
      );
    }
    return accounts;
  }

  /// Derive Tezos cards: one `m/44'/1729'/{index}'/0'` row per derivation
  /// index. Tezos has no legacy/root schemes, so each card holds one row. The
  /// device returns a raw Ed25519 public key, which we encode to a `tz1`
  /// address (matching the app's seed-phrase Tezos derivation).
  Future<List<PickerAccount>> _deriveTezosAccounts(
    Set<String> existingAddresses,
    Map<int, String> importedNames,
  ) async {
    final pubkeys = await _ledgerService.discoverTezosAccounts(
      count: _accountCount,
    );

    final accounts = <PickerAccount>[];
    for (var i = 0; i < pubkeys.length; i++) {
      final address = MultiChainDerivation.tezosAddressFromPublicKey(
        pubkeys[i],
      );
      accounts.add(
        PickerAccount(
          index: i,
          importedName: importedNames[i],
          wallets: [
            PickerWallet(
              accountIndex: i,
              chain: Chain.tezos,
              address: address,
              alreadyImported: existingAddresses.contains(address),
            ),
          ],
        ),
      );
    }
    return accounts;
  }

  /// Drop selections whose wallet no longer appears in the visible cards (e.g.
  /// the legacy/root rows after the gear toggle is switched off).
  void _pruneSelection() {
    final validKeys = _visibleWallets.map((w) => w.key).toSet();
    _selectedByKey.removeWhere((key, _) => !validKeys.contains(key));
  }

  Future<List<PickerAccount>> _enrichAccounts(
    List<PickerAccount> accounts,
  ) async {
    return Future.wait(
      accounts.map((a) async {
        final wallets = await Future.wait(a.wallets.map(_enrichWallet));
        return a.withWallets(wallets);
      }),
    );
  }

  Future<PickerWallet> _enrichWallet(PickerWallet w) async {
    if (!w.enrichable || w.alreadyImported) return w;
    // Balance and artwork count are independent network calls — run them
    // concurrently. Each falls back to 0 when unavailable so we don't show a
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

  /// Per-row wallet name, matching the seed-phrase import naming.
  static String _walletName(Chain chain, SolanaDerivationScheme? scheme) {
    if (chain == Chain.ethereum) return 'Ethereum';
    if (chain == Chain.tezos) return 'Tezos';
    return switch (scheme ?? SolanaDerivationScheme.standard) {
      SolanaDerivationScheme.standard => 'Solana',
      SolanaDerivationScheme.legacy => 'Solana (legacy)',
      SolanaDerivationScheme.root => 'Solana (root)',
    };
  }

  Future<void> _onImportAccounts(
    _ImportAccounts event,
    Emitter<LedgerConnectState> emit,
  ) async {
    if (_selectedByKey.isEmpty) return;

    emit(const LedgerConnectState.importing());

    try {
      final device = _ledgerService.connectedDevice;
      final wallets = <WalletInfo>[];

      // Create accounts in ascending derivation-index order so the global
      // `Account NN` numbers assigned match the picker's ascending preview,
      // regardless of the order the user tapped the rows.
      final selectedAscending = _selectedByKey.values.toList()
        ..sort((a, b) => a.accountIndex.compareTo(b.accountIndex));

      for (final selected in selectedAscending) {
        final scheme = selected.scheme ?? SolanaDerivationScheme.standard;
        final wallet = await _walletRepo.addLedgerWallet(
          selected.address,
          _walletName(selected.chain, selected.scheme),
          derivationIndex: selected.accountIndex,
          derivationScheme: scheme,
          chain: selected.chain,
          ledgerDeviceId: device?.id,
        );
        wallets.add(wallet);
      }

      _selectedByKey.clear();

      // Switch the session to the imported account so the drawer/home header
      // shows its name (e.g. "Account 05") instead of the wallet's chain-label
      // name. switchToWallet takes the wallet's whole account along and anchors
      // auth on the wallet for an Eth/Tezos-only account (no Solana signer).
      // Skip when the active Profile already links one of these addresses, so
      // the user stays on their Profile rather than jumping to the new account.
      final session = sl<SessionManager>();
      if (wallets.isNotEmpty &&
          !session.activeProfileContainsAnyAddress(
            wallets.map((w) => w.address),
          )) {
        await session.switchToWallet(wallets.last.id);
      }

      emit(LedgerConnectState.imported(wallets));
      _trackImported(_activeChain);
    } on DuplicateWalletException {
      emit(const LedgerConnectState.error('One or more wallets already exist'));
      _trackImportFailed(FailureReason.unknown);
    } catch (e) {
      // Ledger-specific signing failures (SigningException and friends) are
      // classified onto AppFailureKind.signing by AppFailure.from.
      final failure = AppFailure.from(e);
      emit(LedgerConnectState.error(failure.message));
      _trackImportFailed(FailureReason.fromAppFailureKind(failure.kind));
    }
  }

  /// Fire `Wallet Imported` once the selected Ledger accounts are persisted.
  /// Guarded on registration so unit tests (no DI container) skip it.
  void _trackImported(Chain chain) {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImported,
        properties: {
          AnalyticsProp.chain: AnalyticsChain.fromChain(chain).wire,
          AnalyticsProp.method: 'ledger',
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
          AnalyticsProp.method: 'ledger',
          AnalyticsProp.reason: reason.wire,
        },
      ),
    );
  }

  @override
  Future<void> close() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _scanFinishedSub?.cancel();
    _scanFinishedSub = null;
    await _ledgerService.stopScan();
    await _ledgerService.disconnect();
    return super.close();
  }
}
