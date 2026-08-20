import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart' show SentryLevel;

import '../security/secure_storage.dart';
import '../services/sentry_service.dart';

part 'database.g.dart';

// ============================================================================
// Table Definitions
// ============================================================================

/// A seed phrase (mnemonic), decoupled from any profile/account grouping.
class SeedPhrases extends Table {
  /// UUID primary key
  TextColumn get id => text()();

  /// User-visible label (e.g. "Seed 1")
  TextColumn get name => text()();

  /// Timestamp when seed phrase was created (Unix seconds)
  IntColumn get createdAt => integer()();

  /// Explicit display order (for drag-to-reorder)
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// An Account — a derivation-index grouping of wallets across chains.
///
/// Three shapes (see [kind]):
///  - `seed`: one Account per `(seedPhraseId, derivationIndex)`, holding the
///    multi-chain wallets at that index (+ legacy Solana rows if imported).
///  - `privateKey`: one Account holding a single imported-key wallet.
///  - `hardware`: one Account per Ledger `derivationIndex`, holding that index's
///    Solana wallets (standard + legacy/root rows if imported).
@DataClassName('AccountRow')
class Accounts extends Table {
  /// UUID primary key
  TextColumn get id => text()();

  /// FK to SeedPhrases — only set for `seed` accounts.
  TextColumn get seedPhraseId => text().nullable()();

  /// HD derivation index — set for `seed` and `hardware` accounts.
  IntColumn get derivationIndex => integer().nullable()();

  /// Account shape: 'seed', 'privateKey', or 'hardware'.
  TextColumn get kind => text()();

  /// User-visible label (default "Account 1", user-editable).
  TextColumn get name => text()();

  /// Stable random UUID seed for the generated avatar (the identicon service,
  /// DiceBear `identicon`). Stays fixed across wallet add/remove and renames.
  TextColumn get avatarSeed => text()();

  /// Timestamp when the account was created (Unix seconds).
  IntColumn get createdAt => integer()();

  /// Explicit display order (for drag-to-reorder).
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Wallet — HD, imported key, view-only, social, or hardware.
class Wallets extends Table {
  /// UUID primary key
  TextColumn get id => text()();

  /// FK to Accounts — the account this wallet belongs to. Populated for all
  /// wallets created under the Accounts model.
  TextColumn get accountId => text().nullable()();

  /// FK to SeedPhrases — only set for HD wallets
  TextColumn get seedPhraseId => text().nullable()();

  /// On-chain address (base58 for Solana)
  TextColumn get address => text()();

  /// User-visible wallet name
  TextColumn get name => text()();

  /// Type: 'hd', 'imported_key', 'view_only', 'social', 'ledger'
  TextColumn get walletType => text()();

  /// HD derivation index (null for non-HD wallets)
  IntColumn get derivationIndex => integer().nullable()();

  /// Ledger derivation scheme: 'standard' or 'legacy' (null for non-Ledger)
  TextColumn get derivationScheme => text().nullable()();

  /// Social-auth provider: 'google' or 'apple' (null for non-social wallets)
  TextColumn get socialProvider => text().nullable()();

  /// Blockchain identifier
  TextColumn get chain => text().withDefault(const Constant('solana'))();

  /// Timestamp when wallet was created/imported (Unix seconds)
  IntColumn get createdAt => integer()();

  /// Explicit display order (for drag-to-reorder)
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Cached artwork data for offline access and fast display.
class CachedArtworks extends Table {
  /// Mint account address (unique identifier)
  TextColumn get mintAccount => text()();

  /// Artwork title/name
  TextColumn get name => text()();

  /// Image URL
  TextColumn get imageUrl => text()();

  /// Creator/artist address
  TextColumn get artistAddress => text().nullable()();

  /// Artist display name
  TextColumn get artistName => text().nullable()();

  /// Collection slug/key
  TextColumn get collectionKey => text().nullable()();

  /// Collection name
  TextColumn get collectionName => text().nullable()();

  /// Full artwork JSON data (for detailed view)
  TextColumn get jsonData => text()();

  /// When this cache entry was created/updated
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {mintAccount};
}

/// Cached token information.
class CachedTokens extends Table {
  /// Token mint address
  TextColumn get mint => text()();

  /// Token symbol (e.g., SOL, USDC)
  TextColumn get symbol => text()();

  /// Token name
  TextColumn get name => text()();

  /// Decimal places
  IntColumn get decimals => integer()();

  /// Logo URL
  TextColumn get logoUrl => text().nullable()();

  /// When this cache entry was created/updated
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {mint};
}

/// Cached token balances for instant display.
class CachedBalances extends Table {
  /// Wallet address this balance belongs to
  TextColumn get walletAddress => text()();

  /// Token mint address
  TextColumn get mint => text()();

  /// Token symbol (e.g., SOL, USDC)
  TextColumn get symbol => text()();

  /// Token name
  TextColumn get name => text()();

  /// Decimal places
  IntColumn get decimals => integer()();

  /// Balance in smallest unit (lamports/wei)
  IntColumn get rawBalance => integer()();

  /// Human-readable balance
  RealColumn get uiBalance => real()();

  /// USD price per token (nullable)
  RealColumn get pricePerToken => real().nullable()();

  /// Total USD value (nullable)
  RealColumn get totalUsdValue => real().nullable()();

  /// Token logo URL
  TextColumn get logoUrl => text().nullable()();

  /// True for the native chain asset (native SOL). Native SOL and wrapped SOL
  /// share the same [mint], so this must be part of the primary key — otherwise
  /// the two collapse into a single cached row and the cached portfolio total
  /// under-counts by one of them.
  BoolColumn get isNative => boolean().withDefault(const Constant(false))();

  /// When this cache entry was created/updated
  IntColumn get cachedAt => integer()();

  /// Chain this balance lives on (`solana` | `ethereum`). Defaults to `solana`
  /// so the Solana write path (which omits it) and any pre-multi-chain row stay
  /// correct. A wallet's Solana and Ethereum addresses are disjoint strings, so
  /// this never causes cross-chain key collisions; it is in the primary key
  /// only to keep the row self-describing on read.
  TextColumn get chain => text().withDefault(const Constant('solana'))();

  @override
  Set<Column> get primaryKey => {walletAddress, chain, mint, isNative};
}

/// Cached home feed data (single-row, serialized JSON).
class CachedHomeFeed extends Table {
  /// Always 'default' — single-row table.
  TextColumn get id => text().withDefault(const Constant('default'))();

  /// Full home feed JSON response.
  TextColumn get jsonData => text()();

  /// When this cache entry was created/updated (Unix seconds).
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Cached portfolio sections (serialized JSON, one row per section).
class CachedPortfolios extends Table {
  /// Sorted session wallet addresses joined with ',' — a wallet or session
  /// switch produces a different key, so one session's cache is never
  /// painted for another.
  TextColumn get sessionKey => text()();

