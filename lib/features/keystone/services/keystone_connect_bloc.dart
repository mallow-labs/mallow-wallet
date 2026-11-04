import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:solana/solana.dart' show Ed25519HDPublicKey;

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/crypto/derivation.dart';
import '../../../core/models/account.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/services/keystone_sign_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart';
import '../../accounts/models/picker_account.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/token_repository.dart';

const _tag = 'KeystoneConnect';

/// The UR type a Keystone account export arrives as.
const kKeystoneExportType = 'crypto-multi-accounts';

/// The UR types the import scanner accepts. Connect Software Wallet's entries
/// send one of these: an account export (Solflare, Backpack), one key
/// (MetaMask), or an account (MetaMask's Ledger Live layout). What a code
/// holds is read from its contents, not from the entry that made it.
const kKeystoneImportTypes = {
  kKeystoneExportType,
  RegistryType.cryptoHdKey,
  RegistryType.cryptoAccount,
};

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// Hand-written rather than generated, like the Seed Vault bloc's, so the
/// feature builds without a codegen pass.
sealed class KeystoneConnectEvent {
  const KeystoneConnectEvent();
}

/// A complete UR (one of [kKeystoneImportTypes]) came off the scanner.
class KeystoneExportScanned extends KeystoneConnectEvent {
  const KeystoneExportScanned(this.ur);
  final UR ur;
}

/// Start over: forget every code scanned so far and go back to the scanner.
class KeystoneRescanRequested extends KeystoneConnectEvent {
  const KeystoneRescanRequested();
}

/// Back to the scanner for one more code, keeping what is already scanned —
/// from the picker, or to clear a refusal.
class KeystoneScanAnotherRequested extends KeystoneConnectEvent {
  const KeystoneScanAnotherRequested();
}

/// Leave the scanner for the picker of the codes already scanned.
class KeystoneBackToAccountsRequested extends KeystoneConnectEvent {
  const KeystoneBackToAccountsRequested();
}

class KeystoneToggleWallet extends KeystoneConnectEvent {
  const KeystoneToggleWallet(this.key);
  final String key;
}

class KeystoneToggleAccount extends KeystoneConnectEvent {
  const KeystoneToggleAccount(this.index);
  final int index;
}

/// Name the not-yet-imported account at derivation [index]. A blank [name]
/// clears it back to the default `Account NN`.
class KeystoneRenameAccount extends KeystoneConnectEvent {
  const KeystoneRenameAccount(this.index, this.name);
  final int index;
  final String name;
}

class KeystoneImportRequested extends KeystoneConnectEvent {
  const KeystoneImportRequested();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

sealed class KeystoneConnectState {
  const KeystoneConnectState();
}

/// Waiting for the user to scan a code from the device.
///
/// [error] is the reason the last scan was refused, shown under the scanner.
class KeystoneScanning extends KeystoneConnectState {
  const KeystoneScanning({
    this.error,
    this.notice,
    this.generation = 0,
    this.canReturn = false,
    this.canStartOver = false,
  });
  final String? error;

  /// What the last code added and what to scan next, when it was accepted but
  /// gave no account to list (an Ethereum key with nothing to join).
  final String? notice;

  /// Accounts from earlier codes are waiting in the picker.
  final bool canReturn;

  /// Something has been scanned, so there is something to start over from.
  final bool canStartOver;

  /// Identifies the attempt so a retry replaces even an accepted scanner
  /// whose error and rescan both arrived before the next frame.
  final int generation;
}

class KeystoneAccountsLoaded extends KeystoneConnectState {
  const KeystoneAccountsLoaded({
    required this.accounts,
    required this.selectedKeys,
    required this.baseCounter,
    required this.masterFingerprint,
    this.customNames = const {},
  });

  final List<PickerAccount> accounts;
  final Set<String> selectedKeys;

  /// Names the user typed in the picker, keyed by derivation index. Applied
  /// when the account is created on import; see [previewAccountNames].
  final Map<int, String> customNames;

  /// Next global account number when the picker opened; the live `Account NN`
  /// preview numbers selected cards ascending from here.
  final int baseCounter;

