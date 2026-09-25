import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

import 'package:ledger_solana/ledger_solana.dart';

import '../../shared/utils/chain.dart'
    show Chain, apiOwnerAddress, isEthereumAddress;
import '../crypto/derivation.dart';
import '../crypto/mnemonic_generator.dart';
import '../crypto/private_key_parser.dart';
import '../database/database.dart';
import '../models/account.dart';
import '../observability/app_logger.dart';
import '../security/secure_storage.dart';
import 'preferences_service.dart';

/// Thrown when attempting to import a wallet whose address already exists.
class DuplicateWalletException implements Exception {
  DuplicateWalletException(this.address);
  final String address;

  @override
  String toString() => 'A wallet with this address already exists';
}

/// Thrown when a removal cannot prune the recovery graph. The graph write is
/// the commit point of a removal: nothing is deleted until it succeeds, so a
/// caller that sees this can tell the user nothing changed.
class GraphSyncException implements Exception {
  GraphSyncException(this.cause);
  final Object cause;

  @override
  String toString() => 'Could not update recovery data: $cause';
}

/// What [WalletRepository.restoreDormantFromGraph] did on this launch.
class DormantRestoreResult {
  const DormantRestoreResult({
    this.seedPhrasesRestored = 0,
    this.walletsRestored = 0,
    this.duplicatesDropped = 0,
    this.skipped = 0,
    this.liveSeedUnreadable = false,
  });

  final int seedPhrasesRestored;
  final int walletsRestored;

  /// Dormant entries whose secret equals a live one — pruned and deleted.
  final int duplicatesDropped;

  /// Dormant entries whose secret could not be read this launch; left in the
  /// graph for the next one.
  final int skipped;

  /// A *live* seed's mnemonic did not read, so no dormant seed could be
  /// compared and every one of them was skipped. Correct for one launch, and
  /// invisible forever if that seed never reads again: the dormant seeds are
  /// then skipped at every cold start with nothing to say why. Reported so the
  /// permanent case can be told from the transient one.
  ///
  /// Not part of [isEmpty]: the flag is only ever set on the way to skipping
  /// the dormant seed that asked for the comparison, so [skipped] is already
  /// non-zero whenever it is true.
  final bool liveSeedUnreadable;

  bool get isEmpty =>
      seedPhrasesRestored == 0 &&
      walletsRestored == 0 &&
      duplicatesDropped == 0 &&
      skipped == 0;
}

/// Outcome of [WalletRepository.restoreFromGraph].
sealed class RestoreResult {
  const RestoreResult();
}

/// The graph was written — every row of it, or (after an opt-in
/// `readableOnly` restore) every row whose secret could be read.
class RestoreRestored extends RestoreResult {
  const RestoreRestored({
    required this.seedPhrases,
    required this.wallets,
    this.skippedSeedPhrases = 0,
    this.skippedImportedKeys = 0,
  });

  final int seedPhrases;
  final int wallets;

  /// Entries a `readableOnly` restore left alone because their secret did not
  /// read. They stay in the graph, so the boot-time dormant restore retries
  /// them and a later restore can still pick them up.
  final int skippedSeedPhrases;
  final int skippedImportedKeys;
}

/// Nothing was written: at least one seed phrase or imported key listed in
/// the graph could not be read from the vault. Counts are for the message;
/// ids are deliberately not carried (they name secrets).
class RestoreAborted extends RestoreResult {
  const RestoreAborted({
    required this.missingSeedPhrases,
    required this.totalSeedPhrases,
    required this.missingImportedKeys,
    required this.totalImportedKeys,
    this.readableWallets = 0,
  });

  final int missingSeedPhrases;
  final int totalSeedPhrases;
  final int missingImportedKeys;
  final int totalImportedKeys;

  /// Wallets in the graph a partial restore could still write **and that
  /// could then sign**: an HD wallet of a readable seed, an imported key whose
  /// own secret reads, or a social row (a re-login recovers its key).
  ///
  /// View-only and hardware rows (Ledger, Seed Vault) are deliberately
  /// excluded. They restore fine — and a partial restore does write them — but
  /// they carry no key, so a graph of {one unreadable seed + one watch-only
  /// address} must not count as "something can be read": that partial
  /// restore would put a wallet in the database, report success, and take
  /// the Restore screen away from a user whose seed is still unrecovered.
  final int readableWallets;

  bool get hasMissing => missingSeedPhrases > 0 || missingImportedKeys > 0;

  /// Whether a `readableOnly: true` restore would write anything the user can
  /// sign with. When false the only ways forward are a retry and Start fresh.
  bool get hasReadable =>
      totalSeedPhrases - missingSeedPhrases > 0 ||
      totalImportedKeys - missingImportedKeys > 0 ||
      readableWallets > 0;
}

/// The graph could not be parsed, or the transactional write failed (and was
/// rolled back).
class RestoreFailed extends RestoreResult {
  const RestoreFailed(this.error);

  final Object error;
}

/// The restore pre-check's answer: the [RestoreAborted] a full restore would
/// return, plus the ids behind its counts so a partial restore can skip them.
class _MissingSecrets {
  const _MissingSecrets({
    required this.aborted,
    required this.seedPhraseIds,
    required this.importedKeyIds,
  });

  final RestoreAborted aborted;
  final Set<String> seedPhraseIds;
  final Set<String> importedKeyIds;
}

/// Info about a derived address for the HD picker screen.
class DerivedAddressInfo {
  const DerivedAddressInfo({
    required this.index,
    required this.address,
    required this.alreadyImported,
  });

  final int index;
  final String address;
  final bool alreadyImported;
}

/// Multi-chain account addresses derived for the import picker, paired with
/// the subset of those addresses that are already imported.
class AccountPickerInfo {
  const AccountPickerInfo({
    required this.accounts,
    required this.alreadyImported,
    this.importedNamesByIndex = const {},
  });

  final List<AccountAddresses> accounts;

  /// Addresses (across all chains/schemes) already present in the DB.
  final Set<String> alreadyImported;

  /// Stored account names keyed by derivation index, for indices that already
  /// have an imported account on this seed phrase. Lets the picker surface a
  /// user-edited name instead of the default `Account NN`.
  final Map<int, String> importedNamesByIndex;
}

/// One chain's key material for a social-login account, handed from the auth
/// service into [WalletRepository.addSocialAccount].
///
/// Deliberately hand-written rather than freezed: a generated `toString` prints
/// every field, and `debugPrint` is not stripped from release builds — its
/// output reaches the platform log (logcat / OSLog), where anything printed is
/// readable off the device. So a generated `toString` would put the private key
/// there.
class SocialChainCredential {
  const SocialChainCredential({required this.address, required this.storedKey});

  /// The on-chain address this key derives.
  final String address;

  /// The private key in the exact format the imported-key loaders expect
  /// (Solana: base58 of the 64-byte keypair; Ethereum and Tezos: the raw hex
  /// secp256k1 key, used directly / as an ed25519 seed respectively).
  final String storedKey;

  @override
  String toString() =>
      'SocialChainCredential(address: $address, storedKey: <redacted>)';
}

/// A single wallet the user chose to import from the phrase picker.
class WalletImportSelection {
  const WalletImportSelection({
    required this.index,
    required this.chain,
    required this.address,
    this.scheme,
  });

  final int index;
  final Chain chain;
  final String address;

  /// Solana derivation scheme; null for standard Solana and non-Solana chains.
  final SolanaDerivationScheme? scheme;
}

/// Manages seed phrases and wallets across DB and secure storage.
///
/// Replaces AccountRepository — no account CRUD; seed phrases are the
/// top-level grouping for HD wallets. Non-HD wallets (imported key,
/// view-only, social) are standalone.
@lazySingleton
class WalletRepository {
  WalletRepository(this._db, this._storage, this._prefs);

  final MallowDatabase _db;
  final SecureWalletStorage _storage;
  final PreferencesService _prefs;

  // Serializes every mutation of the wallet set. Not a nicety: the recovery
  // graph is rebuilt from the *whole* database on each mutation, so two of
  // them in flight un-prune each other. A removal prunes an entry, then
  // deletes its rows and secrets; a plain sync (a rename, a reorder, a wallet
  // switch) landing in that gap rebuilds the graph from a database that still
  // holds the row and writes the pruned entry straight back — indexing a
  // secret the removal is about to delete. That entry is a zombie: the boot
  // restore aborts on it forever, and the only way out erases the readable
  // seeds too. It also makes dedupe-by-mnemonic race-safe against a
  // double-tapped onboarding button, which is what it originally guarded.
  //
  // Taken by the public entry points only. Nothing below them may take it
  // again — a nested take waits for its own caller and deadlocks.
  Future<void> _mutationLock = Future.value();

  Future<T> _locked<T>(Future<T> Function() body) {
    final op = _mutationLock.then((_) => body());
    _mutationLock = op.then((_) {
      walletsRevision.value++;
    }, onError: (_) {});
    return op;
  }

  /// Bumped after every successful mutation taken through [_locked].
  ///
  /// Deliberately hung off the lock rather than off individual call sites: the
  /// push-token sync has to mirror the wallets on this device, and wiring it to
  /// each add/remove/import/reset entry point means the next one added silently
  /// stops syncing. Every mutation already goes through here, so nothing can
  /// opt out.
  ///
  /// A revision counter, not the wallet list: it fires for renames and reorders
  /// too, and listeners are expected to re-read and no-op when nothing they care
  /// about changed.
  final ValueNotifier<int> walletsRevision = ValueNotifier(0);

  // ---------------------------------------------------------------------------
  // Read
  // ---------------------------------------------------------------------------

  /// Get all wallets.
  Future<List<WalletInfo>> getAllWallets() async {
    final rows = await _db.getAllWallets();
    return rows.map(_walletRowToInfo).toList();
  }

  /// Get all seed phrases.
  Future<List<SeedPhraseInfo>> getAllSeedPhrases() async {
    final rows = await _db.getAllSeedPhrases();
    return rows.map(_seedPhraseRowToInfo).toList();
  }

  /// Returns the id of the seed phrase already stored for [mnemonic], or null
  /// when this mnemonic has not been imported on this device. Lets the import
  /// picker fold a re-typed phrase into its existing seed so prior imports
  /// surface as already-imported rather than fresh rows. Mirrors the dedupe in
  /// [_createSeedPhraseFromMnemonicLocked].
  Future<String?> findSeedPhraseIdForMnemonic(String mnemonic) async {
    final normalized = mnemonic.trim().toLowerCase();
    final existingSeedPhrases = await _db.getAllSeedPhrases();
    for (final sp in existingSeedPhrases) {
      final existing = await _storage.loadMnemonicForSeedPhrase(sp.id);
      if (existing == normalized) return sp.id;
    }
    return null;
  }

  /// Get wallets for a specific seed phrase.
  Future<List<WalletInfo>> getWalletsForSeedPhrase(String seedPhraseId) async {
    final rows = await _db.getWalletsForSeedPhrase(seedPhraseId);
    return rows.map(_walletRowToInfo).toList();
  }

  /// Get the wallet rows of one account.
  ///
  /// Narrower than [getAccountViews], which loads every account and its rows —
  /// this is for a caller that already has an account id in hand, e.g. social
  /// key recovery resolving the account's provider and Solana address.
  Future<List<WalletInfo>> getWalletsForAccount(String accountId) async {
    final rows = await _db.getWalletsForAccount(accountId);
    return rows.map(_walletRowToInfo).toList();
  }

  /// Get the currently active wallet.
  Future<WalletInfo?> getActiveWallet() async {
    final walletId = await _storage.loadSelectedWalletId();
    if (walletId == null) return null;
    final row = await _db.getWalletById(walletId);
    if (row == null) return null;
    return _walletRowToInfo(row);
  }