  /// Section name ('artworks' or 'groups'). Sections are written
  /// independently by their fetches, which run in parallel — separate rows
  /// avoid a read-modify-write race on a combined blob.
  TextColumn get section => text()();

  /// Raw wire response JSON for the section.
  TextColumn get jsonData => text()();

  /// When this cache entry was created/updated (Unix seconds).
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {sessionKey, section};
}

/// Cached user profile data for progressive loading.
class CachedUserProfiles extends Table {
  /// User wallet address (primary key).
  TextColumn get address => text()();

  /// Full profile JSON (UserProfile + artworks + groups + youOwn).
  TextColumn get jsonData => text()();

  /// When this cache entry was created/updated (Unix seconds).
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {address};
}

/// Cached Jupiter token market data (24h price changes).
///
/// Global cache (not per-wallet) refreshed every 15 minutes.
class CachedTokenMarketData extends Table {
  /// Token mint address
  TextColumn get mint => text()();

  /// USD price per token from Jupiter. Preferred over Helius's `price_info`
  /// when present; Helius is used only as a fallback.
  RealColumn get usdPrice => real().nullable()();

  /// 24-hour price change percentage from Jupiter
  RealColumn get priceChangePercent24h => real().nullable()();

  /// True when Jupiter's `tags` array for this mint contains `verified`.
  BoolColumn get isVerified => boolean().withDefault(const Constant(false))();

  /// Display name from Jupiter. Used as a fallback when Helius doesn't return
  /// a name for the asset.
  TextColumn get name => text().nullable()();

  /// Display symbol from Jupiter. Used as a fallback when Helius doesn't
  /// return one (and no override/registry entry exists).
  TextColumn get symbol => text().nullable()();

  /// Icon URL from Jupiter. Used as a fallback when Helius's `content.files`
  /// is empty.
  TextColumn get iconUrl => text().nullable()();

  /// When this cache entry was created/updated (Unix seconds)
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {mint};
}

/// Cached detailed Jupiter token info (the `/tokens/v2/search` single-mint
/// payload backing the token-detail screen: authorities, supply, market cap,
/// holders, 24h stats, audit).
///
/// Stored as a serialized [JupiterTokenInfo] JSON blob — the shape is wide and
/// detail-screen-only, so a blob avoids lossy column mapping and schema churn.
/// Read-through with a short TTL (see `JupiterTokenInfoService`): the metadata
/// fields are effectively immutable, the market fields tolerate minutes of lag.
class CachedJupiterTokenInfo extends Table {
  /// Token mint address.
  TextColumn get mint => text()();

  /// Serialized [JupiterTokenInfo] JSON.
  TextColumn get jsonData => text()();

  /// When this cache entry was created/updated (Unix seconds).
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {mint};
}

/// Cached Jupiter **verified** token list (`/tokens/v2/tag?query=verified`) —
/// the browsable catalog behind the swap buy-side search, the Solana analog of
/// [CachedEvmTokenList]. Presence of a row means the mint carries Jupiter's
/// `verified` tag; the whole list is replaced atomically on refresh.
///
/// Distinct from [CachedTokenMarketData], which only ever holds mints the user
/// actually holds and so can't answer "what verified tokens exist". Only the
/// display fields are stored — market data for a picked token still comes from
/// [CachedTokenMarketData] / `JupiterTokenService`.
///
/// Heavily cached (24h TTL, see `JupiterVerifiedTokenListService`): the upstream
/// payload is ~5 MB, so it must not be re-fetched per search or per sheet open.
class CachedJupiterTokenList extends Table {
  /// Token mint address.
  TextColumn get mint => text()();

  /// Token symbol from the list.
  TextColumn get symbol => text().nullable()();

  /// Token name from the list.
  TextColumn get name => text().nullable()();

  /// Decimals from the list.
  IntColumn get decimals => integer().nullable()();

  /// Icon URL (`icon`) from the list.
  TextColumn get iconUrl => text().nullable()();

  /// 24h traded volume in USD (`stats24h.buyVolume + sellVolume`), ranking the
  /// swap picker's "Popular" tab. Null for a token the upstream list reports no
  /// 24h stats for — roughly half the catalog — which is excluded from the tab
  /// rather than ranked as zero.
  RealColumn get dailyVolume => real().nullable()();

  /// When this cache entry was created/updated (Unix seconds).
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {mint};
}

/// Cached EVM (Uniswap) token list — the verified-token source of truth for
/// Ethereum, the analog of Jupiter's `verified` tag for Solana. Presence of a
/// `(chain, contractAddress)` row means the token is verified.
///
/// Heavily cached (24h+ TTL, see `UniswapTokenListService`): the upstream list
/// changes rarely, so this avoids re-fetching on every portfolio load.
class CachedEvmTokenList extends Table {
  /// Token contract address, lowercased.
  TextColumn get contractAddress => text()();

  /// Chain this list entry belongs to (`ethereum`).
  TextColumn get chain => text()();

  /// Token symbol from the list.
  TextColumn get symbol => text().nullable()();

  /// Token name from the list.
  TextColumn get name => text().nullable()();

  /// Decimals from the list.
  IntColumn get decimals => integer().nullable()();

  /// Logo URL (`logoURI`) from the list.
  TextColumn get logoUrl => text().nullable()();

  /// When this cache entry was created/updated (Unix seconds).
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {chain, contractAddress};
}

/// Cached detailed EVM token info backing the token-detail screen — the EVM
/// analog of [CachedJupiterTokenInfo]. Stored as a serialized JSON blob keyed
/// by `(chain, contractAddress)`. Short TTL (see `EthereumTokenInfoService`).
class CachedEvmTokenInfo extends Table {
  /// Token contract address, lowercased.
  TextColumn get contractAddress => text()();

  /// Chain this info belongs to (`ethereum`).
  TextColumn get chain => text()();

  /// Serialized token-info JSON.
  TextColumn get jsonData => text()();

  /// When this cache entry was created/updated (Unix seconds).
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {chain, contractAddress};
}

/// Per-token transfer history, scoped to (walletAddress, mint).
///
/// Rows are pre-shaped `api.Activity` JSON as returned by
/// `/v1/mobile/transfers` — no client-side re-mapping on read.
class TokenTransfers extends Table {
  /// Wallet address whose history this row belongs to.
  TextColumn get walletAddress => text()();

  /// Token mint this row was fetched under.
  TextColumn get mint => text()();

  /// `api.Activity.id` — unique within a (walletAddress, mint).
  TextColumn get activityId => text()();

