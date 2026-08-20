import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';

/// Schema-upgrade tests.
///
/// The v0.4.0 → v0.5.0 update (schema 18 → 19) wiped every user's wallets
/// table because `onUpgrade` destructively dropped all tables on any version
/// bump, forcing everyone through the "Restore wallet" screen. These tests
/// pin the contract that upgrades from released schemas (>= 17) migrate
/// stepwise and MUST NOT touch wallet rows.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mallow_migration_test');
    dbFile = File('${tempDir.path}/test.db');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// Creates the current schema on [dbFile], inserts one wallet row, then
  /// rewinds `user_version` to [version] (optionally undoing newer-schema
  /// DDL via [downgradeStatements]) so the next open runs `onUpgrade` from
  /// that version.
  Future<void> seedDbAtVersion(
    int version, {
    List<String> downgradeStatements = const [],
  }) async {
    final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
    await db.upsertWalletEntry(
      WalletsCompanion.insert(
        id: 'wallet-1',
        address: 'So1anaAddre55',
        name: 'Account 01',
        walletType: 'hd',
        createdAt: 1700000000,
      ),
    );
    for (final statement in downgradeStatements) {
      await db.customStatement(statement);
    }
    await db.customStatement('PRAGMA user_version = $version;');
    await db.close();
  }

  test('upgrade from schema 19 adds pending_evm_transactions only', () async {
    await seedDbAtVersion(
      19,
      downgradeStatements: ['DROP TABLE pending_evm_transactions;'],
    );

    final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    // Stepwise, not destructive: v19 shipped, so the <17 rebuild branch must
    // not run for it.
    final wallets = await db.getAllWallets();
    expect(wallets, hasLength(1));
    expect(wallets.single.id, 'wallet-1');

    // The v20 table exists and is usable.
    await db.upsertPendingEvmTransaction(
      PendingEvmTransactionsCompanion.insert(
        walletAddress: '0xaaaa',
        nonce: 3,
        chainId: 1,
        kind: 'send',
        status: 'pending',
        toAddress: '0xbbbb',
        valueWei: '0',
        data: '',
        gasLimit: 21000,
        metadataJson: '{"title":"Send"}',
        candidatesJson: '[]',
        createdAt: 1753840000,
      ),
    );
    expect(await db.getPendingEvmTransaction('0xaaaa', 3), isNotNull);

    // The v19 table the previous migration added is untouched by the v20 step.
    final cachedPortfolios = await db.getPortfolioCache('addr', 'artworks');
    expect(cachedPortfolios, isNull);
  });

  test('upgrade from schema 18 (v0.4.0) preserves wallets', () async {
    await seedDbAtVersion(
      18,
      downgradeStatements: [
        'DROP TABLE cached_portfolios;',
        'DROP TABLE pending_evm_transactions;',
      ],
    );

    final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    // Wallet row survived the upgrade — a wipe here is what kicked every
    // v0.4.0 user to the "Restore wallet" screen.
    final wallets = await db.getAllWallets();
    expect(wallets, hasLength(1));
    expect(wallets.single.id, 'wallet-1');

    // The v19 table was created and is usable.
    await db.upsertPortfolioCache(
      const CachedPortfoliosCompanion(
        sessionKey: Value('addr'),
        section: Value('artworks'),
        jsonData: Value('{}'),
        cachedAt: Value(1700000000),
      ),
    );
    final cached = await db.getPortfolioCache('addr', 'artworks');
    expect(cached, isNotNull);
  });

  test(
    'upgrade from schema 17 preserves wallets and adds socialProvider',
    () async {
      await seedDbAtVersion(
        17,
        downgradeStatements: [
          'DROP TABLE cached_portfolios;',
          'DROP TABLE pending_evm_transactions;',
          'ALTER TABLE wallets DROP COLUMN social_provider;',
        ],
      );

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final wallets = await db.getAllWallets();
      expect(wallets, hasLength(1));
      expect(wallets.single.socialProvider, isNull);
    },
  );

  test('upgrade from schema 21 clears the cached Jupiter list', () async {
    final seed = MallowDatabase.forTesting(NativeDatabase(dbFile));
    await seed.replaceJupiterTokenList([
      CachedJupiterTokenListCompanion(
        mint: const Value('So11111111111111111111111111111111111111112'),
        symbol: const Value('SOL'),
        name: const Value('Wrapped SOL'),
        decimals: const Value(9),
        cachedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    ]);
    await seed.customStatement(
      'ALTER TABLE cached_jupiter_token_list DROP COLUMN daily_volume;',
    );
    await seed.customStatement('PRAGMA user_version = 21;');
    await seed.close();

    final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    // v21 rows carry no volume, so the swap picker's "Popular" tab has nothing
    // to rank. Keeping them would satisfy the 24h freshness check and leave the
    // tab empty for a day after the update; dropping them forces a refetch.
    expect(await db.getJupiterTokenListCacheTime(), isNull);
  });

  test(
    'upgrade from pre-release schema (< 17) rebuilds destructively',
    () async {
      // Pre-v17 schemas can't be migrated in place (Accounts restructure,
      // balance-cache rekey) — the rebuild is intentional there, and recovery
      // goes through the Keychain wallet graph.
      await seedDbAtVersion(16);

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final wallets = await db.getAllWallets();
      expect(wallets, isEmpty);
    },
  );
}