  /// The device the export came from, shown so a user with two Keystones can
  /// tell which one this is.
  final int masterFingerprint;
}

class KeystoneImporting extends KeystoneConnectState {
  const KeystoneImporting();
}

class KeystoneImported extends KeystoneConnectState {
  const KeystoneImported(this.wallets);
  final List<WalletInfo> wallets;
}

class KeystoneConnectError extends KeystoneConnectState {
  const KeystoneConnectError(this.message);
  final String message;
}

// ---------------------------------------------------------------------------
// Export parsing
// ---------------------------------------------------------------------------

/// One importable wallet from a code: its chain, where it sits and its
/// address.
class KeystoneExportedWallet {
  const KeystoneExportedWallet({
    required this.index,
    required this.address,
    this.scheme,
    this.chain = Chain.solana,
  });

  final int index;
  final Chain chain;

  /// The Solana path; null for an Ethereum row, which has one layout.
  final SolanaDerivationScheme? scheme;
  final String address;
}

/// What one scanned code holds: the device it came from, its Solana accounts,
/// and its BIP-44 standard Ethereum account key. Either may be missing, not
/// both.
typedef KeystoneCode = ({
  int masterFingerprint,
  List<KeystoneExportedWallet> solana,
  KeystoneHdKey? ethereum,
});

// Keep our import guidance distinct from package diagnostics so only these
// rejections' messages can be shown directly to the user.
class _ImportGuidanceException extends UrDecodeException {
  _ImportGuidanceException(super.message);
}

/// Reads whatever [ur] carries, whichever Connect Software Wallet entry made
/// it: Solflare's export has Solana accounts, MetaMask's one Ethereum key, and
/// Backpack's both.
///
/// Throws [UrDecodeException] for a code that cannot be read. Package messages
/// are diagnostic text; a code with nothing to import, or with Ethereum only in
/// a Ledger layout, carries guidance naming the entry to choose.
///
/// The code is untrusted input — anything scanned off a screen is — so the
/// package's decoder enforces the shape (key lengths, known path shapes,
/// index cap, key-count cap). An Ethereum key in a Ledger layout, or one that
/// does not derive, is left out rather than refusing the Solana accounts
/// beside it: its addresses sit at other paths than the one the app signs
/// with.
KeystoneCode parseKeystoneCode(UR ur) {
  var solana = const <KeystoneExportedWallet>[];
  int? fingerprint;
  if (ur.type == kKeystoneExportType) {
    final export = KeystoneMultiAccounts.fromUr(ur);
    fingerprint = export.masterFingerprint;
    solana = [
      for (final a in solanaAccountsFromExport(export))
        KeystoneExportedWallet(
          index: a.index,
          scheme: solanaSchemeFromKeystone(a.scheme),
          address: Ed25519HDPublicKey(a.publicKey).toBase58(),
        ),
    ];
  }
  final ethereum = _standardEthereumXpubOrNull(ur);
  if (solana.isEmpty && ethereum == null) {
    if (_hasLedgerEthereumLayout(ur)) {
      throw _ImportGuidanceException(
        'That Ethereum code uses a Ledger account layout. On your Keystone, '
        'choose MetaMask, then BIP44 Standard.',
      );
    }
    throw _ImportGuidanceException(
      'That code has no Solana or Ethereum accounts. On your Keystone, open '
      'Connect Software Wallet and choose Solflare or MetaMask.',
    );
  }
  return (
    // A standard key always carries the fingerprint (ethStandardXpubFromUr).
    masterFingerprint: fingerprint ?? ethereum!.origin!.sourceFingerprint!,
    solana: solana,
    ethereum: ethereum,
  );
}

bool _hasLedgerEthereumLayout(UR ur) {
  try {
    return switch (classifyEthExport(ur)) {
      KeystoneEthExportKind.ledgerLegacy ||
      KeystoneEthExportKind.ledgerLive => true,
      _ => false,
    };
  } on UrDecodeException {
    return false;
  }
}

/// The standard Ethereum key in [ur], or null when there is none, it is in
/// another layout, or it does not derive: the decoder checks the key's length
/// and prefix, not that it is a point on the curve.
KeystoneHdKey? _standardEthereumXpubOrNull(UR ur) {
  try {
    if (classifyEthExport(ur) != KeystoneEthExportKind.bip44Standard) {
      return null;
    }
    final xpub = ethStandardXpubFromUr(ur);
    keystoneEthereumAddress(xpub, 0);
    return xpub;
  } on UrDecodeException catch (e) {
    AppLogger.debug(_tag, 'Ethereum key skipped: ${e.message}');
    return null;
  } catch (_) {
    AppLogger.debug(_tag, 'Ethereum key skipped: it does not derive');
    return null;
  }
}

/// One Ethereum wallet per index, or none when the key does not derive: the
/// decoder checks the key's length and prefix, not that it is a point on the
/// curve, and a bad key must not refuse the Solana accounts beside it.
List<KeystoneExportedWallet> _ethereumWalletsOrEmpty(
  KeystoneHdKey xpub,
  List<int> indices,
) {
  try {
    return [
      for (final index in indices)
        KeystoneExportedWallet(
          index: index,
          chain: Chain.ethereum,
          address: keystoneEthereumAddress(xpub, index),
        ),
    ];
  } catch (_) {
    AppLogger.debug(_tag, 'Ethereum key skipped: it does not derive');
    return const [];
  }
}

/// The Ethereum address at account [index] under a BIP-44 standard [xpub], as
/// [ethStandardXpubFromUr] returns it (33-byte key, 32-byte chain code).
String keystoneEthereumAddress(KeystoneHdKey xpub, int index) =>
    MultiChainDerivation.ethereumAddressFromAccountXpub(
      xpub.keyData,
      xpub.chainCode!,
      index,
    );

// ---------------------------------------------------------------------------
// BLoC
// ---------------------------------------------------------------------------

/// The Keystone import flow: scan codes → pick → persist.
///
/// The user scans whatever code the device shows, and as many as they like:
/// each adds what it holds to one picker. Solflare's code carries Solana
/// accounts only, MetaMask's an Ethereum key only, Backpack's both. An
/// Ethereum key adds a row on every account index known for the device — the
/// Solana accounts scanned so far and the device's accounts already in mallow
/// — since the key alone says nothing about which indexes the user holds.
/// Every code must come from the same device; switching devices is a start
/// over.
///
/// The peer of `SeedVaultConnectBloc`, and shaped like it: the same
/// [PickerAccount] cards, the same ascending import so previewed `Account NN`
/// names are the ones assigned, and the same active-Profile guard on the
/// post-import session switch.
///
/// Unlike the other two pickers there is no legacy toggle. The Keystone code
/// is already the user's choice of path — Solflare's entry exports the
/// standard path, Backpack's the legacy one — so hiding the legacy rows would
/// show a Backpack code as empty. Every account scanned is shown.
class KeystoneConnectBloc
    extends Bloc<KeystoneConnectEvent, KeystoneConnectState> {
  KeystoneConnectBloc(this._walletRepo, this._tokenRepo, this._portfolioRepo)
    : super(const KeystoneScanning()) {
    on<KeystoneExportScanned>(_onScanned);
    on<KeystoneRescanRequested>(_onRescan);
    on<KeystoneScanAnotherRequested>(_onScanAnother);
    on<KeystoneBackToAccountsRequested>(_onBackToAccounts);
    on<KeystoneToggleWallet>(_onToggleWallet);
    on<KeystoneToggleAccount>(_onToggleAccount);
    on<KeystoneRenameAccount>(_onRenameAccount);
    on<KeystoneImportRequested>(_onImport);
  }

  final WalletRepository _walletRepo;
  final TokenRepository _tokenRepo;
  final PortfolioRepository _portfolioRepo;

  final _selectedByKey = <String, PickerWallet>{};

  /// Names the user typed in the picker, keyed by derivation index. Dropped by
  /// a start over, which may switch to another device.
  Map<int, String> _customNames = const {};

  // Keep the device identity with its accounts so a rescan cannot lend an
  // older export a different fingerprint when it finishes loading.
  ({List<PickerAccount> accounts, int baseCounter, int masterFingerprint})?
  _loadedExport;

  // Everything scanned since the flow opened or the user started over: the
  // device, its Solana accounts by row key, and its Ethereum account key.
  int? _device;
  final _scannedSolana = <String, KeystoneExportedWallet>{};
  KeystoneHdKey? _scannedEthereum;

  /// Bumped by every scan and every move between scanner and picker, so a
  /// scan's lookups cannot land after the user has moved on.
  int _scanGeneration = 0;

  /// Bumped only by a start over. Enrichment outlives a move to the scanner
  /// for another code — its rows are still in the picker — but not this.
  int _session = 0;
  bool _scanInProgress = false;

  Iterable<PickerWallet> get _visibleWallets =>
      _loadedExport?.accounts.expand((a) => a.wallets) ?? const [];

  Set<String> get _selectedKeys =>
      Set.unmodifiable(_selectedByKey.keys.toSet());

  void _emitScanning(
    Emitter<KeystoneConnectState> emit, {
    String? error,
    String? notice,
  }) => emit(
    KeystoneScanning(
      error: error,
      notice: notice,
      generation: _scanGeneration,
      canReturn: _loadedExport != null,
      canStartOver: _device != null,
    ),
  );

  Future<void> _onScanned(
    KeystoneExportScanned event,
    Emitter<KeystoneConnectState> emit,
  ) async {
    if (state is! KeystoneScanning || _scanInProgress) return;
    final generation = ++_scanGeneration;
    final session = _session;
    _scanInProgress = true;
    final KeystoneCode code;
    try {
      code = parseKeystoneCode(event.ur);
    } on _ImportGuidanceException catch (e) {
      _scanInProgress = false;
      _emitScanning(emit, error: e.message);
      return;
    } catch (e) {
      // Untrusted input: whatever the parse throws, the scan must reset
      // rather than leave [_scanInProgress] set and the scanner idle.
      _scanInProgress = false;
      AppLogger.debug(
        _tag,
        e is UrDecodeException ? e.message : 'export parse failed',
      );
      _emitScanning(
        emit,
        error:
            "That code couldn't be read. On your Keystone, open Connect "
            'Software Wallet and choose Solflare or MetaMask.',
      );
      return;
    }

    final device = _device;
    if (device != null && code.masterFingerprint != device) {
      // Rows from two devices would make one picker whose accounts sign on
      // different hardware under one fingerprint label.
      _scanInProgress = false;
      _emitScanning(
        emit,
        error:
            'That code is from Keystone '
            '${formatMasterFingerprint(code.masterFingerprint)}, and the '
            'accounts so far are from Keystone '
            '${formatMasterFingerprint(device)}. Tap Start over to switch '
            'devices.',
      );
      return;
    }

    try {
      final baseCounter = await _walletRepo.peekNextAccountNumber();
      if (generation != _scanGeneration) return;
      final existingWallets = await _walletRepo.getAllWallets();
      if (generation != _scanGeneration) return;
      // Lower-cased: an Ethereum address may be stored in another casing,
      // and Solana addresses never collide case-insensitively in practice.
      final existing = existingWallets
          .map((w) => w.address.toLowerCase())
          .toSet();
      final accountViews = await _walletRepo.getAccountViews();
      if (generation != _scanGeneration) return;

      final masterFingerprint = code.masterFingerprint;
      // Names of this device's already-imported accounts, by index, so an
      // edited name shows instead of `Account NN`. Matched on the fingerprint
      // too: another Keystone's account at the same index is a different
      // account, and borrowing its name would preview a name the import never
      // assigns.
      final importedNames = <int, String>{
        for (final a in accountViews)
          if (a.kind == AccountKind.keystone &&
              a.derivationIndex != null &&
              a.primaryWallet?.masterFingerprint == masterFingerprint)
            a.derivationIndex!: a.name,
      };

      final solana = {
        ..._scannedSolana,
        for (final w in code.solana) '${w.index}:${w.scheme?.name}': w,
      };
      final ethereum = code.ethereum ?? _scannedEthereum;
      final ethereumIndexes = {
        for (final w in solana.values) w.index,
        ...importedNames.keys,
      }.toList()..sort();
      final exported = [
        ...solana.values,
        if (ethereum != null)
          ..._ethereumWalletsOrEmpty(ethereum, ethereumIndexes),
      ];

      _device = masterFingerprint;
      _scannedSolana
        ..clear()
        ..addAll(solana);
      _scannedEthereum = ethereum;

      if (exported.isEmpty) {
        _emitScanning(
          emit,
          notice:
              'Ethereum added. Now scan a Solana code, so mallow knows which '
              'accounts to add it to: on your Keystone, choose Solflare or '
              'Backpack.',
        );
        return;
      }

      // Rows scanned before keep their balances rather than loading again.
      final previous = {for (final w in _visibleWallets) w.key: w};
      final byIndex = <int, List<PickerWallet>>{};
      for (final w in exported) {
        final row = PickerWallet(
          accountIndex: w.index,
          chain: w.chain,
          address: w.address,
          alreadyImported: existing.contains(w.address.toLowerCase()),
          scheme: w.scheme,
        );
        final before = previous[row.key];
        byIndex
            .putIfAbsent(w.index, () => [])
            .add(
              before != null && before.address == row.address
                  ? row.copyWith(
                      artworkCount: before.artworkCount,
                      balanceUsd: before.balanceUsd,
                    )
                  : row,
            );
      }
      final indices = byIndex.keys.toList()..sort();
      final accounts = [
        for (final index in indices)
          PickerAccount(
            index: index,
            importedName: importedNames[index],
            wallets: _sortRows(byIndex[index]!),
          ),
      ];
      _loadedExport = (
        accounts: accounts,
        baseCounter: baseCounter,
        masterFingerprint: masterFingerprint,
      );
      // A selection survives another scan while its row is still selectable.
      final selectable = {
        for (final w in accounts.expand((a) => a.wallets))
          if (!w.alreadyImported && !w.addressPending) w.key: w,
      };
      final kept = {
        for (final key in _selectedByKey.keys) key: ?selectable[key],
      };
      _selectedByKey
        ..clear()
        ..addAll(kept);
      _emitAccountsLoaded(emit);

      await _enrichLoaded(session, emit);
    } catch (e) {
      if (generation != _scanGeneration) return;
      AppLogger.error(_tag, 'could not load the Keystone export', e);
      _emitScanning(emit, error: AppFailure.from(e).message);
    } finally {
      if (generation == _scanGeneration) _scanInProgress = false;
    }
  }

  void _onRescan(
    KeystoneRescanRequested event,
    Emitter<KeystoneConnectState> emit,
  ) {
    ++_scanGeneration;
    ++_session;
    _scanInProgress = false;
    _selectedByKey.clear();
    _customNames = const {};
    _loadedExport = null;
    _device = null;
    _scannedSolana.clear();
    _scannedEthereum = null;
    _emitScanning(emit);
  }

  void _onScanAnother(
    KeystoneScanAnotherRequested event,
    Emitter<KeystoneConnectState> emit,
  ) {
    if (state is! KeystoneScanning && state is! KeystoneAccountsLoaded) return;
    ++_scanGeneration;
    _scanInProgress = false;
    _emitScanning(emit);
  }

  void _onBackToAccounts(
    KeystoneBackToAccountsRequested event,
    Emitter<KeystoneConnectState> emit,
  ) {
    if (state is! KeystoneScanning || _loadedExport == null) return;
    ++_scanGeneration;
    _scanInProgress = false;
    _emitAccountsLoaded(emit);
  }

  /// Solana standard, then legacy, then root, then Ethereum inside a card —
  /// the order the other pickers use.
  static List<PickerWallet> _sortRows(List<PickerWallet> rows) =>
      [...rows]..sort((a, b) {
        int rank(PickerWallet w) => switch (w.chain) {
          Chain.solana => switch (w.scheme) {
            SolanaDerivationScheme.standard || null => 0,
            SolanaDerivationScheme.legacy => 1,
            SolanaDerivationScheme.root => 2,
          },
          Chain.ethereum => 3,
          Chain.tezos => 4,
        };
        return rank(a).compareTo(rank(b));
      });

  void _emitAccountsLoaded(Emitter<KeystoneConnectState> emit) {
    final export = _loadedExport;
    if (export == null) return;
    emit(
      KeystoneAccountsLoaded(
        accounts: export.accounts,
        selectedKeys: _selectedKeys,
        baseCounter: export.baseCounter,
        masterFingerprint: export.masterFingerprint,
        customNames: _customNames,
      ),
    );
  }

  void _onToggleWallet(
    KeystoneToggleWallet event,
    Emitter<KeystoneConnectState> emit,
  ) {
    if (state is! KeystoneAccountsLoaded) return;
    if (_selectedByKey.containsKey(event.key)) {
      _selectedByKey.remove(event.key);
    } else {
      final wallet = _visibleWallets.firstWhereOrNull(
        (w) => w.key == event.key,
      );
      if (wallet == null || wallet.alreadyImported) return;
      _selectedByKey[event.key] = wallet;
    }
    _emitAccountsLoaded(emit);
  }

  void _onToggleAccount(
    KeystoneToggleAccount event,
    Emitter<KeystoneConnectState> emit,
  ) {
    if (state is! KeystoneAccountsLoaded) return;
    final account = _loadedExport?.accounts.firstWhereOrNull(
      (a) => a.index == event.index,
    );
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

  void _onRenameAccount(
    KeystoneRenameAccount event,
    Emitter<KeystoneConnectState> emit,
  ) {
    final export = _loadedExport;
    if (state is! KeystoneAccountsLoaded || export == null) return;
    final names = renamePickerAccount(
      accounts: export.accounts,
      customNames: _customNames,
      index: event.index,
      name: event.name,
    );
    if (names == null) return;
    _customNames = names;
    _emitAccountsLoaded(emit);
  }

  // ---------------------------------------------------------------------------
  // Enrichment
  // ---------------------------------------------------------------------------

  /// Loads balances for the picker's rows that have none yet, then writes them
  /// into whatever the picker holds by then: another code may have been
  /// scanned meanwhile, and its rows must not be replaced by this older list.
  Future<void> _enrichLoaded(
    int session,
    Emitter<KeystoneConnectState> emit,
  ) async {
    final pending = _visibleWallets
        .where((w) => w.enrichable && !w.alreadyImported)
        .where((w) => w.artworkCount == null)
        .toList();
    if (pending.isEmpty) return;
    final enriched = {
      for (final w in await Future.wait(pending.map(_enrichWallet))) w.key: w,
    };
    final export = _loadedExport;
    if (session != _session || export == null) return;
    _loadedExport = (
      accounts: [
        for (final a in export.accounts)
          a.withWallets([
            for (final w in a.wallets)
              if (enriched[w.key] case final e?
                  when e.address == w.address && w.artworkCount == null)
                w.copyWith(
                  artworkCount: e.artworkCount,
                  balanceUsd: e.balanceUsd,
                )
              else
                w,
          ]),
      ],
      baseCounter: export.baseCounter,
      masterFingerprint: export.masterFingerprint,
    );
    if (state is KeystoneAccountsLoaded) _emitAccountsLoaded(emit);
  }

  Future<PickerWallet> _enrichWallet(PickerWallet w) async {
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

  static String _walletName(PickerWallet w) => switch (w.chain) {
    Chain.solana => switch (w.scheme ?? SolanaDerivationScheme.standard) {
      SolanaDerivationScheme.standard => 'Solana',
      SolanaDerivationScheme.legacy => 'Solana (legacy)',
      SolanaDerivationScheme.root => 'Solana (root)',
    },
    Chain.ethereum => 'Ethereum',
    // No Keystone export yields a Tezos row: the firmware has no Tezos app.
    Chain.tezos => throw StateError('Keystone has no Tezos wallets'),
  };

  Future<void> _onImport(
    KeystoneImportRequested event,
    Emitter<KeystoneConnectState> emit,
  ) async {
    final export = _loadedExport;
    if (state is! KeystoneAccountsLoaded ||
        export == null ||
        _selectedByKey.isEmpty) {
      return;
    }

    emit(const KeystoneImporting());

    try {
      final wallets = <WalletInfo>[];
      // Ascending by index so the `Account NN` numbers assigned match the
      // picker's ascending preview, whatever order the rows were tapped in.
      final selectedAscending = _selectedByKey.values.toList()
        ..sort((a, b) => a.accountIndex.compareTo(b.accountIndex));

      for (final selected in selectedAscending) {
        wallets.add(
          await _walletRepo.addKeystoneWallet(
            selected.address,
            _walletName(selected),
            masterFingerprint: export.masterFingerprint,
            derivationIndex: selected.accountIndex,
            derivationScheme:
                selected.scheme ?? SolanaDerivationScheme.standard,
            chain: selected.chain,
            accountName: _customNames[selected.accountIndex],
          ),
        );
      }
      _selectedByKey.clear();
      _customNames = const {};

      final session = sl<SessionManager>();
      final solanaImported = wallets.any(
        (w) => w.chain == Chain.solana.toDbString(),
      );
      final existingIndexes = {
        for (final a in export.accounts)
          if (a.importedName != null) a.index,
      };
      final joinsExistingAccounts = selectedAscending.every(
        (w) => existingIndexes.contains(w.accountIndex),
      );
      if (wallets.isNotEmpty && !solanaImported && joinsExistingAccounts) {
        // Ethereum added beside accounts already here: stay put. The session
        // caches the active account's wallets, and the browser and the
        // chain-specific lookups read that copy, so re-read it or the new
        // wallet stays invisible until the account is selected again. The
        // wallets are saved, so a failed re-read is not an import error; the
        // next account switch re-reads anyway.
        try {
          await session.refreshActiveAccount();
        } catch (e) {
          AppLogger.error(_tag, 'session refresh after import failed', e);
        }
      } else if (wallets.isNotEmpty &&
          !session.activeProfileContainsAnyAddress(
            wallets.map((w) => w.address),
          )) {
        // Switch to the imported account so the drawer and header show it —
        // unless the active Profile already links one of these addresses, in
        // which case importing its Keystone backing must leave the user there.
        // A Solana row when there is one: it is the chain the app signs in
        // with, and an Ethereum row sits beside it on the same account.
        final target = wallets.lastWhere(
          (w) => w.chain == Chain.solana.toDbString(),
          orElse: () => wallets.last,
        );
        await session.switchToWallet(target.id);
      }

      emit(KeystoneImported(wallets));
      _track(AnalyticsEvent.walletImported, {
        AnalyticsProp.chain: AnalyticsChain.fromChain(
          solanaImported ? Chain.solana : Chain.ethereum,
        ).wire,
        AnalyticsProp.method: 'keystone',
      });
    } on DuplicateWalletException {
      emit(const KeystoneConnectError('One or more wallets already exist'));
      _trackFailed(FailureReason.unknown);
    } on GraphSyncException {
      // Either superseding a view-only wallet at an address failed (nothing
      // added) or a wallet's row landed and the graph write after it failed,
      // so the copy claims neither — a retry of the second case is refused
      // as a duplicate.
      emit(
        const KeystoneConnectError(
          'Could not update recovery data. Check your wallet list '
          'before trying again.',
        ),
      );
      _trackFailed(FailureReason.unknown);
    } catch (e) {
      final failure = AppFailure.from(e);
      emit(KeystoneConnectError(failure.message));
      _trackFailed(FailureReason.fromAppFailureKind(failure.kind));
    }
  }

  void _trackFailed(FailureReason reason) => _track(
    AnalyticsEvent.walletImportFailed,
    {AnalyticsProp.method: 'keystone', AnalyticsProp.reason: reason.wire},
  );

  /// Guarded on registration so unit tests (no DI container) skip it.
  void _track(String event, Map<String, Object?> properties) {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(sl<AnalyticsService>().track(event, properties: properties));
  }
}