  /// Transaction signature (hoisted for explorer linking without decoding
  /// [jsonData]).
  TextColumn get signature => text()();

  /// Serialized `api.Activity` JSON.
  TextColumn get jsonData => text()();

  /// Activity timestamp (Unix seconds).
  IntColumn get timestamp => integer()();

  /// When this cache entry was created/updated (Unix seconds).
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {walletAddress, mint, activityId};
}

/// Activity/transaction history.
class Activities extends Table {
  /// Transaction signature (unique identifier)
  TextColumn get txId => text()();

  /// Wallet address this activity belongs to
  TextColumn get walletAddress => text()();

  /// Activity type (send, receive, swap, buy, sell, list, delist, etc.)
  TextColumn get type => text()();

  /// Activity description/title
  TextColumn get title => text().nullable()();

  /// Related mint account (for NFT activities)
  TextColumn get mintAccount => text().nullable()();

  /// Amount in lamports or smallest unit
  IntColumn get amount => integer().nullable()();

  /// Token mint for the amount
  TextColumn get tokenMint => text().nullable()();

  /// Full activity JSON data
  TextColumn get jsonData => text()();

  /// Activity timestamp (Unix seconds)
  IntColumn get timestamp => integer()();

  /// When this cache entry was created
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {txId};
}

/// Locally tracked pending EVM transactions — one row per replaceable
/// (wallet, nonce) slot.
///
/// Written at the `signAndBroadcastEvmTransfer` funnel so every EVM broadcast
/// the app makes is recoverable after a restart, and read by
/// `PendingEvmTxTracker` to drive the Pending section, speed-up and cancel.
///
/// This is **durable user state, not a cache**: rows are deleted only when the
/// nonce resolves on-chain or the wallet is permanently removed. It is
/// deliberately absent from [MallowDatabase.clearCache] and has no TTL — until
/// the nonce is consumed the transaction is genuinely still actionable.
class PendingEvmTransactions extends Table {
  /// Broadcasting wallet, lowercased (the `apiOwnerAddress` convention).
  TextColumn get walletAddress => text()();

  /// The replaceable nonce slot. Speed-up/cancel reuse it; they never allocate
  /// a new one, which is why (wallet, nonce) is the row identity.
  IntColumn get nonce => integer()();

  /// EIP-155 chain id (always 1 today; stored for future multi-EVM support).
  IntColumn get chainId => integer()();

  /// `PendingEvmTxKind` wire name (`send`, `nftTransfer`, `swap`, `other`,
  /// `external`).
  TextColumn get kind => text()();

  /// `PendingEvmTxStatus` wire name (`pending`, `cancelling`).
  TextColumn get status => text()();

  /// Original tx `to` — replayed verbatim when rebuilding a speed-up.
  TextColumn get toAddress => text()();

  /// Original tx value in wei, as a decimal string (BigInt doesn't fit int64).
  TextColumn get valueWei => text()();

  /// Original calldata as `0x` hex (empty for a native send). Never logged.
  TextColumn get data => text()();

  /// Signed gas limit — reused verbatim on a speed-up so the replacement can't
  /// invalidate the original estimate.
  IntColumn get gasLimit => integer()();

  /// `PendingTxMetadata` JSON — display payload only, never used to build a tx.
  TextColumn get metadataJson => text()();

  /// `PendingTxCandidate` JSON list — every live hash for this nonce (original
  /// plus each replacement); any of them can be the one that mines.
  TextColumn get candidatesJson => text()();

  /// Broadcast time (Unix seconds) — drives the elapsed-time display.
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {walletAddress, nonce};
}

// ============================================================================
// Database Class
// ============================================================================

/// mallow wallet local database.
///
/// Uses Drift (formerly moor) for SQLite storage.
@DriftDatabase(
  tables: [
    SeedPhrases,
    Accounts,
    Wallets,
    CachedArtworks,
    CachedTokens,
    CachedBalances,
    CachedTokenMarketData,
    CachedJupiterTokenInfo,
    CachedJupiterTokenList,
    CachedEvmTokenList,
    CachedEvmTokenInfo,
    Activities,
    TokenTransfers,
    CachedHomeFeed,
    CachedPortfolios,
    CachedUserProfiles,
    PendingEvmTransactions,
  ],
)
@lazySingleton
class MallowDatabase extends _$MallowDatabase {
  MallowDatabase(SecureWalletStorage storage) : super(_openConnection(storage));

  /// Opens the database against a caller-supplied executor (e.g. an in-memory
  /// [NativeDatabase] in tests), bypassing the encrypted on-disk connection.
  @visibleForTesting
  MallowDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 22;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) => m.createAll(),
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 17) {
        // Pre-release schemas can't be migrated in place: v16 restructured
        // wallet grouping (Accounts model) and v17 rekeyed the balance cache
        // for multi-chain. Rebuild from scratch — seed phrases live in
        // MnemonicVault and the wallet graph is mirrored to Keychain, so the
        // recovery screen restores wallets (WalletRepository.restoreFromGraph).
        //
        // WARNING: this drops the wallets/accounts tables, which forces every
        // user through the "Restore wallet" screen after the update. It must
        // never run for released schemas (v0.4.0 shipped v18) — every
        // schemaVersion bump MUST add a stepwise migration below instead.
        for (final table in allTables) {
          await m.deleteTable(table.actualTableName);
        }
        await m.createAll();
        return;
      }
      if (from < 18) {
        await m.addColumn(wallets, wallets.socialProvider);
      }
      if (from < 19) {
        await m.createTable(cachedPortfolios);
      }
      if (from < 20) {
        await m.createTable(pendingEvmTransactions);
      }
      if (from < 21) {
        await m.createTable(cachedJupiterTokenList);
      }
      // `from >= 21`, not just `from < 22`: the step above creates the table
      // from its *current* definition, which already carries the column, so an
      // unconditional ADD COLUMN fails on every upgrade that passes through it.
      if (from >= 21 && from < 22) {
        await m.addColumn(
          cachedJupiterTokenList,
          cachedJupiterTokenList.dailyVolume,
        );
        // The rows already cached carry no volume, and the 24h TTL would keep
        // them in place — leaving the swap picker's "Popular" tab empty for up
        // to a day after the update. Clearing them makes the next
        // `ensureCached()` re-fetch and backfill.
        await delete(cachedJupiterTokenList).go();
      }
    },
  );

  // ============================================================================
  // SeedPhrase Operations
  // ============================================================================

  /// Get all seed phrases ordered by sortIndex.
  Future<List<SeedPhrase>> getAllSeedPhrases() {
    return (select(
      seedPhrases,
    )..orderBy([(t) => OrderingTerm.asc(t.sortIndex)])).get();
  }