  /// Get a single wallet by ID.
  Future<WalletInfo?> getWalletById(String walletId) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) return null;
    return _walletRowToInfo(row);
  }

  /// Get a single wallet by its on-chain address (EVM matched
  /// case-insensitively, see [_lookupWalletByAddress]).
  Future<WalletInfo?> getWalletByAddress(String address) async {
    final row = await _lookupWalletByAddress(address);
    if (row == null) return null;
    return _walletRowToInfo(row);
  }

  /// Check if any wallets exist.
  Future<bool> hasAnyWallets() => _db.hasAnyWallets();

  /// Get account views — one [Account] per row in the Accounts table, each
  /// with its wallets, ordered by sortIndex.
  ///
  /// A pure read: every wallet is assigned its account at creation time, so no
  /// reconciliation pass is needed here.
  Future<List<Account>> getAccountViews() async {
    final accountRows = await _db.getAllAccounts();
    final result = <Account>[];
    for (final a in accountRows) {
      final walletRows = await _db.getWalletsForAccount(a.id);
      result.add(
        Account(
          id: a.id,
          name: a.name,
          avatarSeed: a.avatarSeed,
          kind: AccountKind.fromDbString(a.kind),
          seedPhraseId: a.seedPhraseId,
          derivationIndex: a.derivationIndex,
          sortIndex: a.sortIndex,
          wallets: walletRows.map(_walletRowToInfo).toList(),
        ),
      );
    }
    return result;
  }

  /// Get the active selection as (Account, WalletInfo).
  Future<(Account, WalletInfo)?> getActiveSelection() async {
    final walletId = await _storage.loadSelectedWalletId();
    if (walletId == null) return null;

    final walletRow = await _db.getWalletById(walletId);
    if (walletRow == null) return null;

    final wallet = _walletRowToInfo(walletRow);
    final accounts = await getAccountViews();
    final account = accounts.cast<Account?>().firstWhere(
      (a) => a!.wallets.any((w) => w.id == walletId),
      orElse: () => null,
    );
    if (account == null) return null;

    return (account, wallet);
  }

  /// Resolve on-chain [addresses] to the local Account each belongs to, for
  /// display of the account's `Account NN` name + generated avatar in place of
  /// a bare address. Addresses without a stored wallet (or whose wallet has no
  /// account) are absent from the result. The match is case-insensitive so a
  /// checksummed EVM address still resolves against the stored wallet.
  Future<Map<String, ({String name, String avatarSeed})>> accountsForAddresses(
    List<String> addresses,
  ) async {
    if (addresses.isEmpty) return const {};
    final walletRows = await _db.getAllWallets();
    final accountRows = await _db.getAllAccounts();
    final accountsById = {for (final a in accountRows) a.id: a};
    final walletByAddress = {
      for (final w in walletRows) w.address.toLowerCase(): w,
    };
    final result = <String, ({String name, String avatarSeed})>{};
    for (final address in addresses) {
      final wallet = walletByAddress[address.toLowerCase()];
      final accountId = wallet?.accountId;
      if (accountId == null) continue;
      final account = accountsById[accountId];
      if (account == null) continue;
      result[address] = (name: account.name, avatarSeed: account.avatarSeed);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Create Seed Phrase
  // ---------------------------------------------------------------------------

  /// Create a new seed phrase with a freshly generated mnemonic and derive
  /// the first HD wallet.
  Future<SeedPhraseInfo> createNewSeedPhrase({bool use24Words = false}) async {
    final mnemonic = use24Words
        ? MnemonicGenerator.generate24Words()
        : MnemonicGenerator.generate12Words();
    return _createSeedPhraseFromMnemonic(mnemonic);
  }

  /// Create a seed phrase from an existing mnemonic.
  ///
  /// When [autoDerive] is true (default), also derives the first HD wallet
  /// and auto-selects it. Set to false when navigating to the HD picker so
  /// the user can choose which wallets to import.
  Future<SeedPhraseInfo> createSeedPhrase(
    String mnemonic, {
    bool autoDerive = true,
  }) async {
    final normalized = mnemonic.trim().toLowerCase();
    if (!MnemonicGenerator.validate(normalized)) {
      throw ArgumentError('Invalid mnemonic');
    }
    return _createSeedPhraseFromMnemonic(normalized, autoDerive: autoDerive);
  }

  Future<SeedPhraseInfo> _createSeedPhraseFromMnemonic(
    String normalizedMnemonic, {
    bool autoDerive = true,
  }) => _locked(
    () => _createSeedPhraseFromMnemonicLocked(
      normalizedMnemonic,
      autoDerive: autoDerive,
    ),
  );

  Future<SeedPhraseInfo> _createSeedPhraseFromMnemonicLocked(
    String normalizedMnemonic, {
    required bool autoDerive,
  }) async {
    // Dedupe by mnemonic: returning the existing seed phrase here prevents
    // duplicate rows when the same mnemonic is submitted more than once.
    final existingSeedPhrases = await _db.getAllSeedPhrases();
    for (final sp in existingSeedPhrases) {
      final existing = await _storage.loadMnemonicForSeedPhrase(sp.id);
      if (existing == normalizedMnemonic) {
        return _seedPhraseRowToInfo(sp);
      }
    }

    final seedPhraseId = _generateId();
    final seedPhraseName = 'Seed ${existingSeedPhrases.length + 1}';
    final spSortIndex = await _db.maxSeedPhraseSortIndex() + 1;

    // Store mnemonic
    await _storage.storeMnemonicForSeedPhrase(seedPhraseId, normalizedMnemonic);

    // Create seed phrase row
    await _db.upsertSeedPhrase(
      SeedPhrasesCompanion.insert(
        id: seedPhraseId,
        name: seedPhraseName,
        createdAt: _nowSeconds(),
        sortIndex: Value(spSortIndex),
      ),
    );

    if (autoDerive) {
      // Derive the full first account — Solana, Ethereum, and Tezos at index 0
      // — so the initial wallet is the complete multi-chain account, matching
      // the import picker. importAccountsFromPhrase creates the account, inserts
      // each chain's wallet, and auto-selects the first Solana wallet.
      final addresses =
          await MultiChainDerivation.getMultiChainAddressesAtIndices(
            normalizedMnemonic,
            const [0],
          );
      final first = addresses.first;
      // The private body, not the public entry point: this already holds the
      // mutation lock, and taking it again would wait for itself.
      await _importAccountsFromPhraseLocked(seedPhraseId, [
        WalletImportSelection(
          index: 0,
          chain: Chain.solana,
          address: first.solanaStandard,
        ),
        // Both are derived here (no chain is skipped on this path), so the
        // guards only satisfy the nullable fields.
        if (first.ethereum != null)
          WalletImportSelection(
            index: 0,
            chain: Chain.ethereum,
            address: first.ethereum!,
          ),
        if (first.tezos != null)
          WalletImportSelection(
            index: 0,
            chain: Chain.tezos,
            address: first.tezos!,
          ),
      ]);
    }

    final info = SeedPhraseInfo(id: seedPhraseId, name: seedPhraseName);
    await _syncWalletGraph();
    return info;
  }

  // ---------------------------------------------------------------------------
  // Add Standalone Wallets
  // ---------------------------------------------------------------------------

  /// Address dedupe lookup. EVM (`0x…`) addresses are matched
  /// case-insensitively — the same account can arrive EIP-55 checksummed (from
  /// ENS resolution/derivation) or lowercased (from a pasted address), and both
  /// forms must collapse to one wallet row. Solana/Tezos encodings are
  /// case-significant, so they fall back to an exact match.
  Future<Wallet?> _lookupWalletByAddress(String address) {
    return isEthereumAddress(address)
        ? _db.getWalletByAddressLower(address)
        : _db.getWalletByAddress(address);
  }

  /// Frees [address] for a signing-capable import (HD, imported key, hardware,
  /// or social). A signing wallet takes precedence over a watch-only one: when
  /// a view-only wallet already occupies this address, it is removed (along
  /// with its now-empty account) so the caller can proceed with the import.
  ///
  /// Returns true when the address is available to import — either nothing was
  /// there, or a view-only wallet was cleared. Returns false when a signing
  /// wallet already holds the address, i.e. a genuine duplicate the caller must
  /// reject (or skip).
  ///
  /// Throws [GraphSyncException] when the view-only wallet's prune from the
  /// recovery graph fails: that write is the commit point of its removal, so
  /// nothing was deleted and the import cannot proceed — every signing-import
  /// caller surfaces that as a recovery-data error and adds nothing.
  Future<bool> _clearWatchOnlyForSigningImport(String address) async {
    final existing = await _lookupWalletByAddress(address);
    if (existing == null) return true;
    if (WalletType.fromDbString(existing.walletType) != WalletType.viewOnly) {
      return false;
    }

    // A view-only wallet is always alone in its account (see
    // addViewOnlyWallet), so removing it empties the account and the removal
    // takes the account row with it — inside the same graph prune, rather than
    // leaving a dangling watch-only account for the next sync to write out.
    //
    // The private removal, not [removeWallet]: every caller of this already
    // holds the mutation lock, and taking it again would wait for itself.
    await _removeWallets([existing.id]);
    return true;
  }

  /// Add an imported private key wallet.
  Future<WalletInfo> addImportedKeyWallet(String privateKey, String name) =>
      _locked(() => _addImportedKeyWalletLocked(privateKey, name));

  Future<WalletInfo> _addImportedKeyWalletLocked(
    String privateKey,
    String name,
  ) async {
    final parsed = await PrivateKeyParser.parse(privateKey);

    // A signing import supersedes a watch-only wallet of the same address; a
    // real signer already there is a genuine duplicate.
    if (!await _clearWatchOnlyForSigningImport(parsed.address)) {
      throw DuplicateWalletException(parsed.address);
    }

    final walletId = _generateId();
    await _storage.storePrivateKey(walletId, parsed.storedKey);
    final sortIndex = await _db.maxWalletSortIndex() + 1;
    // Account label comes from the global counter (`Account NN`); the caller's
    // [name] stays the wallet-row label.
    final accountId = await _createAccount(kind: AccountKind.privateKey);

    await _db.upsertWalletEntry(
      WalletsCompanion.insert(
        id: walletId,
        accountId: Value(accountId),
        address: parsed.address,
        name: name,
        walletType: WalletType.importedKey.toDbString(),
        chain: Value(parsed.chain.toDbString()),
        createdAt: _nowSeconds(),
        sortIndex: Value(sortIndex),
      ),
    );

    final wallet = WalletInfo(
      id: walletId,
      address: parsed.address,
      name: name,
      walletType: WalletType.importedKey,
      chain: parsed.chain.toDbString(),
      accountId: accountId,
    );

    // Only auto-select if there's no current selection (onboarding case).
    // Post-onboarding, the caller must call WalletManager.switchWalletById
    // so the wallet-changed event fires and AuthService re-logs in.
    if (await _storage.loadSelectedWalletId() == null) {
      await _storage.storeSelectedWalletId(walletId);
    }
    await _syncWalletGraph();
    return wallet;
  }

  /// Add a view-only wallet.
  Future<WalletInfo> addViewOnlyWallet(String address, String name) =>
      _locked(() => _addViewOnlyWalletLocked(address, name));

  Future<WalletInfo> _addViewOnlyWalletLocked(
    String address,
    String name,
  ) async {
    final existing = await _lookupWalletByAddress(address);
    if (existing != null) throw DuplicateWalletException(address);

    final walletId = _generateId();
    final sortIndex = await _db.maxWalletSortIndex() + 1;
    // Infer the chain from the address shape so an EVM (`0x…`) or Tezos watch
    // address isn't stored as Solana — a wrong chain mislabels the receive QR
    // and routes balance lookups to the wrong network.
    final chain = Chain.fromAddress(address);
    // Account label comes from the global counter (`Account NN`); the caller's
    // [name] stays the wallet-row label.
    final accountId = await _createAccount(kind: AccountKind.viewOnly);
    await _db.upsertWalletEntry(
      WalletsCompanion.insert(
        id: walletId,
        accountId: Value(accountId),
        address: address,
        name: name,
        walletType: WalletType.viewOnly.toDbString(),
        chain: Value(chain.toDbString()),
        createdAt: _nowSeconds(),
        sortIndex: Value(sortIndex),
      ),
    );

    final wallet = WalletInfo(
      id: walletId,
      address: address,
      name: name,
      walletType: WalletType.viewOnly,
      chain: chain.toDbString(),
      accountId: accountId,
    );

    if (await _storage.loadSelectedWalletId() == null) {
      await _storage.storeSelectedWalletId(walletId);
    }
    await _syncWalletGraph();
    return wallet;
  }

  /// Add a Ledger hardware wallet.
  ///
  /// [chain] reflects which Ledger app the account was derived from (Solana or
  /// Ethereum). Along with [derivationIndex] and [ledgerDeviceId], this is the
  /// data required to re-derive the key and sign on-device later.
  Future<WalletInfo> addLedgerWallet(
    String address,
    String name, {
    int derivationIndex = 0,
    SolanaDerivationScheme derivationScheme = SolanaDerivationScheme.standard,
    Chain chain = Chain.solana,
    String? ledgerDeviceId,
  }) => _locked(
    () => _addLedgerWalletLocked(
      address,
      name,
      derivationIndex: derivationIndex,
      derivationScheme: derivationScheme,
      chain: chain,
      ledgerDeviceId: ledgerDeviceId,
    ),
  );

  Future<WalletInfo> _addLedgerWalletLocked(
    String address,
    String name, {
    required int derivationIndex,
    required SolanaDerivationScheme derivationScheme,
    required Chain chain,
    required String? ledgerDeviceId,
  }) async {
    // A signing import supersedes a watch-only wallet of the same address; a
    // real signer already there is a genuine duplicate.
    if (!await _clearWatchOnlyForSigningImport(address)) {
      throw DuplicateWalletException(address);
    }

    final walletId = _generateId();
    final sortIndex = await _db.maxWalletSortIndex() + 1;
    final accountId = await _ensureHardwareAccount(derivationIndex);

    await _db.upsertWalletEntry(
      WalletsCompanion.insert(
        id: walletId,
        accountId: Value(accountId),
        address: address,
        name: name,
        walletType: WalletType.ledger.toDbString(),
        derivationIndex: Value(derivationIndex),
        derivationScheme: Value(derivationScheme.name),
        chain: Value(chain.toDbString()),
        createdAt: _nowSeconds(),
        sortIndex: Value(sortIndex),
      ),
    );

    if (ledgerDeviceId != null) {
      await _storage.storeLedgerDeviceId(walletId, ledgerDeviceId);
    }

    final wallet = WalletInfo(
      id: walletId,
      address: address,
      name: name,
      walletType: WalletType.ledger,
      chain: chain.toDbString(),
      derivationIndex: derivationIndex,
      derivationScheme: derivationScheme,
      accountId: accountId,
    );

    if (await _storage.loadSelectedWalletId() == null) {
      await _storage.storeSelectedWalletId(walletId);
    }
    await _syncWalletGraph();
    return wallet;
  }

  /// Add a Seed Vault wallet.
  ///
  /// [addLedgerWallet] minus the device-id write: Seed Vault holds the key
  /// itself and is addressed by the running device, so there is nothing of ours
  /// to store — no secret, and no new row shape. The chain is always Solana
  /// because Seed Vault defines exactly one signing purpose.
  ///
  /// [derivationIndex] and [derivationScheme] are persisted for display, the
  /// `Account NN` grouping and the import picker; the path actually signed with
  /// is the one the vault itself reports, never one rebuilt from these.
  Future<WalletInfo> addSeedVaultWallet(
    String address,
    String name, {
    int derivationIndex = 0,
    SolanaDerivationScheme derivationScheme = SolanaDerivationScheme.standard,
  }) => _locked(
    () => _addSeedVaultWalletLocked(
      address,
      name,
      derivationIndex: derivationIndex,
      derivationScheme: derivationScheme,
    ),
  );

  Future<WalletInfo> _addSeedVaultWalletLocked(
    String address,
    String name, {
    required int derivationIndex,
    required SolanaDerivationScheme derivationScheme,
  }) async {
    // A signing import supersedes a watch-only wallet of the same address; a
    // real signer already there is a genuine duplicate.
    if (!await _clearWatchOnlyForSigningImport(address)) {
      throw DuplicateWalletException(address);
    }

    final walletId = _generateId();
    final sortIndex = await _db.maxWalletSortIndex() + 1;
    final accountId = await _ensureSeedVaultAccount(derivationIndex);

    await _db.upsertWalletEntry(
      WalletsCompanion.insert(
        id: walletId,
        accountId: Value(accountId),
        address: address,
        name: name,
        walletType: WalletType.seedVault.toDbString(),
        derivationIndex: Value(derivationIndex),
        derivationScheme: Value(derivationScheme.name),
        chain: Value(Chain.solana.toDbString()),
        createdAt: _nowSeconds(),
        sortIndex: Value(sortIndex),
      ),
    );

    final wallet = WalletInfo(
      id: walletId,
      address: address,
      name: name,
      walletType: WalletType.seedVault,
      chain: Chain.solana.toDbString(),
      derivationIndex: derivationIndex,
      derivationScheme: derivationScheme,
      accountId: accountId,
    );

    if (await _storage.loadSelectedWalletId() == null) {
      await _storage.storeSelectedWalletId(walletId);
    }
    await _syncWalletGraph();
    return wallet;
  }

  /// Add — or complete — the multi-chain account behind a social login.
  ///
  /// One social identity becomes one [AccountKind.social] account holding one
  /// [WalletType.social] row per chain, the same shape a seed-phrase account
  /// gets from [importAccountsFromPhrase]. Each row owns a private key in
  /// secure storage in the format the imported-key loaders expect, so social
  /// rows sign locally through the existing `importedKey` paths.
  ///
  /// Idempotent (create-or-complete). Re-logging in with the same identity
  /// reuses the account behind the Solana address, inserts whatever chain rows
  /// are missing, and re-stores every key — that last part is also the
  /// key-recovery path for a wiped keystore. The returned `existed` reports
  /// whether the social account was already present.
  ///
  /// Per address: a watch-only wallet is superseded, as for any signing import.
  /// A *different* signing wallet type (HD / imported key / Ledger) already at
  /// one of the addresses is a genuine duplicate and throws
  /// [DuplicateWalletException] — checked for all three addresses before
  /// anything is written, so a collision cannot leave a half-built account.
  Future<({List<WalletInfo> wallets, bool existed})> addSocialAccount({
    required String provider,
    required String name,
    required SocialChainCredential solana,
    required SocialChainCredential ethereum,
    required SocialChainCredential tezos,
  }) => _locked(
    () => _addSocialAccountLocked(
      provider: provider,
      name: name,
      solana: solana,
      ethereum: ethereum,
      tezos: tezos,
    ),
  );

  Future<({List<WalletInfo> wallets, bool existed})> _addSocialAccountLocked({
    required String provider,
    required String name,
    required SocialChainCredential solana,
    required SocialChainCredential ethereum,
    required SocialChainCredential tezos,
  }) async {
    // Account-card order: Solana, then Tezos, then Ethereum (matches
    // [_walletImportOrder], which orders a seed account's rows).
    final credentials = <(Chain, SocialChainCredential)>[
      (Chain.solana, solana),
      (Chain.tezos, tezos),
      (Chain.ethereum, ethereum),
    ];

    for (final (_, cred) in credentials) {
      final row = await _lookupWalletByAddress(cred.address);
      if (row == null) continue;
      final type = WalletType.fromDbString(row.walletType);
      if (type != WalletType.social && type != WalletType.viewOnly) {
        throw DuplicateWalletException(cred.address);
      }
    }

    // The Solana row identifies the account: a social row already there means
    // this identity logged in before (or holds a legacy Solana-only row).
    final existingSolana = await _lookupWalletByAddress(solana.address);
    final existed =
        existingSolana != null &&
        WalletType.fromDbString(existingSolana.walletType) == WalletType.social;

    var accountId = existed ? existingSolana.accountId : null;
    if (accountId == null) {
      // Account label comes from the global counter (`Account NN`); the
      // caller's [name] stays the wallet-row label.
      //
      // The avatar is seeded from the Solana address rather than a random
      // UUID: the same social identity rebuilds the same account on every
      // device, so its default avatar must be reproducible from the identity
      // alone — a random seed would draw a different one per install.
      accountId = await _createAccount(
        kind: AccountKind.social,
        avatarSeed: solana.address,
      );
      // Adopt a pre-Accounts-model social row (restored from an old graph) so
      // the sibling chain rows do not land in a different account than it.
      if (existed) {
        await _db.updateWalletAccountId(existingSolana.id, accountId);
      }
    }

    final results = <WalletInfo>[];
    String? solanaWalletId;

    for (final (chain, cred) in credentials) {
      final existing = await _lookupWalletByAddress(cred.address);
      if (existing != null &&
          WalletType.fromDbString(existing.walletType) == WalletType.social) {
        // Row already there — (re-)store its key so a row whose key was lost
        // with the keystore signs again after this login.
        await _storage.storePrivateKey(existing.id, cred.storedKey);
        // Adopt a row stranded under another account. Removing this identity's
        // Solana row on its own ([removeWallet] deletes one row and does no
        // account-level cleanup) makes the next login mint a fresh account, and
        // the surviving chain rows would stay under the dead one — invisible to
        // [getWalletsForAccount], so the account card would show the wrong
        // chains and the send gates would offer them from the wrong account.
        if (existing.accountId != accountId) {
          await _db.updateWalletAccountId(existing.id, accountId);
        }
        results.add(_walletRowToInfo(existing).copyWith(accountId: accountId));
        if (chain == Chain.solana) solanaWalletId = existing.id;
        continue;
      }

      // A signing import supersedes a watch-only wallet of the same address;
      // any other signing wallet already threw above.
      await _clearWatchOnlyForSigningImport(cred.address);

      final walletId = _generateId();
      // Key before row, as in [addImportedKeyWallet], so there is no window
      // where a signing row exists without the key it signs with.
      await _storage.storePrivateKey(walletId, cred.storedKey);
      final sortIndex = await _db.maxWalletSortIndex() + 1;
      await _db.upsertWalletEntry(
        WalletsCompanion.insert(
          id: walletId,
          accountId: Value(accountId),
          address: cred.address,
          name: name,
          walletType: WalletType.social.toDbString(),
          socialProvider: Value(provider),
          chain: Value(chain.toDbString()),
          createdAt: _nowSeconds(),
          sortIndex: Value(sortIndex),
        ),
      );

      results.add(
        WalletInfo(
          id: walletId,
          address: cred.address,
          name: name,
          walletType: WalletType.social,
          socialProvider: provider,
          chain: chain.toDbString(),
          accountId: accountId,
        ),
      );
      if (chain == Chain.solana) solanaWalletId = walletId;
    }

    // Only auto-select if there's no current selection (onboarding case) —
    // post-onboarding the caller switches explicitly so the wallet-changed
    // event fires. Matches [importAccountsFromPhrase], which selects Solana.
    if (solanaWalletId != null &&
        await _storage.loadSelectedWalletId() == null) {
      await _storage.storeSelectedWalletId(solanaWalletId);
    }

    await _syncWalletGraph();
    return (wallets: results, existed: existed);
  }

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  /// Set the active wallet and persist.
  Future<WalletInfo> setActiveWallet(String walletId) => _locked(() async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw StateError('Wallet not found: $walletId');

    await _storage.storeSelectedWalletId(walletId);

    await _syncWalletGraph();
    return _walletRowToInfo(row);
  });

  // ---------------------------------------------------------------------------
  // HD Address Picker
  // ---------------------------------------------------------------------------

  /// Derive N addresses for the HD picker, marking already-imported ones.
  Future<List<DerivedAddressInfo>> deriveAddressesForPicker(
    String seedPhraseId, {
    int count = 10,
    int startIndex = 0,
  }) async {
    final mnemonic = await _storage.loadMnemonicForSeedPhrase(seedPhraseId);
    if (mnemonic == null) throw StateError('No mnemonic for seed phrase');

    final existingWallets = await _db.getWalletsForSeedPhrase(seedPhraseId);
    final existingAddresses = existingWallets.map((w) => w.address).toSet();

    final indices = [for (var i = startIndex; i < startIndex + count; i++) i];
    final addresses = await MultiChainDerivation.getSolanaAddressesAtIndices(
      mnemonic,
      indices,
    );

    return [
      for (var k = 0; k < indices.length; k++)
        DerivedAddressInfo(
          index: indices[k],
          address: addresses[k],
          alreadyImported: existingAddresses.contains(addresses[k]),
        ),
    ];
  }

  /// Derive multi-chain account addresses for the import picker.
  ///
  /// Returns one [AccountAddresses] per derivation index (Solana + Ethereum +
  /// Tezos, plus legacy/root Solana when [includeLegacy] is true), along with
  /// the set of addresses already imported (so the picker can disable them).
  ///
  /// [deriveEthereum] / [deriveTezos] let the caller skip a chain it will not
  /// show; the skipped chain comes back null instead of being derived.
  Future<AccountPickerInfo> deriveAccountsForPicker(
    String seedPhraseId, {
    int count = 5,
    int startIndex = 0,
    bool includeLegacy = false,
    bool deriveEthereum = true,
    bool deriveTezos = true,
  }) async {
    final mnemonic = await _storage.loadMnemonicForSeedPhrase(seedPhraseId);
    if (mnemonic == null) throw StateError('No mnemonic for seed phrase');

    final indices = [for (var i = startIndex; i < startIndex + count; i++) i];
    final accounts = await MultiChainDerivation.getMultiChainAddressesAtIndices(
      mnemonic,
      indices,
      includeLegacyPaths: includeLegacy,
      deriveEthereum: deriveEthereum,
      deriveTezos: deriveTezos,
    );

    final existing = (await _db.getAllWallets()).map((w) => w.address).toSet();

    // Surface the stored name for indices already imported on this phrase, so a
    // user-edited name shows in the picker instead of the generic `Account NN`.
    final names = <int, String>{
      for (final a in await _db.getAllAccounts())
        if (a.seedPhraseId == seedPhraseId && a.derivationIndex != null)
          a.derivationIndex!: a.name,
    };
    return AccountPickerInfo(
      accounts: accounts,
      alreadyImported: existing,
      importedNamesByIndex: names,
    );
  }

  // ---------------------------------------------------------------------------
  // Import multi-chain accounts
  // ---------------------------------------------------------------------------

  /// Import the selected wallets from the multi-chain picker.
  ///
  /// Groups [selections] by derivation index — one `seed` [Account] per index
  /// (named `Account NN`, with a generated avatar seed) — and inserts each
  /// selected wallet under it. Already-imported addresses are skipped. The
  /// first imported Solana wallet is auto-selected when nothing is selected yet
  /// so the post-import session logs in as that account.
  ///
  /// Throws [StateError] when [seedPhraseId] has no row: the picker resolved
  /// it before the user chose, and a removal in between deletes the row *and*
  /// the mnemonic. HD rows written under it would show wallets that cannot
  /// sign, and a restore would faithfully bring them back that way.
  Future<List<WalletInfo>> importAccountsFromPhrase(
    String seedPhraseId,
    List<WalletImportSelection> selections,
  ) => _locked(() => _importAccountsFromPhraseLocked(seedPhraseId, selections));

  Future<List<WalletInfo>> _importAccountsFromPhraseLocked(
    String seedPhraseId,
    List<WalletImportSelection> selections,
  ) async {
    if (selections.isEmpty) return const [];
    if (await _db.getSeedPhraseById(seedPhraseId) == null) {
      throw StateError('seed phrase $seedPhraseId not found');
    }

    // Group by index, preserving ascending index order.
    final byIndex = <int, List<WalletImportSelection>>{};
    for (final s in selections) {
      byIndex.putIfAbsent(s.index, () => []).add(s);
    }
    final sortedIndices = byIndex.keys.toList()..sort();

    final results = <WalletInfo>[];
    String? firstSolanaWalletId;

    for (final index in sortedIndices) {
      final accountId = await _ensureSeedAccount(seedPhraseId, index);

      // Order wallets within the account: Solana, Tezos, Ethereum (matches the
      // picker), with legacy/root Solana following standard.
      final wallets = byIndex[index]!..sort(_walletImportOrder);

      for (final sel in wallets) {
        // An HD import supersedes a watch-only wallet of the same address; skip
        // only when a real signer already holds it.
        if (!await _clearWatchOnlyForSigningImport(sel.address)) continue;

        final walletId = _generateId();
        final sortIndex = await _db.maxWalletSortIndex() + 1;
        await _db.upsertWalletEntry(
          WalletsCompanion.insert(
            id: walletId,
            accountId: Value(accountId),
            seedPhraseId: Value(seedPhraseId),
            address: sel.address,
            name: _walletImportName(sel),
            walletType: WalletType.hd.toDbString(),
            derivationIndex: Value(index),
            derivationScheme: Value(sel.scheme?.name),
            chain: Value(sel.chain.toDbString()),
            createdAt: _nowSeconds(),
            sortIndex: Value(sortIndex),
          ),
        );

        final info = WalletInfo(
          id: walletId,
          address: sel.address,
          name: _walletImportName(sel),
          walletType: WalletType.hd,
          chain: sel.chain.toDbString(),
          accountId: accountId,
          seedPhraseId: seedPhraseId,
          derivationIndex: index,
          derivationScheme: sel.scheme,
        );
        results.add(info);
        if (sel.chain == Chain.solana && firstSolanaWalletId == null) {
          firstSolanaWalletId = walletId;
        }
      }
    }

    if (results.isNotEmpty) {
      // Auto-select the first imported Solana wallet if nothing is selected,
      // so the session logs in as the first imported account.
      if (await _storage.loadSelectedWalletId() == null &&
          firstSolanaWalletId != null) {
        await _storage.storeSelectedWalletId(firstSolanaWalletId);
      }
      await _syncWalletGraph();
    }
    return results;
  }

  /// Sort order within an account card: Solana first, then Tezos, then
  /// Ethereum; within Solana, standard before legacy before root.
  static int _walletImportOrder(
    WalletImportSelection a,
    WalletImportSelection b,
  ) {
    int chainRank(Chain c) => switch (c) {
      Chain.solana => 0,
      Chain.tezos => 1,
      Chain.ethereum => 2,
    };
    final byChain = chainRank(a.chain).compareTo(chainRank(b.chain));
    if (byChain != 0) return byChain;
    int schemeRank(SolanaDerivationScheme? s) => switch (s) {
      null || SolanaDerivationScheme.standard => 0,
      SolanaDerivationScheme.legacy => 1,
      SolanaDerivationScheme.root => 2,
    };
    return schemeRank(a.scheme).compareTo(schemeRank(b.scheme));
  }

  static String _walletImportName(WalletImportSelection sel) =>
      switch ((sel.chain, sel.scheme)) {
        (Chain.solana, SolanaDerivationScheme.legacy) => 'Solana (legacy)',
        (Chain.solana, SolanaDerivationScheme.root) => 'Solana (root)',
        (Chain.solana, _) => 'Solana',
        (Chain.ethereum, _) => 'Ethereum',
        (Chain.tezos, _) => 'Tezos',
      };

  // ---------------------------------------------------------------------------
  // Reorder
  // ---------------------------------------------------------------------------

  /// Reassign sortIndex values for a list of wallets in their new order.
  ///
  /// [orderedWalletIds] is the wallet IDs in the desired display order.
  /// Assigns sortIndex 0, 1, 2... to each wallet and persists to the graph.
  Future<void> reorderWalletsInGroup(List<String> orderedWalletIds) =>
      _locked(() async {
        for (var i = 0; i < orderedWalletIds.length; i++) {
          await _db.updateWalletSortIndex(orderedWalletIds[i], i);
        }
        await _syncWalletGraph();
      });

  // ---------------------------------------------------------------------------
  // Rename
  // ---------------------------------------------------------------------------

  /// Rename a wallet and sync the wallet graph.
  Future<void> renameWallet(String walletId, String newName) =>
      _locked(() async {
        await _db.updateWalletName(walletId, newName);
        await _syncWalletGraph();
      });

  /// Rename an account and sync the wallet graph.
  Future<void> renameAccount(String accountId, String newName) =>
      _locked(() async {
        await _db.updateAccountName(accountId, newName);
        await _syncWalletGraph();
      });

  /// Update an account's generated-avatar seed and sync the wallet graph.
  Future<void> updateAccountAvatarSeed(String accountId, String seed) =>
      _locked(() async {
        await _db.updateAccountAvatarSeed(accountId, seed);
        await _syncWalletGraph();
      });

  /// Reorder accounts; persists the new sortIndex for each in list order.
  Future<void> reorderAccounts(List<String> orderedAccountIds) =>
      _locked(() async {
        for (var i = 0; i < orderedAccountIds.length; i++) {
          await _db.updateAccountSortIndex(orderedAccountIds[i], i);
        }
        await _syncWalletGraph();
      });

  /// Remove an entire account: its wallets and then its row. Returns the
  /// replacement active wallet id, or null if no wallets remain.
  ///
  /// Graph-first and all-or-nothing, like [removeWallet]: one prune names the
  /// account and every wallet it holds, and it is the commit point — a
  /// [GraphSyncException] from it leaves the whole account in place.
  Future<String?> removeAccount(String accountId) => _locked(() async {
    final wallets = await _db.getWalletsForAccount(accountId);
    return _removeWallets(
      wallets.map((w) => w.id),
      removedAccountIds: {accountId},
    );
  });

  // ---------------------------------------------------------------------------
  // Remove Wallets
  // ---------------------------------------------------------------------------

  /// Remove a single wallet, cleaning up secrets and cached data.
  ///
  /// Returns the ID of the replacement active wallet, or null if no wallets
  /// remain (caller should redirect to welcome/onboarding).
  Future<String?> removeWallet(String walletId) =>
      _locked(() => _removeWallets([walletId]));

  /// Remove several wallets as one all-or-nothing operation, cleaning up
  /// secrets and cached data. Prefer this over a loop of [removeWallet]: one
  /// graph prune covers the whole set, so a failure removes none of them.
  ///
  /// Returns the ID of the replacement active wallet, or null if no wallets
  /// remain (caller should redirect to welcome/onboarding).
  Future<String?> removeWallets(Iterable<String> walletIds) =>
      _locked(() => _removeWallets(walletIds));

  /// The one removal path — [removeWallet], [removeWallets] and
  /// [removeAccount] all run through it, so they cannot drift apart.
  ///
  /// A seed phrase goes when *every* wallet holding it is in this removal set.
  /// That is computed across the whole set, not per wallet: removing the last
  /// two siblings one at a time would decide "not the last one" for the first
  /// of them.
  ///
  /// One graph prune covers the whole set and is the commit point; only after
  /// it succeeds is anything deleted. Removing wallets one call at a time
  /// instead commits a prune per wallet, so a failure partway leaves earlier
  /// wallets already gone while the caller reports that nothing was removed.
  ///
  /// [removedAccountIds] rows are deleted here too, after their wallets — and
  /// so is every account this removal empties. Nothing cascades in the
  /// database (an account's seed phrase is a plain nullable column), so an
  /// account left behind keeps its place in the graph, comes back on a restore
  /// and shows as a card with no wallets under a seed phrase that is gone.
  ///
  /// The one prune is the only graph write: it is computed from the database
  /// *as it will be*, so a plain sync afterwards would rebuild byte-identical
  /// content. That includes the selection — the replacement is decided before
  /// the prune and stored right after it, so from the moment this method
  /// returns, success or [GraphSyncException], both the stored graph's
  /// `selectedWalletId` and the selection in secure storage name a live wallet
  /// or are null. A crash in between leaves the older of the two, which still
  /// names a wallet whose row has not been deleted yet.
  ///
  /// Returns null without touching anything when no id resolves to a wallet
  /// row and there is no account to remove.
  Future<String?> _removeWallets(
    Iterable<String> walletIds, {
    Set<String> removedAccountIds = const {},
  }) async {
    final rows = <Wallet>[];
    for (final id in walletIds.toSet()) {
      final row = await _db.getWalletById(id);
      if (row != null) rows.add(row);
    }
    if (rows.isEmpty && removedAccountIds.isEmpty) return null;

    final removedWalletIds = rows.map((r) => r.id).toSet();

    // Last wallets of their seed phrases? Then those seed phrases (and their
    // mnemonics) go too — decided up front so the graph prune below can name
    // them.
    final removedSeedPhraseIds = <String>{};
    final seedPhraseIds = {
      for (final r in rows)
        if (r.seedPhraseId != null) r.seedPhraseId!,
    };
    for (final seedPhraseId in seedPhraseIds) {
      final siblings = await _db.getWalletsForSeedPhrase(seedPhraseId);
      if (siblings.every((w) => removedWalletIds.contains(w.id))) {
        removedSeedPhraseIds.add(seedPhraseId);
      }
    }

    // Accounts this removal empties go with their wallets — including the
    // accounts of a seed phrase that is going, which can hold no wallet at all
    // (an import whose every selection was already taken leaves the account
    // row it created behind).
    final candidateAccountIds = {
      for (final r in rows)
        if (r.accountId != null) r.accountId!,
    };
    if (removedSeedPhraseIds.isNotEmpty) {
      for (final a in await _db.getAllAccounts()) {
        if (removedSeedPhraseIds.contains(a.seedPhraseId)) {
          candidateAccountIds.add(a.id);
        }
      }
    }
    final prunedAccountIds = {...removedAccountIds};
    for (final accountId in candidateAccountIds) {
      if (prunedAccountIds.contains(accountId)) continue;
      final held = await _db.getWalletsForAccount(accountId);
      if (held.every((w) => removedWalletIds.contains(w.id))) {
        prunedAccountIds.add(accountId);
      }
    }

    // The replacement for an active wallet that is going, decided before the
    // commit point so the pruned graph can carry it. Prefer a row that binds
    // the global signer — Solana, see [WalletInfo.bindsGlobalSigner]. Solana
    // signing resolves its keypair from the *selection*, not an explicit
    // wallet id, so parking the selection on a Tezos or Ethereum row leaves
    // `getPublicKey()` / `signMessage()` with no Solana key to load. Falls
    // back to the first row when no Solana row remains.
    final currentSelection = await _storage.loadSelectedWalletId();
    final selectionRemoved =
        currentSelection != null && removedWalletIds.contains(currentSelection);
    String? replacement;
    if (selectionRemoved) {
      final survivors = (await _db.getAllWallets())
          .where((w) => !removedWalletIds.contains(w.id))
          .toList();
      if (survivors.isNotEmpty) {
        replacement = survivors
            .firstWhere(
              (w) => _walletRowToInfo(w).bindsGlobalSigner,
              orElse: () => survivors.first,
            )
            .id;
      }
    }

    // Commit point: prune the recovery graph BEFORE deleting anything. The
    // graph carries over every entry the DB lacks, so an entry must be named
    // as removed here or it would come back on the next sync. If this write
    // fails it throws GraphSyncException and nothing below runs — the wallets,
    // their secrets, their rows and the selection are all still there.
    await _syncWalletGraph(
      removedWalletIds: removedWalletIds,
      removedSeedPhraseIds: removedSeedPhraseIds,
      removedAccountIds: prunedAccountIds,
      replacementSelectedWalletId: replacement,
    );

    // Storage follows the graph immediately, while every row still exists, so
    // the two never disagree about what is selected.
    if (selectionRemoved) {
      if (replacement != null) {
        await _storage.storeSelectedWalletId(replacement);
      } else {
        await _storage.deleteSelectedWalletId();
      }
    }

    for (final row in rows) {
      await _deleteWalletData(row);
    }

    // Seed phrases whose last holder just went: the row and the mnemonic go
    // with them, once each. A vault delete that fails (iOS returns
    // `delete_failed` for a Keychain status it cannot classify) leaves an
    // orphan the wipe sweep collects — nothing indexes it any more, since the
    // prune already dropped it. Failing the removal over that would report
    // "nothing was removed" for a removal that is already done.
    for (final seedPhraseId in removedSeedPhraseIds) {
      await _db.deleteSeedPhraseById(seedPhraseId);
      try {
        await _storage.deleteMnemonicForSeedPhrase(seedPhraseId);
      } catch (e) {
        // Reported through AppLogger only: it prints the same console line in
        // debug and drops it in release, where a bare `debugPrint` would still
        // reach logcat/OSLog — and an exception's own message can quote the
        // item it failed on.
        AppLogger.warn(
          'WalletRepository',
          'Mnemonic for $seedPhraseId not erased: ${_errorLabel(e)}',
        );
      }
    }

    for (final accountId in prunedAccountIds) {
      await _db.deleteAccountById(accountId);
    }

    // No closing sync: the prune above already wrote what the database now
    // holds. Nothing cascades, so the deletes removed exactly the ids it was
    // told to filter out, and re-reading the stored graph would carry the same
    // dormant entries over again — a byte-identical write.
    return selectionRemoved ? replacement : currentSelection;
  }

  /// Delete everything one wallet row owns, after [_removeWallets] has pruned
  /// the recovery graph. The seed phrase is not this row's to delete: whether
  /// it goes is decided across the whole removal set, by the caller.
  ///
  /// Rows first, secrets last — the same order the seed phrase branch uses,
  /// and for the same reason. A step here can throw, and the state it leaves
  /// behind has to be one the user can still work with: a row whose secret is
  /// gone is a wallet that shows on screen and cannot sign, and the next plain
  /// sync writes it back into the graph, where the restore pre-check counts it
  /// as a missing imported key and aborts *every* restore from then on. A
  /// secret whose row is gone is only an orphan the wipe sweep collects.
  ///
  /// So the secret deletes are logged and swallowed rather than thrown: they
  /// run after the row is already gone (and after the graph prune that
  /// committed the removal), and a vault delete can fail on its own — iOS
  /// reports `delete_failed` for a Keychain status it cannot classify. Rethrown,
  /// it would abandon the deletes after it and tell the caller nothing was
  /// removed, for a removal that has already happened.
  Future<void> _deleteWalletData(Wallet row) async {
    final address = row.address;
    final walletType = WalletType.fromDbString(row.walletType);

    // Delete wallet row from DB
    await _db.deleteWalletById(row.id);

    // Delete cached balances for this wallet
    await _db.deleteBalances(address);

    // Delete locally tracked pending EVM transactions for this wallet. Rows are
    // keyed by the lowercased (`apiOwnerAddress`) form. This is the permanent
    // deletion path — a wallet merely dropped from the session keeps its rows.
    await _db.deletePendingEvmTransactionsForWallet(apiOwnerAddress(address));

    // Delete the private key for wallets that own one — imported-key wallets
    // and social wallets, whose per-chain key is captured at login and stored
    // in the same imported-key format (see [addSocialAccount]).
    if (walletType == WalletType.importedKey ||
        walletType == WalletType.social) {
      await _deleteSecret(
        'private key for ${row.id}',
        () => _storage.deletePrivateKey(row.id),
      );
    }

    // Delete Ledger device ID for hardware wallets
    if (walletType == WalletType.ledger) {
      await _deleteSecret(
        'ledger device id for ${row.id}',
        () => _storage.deleteLedgerDeviceId(row.id),
      );
    }

    // Delete wallet-sig cookie
    await _deleteSecret(
      'wallet-sig cookie for ${row.id}',
      () => _storage.deleteWalletSigCookie(address),
    );
  }

  /// Run one post-commit secret delete, logging and continuing on failure.
  /// See [_deleteWalletData] for why a failure here is not the caller's.
  ///
  /// Reported through [AppLogger]: a swallowed erase leaves key material on
  /// the device that nothing else ever mentions. Not `debugPrint` — that line
  /// survives into release, where it reaches logcat/OSLog, and it would carry
  /// the exception's own message, which can quote the item.
  Future<void> _deleteSecret(
    String what,
    Future<void> Function() delete,
  ) async {
    try {
      await delete();
    } catch (e) {
      AppLogger.warn('WalletRepository', '$what not erased: ${_errorLabel(e)}');
    }
  }

  /// A log-safe label for a failed secret delete: what went wrong, never what
  /// it went wrong on. The platform code (`delete_failed`, a Keychain status)
  /// is the diagnostic part; the exception's message can quote the item.
  static String _errorLabel(Object e) => e is PlatformException
      ? 'PlatformException(${e.code})'
      : e.runtimeType.toString();

  // ---------------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------------

  /// Delete all seed phrases, wallets, their secrets, the database file, and
  /// every stored preference — the storage half of a factory reset.
  ///
  /// This backs Settings → "Reset app" and the reinstall screen's "Start
  /// fresh", which users read as a factory reset, so device-local preferences
  /// go too — not just the account counter. Leaving them behind meant the
  /// previous identity's recent send recipients (and searches, recently-viewed,
  /// buy history) were still suggested after re-onboarding with a different
  /// seed phrase.
  ///
  /// Best-effort: every step runs even when an earlier one fails, and the
  /// failures come back so the caller can tell the user. Secrets are erased
  /// by enumeration ([SecureWalletStorage.eraseAllSecrets]) — the id lists
  /// below only feed the readable inventory; the sweep behind them catches
  /// every item the lists do not know. The database *file* is deleted along
  /// with its encryption key ([MallowDatabase.resetStorage]); if that fails,
  /// the rows are cleared instead so no wallet outlives the reset.
  ///
  /// Rows go **before** the secrets, for the same reason every removal path
  /// puts them first: a reset the user kills part-way (or that the OS ends)
  /// between the two must not leave wallet rows on disk with no secrets
  /// behind them. That state boots into a session with wallets, and the eager
  /// backfill writes a recovery graph naming secrets that are already gone —
  /// every restore from then on aborts on entries nothing can satisfy. The
  /// file delete still runs after, so the file and its key go together.
  ///
  /// Not to be confused with the profile-only "Delete profile" in Settings →
  /// Security & Privacy, which deliberately leaves wallets and the recovery
  /// phrase intact.
  Future<List<EraseFailure>> resetAll() => _locked(_resetAllLocked);

  Future<List<EraseFailure>> _resetAllLocked() async {
    final failures = <EraseFailure>[];

    var seedPhraseIds = const <String>[];
    var walletIds = const <String>[];
    try {
      seedPhraseIds = (await _db.getAllSeedPhrases()).map((s) => s.id).toList();
      walletIds = (await _db.getAllWallets()).map((w) => w.id).toList();
    } catch (e) {
      // The enumeration sweep does not need these; carry on.
      failures.add(EraseFailure('db.listIds', e.runtimeType.toString()));
    }

    // Rows first (see above). Best-effort like every other step: the file
    // delete below normally takes them anyway.
    try {
      await _db.clearAll();
    } catch (e) {
      failures.add(EraseFailure('db.clearRows', e.runtimeType.toString()));
    }

    failures.addAll(
      await _storage.eraseAllSecrets(
        seedPhraseIds: seedPhraseIds,
        walletIds: walletIds,
      ),
    );

    try {
      await _db.resetStorage();
    } catch (e) {
      failures.add(EraseFailure('db.resetStorage', e.runtimeType.toString()));
      try {
        await _db.clearAll();
      } catch (e) {
        failures.add(EraseFailure('db.clearAll', e.runtimeType.toString()));
      }
    }

    // Wipes every preference, including the global account counter, so a fresh
    // onboard begins at Account 01 with default settings and no carried-over
    // history from the previous identity.
    try {
      await _prefs.clearAll();
    } catch (e) {
      failures.add(EraseFailure('prefs.clearAll', e.runtimeType.toString()));
    }

    return failures;
  }

  // ---------------------------------------------------------------------------
  // Wallet Graph Persistence (Recovery)
  // ---------------------------------------------------------------------------

  /// Sync the full wallet graph to Keychain for recovery.
  ///
  /// The graph is the database's content **plus** every entry the stored
  /// graph has that the database does not — carried over unconditionally.
  /// Why: the graph is rewritten on every mutation, and a database that does
  /// not know a seed is not proof the seed is gone. After a transient
  /// keystore misread routed a launch to onboarding, the first new seed used
  /// to overwrite the graph with just itself, orphaning every other seed in
  /// the vault for good. A presence check at sync time would not fix that —
  /// the misread *is* a nil read — so carry-over is unconditional.
  ///
  /// Carry-over is only as safe as the read it carries from, so that read is
  /// guarded ([SecureWalletStorage.loadAccountGraph]): an unreadable keystore
  /// throws instead of answering "absent". The throw lands in the catch below,
  /// which is the safe outcome both ways — a plain sync writes nothing and the
  /// stored graph survives untouched, a pruning sync aborts the removal. A nil
  /// read is the dangerous one: it carries nothing over, so the write that
  /// follows replaces the graph with the database's content alone.
  ///
  /// The only way an entry leaves the graph is by being named in the
  /// `removed*` sets by the code path that deletes its secret. The database
  /// snapshot is filtered by the same ids, so removal paths call this
  /// **before** they delete anything (graph-first): the graph write is the
  /// commit point, and a failure there throws [GraphSyncException] with
  /// nothing removed. Plain syncs keep the old swallow-and-log behaviour —
  /// a failed refresh just means the next mutation writes the same content.
  ///
  /// The written `selectedWalletId` is always one of the wallets in the same
  /// write, or null. A removal prunes the active wallet and the graph would
  /// otherwise keep naming it: nothing repairs a selection that points at a
  /// row no restore creates, so [getActiveWallet] would answer null forever
  /// after that graph is restored. [replacementSelectedWalletId] lets the
  /// removal path name the selection it is about to store, so the pruned
  /// graph is already correct instead of waiting for a follow-up sync.
  Future<void> _syncWalletGraph({
    Set<String> removedSeedPhraseIds = const {},
    Set<String> removedWalletIds = const {},
    Set<String> removedAccountIds = const {},
    String? replacementSelectedWalletId,
  }) async {
    final pruning =
        removedSeedPhraseIds.isNotEmpty ||
        removedWalletIds.isNotEmpty ||
        removedAccountIds.isNotEmpty;
    try {
      final seedPhrases = (await getAllSeedPhrases())
          .where((sp) => !removedSeedPhraseIds.contains(sp.id))
          .toList();
      final accountRows = (await _db.getAllAccounts())
          .where((a) => !removedAccountIds.contains(a.id))
          .toList();
      final wallets = (await getAllWallets())
          .where((w) => !removedWalletIds.contains(w.id))
          .toList();
      final selectedWalletId =
          replacementSelectedWalletId ?? await _storage.loadSelectedWalletId();

      final seedEntries = seedPhrases
          .map(
            (sp) => <String, dynamic>{
              'id': sp.id,
              'name': sp.name,
              'sortIndex': sp.sortIndex,
            },
          )
          .toList();
      final accountEntries = accountRows
          .map(
            (a) => <String, dynamic>{
              'id': a.id,
              'seedPhraseId': a.seedPhraseId,
              'derivationIndex': a.derivationIndex,
              'kind': a.kind,
              'name': a.name,
              'avatarSeed': a.avatarSeed,
              'sortIndex': a.sortIndex,
            },
          )
          .toList();
      final walletEntries = wallets
          .map(
            (w) => <String, dynamic>{
              'id': w.id,
              'accountId': w.accountId,
              'address': w.address,
              'name': w.name,
              'walletType': w.walletType.toDbString(),
              'seedPhraseId': w.seedPhraseId,
              'derivationIndex': w.derivationIndex,
              'derivationScheme': w.derivationScheme?.name,
              'socialProvider': w.socialProvider,
              'chain': w.chain,
              'sortIndex': w.sortIndex,
            },
          )
          .toList();

      _carryOverDormantEntries(
        stored: await _loadStoredGraph(),
        seedEntries: seedEntries,
        accountEntries: accountEntries,
        walletEntries: walletEntries,
        removedSeedPhraseIds: removedSeedPhraseIds,
        removedWalletIds: removedWalletIds,
        removedAccountIds: removedAccountIds,
      );

      // Never name a wallet this write does not contain: a graph is only ever
      // read back to rebuild the database from, and a selection pointing at a
      // row that rebuild does not create leaves the session with no active
      // wallet and nothing to repair it.
      final graphWalletIds = walletEntries
          .map((e) => e['id'] as String?)
          .toSet();

      final graph = {
        'version': 3,
        'seedPhrases': seedEntries,
        'accounts': accountEntries,
        'wallets': walletEntries,
        'selectedWalletId': graphWalletIds.contains(selectedWalletId)
            ? selectedWalletId
            : null,
      };

      await _storage.storeAccountGraph(jsonEncode(graph));
    } catch (e) {
      if (pruning) throw GraphSyncException(e);
      debugPrint('[WalletRepository] Failed to sync wallet graph: $e');
    }
  }

  /// The stored graph, or null when absent or unparseable (an unparseable
  /// graph has nothing to carry; it is overwritten).
  ///
  /// A failed read is **not** null. Only the parse is caught here; a keystore
  /// that cannot be read throws out of this method on purpose, because null is
  /// acted on — the sync carries nothing over and overwrites, the boot restore
  /// concludes there is nothing dormant. "Unknown" must reach the caller as a
  /// throw so it can leave everything as it is.
  Future<Map<String, dynamic>?> _loadStoredGraph() async {
    final json = await _storage.loadAccountGraph();
    if (json == null || json.isEmpty) return null;
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[WalletRepository] Stored wallet graph is unreadable: $e');
      return null;
    }
  }

  /// Append to the fresh entry lists every stored entry the database does not
  /// have and no caller has removed. See [_syncWalletGraph].
  ///
  /// A seed phrase the database holds is authoritative for its own accounts
  /// and wallets; only seeds absent from the database are carried, whole.
  /// Non-seed wallets are carried individually, each with its account if the
  /// database lacks that too. Accounts nothing references are dropped.
  static void _carryOverDormantEntries({
    required Map<String, dynamic>? stored,
    required List<Map<String, dynamic>> seedEntries,
    required List<Map<String, dynamic>> accountEntries,
    required List<Map<String, dynamic>> walletEntries,
    required Set<String> removedSeedPhraseIds,
    required Set<String> removedWalletIds,
    required Set<String> removedAccountIds,
  }) {
    if (stored == null) return;
    final dbSeedIds = seedEntries.map((e) => e['id'] as String).toSet();
    final dbAccountIds = accountEntries.map((e) => e['id'] as String).toSet();
    final dbWalletIds = walletEntries.map((e) => e['id'] as String).toSet();

    final storedSeeds = _entries(stored['seedPhrases']);
    final storedAccounts = _entries(stored['accounts']);
    final storedWallets = _entries(stored['wallets']);

    final carriedSeedIds = <String>{};
    for (final sp in storedSeeds) {
      final id = sp['id'] as String?;
      if (id == null || dbSeedIds.contains(id)) continue;
      if (removedSeedPhraseIds.contains(id)) continue;
      seedEntries.add(sp);
      carriedSeedIds.add(id);
    }

    final carriedAccountIds = <String>{};
    for (final w in storedWallets) {
      final id = w['id'] as String?;
      if (id == null || dbWalletIds.contains(id)) continue;
      if (removedWalletIds.contains(id)) continue;
      final seedPhraseId = w['seedPhraseId'] as String?;
      // A seed the DB holds owns its wallets; only carried seeds bring theirs.
      if (seedPhraseId != null && !carriedSeedIds.contains(seedPhraseId)) {
        continue;
      }
      walletEntries.add(w);
      final accountId = w['accountId'] as String?;
      if (accountId != null) carriedAccountIds.add(accountId);
    }

    for (final a in storedAccounts) {
      final id = a['id'] as String?;
      if (id == null || dbAccountIds.contains(id)) continue;
      if (removedAccountIds.contains(id)) continue;
      final seedPhraseId = a['seedPhraseId'] as String?;
      final referenced =
          carriedAccountIds.contains(id) ||
          (seedPhraseId != null && carriedSeedIds.contains(seedPhraseId));
      if (referenced) accountEntries.add(a);
    }
  }

  static List<Map<String, dynamic>> _entries(Object? raw) => switch (raw) {
    final List<dynamic> list => list.whereType<Map<String, dynamic>>().toList(),
    _ => const [],
  };

  // ---------------------------------------------------------------------------
  // Account creation
  // ---------------------------------------------------------------------------

  /// Find-or-create the `seed` account for a (seedPhrase, derivationIndex) pair.
  /// HD wallets sharing a derivation index — across chains — share one account.
  /// A newly created account draws the next global account number.
  Future<String> _ensureSeedAccount(String seedPhraseId, int index) async {
    final existing = await _db.getSeedAccount(seedPhraseId, index);
    return existing?.id ??
        await _createAccount(
          kind: AccountKind.seed,
          seedPhraseId: seedPhraseId,
          derivationIndex: index,
        );
  }

  /// Find-or-create the `hardware` account for a Ledger derivation index, so
  /// each imported index becomes its own account (named `Account NN` from the
  /// global counter, like every other account). Solana wallets sharing an
  /// index — standard, legacy, root — share one account.
  Future<String> _ensureHardwareAccount(int index) async {
    final existing = await _db.getHardwareAccountByIndex(index);
    return existing?.id ??
        await _createAccount(
          kind: AccountKind.hardware,
          derivationIndex: index,
        );
  }

  /// Find-or-create the `seedVault` account for a Seed Vault derivation index.
  /// Same shape as [_ensureHardwareAccount], and separate from it for the
  /// reason [AccountKind.seedVault] records: hardware accounts are keyed by
  /// index alone, so one kind for both devices would merge a Ledger and a
  /// Seed Vault imported at the same index into a single account.
  Future<String> _ensureSeedVaultAccount(int index) async {
    final existing = await _db.getSeedVaultAccountByIndex(index);
    return existing?.id ??
        await _createAccount(
          kind: AccountKind.seedVault,
          derivationIndex: index,
        );
  }

  /// Creates an account row. When [name] is null/blank the account is named
  /// `Account NN` from the global counter; an explicit name is used verbatim.
  /// Either way the counter advances by one, so numbering stays monotonic and
  /// never reuses a value (high-water mark).
  ///
  /// [avatarSeed] pins the generated avatar to a caller-supplied identifier
  /// instead of a fresh random UUID — used where the same account can be
  /// rebuilt on another device and must look the same there (see
  /// [addSocialAccount]). The user can still change it afterwards.
  Future<String> _createAccount({
    required AccountKind kind,
    String? name,
    String? seedPhraseId,
    int? derivationIndex,
    String? avatarSeed,
  }) async {
    final number = await _allocateAccountNumber();
    final resolvedName = (name == null || name.trim().isEmpty)
        ? formatAccountName(number)
        : name;
    final id = _generateId();
    final sortIndex = await _db.maxAccountSortIndex() + 1;
    await _db.upsertAccount(
      AccountsCompanion.insert(
        id: id,
        seedPhraseId: Value(seedPhraseId),
        derivationIndex: Value(derivationIndex),
        kind: kind.toDbString(),
        name: resolvedName,
        avatarSeed: (avatarSeed == null || avatarSeed.isEmpty)
            ? _generateId()
            : avatarSeed,
        createdAt: _nowSeconds(),
        sortIndex: Value(sortIndex),
      ),
    );
    return id;
  }

  // ---------------------------------------------------------------------------
  // Global account counter
  // ---------------------------------------------------------------------------

  /// The next number a new account would be assigned, without consuming it.
  /// Drives the live `Account NN` preview in the import pickers. Seeds on first
  /// use (see [_seededNextAccountNumber]).
  Future<int> peekNextAccountNumber() => _seededNextAccountNumber();

  /// Returns the persisted next-account number, seeding it once from the
  /// highest trailing number already present in existing account names (so an
  /// install that predates the counter continues its sequence without renaming
  /// or colliding). Minimum 1 when no numeric names exist.
  Future<int> _seededNextAccountNumber() async {
    final stored = _prefs.rawNextAccountNumber;
    if (stored != null) return stored;

    var maxSuffix = 0;
    for (final a in await _db.getAllAccounts()) {
      final match = RegExp(r'(\d+)\s*$').firstMatch(a.name);
      final n = match == null ? null : int.tryParse(match.group(1)!);
      if (n != null && n > maxSuffix) maxSuffix = n;
    }
    final seed = maxSuffix + 1;
    await _prefs.setNextAccountNumber(seed);
    return seed;
  }

  /// Consume the next account number and advance the high-water mark. Callers
  /// must invoke this in ascending derivation-index order within a batch so the
  /// assigned numbers match the picker's ascending preview.
  Future<int> _allocateAccountNumber() async {
    final n = await _seededNextAccountNumber();
    await _prefs.setNextAccountNumber(n + 1);
    return n;
  }

  /// Public wrapper for eager backfill from AuthStateNotifier.
  Future<void> syncWalletGraph() => _locked(() => _syncWalletGraph());

  /// Restore seed phrases and wallets from a Keychain graph JSON blob.
  ///
  /// Expects a v3 graph (seed phrases + accounts + wallets). All-or-nothing:
  ///
  /// - Before anything is written, every seed phrase and every imported-key
  ///   wallet in the graph must have its secret readable from the vault. One
  ///   miss — a nil read *or* a read error — aborts the whole restore with
  ///   [RestoreAborted] and nothing is written. Restoring rows whose keys are
  ///   gone would put wallets on screen that cannot sign, and a partial
  ///   restore used to leave a subset that the next graph sync then wrote
  ///   back over the full graph. Social keys are exempt (a re-login recovers
  ///   them); Ledger ids and view-only rows hold no secret.
  /// - The row writes run in one transaction, so a mid-way failure leaves the
  ///   database exactly as it was.
  ///
  /// [readableOnly] is the opt-in way past that abort, offered on the Restore
  /// screen once an abort has happened and only when something *is* readable.
  /// It writes every entry whose secret reads and skips the rest — and it
  /// writes nothing to the graph, so the skipped entries stay listed there:
  /// the boot-time dormant restore retries them at every launch, and a later
  /// restore can still take them. Without it one unreadable entry aborts every
  /// restore forever and the only other action erases the readable seeds too.
  Future<RestoreResult> restoreFromGraph(
    String graphJson, {
    bool readableOnly = false,
  }) => _locked(
    () => _restoreFromGraphLocked(graphJson, readableOnly: readableOnly),
  );

  Future<RestoreResult> _restoreFromGraphLocked(
    String graphJson, {
    required bool readableOnly,
  }) async {
    final Map<String, dynamic> graph;
    try {
      graph = jsonDecode(graphJson) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[WalletRepository] Failed to restore from graph: $e');
      return RestoreFailed(e);
    }

    try {
      final missing = await _findMissingSecrets(graph);
      if (missing.aborted.hasMissing) {
        if (!readableOnly || !missing.aborted.hasReadable) {
          return missing.aborted;
        }
        return await _restoreReadableFromGraph(graph, missing);
      }

      await _db.transaction(() => _restoreFromGraphV3(graph));
      await _restoreSelection(graph, _entryIds(_entries(graph['wallets'])));

      return RestoreRestored(
        seedPhrases:
            (graph['seedPhrases'] as List<dynamic>? ?? const []).length,
        wallets: (graph['wallets'] as List<dynamic>? ?? const []).length,
      );
    } catch (e) {
      debugPrint('[WalletRepository] Failed to restore from graph: $e');
      return RestoreFailed(e);
    }
  }

  /// Write everything in [graph] whose secret read, skipping the entries
  /// [missing] names and the rows that depend on them: a missing seed takes
  /// its accounts and wallets with it, a missing imported key takes its own
  /// row, and an account belonging to neither a restored wallet nor a
  /// restored seed is left out.
  ///
  /// The graph itself is not touched — the skipped entries stay in it.
  Future<RestoreResult> _restoreReadableFromGraph(
    Map<String, dynamic> graph,
    _MissingSecrets missing,
  ) async {
    final seedPhrases = _entries(
      graph['seedPhrases'],
    ).where((sp) => !missing.seedPhraseIds.contains(sp['id'])).toList();
    final wallets = _entries(graph['wallets']).where((w) {
      if (missing.importedKeyIds.contains(w['id'])) return false;
      final seedPhraseId = w['seedPhraseId'];
      return !missing.seedPhraseIds.contains(seedPhraseId);
    }).toList();
    final walletAccountIds = wallets.map((w) => w['accountId']).toSet();
    final restoredSeedIds = _entryIds(seedPhrases);
    // An account of a restored seed is kept even when no wallet references it:
    // an import whose every selection was already taken leaves such an account
    // behind, and the full restore writes it. Dropping it here would make a
    // partial restore quietly lose an account row the graph still lists.
    final accounts = _entries(graph['accounts'])
        .where(
          (a) =>
              walletAccountIds.contains(a['id']) ||
              restoredSeedIds.contains(a['seedPhraseId']),
        )
        .toList();

    await _db.transaction(
      () => _upsertGraphEntries(
        seedPhrases: seedPhrases,
        accounts: accounts,
        wallets: wallets,
      ),
    );
    await _restoreSelection(graph, _entryIds(wallets));

    return RestoreRestored(
      seedPhrases: seedPhrases.length,
      wallets: wallets.length,
      skippedSeedPhrases: missing.seedPhraseIds.length,
      skippedImportedKeys: missing.importedKeyIds.length,
    );
  }

  /// Decide the active selection after a restore wrote [restoredWalletIds].
  ///
  /// The graph's own choice is taken only when the wallet it names is actually
  /// there. Graphs written before the prune validated its selection can name a
  /// wallet the same write removed, and a partial restore is the other way it
  /// happens: the selected wallet may be one of the skipped rows.
  ///
  /// Leaving the selection alone in that case is not enough. The stored id
  /// ([SecureWalletStorage.loadSelectedWalletId]) lives in the plugin store,
  /// which survives an iOS reinstall — so after a restore it can still name a
  /// wallet that no longer has a row, and [getActiveWallet] answers null
  /// forever with nothing but a manual wallet switch to repair it. So when
  /// neither id resolves, the selection is re-pointed at a restored wallet, in
  /// this order: a Solana row that can sign, then any Solana row, then the
  /// first restored row. A restore that wrote no wallet at all clears the
  /// selection instead.
  ///
  /// Solana first because its signing resolves the keypair from the
  /// *selection* rather than an explicit id ([WalletInfo.bindsGlobalSigner]),
  /// so parking the selection off-chain leaves it with no key to load. But
  /// that flag says which chain reads the selection, not that the row holds a
  /// key: a watch-only Solana row passes it and can still sign nothing, so a
  /// signing row of the same chain is taken ahead of it when the restore
  /// wrote one.
  Future<void> _restoreSelection(
    Map<String, dynamic> graph,
    Set<String> restoredWalletIds,
  ) async {
    final selectedWalletId = graph['selectedWalletId'] as String?;
    if (selectedWalletId != null &&
        await _db.getWalletById(selectedWalletId) != null) {
      await _storage.storeSelectedWalletId(selectedWalletId);
      return;
    }

    final stored = await _storage.loadSelectedWalletId();
    if (stored != null && await _db.getWalletById(stored) != null) return;

    final restored = (await _db.getAllWallets())
        .where((w) => restoredWalletIds.contains(w.id))
        .toList();
    if (restored.isEmpty) {
      await _storage.deleteSelectedWalletId();
      return;
    }
    final infos = restored.map(_walletRowToInfo).toList();
    final pick = infos.firstWhere(
      (w) => w.bindsGlobalSigner && w.canSign,
      orElse: () => infos.firstWhere(
        (w) => w.bindsGlobalSigner,
        orElse: () => infos.first,
      ),
    );
    await _storage.storeSelectedWalletId(pick.id);
  }

  /// The `id` field of every graph entry that has one.
  static Set<String> _entryIds(List<Map<String, dynamic>> entries) => {
    for (final e in entries)
      if (e['id'] case final String id) id,
  };

  /// Presence pre-check for [restoreFromGraph]: counts the seed phrases and
  /// imported-key wallets in [graph] whose secret cannot be read right now,
  /// and names them so a `readableOnly` restore can filter them out. The ids
  /// are row ids, not secrets — they are what the graph is indexed by.
  /// A read error counts as missing — restore must not proceed on a keystore
  /// it cannot see.
  Future<_MissingSecrets> _findMissingSecrets(
    Map<String, dynamic> graph,
  ) async {
    var totalSeeds = 0;
    final missingSeeds = <String>{};
    for (final spJson in graph['seedPhrases'] as List<dynamic>? ?? const []) {
      final id = (spJson as Map<String, dynamic>)['id'] as String;
      totalSeeds++;
      if ((await _tryRead(() => _storage.loadMnemonicForSeedPhrase(id))) ==
          null) {
        missingSeeds.add(id);
      }
    }

    var totalKeys = 0;
    var readableWallets = 0;
    final missingKeys = <String>{};
    for (final wJson in graph['wallets'] as List<dynamic>? ?? const []) {
      final w = wJson as Map<String, dynamic>;
      final id = w['id'] as String;
      final underMissingSeed = missingSeeds.contains(w['seedPhraseId']);
      final type = WalletType.fromDbString(w['walletType'] as String);
      if (type != WalletType.importedKey) {
        // Only rows that could sign afterwards count — an HD row of a seed
        // that read, or a social row whose key a re-login mints again. A
        // view-only or Ledger row restores without a secret, so counting it
        // would offer a partial restore that writes nothing signable and
        // then hides the Restore screen behind a database that has wallets.
        if (!underMissingSeed &&
            (type == WalletType.hd || type == WalletType.social)) {
          readableWallets++;
        }
        continue;
      }
      totalKeys++;
      if ((await _tryRead(() => _storage.loadPrivateKey(id))) == null) {
        missingKeys.add(id);
      } else if (!underMissingSeed) {
        readableWallets++;
      }
    }

    return _MissingSecrets(
      aborted: RestoreAborted(
        missingSeedPhrases: missingSeeds.length,
        totalSeedPhrases: totalSeeds,
        missingImportedKeys: missingKeys.length,
        totalImportedKeys: totalKeys,
        readableWallets: readableWallets,
      ),
      seedPhraseIds: missingSeeds,
      importedKeyIds: missingKeys,
    );
  }

  /// Restore a v3 graph (Accounts-model: seed phrases + accounts + wallets).
  Future<void> _restoreFromGraphV3(Map<String, dynamic> graph) {
    return _upsertGraphEntries(
      seedPhrases: (graph['seedPhrases'] as List<dynamic>)
          .cast<Map<String, dynamic>>(),
      accounts: (graph['accounts'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>(),
      wallets: (graph['wallets'] as List<dynamic>).cast<Map<String, dynamic>>(),
    );
  }

  /// Write graph entries as rows. Shared by the full restore and the dormant
  /// restore; callers wrap it in a transaction.
  Future<void> _upsertGraphEntries({
    required List<Map<String, dynamic>> seedPhrases,
    required List<Map<String, dynamic>> accounts,
    required List<Map<String, dynamic>> wallets,
  }) async {
    var spFallbackSort = 0;
    for (final sp in seedPhrases) {
      final sortIndex = (sp['sortIndex'] as int?) ?? spFallbackSort;
      spFallbackSort = sortIndex + 1;
      await _db.upsertSeedPhrase(
        SeedPhrasesCompanion.insert(
          id: sp['id'] as String,
          name: sp['name'] as String,
          createdAt: _nowSeconds(),
          sortIndex: Value(sortIndex),
        ),
      );
    }

    var accFallbackSort = 0;
    for (final a in accounts) {
      final sortIndex = (a['sortIndex'] as int?) ?? accFallbackSort;
      accFallbackSort = sortIndex + 1;
      await _db.upsertAccount(
        AccountsCompanion.insert(
          id: a['id'] as String,
          seedPhraseId: Value(a['seedPhraseId'] as String?),
          derivationIndex: Value(a['derivationIndex'] as int?),
          kind: a['kind'] as String,
          name: a['name'] as String,
          avatarSeed: a['avatarSeed'] as String,
          createdAt: _nowSeconds(),
          sortIndex: Value(sortIndex),
        ),
      );
    }

    final walletFallbackSort = <String?, int>{};
    for (final w in wallets) {
      final seedPhraseId = w['seedPhraseId'] as String?;
      final fallback = walletFallbackSort[seedPhraseId] ?? 0;
      final sortIndex = (w['sortIndex'] as int?) ?? fallback;
      walletFallbackSort[seedPhraseId] = sortIndex + 1;
      await _db.upsertWalletEntry(
        WalletsCompanion.insert(
          id: w['id'] as String,
          accountId: Value(w['accountId'] as String?),
          seedPhraseId: Value(seedPhraseId),
          address: w['address'] as String,
          name: w['name'] as String,
          walletType: w['walletType'] as String,
          derivationIndex: Value(w['derivationIndex'] as int?),
          derivationScheme: Value(w['derivationScheme'] as String?),
          socialProvider: Value(w['socialProvider'] as String?),
          chain: Value(w['chain'] as String? ?? 'solana'),
          createdAt: _nowSeconds(),
          sortIndex: Value(sortIndex),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Dormant entries (graph knows them, database does not)
  // ---------------------------------------------------------------------------

  /// Bring back wallets the recovery graph lists but the database lacks.
  ///
  /// Runs once per cold start, after the database opened and before routing,
  /// and only when the database already has wallets (an empty database is the
  /// explicit Restore screen's case). How an entry gets dormant: the graph
  /// carries over what the database does not know ([_syncWalletGraph]), so
  /// after a misread-routed onboarding the old seeds stay listed while the
  /// database holds only the new one.
  ///
  /// The dormant diff is computed before any secret is read, so a launch where
  /// the graph and the database agree — every launch after the first — reads
  /// and decrypts nothing.
  ///
  /// Per dormant seed phrase / imported-key wallet: read its secret. A nil or
  /// failed read skips it for this launch (it stays in the graph). What
  /// happens to a readable one:
  ///
  /// - **Seed phrase.** Its mnemonic is compared against every live seed's
  ///   mnemonic, and against every seed restored earlier in this pass.
  ///   Equal to one of them (both reads non-null) is a duplicate:
  ///   the dormant entry is pruned from the graph and its vault copy deleted,
  ///   because the live seed holds the same secret. If any live seed's
  ///   mnemonic does *not* read, no comparison can be made and **every**
  ///   dormant seed is skipped this launch — restoring one would write a
  ///   second seed row for a secret that may already be live, and nothing
  ///   merges the two afterwards. Otherwise it is restored.
  /// - **Imported key.** A live row at the same address is not enough to call
  ///   it a duplicate: a view-only or Ledger row there holds no key, so
  ///   deleting the dormant one would destroy the only copy of it. It is a
  ///   duplicate only when some live row at that address holds a signing
  ///   secret that reads right now — an imported/social row's private key, or
  ///   a seed-derived row's mnemonic. Anything else skips it.
  /// - **Social.** Its key is recoverable by re-logging in, so it is not
  ///   protected the way an imported key is — but it is still the only copy on
  ///   this device, and a live view-only or Ledger row at the same address
  ///   cannot sign. So the same live-signing test applies: a duplicate only
  ///   when some live row at that address holds a readable signing secret.
  /// - **Ledger and view-only.** No vault secret at all: restored when the
  ///   address is new, pruned as duplicates when it is not.
  ///
  /// A restore writes rows only, one transaction per entry, and what it writes
  /// counts as live for every decision after it — its mnemonic for the seed
  /// comparison, its addresses for the wallet ones. Otherwise a second dormant
  /// entry for the same secret is judged against a snapshot taken before the
  /// restore, written a second time, and nothing merges the two rows
  /// afterwards. A restored seed's wallet whose address is already live is the
  /// one row that is *not* written: the address derives from the key, so the
  /// row already there holds the same key material, and a second signing row
  /// at one address is what the import guards forbid. Its graph entry is
  /// pruned with the duplicates, and nothing goes with it — the seed, and the
  /// mnemonic every one of its wallets derives from, is restored.
  ///
  /// Every duplicate both passes find is pruned by **one** graph write after
  /// them, and only then are the vault items deleted, one at a time. The graph
  /// write is still the commit point: a failure there deletes nothing and
  /// leaves every entry dormant for the next launch.
  ///
  /// A malformed entry counts as skipped and never stops the ones after it.
  /// The active selection is never touched. Silent to the user; the caller
  /// reports the counts.
  ///
  /// [graphJson] is the graph blob the caller has already read — the boot path
  /// reads it for its backfill check — since each read costs a protected-data
  /// probe plus a Keychain fetch and doing both twice per cold start buys
  /// nothing. Only a **successful** read may be passed: a read that threw
  /// means "unknown", not "no graph", and absence is acted on here.
  Future<DormantRestoreResult> restoreDormantFromGraph({String? graphJson}) =>
      _locked(() => _restoreDormantFromGraphLocked(graphJson));

  Future<DormantRestoreResult> _restoreDormantFromGraphLocked(
    String? graphJson,
  ) async {
    final stored = graphJson == null
        ? await _loadStoredGraph()
        : _decodeGraph(graphJson);
    if (stored == null) return const DormantRestoreResult();

    final dbSeeds = await _db.getAllSeedPhrases();
    final dbSeedIds = dbSeeds.map((s) => s.id).toSet();
    final dbWallets = await _db.getAllWallets();
    final dbWalletIds = dbWallets.map((w) => w.id).toSet();

    final storedAccounts = _entries(stored['accounts']);
    final storedWallets = _entries(stored['wallets']);

    // The diff comes first so the steady state costs zero keystore reads: with
    // nothing dormant there is nothing to compare, and reading every live
    // mnemonic to answer that would decrypt N secrets on every cold start.
    final dormantSeeds = _entries(stored['seedPhrases'])
        .where((sp) => sp['id'] is String && !dbSeedIds.contains(sp['id']))
        .toList();
    final dormantWallets = storedWallets
        .where(
          (w) =>
              w['id'] is String &&
              !dbWalletIds.contains(w['id']) &&
              w['seedPhraseId'] == null, // seed wallets come with their seed
        )
        .toList();
    if (dormantSeeds.isEmpty && dormantWallets.isEmpty) {
      return const DormantRestoreResult();
    }

    // EVM addresses compare case-insensitively, so address identity is the
    // `apiOwnerAddress` form everywhere below.
    final dbAddresses = dbWallets
        .map((w) => apiOwnerAddress(w.address))
        .toSet();
    final dbAccountIds = (await _db.getAllAccounts()).map((a) => a.id).toSet();

    var seedsRestored = 0;
    var walletsRestored = 0;
    var duplicates = 0;
    var skipped = 0;

    // Live mnemonics, for the seed duplicate rule: read at most once, and only
    // when a dormant seed actually needs the comparison. `null` means at least
    // one live seed did not read, so the comparison is impossible this launch.
    Set<String>? liveMnemonics;
    var liveMnemonicsRead = false;
    var liveSeedUnreadable = false;
    Future<Set<String>?> readLiveMnemonics() async {
      if (liveMnemonicsRead) return liveMnemonics;
      liveMnemonicsRead = true;
      final read = <String>{};
      for (final sp in dbSeeds) {
        final m = await _tryRead(
          () => _storage.loadMnemonicForSeedPhrase(sp.id),
        );
        if (m == null) {
          // Correct to wait, but a live seed that never reads again makes the
          // wait permanent — so say so, once, for the caller to report.
          liveSeedUnreadable = true;
          return null;
        }
        read.add(m);
      }
      return liveMnemonics = read;
    }

    // Addresses restored during this run whose secret read non-null, so a
    // second dormant entry for the same key is still recognised as a duplicate.
    final restoredSigningAddresses = <String>{};

    // Entries both passes decided to drop, pruned by one graph write after
    // them. `duplicateKeyIds` is the subset that owns a vault item.
    final duplicateSeedIds = <String>{};
    final duplicateWalletIds = <String>{};
    final duplicateKeyIds = <String>{};

    for (final sp in dormantSeeds) {
      final id = sp['id'] as String;
      try {
        final mnemonic = await _tryRead(
          () => _storage.loadMnemonicForSeedPhrase(id),
        );
        if (mnemonic == null) {
          skipped++;
          continue;
        }
        final live = await readLiveMnemonics();
        if (live == null) {
          // A live seed did not read. Guessing "not a duplicate" here writes a
          // second seed row plus duplicate-address wallet rows for a secret
          // that may already be live, and no later launch undoes that — both
          // ids are then in the database. Wait for a launch that can compare.
          skipped++;
          continue;
        }
        if (live.contains(mnemonic)) {
          // Same secret lives under another id — a live seed, or one restored
          // earlier in this pass, whose mnemonic was read to get here: drop
          // the dormant copy.
          duplicateSeedIds.add(id);
          continue;
        }
        final accounts = storedAccounts
            .where(
              (a) => a['seedPhraseId'] == id && !dbAccountIds.contains(a['id']),
            )
            .toList();
        // A wallet whose address is already live is dropped rather than
        // written: an address identifies the key it derives from, so the row
        // already there holds this key material, and a second signing row at
        // one address is what the import guards forbid. Collected, not pruned
        // yet — a transaction that throws below must leave the entry alone.
        final wallets = <Map<String, dynamic>>[];
        final collided = <String>[];
        final freshAddresses = <String>[];
        for (final w in storedWallets) {
          if (w['seedPhraseId'] != id || dbWalletIds.contains(w['id'])) {
            continue;
          }
          final address = w['address'];
          final walletId = w['id'];
          if (address is String &&
              walletId is String &&
              dbAddresses.contains(apiOwnerAddress(address))) {
            collided.add(walletId);
            continue;
          }
          wallets.add(w);
          if (address is String) freshAddresses.add(apiOwnerAddress(address));
        }
        await _db.transaction(
          () => _upsertGraphEntries(
            seedPhrases: [sp],
            accounts: accounts,
            wallets: wallets,
          ),
        );
        seedsRestored++;
        walletsRestored += wallets.length;
        duplicateWalletIds.addAll(collided);
        // Everything judged after this point — the seeds later in this pass
        // and every dormant wallet in the next one — must see what was just
        // written as live. The mnemonic read non-null, so these rows can sign:
        // another entry at one of their addresses is a duplicate, not the last
        // copy of a key.
        live.add(mnemonic);
        dbAddresses.addAll(freshAddresses);
        restoredSigningAddresses.addAll(freshAddresses);
      } catch (e) {
        // A malformed entry (or a row write that fails) must not cost the
        // entries after it their restore, nor the caller its counts.
        skipped++;
        debugPrint('[WalletRepository] Dormant seed $id skipped: $e');
      }
    }

    for (final w in dormantWallets) {
      final id = w['id'] as String;
      try {
        final address = w['address'] as String?;
        if (address == null) {
          // Malformed like any other: counted, so the launch's counts still
          // add up to the number of entries it looked at.
          skipped++;
          continue;
        }
        final type = WalletType.fromDbString(w['walletType'] as String? ?? '');
        final addressKey = apiOwnerAddress(address);
        final addressIsLive = dbAddresses.contains(addressKey);

        if (type == WalletType.importedKey) {
          final key = await _tryRead(() => _storage.loadPrivateKey(id));
          if (key == null) {
            skipped++;
            continue;
          }
        }

        // Rows that own a vault key — imported *and* social — are only
        // duplicates when a live row at the address can actually sign. A
        // social key is recoverable by re-login and an imported one is not,
        // but on this device both are the only copy, and deleting one because
        // a view-only or Ledger row happens to hold the address destroys it
        // either way.
        if ((type == WalletType.importedKey || type == WalletType.social) &&
            addressIsLive &&
            !restoredSigningAddresses.contains(addressKey) &&
            !await _hasLiveSigningSecret(dbWallets, addressKey)) {
          // Every live row at this address is view-only, a Ledger, or a row
          // whose own secret did not read: none of them can sign, so this
          // dormant key is the only copy. Keep it and the graph entry.
          skipped++;
          continue;
        }

        if (addressIsLive) {
          // The address is live under a row that holds the same secret.
          duplicateWalletIds.add(id);
          if (type == WalletType.importedKey || type == WalletType.social) {
            duplicateKeyIds.add(id);
          }
          continue;
        }

        final accountId = w['accountId'] as String?;
        final accounts = storedAccounts
            .where(
              (a) => a['id'] == accountId && !dbAccountIds.contains(accountId),
            )
            .toList();
        await _db.transaction(
          () => _upsertGraphEntries(
            seedPhrases: const [],
            accounts: accounts,
            wallets: [w],
          ),
        );
        if (accountId != null) dbAccountIds.add(accountId);
        dbAddresses.add(addressKey);
        if (type == WalletType.importedKey) {
          restoredSigningAddresses.add(addressKey);
        }
        walletsRestored++;
      } catch (e) {
        skipped++;
        debugPrint('[WalletRepository] Dormant wallet $id skipped: $e');
      }
    }

    // One prune for every duplicate both passes found. A `_syncWalletGraph` is
    // a full rebuild — three table reads, a protected-data probe, a graph read
    // and a Keychain write — and this runs before the first route is resolved,
    // so one per entry paid that N times. Order does not matter: no decision
    // above reads what a prune changes.
    if (duplicateSeedIds.isNotEmpty || duplicateWalletIds.isNotEmpty) {
      var pruned = true;
      try {
        await _syncWalletGraph(
          removedSeedPhraseIds: duplicateSeedIds,
          removedWalletIds: duplicateWalletIds,
        );
      } on GraphSyncException {
        pruned = false;
      }
      if (!pruned) {
        // The graph write is the commit point: nothing left the graph, so
        // nothing may leave the vault. Every entry is decided again next
        // launch.
        skipped += duplicateSeedIds.length + duplicateWalletIds.length;
      } else {
        for (final id in duplicateSeedIds) {
          try {
            await _storage.deleteMnemonicForSeedPhrase(id);
            duplicates++;
          } catch (e) {
            // Pruned but not erased: the graph no longer indexes it, so the
            // count is what says this launch left something behind.
            skipped++;
            debugPrint('[WalletRepository] Dormant seed $id not erased: $e');
          }
        }
        for (final id in duplicateWalletIds) {
          try {
            if (duplicateKeyIds.contains(id)) {
              await _storage.deletePrivateKey(id);
            }
            duplicates++;
          } catch (e) {
            skipped++;
            debugPrint('[WalletRepository] Dormant key $id not erased: $e');
          }
        }
      }
    }

    return DormantRestoreResult(
      seedPhrasesRestored: seedsRestored,
      walletsRestored: walletsRestored,
      duplicatesDropped: duplicates,
      skipped: skipped,
      liveSeedUnreadable: liveSeedUnreadable,
    );
  }

  /// Parse a graph blob the caller already read, the way [_loadStoredGraph]
  /// parses the one it reads itself: unparseable is null. Safe to act on as
  /// "nothing dormant" — the caller passes a read that succeeded, so null here
  /// means the blob is unusable, not that the keystore stayed silent.
  static Map<String, dynamic>? _decodeGraph(String json) {
    if (json.isEmpty) return null;
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[WalletRepository] Stored wallet graph is unreadable: $e');
      return null;
    }
  }

  /// Whether any row in [rows] at [addressKey] holds a signing secret that
  /// reads right now: an imported/social row's private key, or a seed-derived
  /// row's mnemonic. View-only and hardware rows (Ledger, Seed Vault) never
  /// do — the key material is elsewhere — so an address being live says
  /// nothing on its own about whether a dormant key at that address is still
  /// the only copy.
  Future<bool> _hasLiveSigningSecret(
    List<Wallet> rows,
    String addressKey,
  ) async {
    for (final row in rows) {
      if (apiOwnerAddress(row.address) != addressKey) continue;
      final seedPhraseId = row.seedPhraseId;
      if (seedPhraseId != null) {
        final mnemonic = await _tryRead(
          () => _storage.loadMnemonicForSeedPhrase(seedPhraseId),
        );
        if (mnemonic != null) return true;
        continue;
      }
      final type = WalletType.fromDbString(row.walletType);
      if (type == WalletType.importedKey || type == WalletType.social) {
        if (await _tryRead(() => _storage.loadPrivateKey(row.id)) != null) {
          return true;
        }
      }
    }
    return false;
  }

  /// Read a secret for a presence/equality check; any failure reads as null.
  Future<String?> _tryRead(Future<String?> Function() read) async {
    try {
      final value = await read();
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  WalletInfo _walletRowToInfo(Wallet row) => WalletInfo(
    id: row.id,
    address: row.address,
    name: row.name,
    walletType: WalletType.fromDbString(row.walletType),
    chain: row.chain,
    accountId: row.accountId,
    seedPhraseId: row.seedPhraseId,
    derivationIndex: row.derivationIndex,
    derivationScheme: _parseDerivationScheme(row.derivationScheme),
    socialProvider: row.socialProvider,
    sortIndex: row.sortIndex,
  );

  static SolanaDerivationScheme? _parseDerivationScheme(String? raw) {
    if (raw == null) return null;
    return SolanaDerivationScheme.values.asNameMap()[raw];
  }

  SeedPhraseInfo _seedPhraseRowToInfo(SeedPhrase row) =>
      SeedPhraseInfo(id: row.id, name: row.name, sortIndex: row.sortIndex);

  static const _uuid = Uuid();
  static String _generateId() => _uuid.v4();
  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
