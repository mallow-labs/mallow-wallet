import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
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
import '../security/secure_storage.dart';
import 'preferences_service.dart';

/// Thrown when attempting to import a wallet whose address already exists.
class DuplicateWalletException implements Exception {
  DuplicateWalletException(this.address);
  final String address;

  @override
  String toString() => 'A wallet with this address already exists';
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

  // Serializes seed-phrase creation so dedupe-by-mnemonic is race-safe
  // against concurrent callers (e.g. a double-tapped onboarding button).
  Future<void> _seedPhraseCreateLock = Future.value();

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
  }) {
    final operation = _seedPhraseCreateLock.then(
      (_) => _createSeedPhraseFromMnemonicLocked(
        normalizedMnemonic,
        autoDerive: autoDerive,
      ),
    );
    _seedPhraseCreateLock = operation.then((_) {}, onError: (_) {});
    return operation;
  }

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
      await importAccountsFromPhrase(seedPhraseId, [
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
  Future<bool> _clearWatchOnlyForSigningImport(String address) async {
    final existing = await _lookupWalletByAddress(address);
    if (existing == null) return true;
    if (WalletType.fromDbString(existing.walletType) != WalletType.viewOnly) {
      return false;
    }

    // A view-only wallet is always alone in its account (see addViewOnlyWallet).
    // Remove the wallet — cleaning up its cached balances and re-selecting a
    // replacement if it was active — then drop the emptied account row so no
    // dangling watch-only account remains.
    final accountId = existing.accountId;
    await removeWallet(existing.id);
    if (accountId != null) {
      final remaining = await _db.getWalletsForAccount(accountId);
      if (remaining.isEmpty) await _db.deleteAccountById(accountId);
    }
    return true;
  }

  /// Add an imported private key wallet.
  Future<WalletInfo> addImportedKeyWallet(
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
  Future<WalletInfo> addViewOnlyWallet(String address, String name) async {
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
  Future<WalletInfo> setActiveWallet(String walletId) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw StateError('Wallet not found: $walletId');

    await _storage.storeSelectedWalletId(walletId);

    await _syncWalletGraph();
    return _walletRowToInfo(row);
  }

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
  Future<List<WalletInfo>> importAccountsFromPhrase(
    String seedPhraseId,
    List<WalletImportSelection> selections,
  ) async {
    if (selections.isEmpty) return const [];

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
  Future<void> reorderWalletsInGroup(List<String> orderedWalletIds) async {
    for (var i = 0; i < orderedWalletIds.length; i++) {
      await _db.updateWalletSortIndex(orderedWalletIds[i], i);
    }
    await _syncWalletGraph();
  }

  // ---------------------------------------------------------------------------
  // Rename
  // ---------------------------------------------------------------------------

  /// Rename a wallet and sync the wallet graph.
  Future<void> renameWallet(String walletId, String newName) async {
    await _db.updateWalletName(walletId, newName);
    await _syncWalletGraph();
  }

  /// Rename an account and sync the wallet graph.
  Future<void> renameAccount(String accountId, String newName) async {
    await _db.updateAccountName(accountId, newName);
    await _syncWalletGraph();
  }

  /// Update an account's generated-avatar seed and sync the wallet graph.
  Future<void> updateAccountAvatarSeed(String accountId, String seed) async {
    await _db.updateAccountAvatarSeed(accountId, seed);
    await _syncWalletGraph();
  }

  /// Reorder accounts; persists the new sortIndex for each in list order.
  Future<void> reorderAccounts(List<String> orderedAccountIds) async {
    for (var i = 0; i < orderedAccountIds.length; i++) {
      await _db.updateAccountSortIndex(orderedAccountIds[i], i);
    }
    await _syncWalletGraph();
  }

  /// Remove an entire account: deletes each of its wallets (cleaning up
  /// secrets/cached data via [removeWallet]) then the account row. Returns the
  /// replacement active wallet id, or null if no wallets remain.
  Future<String?> removeAccount(String accountId) async {
    final wallets = await _db.getWalletsForAccount(accountId);
    String? replacement;
    for (final w in wallets) {
      replacement = await removeWallet(w.id);
    }
    await _db.deleteAccountById(accountId);
    await _syncWalletGraph();
    return replacement;
  }

  // ---------------------------------------------------------------------------
  // Remove Single Wallet
  // ---------------------------------------------------------------------------

  /// Remove a single wallet, cleaning up secrets and cached data.
  ///
  /// Returns the ID of the replacement active wallet, or null if no wallets
  /// remain (caller should redirect to welcome/onboarding).
  Future<String?> removeWallet(String walletId) async {
    final walletRow = await _db.getWalletById(walletId);
    if (walletRow == null) return null;

    final address = walletRow.address;
    final seedPhraseId = walletRow.seedPhraseId;
    final walletType = WalletType.fromDbString(walletRow.walletType);

    // Delete the private key for wallets that own one — imported-key wallets
    // and social wallets, whose per-chain key is captured at login and stored
    // in the same imported-key format (see [addSocialAccount]).
    if (walletType == WalletType.importedKey ||
        walletType == WalletType.social) {
      await _storage.deletePrivateKey(walletId);
    }

    // Delete Ledger device ID for hardware wallets
    if (walletType == WalletType.ledger) {
      await _storage.deleteLedgerDeviceId(walletId);
    }

    // Delete wallet-sig cookie
    await _storage.deleteWalletSigCookie(address);

    // Delete wallet row from DB
    await _db.deleteWalletById(walletId);

    // If this was the last wallet for a seed phrase, delete the seed phrase
    if (seedPhraseId != null) {
      final remaining = await _db.getWalletsForSeedPhrase(seedPhraseId);
      if (remaining.isEmpty) {
        await _db.deleteSeedPhraseById(seedPhraseId);
        await _storage.deleteMnemonicForSeedPhrase(seedPhraseId);
      }
    }

    // Delete cached balances for this wallet
    await _db.deleteBalances(address);

    // Delete locally tracked pending EVM transactions for this wallet. Rows are
    // keyed by the lowercased (`apiOwnerAddress`) form. This is the permanent
    // deletion path — a wallet merely dropped from the session keeps its rows.
    await _db.deletePendingEvmTransactionsForWallet(apiOwnerAddress(address));

    // If deleted wallet was the active one, select a replacement
    final currentSelection = await _storage.loadSelectedWalletId();
    if (currentSelection == walletId) {
      final allWallets = await _db.getAllWallets();
      if (allWallets.isNotEmpty) {
        // Prefer a row that binds the global signer — Solana, see
        // [WalletInfo.bindsGlobalSigner]. Solana signing resolves its keypair
        // from the *selection*, not an explicit wallet id, so parking the
        // selection on a Tezos or Ethereum row leaves `getPublicKey()` /
        // `signMessage()` with no Solana key to load. Falls back to the first
        // row when no Solana row remains.
        final replacement = allWallets
            .firstWhere(
              (w) => _walletRowToInfo(w).bindsGlobalSigner,
              orElse: () => allWallets.first,
            )
            .id;
        await _storage.storeSelectedWalletId(replacement);
        await _syncWalletGraph();
        return replacement;
      } else {
        // No wallets remain
        await _storage.deleteSelectedWalletId();
        await _syncWalletGraph();
        return null;
      }
    }

    await _syncWalletGraph();
    return currentSelection;
  }

  // ---------------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------------

  /// Delete all seed phrases, wallets, their secrets, and every stored
  /// preference.
  ///
  /// This backs Settings → "Reset app", which users read as a factory reset,
  /// so device-local preferences go too — not just the account counter.
  /// Leaving them behind meant the previous identity's recent send recipients
  /// (and searches, recently-viewed, buy history) were still suggested after
  /// re-onboarding with a different seed phrase.
  ///
  /// Not to be confused with the profile-only "Delete account" in Settings →
  /// Security & Privacy, which deliberately leaves wallets and the recovery
  /// phrase intact.
  Future<void> resetAll() async {
    final seedPhrases = await _db.getAllSeedPhrases();
    final wallets = await _db.getAllWallets();

    await _storage.clearAll(
      seedPhraseIds: seedPhrases.map((s) => s.id).toList(),
      walletIds: wallets.map((w) => w.id).toList(),
    );

    await _db.clearAll();
    // Wipes every preference, including the global account counter, so a fresh
    // onboard begins at Account 01 with default settings and no carried-over
    // history from the previous identity.
    await _prefs.clearAll();
  }

  // ---------------------------------------------------------------------------
  // Wallet Graph Persistence (Recovery)
  // ---------------------------------------------------------------------------

  /// Sync the full wallet graph to Keychain for recovery.
  Future<void> _syncWalletGraph() async {
    try {
      final seedPhrases = await getAllSeedPhrases();
      final accountRows = await _db.getAllAccounts();
      final wallets = await getAllWallets();
      final selectedWalletId = await _storage.loadSelectedWalletId();

      final graph = {
        'version': 3,
        'seedPhrases': seedPhrases
            .map(
              (sp) => {'id': sp.id, 'name': sp.name, 'sortIndex': sp.sortIndex},
            )
            .toList(),
        'accounts': accountRows
            .map(
              (a) => {
                'id': a.id,
                'seedPhraseId': a.seedPhraseId,
                'derivationIndex': a.derivationIndex,
                'kind': a.kind,
                'name': a.name,
                'avatarSeed': a.avatarSeed,
                'sortIndex': a.sortIndex,
              },
            )
            .toList(),
        'wallets': wallets
            .map(
              (w) => {
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
            .toList(),
        'selectedWalletId': selectedWalletId,
      };

      await _storage.storeAccountGraph(jsonEncode(graph));
    } catch (e) {
      debugPrint('[WalletRepository] Failed to sync wallet graph: $e');
    }
  }

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
  Future<void> syncWalletGraph() => _syncWalletGraph();

  /// Restore seed phrases and wallets from a Keychain graph JSON blob.
  ///
  /// Expects a v3 graph (seed phrases + accounts + wallets). Returns true if
  /// restoration succeeded.
  Future<bool> restoreFromGraph(String graphJson) async {
    try {
      final graph = jsonDecode(graphJson) as Map<String, dynamic>;
      await _restoreFromGraphV3(graph);

      // Restore active selection
      final selectedWalletId = graph['selectedWalletId'] as String?;
      if (selectedWalletId != null) {
        await _storage.storeSelectedWalletId(selectedWalletId);
      }

      return true;
    } catch (e) {
      debugPrint('[WalletRepository] Failed to restore from graph: $e');
      return false;
    }
  }

  /// Restore a v3 graph (Accounts-model: seed phrases + accounts + wallets).
  Future<void> _restoreFromGraphV3(Map<String, dynamic> graph) async {
    final seedPhrases = graph['seedPhrases'] as List<dynamic>;
    var spFallbackSort = 0;
    for (final spJson in seedPhrases) {
      final sp = spJson as Map<String, dynamic>;
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

    final accounts = graph['accounts'] as List<dynamic>? ?? const [];
    var accFallbackSort = 0;
    for (final aJson in accounts) {
      final a = aJson as Map<String, dynamic>;
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

    final wallets = graph['wallets'] as List<dynamic>;
    final walletFallbackSort = <String?, int>{};
    for (final wJson in wallets) {
      final w = wJson as Map<String, dynamic>;
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