  /// Returns the maximum sortIndex across all seed phrases, or -1 if none exist.
  Future<int> maxSeedPhraseSortIndex() async {
    final rows = await select(seedPhrases).get();
    if (rows.isEmpty) return -1;
    return rows.map((r) => r.sortIndex).reduce((a, b) => a > b ? a : b);
  }

  /// Get a seed phrase by ID.
  Future<SeedPhrase?> getSeedPhraseById(String id) {
    return (select(
      seedPhrases,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Insert or update a seed phrase.
  Future<void> upsertSeedPhrase(SeedPhrasesCompanion seedPhrase) {
    return into(seedPhrases).insertOnConflictUpdate(seedPhrase);
  }

  /// Delete a seed phrase by ID.
  Future<void> deleteSeedPhraseById(String id) {
    return (delete(seedPhrases)..where((t) => t.id.equals(id))).go();
  }

  // ============================================================================
  // Account Operations
  // ============================================================================

  /// Get all accounts ordered by sortIndex.
  Future<List<AccountRow>> getAllAccounts() {
    return (select(
      accounts,
    )..orderBy([(t) => OrderingTerm.asc(t.sortIndex)])).get();
  }

  /// Get an account by ID.
  Future<AccountRow?> getAccountById(String id) {
    return (select(accounts)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Find the `seed` account for a given (seedPhraseId, derivationIndex), or null.
  Future<AccountRow?> getSeedAccount(String seedPhraseId, int derivationIndex) {
    return (select(accounts)..where(
          (t) =>
              t.seedPhraseId.equals(seedPhraseId) &
              t.derivationIndex.equals(derivationIndex),
        ))
        .getSingleOrNull();
  }

  /// Find the `hardware` account for a given derivation index, or null. Each
  /// Ledger derivation index gets its own account (mirrors `seed` accounts).
  Future<AccountRow?> getHardwareAccountByIndex(int derivationIndex) {
    return (select(accounts)..where(
          (t) =>
              t.kind.equals('hardware') &
              t.derivationIndex.equals(derivationIndex),
        ))
        .getSingleOrNull();
  }

  /// Returns the maximum account sortIndex, or -1 if none exist.
  Future<int> maxAccountSortIndex() async {
    final rows = await select(accounts).get();
    if (rows.isEmpty) return -1;
    return rows.map((r) => r.sortIndex).reduce((a, b) => a > b ? a : b);
  }

  /// Insert or update an account.
  Future<void> upsertAccount(AccountsCompanion account) {
    return into(accounts).insertOnConflictUpdate(account);
  }

  /// Delete an account by ID.
  Future<void> deleteAccountById(String id) {
    return (delete(accounts)..where((t) => t.id.equals(id))).go();
  }

  /// Update the name for a single account.
  Future<void> updateAccountName(String id, String name) {
    return (update(accounts)..where((t) => t.id.equals(id))).write(
      AccountsCompanion(name: Value(name)),
    );
  }

  /// Update the generated-avatar seed for a single account.
  Future<void> updateAccountAvatarSeed(String id, String seed) {
    return (update(accounts)..where((t) => t.id.equals(id))).write(
      AccountsCompanion(avatarSeed: Value(seed)),
    );
  }

  /// Update the sort index for a single account.
  Future<void> updateAccountSortIndex(String id, int sortIndex) {
    return (update(accounts)..where((t) => t.id.equals(id))).write(
      AccountsCompanion(sortIndex: Value(sortIndex)),
    );
  }

  /// Get wallets for a specific account, ordered by sortIndex.
  Future<List<Wallet>> getWalletsForAccount(String accountId) {
    return (select(wallets)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortIndex)]))
        .get();
  }

  // ============================================================================
  // Wallet Operations
  // ============================================================================

  /// Check if any wallets exist.
  Future<bool> hasAnyWallets() async {
    final row = await (select(wallets)..limit(1)).getSingleOrNull();
    return row != null;
  }

  /// Get all wallets ordered by sortIndex.
  Future<List<Wallet>> getAllWallets() {
    return (select(
      wallets,
    )..orderBy([(t) => OrderingTerm.asc(t.sortIndex)])).get();
  }

  /// Get wallets for a specific seed phrase, ordered by sortIndex.
  Future<List<Wallet>> getWalletsForSeedPhrase(String seedPhraseId) {
    return (select(wallets)
          ..where((t) => t.seedPhraseId.equals(seedPhraseId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortIndex)]))
        .get();
  }

  /// Returns the maximum sortIndex for wallets, optionally filtered by
  /// [seedPhraseId]. Pass null to query standalone wallets (seedPhraseId IS
  /// NULL). Returns -1 if no matching wallets exist.
  Future<int> maxWalletSortIndex({String? seedPhraseId}) async {
    final query = select(wallets);
    if (seedPhraseId != null) {
      query.where((t) => t.seedPhraseId.equals(seedPhraseId));
    } else {
      query.where((t) => t.seedPhraseId.isNull());
    }
    final rows = await query.get();
    if (rows.isEmpty) return -1;
    return rows.map((r) => r.sortIndex).reduce((a, b) => a > b ? a : b);
  }

  /// Get a wallet by its UUID.
  Future<Wallet?> getWalletById(String id) {
    return (select(wallets)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Get a wallet by on-chain address.
  Future<Wallet?> getWalletByAddress(String address) {
    return (select(
      wallets,
    )..where((t) => t.address.equals(address))).getSingleOrNull();
  }

  /// Get a wallet whose stored address matches [address] case-insensitively.
  /// Used for EVM dedupe, where the same account may be stored EIP-55
  /// checksummed (from ENS/derivation) or lowercased (from a pasted address).
  /// Solana/Tezos callers must use [getWalletByAddress] — their base58/b58check
  /// encodings are case-significant and would collide under a `lower()` match.
  ///
  /// Limited to one row rather than [SingleSelectable.getSingleOrNull]: address
  /// has no unique index, and devices that predate this case-insensitive dedupe
  /// can already hold two rows for the same EVM account (checksummed +
  /// lowercased). Both match here, and `getSingleOrNull` would throw on them.
  Future<Wallet?> getWalletByAddressLower(String address) {
    final lowered = address.toLowerCase();
    return (select(wallets)
          ..where((t) => t.address.lower().equals(lowered))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Insert or update a wallet.
  Future<void> upsertWalletEntry(WalletsCompanion wallet) {
    return into(wallets).insertOnConflictUpdate(wallet);
  }

  /// Delete a wallet by ID.
  Future<void> deleteWalletById(String id) {
    return (delete(wallets)..where((t) => t.id.equals(id))).go();
  }

  /// Update the sortIndex for a single wallet.
  Future<void> updateWalletSortIndex(String id, int sortIndex) {
    return (update(wallets)..where((t) => t.id.equals(id))).write(
      WalletsCompanion(sortIndex: Value(sortIndex)),
    );
  }

  /// Update the name for a single wallet.
  Future<void> updateWalletName(String id, String name) {
    return (update(wallets)..where((t) => t.id.equals(id))).write(
      WalletsCompanion(name: Value(name)),
    );
  }

  /// Assign a wallet to an account.
  Future<void> updateWalletAccountId(String id, String accountId) {
    return (update(wallets)..where((t) => t.id.equals(id))).write(
      WalletsCompanion(accountId: Value(accountId)),
    );
  }

  /// Get the next derivation index for a seed phrase (max existing + 1).
  Future<int> nextDerivationIndex(String seedPhraseId) async {
    final ws = await getWalletsForSeedPhrase(seedPhraseId);
    if (ws.isEmpty) return 0;
    final maxIndex = ws
        .map((w) => w.derivationIndex ?? -1)
        .reduce((a, b) => a > b ? a : b);
    return maxIndex + 1;
  }

  // ============================================================================
  // Artwork Operations
  // ============================================================================

  /// Get a cached artwork by mint account.
  Future<CachedArtwork?> getArtwork(String mintAccount) {
    return (select(
      cachedArtworks,
    )..where((t) => t.mintAccount.equals(mintAccount))).getSingleOrNull();
  }

  /// Get artworks by owner address.
  Future<List<CachedArtwork>> getArtworksByOwner(String ownerAddress) {
    return select(cachedArtworks).get();
  }

  /// Get artworks by artist address.
  Future<List<CachedArtwork>> getArtworksByArtist(String artistAddress) {
    return (select(
      cachedArtworks,
    )..where((t) => t.artistAddress.equals(artistAddress))).get();
  }

  /// Get artworks by collection.
  Future<List<CachedArtwork>> getArtworksByCollection(String collectionKey) {
    return (select(
      cachedArtworks,
    )..where((t) => t.collectionKey.equals(collectionKey))).get();
  }

  /// Insert or update an artwork.
  Future<void> upsertArtwork(CachedArtworksCompanion artwork) {
    return into(cachedArtworks).insertOnConflictUpdate(artwork);
  }

  /// Insert or update multiple artworks.
  Future<void> upsertArtworks(List<CachedArtworksCompanion> artworks) {
    return batch((batch) {
      batch.insertAllOnConflictUpdate(cachedArtworks, artworks);
    });
  }

  /// Delete old cached artworks.
  Future<void> deleteOldArtworks(int olderThanTimestamp) {
    return (delete(
      cachedArtworks,
    )..where((t) => t.cachedAt.isSmallerThanValue(olderThanTimestamp))).go();
  }

  // ============================================================================
  // Token Operations
  // ============================================================================

  /// Get a cached token by mint.
  Future<CachedToken?> getToken(String mint) {
    return (select(
      cachedTokens,
    )..where((t) => t.mint.equals(mint))).getSingleOrNull();
  }

  /// Get all cached tokens.
  Future<List<CachedToken>> getAllTokens() {
    return select(cachedTokens).get();
  }

  /// Insert or update a token.
  Future<void> upsertToken(CachedTokensCompanion token) {
    return into(cachedTokens).insertOnConflictUpdate(token);
  }

  /// Insert or update multiple tokens.
  Future<void> upsertTokens(List<CachedTokensCompanion> tokens) {
    return batch((batch) {
      batch.insertAllOnConflictUpdate(cachedTokens, tokens);
    });
  }

  // ============================================================================
  // Balance Operations
  // ============================================================================

  /// Get cached balances for a wallet address, ordered by USD value descending.
  Future<List<CachedBalance>> getBalances(String walletAddress) {
    return (select(cachedBalances)
          ..where((t) => t.walletAddress.equals(walletAddress))
          ..orderBy([(t) => OrderingTerm.desc(t.totalUsdValue)]))
        .get();
  }

  /// Get the cache timestamp for a wallet's balances.
  Future<DateTime?> getBalancesCacheTime(String walletAddress) async {
    final result =
        await (select(cachedBalances)
              ..where((t) => t.walletAddress.equals(walletAddress))
              ..limit(1))
            .getSingleOrNull();

    if (result == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(result.cachedAt * 1000);
  }

  /// Insert or update multiple balances.
  Future<void> upsertBalances(List<CachedBalancesCompanion> balances) {
    return batch((batch) {
      batch.insertAllOnConflictUpdate(cachedBalances, balances);
    });
  }

  /// Delete all cached balances for a wallet.
  Future<void> deleteBalances(String walletAddress) {
    return (delete(
      cachedBalances,
    )..where((t) => t.walletAddress.equals(walletAddress))).go();
  }

  /// Delete old cached balances (older than specified timestamp).
  Future<void> deleteOldBalances(int olderThanTimestamp) {
    return (delete(
      cachedBalances,
    )..where((t) => t.cachedAt.isSmallerThanValue(olderThanTimestamp))).go();
  }

  // ============================================================================
  // Token Market Data Operations
  // ============================================================================

  /// Get cached market data for specific mints.
  ///
  /// Chunks the lookup to stay under SQLite's default
  /// `SQLITE_LIMIT_VARIABLE_NUMBER` (999 prior to 3.32). Wallets with very
  /// many fungible accounts can otherwise exceed it in a single `IN (...)`.
  Future<List<CachedTokenMarketDataData>> getMarketData(
    List<String> mints,
  ) async {
    if (mints.isEmpty) return const [];
    const chunkSize = 500;
    final results = <CachedTokenMarketDataData>[];
    for (var i = 0; i < mints.length; i += chunkSize) {
      final end = i + chunkSize > mints.length ? mints.length : i + chunkSize;
      final chunk = mints.sublist(i, end);
      final rows = await (select(
        cachedTokenMarketData,
      )..where((t) => t.mint.isIn(chunk))).get();
      results.addAll(rows);
    }
    return results;
  }

  /// Insert or update market data entries.
  Future<void> upsertMarketData(List<CachedTokenMarketDataCompanion> entries) {
    return batch((batch) {
      batch.insertAllOnConflictUpdate(cachedTokenMarketData, entries);
    });
  }

  /// Delete all cached market data.
  Future<void> deleteAllMarketData() {
    return delete(cachedTokenMarketData).go();
  }

  /// Get the cached Jupiter token-info row for a single mint, or null.
  Future<CachedJupiterTokenInfoData?> getTokenInfoCache(String mint) {
    return (select(
      cachedJupiterTokenInfo,
    )..where((t) => t.mint.equals(mint))).getSingleOrNull();
  }

  /// Insert or update a cached Jupiter token-info row.
  Future<void> upsertTokenInfoCache(CachedJupiterTokenInfoCompanion entry) {
    return into(cachedJupiterTokenInfo).insertOnConflictUpdate(entry);
  }

  // ============================================================================
  // Jupiter Verified Token List Operations
  // ============================================================================

  /// Most recent `cachedAt` across the cached Jupiter verified list, or null
  /// when it has never been cached. Drives the 24h freshness check.
  Future<DateTime?> getJupiterTokenListCacheTime() async {
    final row =
        await (select(cachedJupiterTokenList)
              ..orderBy([(t) => OrderingTerm.desc(t.cachedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (row == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(row.cachedAt * 1000);
  }

  /// Replace the whole cached Jupiter verified list with [entries] atomically.
  /// A wholesale replace (rather than an upsert) is what makes row *presence*
  /// mean "still verified" — an upsert would strand de-listed mints forever.
  Future<void> replaceJupiterTokenList(
    List<CachedJupiterTokenListCompanion> entries,
  ) async {
    await batch((batch) {
      batch.deleteAll(cachedJupiterTokenList);
      batch.insertAllOnConflictUpdate(cachedJupiterTokenList, entries);
    });
  }

  /// The cached verified-list row for a single [mint], or null when the
  /// catalog has never been fetched or doesn't carry it.
  ///
  /// A primary-key read, so it is cheap enough to sit in front of a network
  /// lookup for a mint the app can't otherwise name (see
  /// `TokenMetadataService`).
  Future<CachedJupiterTokenListData?> getJupiterTokenListEntry(String mint) {
    return (select(
      cachedJupiterTokenList,
    )..where((t) => t.mint.equals(mint))).getSingleOrNull();
  }

  /// Cached verified tokens whose symbol or name contains [query], plus an
  /// exact mint match. `LIKE` is ASCII-case-insensitive in SQLite by default;
  /// `\`, `%` and `_` in [query] are escaped so a user typing them searches
  /// literally instead of wildcarding the whole list.
  ///
  /// Returns up to [limit] rows best-match-first. The `ORDER BY CASE` mirrors
  /// the caller's Dart ranking (exact symbol or mint > symbol prefix > exact
  /// name > name prefix > symbol substring > the rest) so that [limit] truncates
  /// the *worst* matches. Ranking only after the fetch is not enough: a broad
  /// query like `sol` matches far more than [limit] rows, and SQLite would
  /// otherwise return them in insertion order — dropping `SOL` itself out of the
  /// window, where no amount of caller-side sorting can recover it. `mint` is
  /// compared case-sensitively (base58 is); symbol and name are not.
  Future<List<CachedJupiterTokenListData>> searchJupiterTokenList(
    String query, {
    int limit = 100,
  }) {
    final escaped = query.replaceAllMapped(
      RegExp(r'[\\%_]'),
      (m) => '\\${m[0]}',
    );
    final pattern = '%$escaped%';
    Expression<bool> matches(Expression<String> column, String likePattern) =>
        column.like(likePattern, escapeChar: r'\');

    return (select(cachedJupiterTokenList)
          ..where(
            (t) =>
                matches(t.symbol, pattern) |
                matches(t.name, pattern) |
                t.mint.equals(query),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(
              CaseWhenExpression<int>(
                cases: [
                  CaseWhen(
                    matches(t.symbol, escaped) | t.mint.equals(query),
                    then: const Constant(0),
                  ),
                  CaseWhen(
                    matches(t.symbol, '$escaped%'),
                    then: const Constant(1),
                  ),
                  CaseWhen(matches(t.name, escaped), then: const Constant(2)),
                  CaseWhen(
                    matches(t.name, '$escaped%'),
                    then: const Constant(3),
                  ),
                  CaseWhen(matches(t.symbol, pattern), then: const Constant(4)),
                ],
                orElse: const Constant(5),
              ),
            ),
          ])
          ..limit(limit))
        .get();
  }

  /// The [limit] cached verified tokens with the highest 24h volume, highest
  /// first — the swap picker's "Popular" tab.
  ///
  /// Rows without a volume are excluded rather than sorted last: the upstream
  /// list omits `stats24h` for roughly half the catalog, and a null read as
  /// zero would pad the tail of the tab with tokens nobody traded.
  Future<List<CachedJupiterTokenListData>> topJupiterTokensByVolume({
    int limit = 50,
  }) {
    return (select(cachedJupiterTokenList)
          ..where((t) => t.dailyVolume.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.dailyVolume)])
          ..limit(limit))
        .get();
  }

  // ============================================================================
  // EVM Token List + Info Operations
  // ============================================================================

  /// Get every cached Uniswap-list entry for [chain]. The caller builds a
  /// lowercased contract-address set from this to classify verified tokens.
  Future<List<CachedEvmTokenListData>> getEvmTokenList(String chain) {
    return (select(
      cachedEvmTokenList,
    )..where((t) => t.chain.equals(chain))).get();
  }

  /// Most recent `cachedAt` across the cached list for [chain], or null when
  /// the list has never been cached. Drives the long-TTL freshness check.
  Future<DateTime?> getEvmTokenListCacheTime(String chain) async {
    final row =
        await (select(cachedEvmTokenList)
              ..where((t) => t.chain.equals(chain))
              ..orderBy([(t) => OrderingTerm.desc(t.cachedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (row == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(row.cachedAt * 1000);
  }

  /// Replace the cached Uniswap list for [chain] with [entries] atomically.
  Future<void> replaceEvmTokenList(
    String chain,
    List<CachedEvmTokenListCompanion> entries,
  ) async {
    await batch((batch) {
      batch.deleteWhere(cachedEvmTokenList, (t) => t.chain.equals(chain));
      batch.insertAllOnConflictUpdate(cachedEvmTokenList, entries);
    });
  }

  /// Get the cached EVM token-info row for `(chain, contractAddress)`, or null.
  Future<CachedEvmTokenInfoData?> getEvmTokenInfoCache(
    String chain,
    String contractAddress,
  ) {
    return (select(cachedEvmTokenInfo)..where(
          (t) =>
              t.chain.equals(chain) & t.contractAddress.equals(contractAddress),
        ))
        .getSingleOrNull();
  }

  /// Insert or update a cached EVM token-info row.
  Future<void> upsertEvmTokenInfoCache(CachedEvmTokenInfoCompanion entry) {
    return into(cachedEvmTokenInfo).insertOnConflictUpdate(entry);
  }

  // ============================================================================
  // Activity Operations
  // ============================================================================

  /// Get activities for a wallet address, ordered by timestamp descending.
  Future<List<Activity>> getActivities(String walletAddress, {int? limit}) {
    final query = select(activities)
      ..where((t) => t.walletAddress.equals(walletAddress))
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]);

    if (limit != null) {
      query.limit(limit);
    }

    return query.get();
  }

  /// Get an activity by transaction ID.
  Future<Activity?> getActivity(String txId) {
    return (select(
      activities,
    )..where((t) => t.txId.equals(txId))).getSingleOrNull();
  }

  /// Insert or update an activity.
  Future<void> upsertActivity(ActivitiesCompanion activity) {
    return into(activities).insertOnConflictUpdate(activity);
  }

  /// Insert or update multiple activities.
  Future<void> upsertActivities(List<ActivitiesCompanion> activitiesList) {
    return batch((batch) {
      batch.insertAllOnConflictUpdate(activities, activitiesList);
    });
  }

  /// Delete old activities.
  Future<void> deleteOldActivities(int olderThanTimestamp) {
    return (delete(
      activities,
    )..where((t) => t.cachedAt.isSmallerThanValue(olderThanTimestamp))).go();
  }

  // ============================================================================
  // TokenTransfer Operations
  // ============================================================================

  /// Get cached transfer rows for a (wallet, mint), newest first.
  Future<List<TokenTransfer>> getTokenTransfers(
    String walletAddress,
    String mint, {
    int? limit,
  }) {
    final query = select(tokenTransfers)
      ..where(
        (t) => t.walletAddress.equals(walletAddress) & t.mint.equals(mint),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]);

    if (limit != null) {
      query.limit(limit);
    }

    return query.get();
  }

  /// Latest cache timestamp for a (wallet, mint).
  Future<DateTime?> getTokenTransfersCacheTime(
    String walletAddress,
    String mint,
  ) async {
    final rows =
        await (select(tokenTransfers)
              ..where(
                (t) =>
                    t.walletAddress.equals(walletAddress) & t.mint.equals(mint),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.cachedAt)])
              ..limit(1))
            .get();

    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first.cachedAt * 1000);
  }

  /// Insert/replace cached transfer rows.
  Future<void> upsertTokenTransfers(List<TokenTransfersCompanion> rows) {
    return batch((batch) {
      batch.insertAllOnConflictUpdate(tokenTransfers, rows);
    });
  }

  /// Drop all cached transfers for a (wallet, mint) — used before replacing
  /// with a fresh first page so removed rows don't linger.
  Future<void> clearTokenTransfersForMint(String walletAddress, String mint) {
    return (delete(tokenTransfers)..where(
          (t) => t.walletAddress.equals(walletAddress) & t.mint.equals(mint),
        ))
        .go();
  }

  /// Prune transfer rows older than [olderThanTimestamp] (cachedAt).
  Future<void> deleteOldTokenTransfers(int olderThanTimestamp) {
    return (delete(
      tokenTransfers,
    )..where((t) => t.cachedAt.isSmallerThanValue(olderThanTimestamp))).go();
  }

  // ============================================================================
  // Home Feed Cache Operations
  // ============================================================================

  /// Get cached home feed data.
  Future<CachedHomeFeedData?> getHomeFeedCache() {
    return (select(
      cachedHomeFeed,
    )..where((t) => t.id.equals('default'))).getSingleOrNull();
  }

  /// Insert or update cached home feed data.
  Future<void> upsertHomeFeedCache(CachedHomeFeedCompanion data) {
    return into(cachedHomeFeed).insertOnConflictUpdate(data);
  }

  /// Delete cached home feed data.
  Future<void> deleteHomeFeedCache() {
    return delete(cachedHomeFeed).go();
  }

  // ============================================================================
  // Portfolio Cache Operations
  // ============================================================================

  /// Get one cached portfolio section for [sessionKey].
  Future<CachedPortfolio?> getPortfolioCache(
    String sessionKey,
    String section,
  ) {
    return (select(cachedPortfolios)..where(
          (t) => t.sessionKey.equals(sessionKey) & t.section.equals(section),
        ))
        .getSingleOrNull();
  }

  /// Insert or update a cached portfolio section.
  Future<void> upsertPortfolioCache(CachedPortfoliosCompanion data) {
    return into(cachedPortfolios).insertOnConflictUpdate(data);
  }

  /// Delete all cached portfolio snapshots.
  Future<void> deletePortfolioCache() {
    return delete(cachedPortfolios).go();
  }

  // ============================================================================
  // User Profile Cache Operations
  // ============================================================================

  /// Get cached user profile by address.
  Future<CachedUserProfile?> getCachedUserProfile(String address) {
    return (select(
      cachedUserProfiles,
    )..where((t) => t.address.equals(address))).getSingleOrNull();
  }

  /// Insert or update cached user profile.
  Future<void> upsertCachedUserProfile(CachedUserProfilesCompanion data) {
    return into(cachedUserProfiles).insertOnConflictUpdate(data);
  }

  /// Delete cached user profile by address.
  Future<void> deleteCachedUserProfile(String address) {
    return (delete(
      cachedUserProfiles,
    )..where((t) => t.address.equals(address))).go();
  }

  // ============================================================================
  // Pending EVM Transaction Operations
  // ============================================================================

  /// Every tracked pending EVM transaction, ordered by wallet then nonce
  /// ascending — the order they must mine in, and the order the Pending
  /// section renders.
  Future<List<PendingEvmTransaction>> getPendingEvmTransactions() {
    return (select(pendingEvmTransactions)..orderBy([
          (t) => OrderingTerm.asc(t.walletAddress),
          (t) => OrderingTerm.asc(t.nonce),
        ]))
        .get();
  }

  /// Reactive variant of [getPendingEvmTransactions] — re-emits on every
  /// insert/update/delete so the Pending section follows registrations and
  /// resolutions without polling the DB.
  Stream<List<PendingEvmTransaction>> watchPendingEvmTransactions() {
    return (select(pendingEvmTransactions)..orderBy([
          (t) => OrderingTerm.asc(t.walletAddress),
          (t) => OrderingTerm.asc(t.nonce),
        ]))
        .watch();
  }

  /// The tracked transaction occupying [nonce] for [walletAddress], or null.
  Future<PendingEvmTransaction?> getPendingEvmTransaction(
    String walletAddress,
    int nonce,
  ) {
    return (select(pendingEvmTransactions)..where(
          (t) => t.walletAddress.equals(walletAddress) & t.nonce.equals(nonce),
        ))
        .getSingleOrNull();
  }

  /// Insert or update one tracked transaction (keyed on wallet + nonce).
  Future<void> upsertPendingEvmTransaction(
    PendingEvmTransactionsCompanion data,
  ) {
    return into(pendingEvmTransactions).insertOnConflictUpdate(data);
  }

  /// Write a partial update to the tracked transaction at [nonce] — how a
  /// speed-up/cancel appends a candidate and flips the status without
  /// re-supplying (or accidentally rewriting) the signed payload columns.
  Future<void> updatePendingEvmTransaction(
    String walletAddress,
    int nonce,
    PendingEvmTransactionsCompanion data,
  ) {
    return (update(pendingEvmTransactions)..where(
          (t) => t.walletAddress.equals(walletAddress) & t.nonce.equals(nonce),
        ))
        .write(data);
  }

  /// Delete the tracked transaction at [nonce] — called when the slot resolves
  /// on-chain (confirmed, reverted, cancelled, or replaced).
  Future<void> deletePendingEvmTransaction(String walletAddress, int nonce) {
    return (delete(pendingEvmTransactions)..where(
          (t) => t.walletAddress.equals(walletAddress) & t.nonce.equals(nonce),
        ))
        .go();
  }

  /// Delete every tracked transaction for [walletAddress] — for the permanent
  /// wallet-deletion path (a wallet merely out of session keeps its rows, since
  /// those transactions are still real).
  Future<void> deletePendingEvmTransactionsForWallet(String walletAddress) {
    return (delete(
      pendingEvmTransactions,
    )..where((t) => t.walletAddress.equals(walletAddress))).go();
  }

  // ============================================================================
  // Maintenance
  // ============================================================================

  /// Clear all cached data (keeps wallet/seed phrase info).
  Future<void> clearCache() async {
    await delete(cachedArtworks).go();
    await delete(cachedTokens).go();
    await delete(cachedBalances).go();
    await delete(cachedTokenMarketData).go();
    await delete(activities).go();
    await delete(tokenTransfers).go();
    await delete(cachedHomeFeed).go();
    await delete(cachedUserProfiles).go();
  }

  /// Clear everything (full reset).
  Future<void> clearAll() async {
    await delete(wallets).go();
    await delete(accounts).go();
    await delete(seedPhrases).go();
    // Durable user state, so it is dropped here rather than in [clearCache] —
    // a full reset deletes every wallet, which deletes their pending rows too.
    await delete(pendingEvmTransactions).go();
    await clearCache();
  }
}

// ============================================================================
// Database Connection
// ============================================================================

LazyDatabase _openConnection(SecureWalletStorage storage) {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'mallow.sqlite'));

    // Bootstrap (load or generate) the DB encryption key. The Completer-guarded
    // accessor ensures concurrent cold-start callers share one key instead of
    // racing to write two. `dbFileExists` is the safety interlock: with a
    // database already on disk, a transient keystore "not found" must not
    // mint a fresh key — that would make the file undecryptable (and, before
    // this guard, silently destroyed it).
    final hexKey = await storage.getOrCreateDbEncryptionKey(
      dbFileExists: file.existsSync(),
    );

    // Build the setup closure via a top-level factory so it only captures
    // `hexKey`. Defining it inline here would capture the enclosing scope
    // (including `storage`), and `SecureWalletStorage` holds an
    // _AsyncCompleter that's not sendable to the background isolate.
    final setupEncryption = _makeSetupEncryption(hexKey);

    if (file.existsSync()) {
      probeEncryptedDatabase(file, setupEncryption);
    }

    return NativeDatabase.createInBackground(file, setup: setupEncryption);
  });
}

/// Eagerly probe [file] so a corrupt/wrong-key header (recoverable by moving
/// the file aside) is distinguished from transient failures like a locked
/// file, IO error, or low storage. NativeDatabase.createInBackground opens
/// lazily in another isolate, so a try/catch around it would never see those
/// errors; the wallet tables would silently vanish on the next query failure
/// instead.
///
/// Only SQLITE_NOTADB triggers recovery — and recovery quarantines the file
/// (rename-aside) rather than deleting it. NOTADB also means "right file,
/// wrong key", and deleting on that signal is what used to permanently
/// destroy wallet metadata after a keystore misread.
@visibleForTesting
void probeEncryptedDatabase(File file, void Function(sqlite3.Database) setup) {
  sqlite3.Database? probe;
  try {
    probe = sqlite3.sqlite3.open(file.path);
    setup(probe);
  } on sqlite3.SqliteException catch (e) {
    if (e.resultCode != sqlite3.SqlError.SQLITE_NOTADB) {
      debugPrint(
        '[Database] Encrypted DB open failed with non-recoverable '
        'error (code=${e.resultCode}, extended=${e.extendedResultCode}): '
        '${e.message}. Surfacing so the user can retry.',
      );
      rethrow;
    }
    debugPrint(
      '[Database] Encrypted DB header invalid (SQLITE_NOTADB, '
      'extended=${e.extendedResultCode}); quarantining the file. '
      'Cause: ${e.message}',
    );
    // Close before renaming so the handle cannot pin the old file.
    probe?.close();
    probe = null;
    quarantineCorruptDatabase(file);
    unawaited(
      SentryService.captureMessage(
        'Encrypted DB failed the header check (SQLITE_NOTADB); '
        'file quarantined and recreated',
        level: SentryLevel.error,
        extras: {'extendedResultCode': e.extendedResultCode},
      ),
    );
  } finally {
    probe?.close();
  }
}

/// Move a database file (and its `-wal`/`-shm` sidecars) aside as
/// `<name>.invalid-<millis>` instead of deleting it, so an incident is
/// diagnosable and nothing is irreversibly destroyed. Previous quarantined
/// copies are pruned first so they cannot accumulate.
///
/// The main file is renamed first — its absence is what makes the next open
/// create a fresh database. Sidecar rename failures are tolerable (SQLite
/// discards a stale WAL whose salt does not match) and must not fail the
/// recovery.
@visibleForTesting
void quarantineCorruptDatabase(File file) {
  final dir = file.parent;
  final base = p.basename(file.path);
  if (dir.existsSync()) {
    for (final entity in dir.listSync()) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name.startsWith(base) &&
          name.contains('.invalid-')) {
        try {
          entity.deleteSync();
        } on FileSystemException catch (e) {
          debugPrint('[Database] Failed to prune old quarantined file: $e');
        }
      }
    }
  }
  final suffix = '.invalid-${DateTime.now().millisecondsSinceEpoch}';
  file.renameSync('${file.path}$suffix');
  for (final sidecar in ['${file.path}-wal', '${file.path}-shm']) {
    final f = File(sidecar);
    if (!f.existsSync()) continue;
    try {
      f.renameSync('$sidecar$suffix');
    } on FileSystemException catch (e) {
      debugPrint('[Database] Failed to quarantine sidecar: $e');
    }
  }
}

void Function(sqlite3.Database) _makeSetupEncryption(String hexKey) {
  return (sqlite3.Database db) {
    db.execute("PRAGMA cipher = 'chacha20';");
    db.execute("PRAGMA hexkey = '$hexKey';");
    db.execute('SELECT count(*) FROM sqlite_master;');
  };
}
