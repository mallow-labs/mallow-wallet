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
/// Undo the v23 step on a database created at the current schema.
const _dropKeystoneColumns = [
  'ALTER TABLE accounts DROP COLUMN master_fingerprint;',
  'ALTER TABLE wallets DROP COLUMN master_fingerprint;',
];

/// Undo the v24 step on a database created at the current schema.
const _dropSocialVaultColumn = [
  'ALTER TABLE wallets DROP COLUMN social_vault_id;',
];

/// Undo the v25 step on a database created at the current schema.
const _dropLegacySocialColumn = [
  'ALTER TABLE wallets DROP COLUMN legacy_social;',
];

/// Undo the v26 step on a database created at the current schema.
const _dropSocialIdentityColumn = [
  'ALTER TABLE wallets DROP COLUMN social_identity_id;',
];

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

  /// Creates the current schema on [dbFile], inserts one wallet row (plus
  /// [extraWallets]), then rewinds `user_version` to [version] (optionally
  /// undoing newer-schema DDL via [downgradeStatements]) so the next open runs
  /// `onUpgrade` from that version.
  Future<void> seedDbAtVersion(
    int version, {
    List<String> downgradeStatements = const [],
    List<WalletsCompanion> extraWallets = const [],
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
    for (final wallet in extraWallets) {
      await db.upsertWalletEntry(wallet);
    }
    // Every version below 26 predates the sign-in identity of a vault link.
    if (version >= 17 && version < 26) {
      for (final statement in _dropSocialIdentityColumn) {
        await db.customStatement(statement);
      }
    }
    // Every version below 25 predates the older-sign-in mark. Dropped first:
    // the column has to go before the vault id it is derived from does.
    if (version >= 17 && version < 25) {
      for (final statement in _dropLegacySocialColumn) {
        await db.customStatement(statement);
      }
    }
    // Every stepwise version below 23 predates the Keystone columns; leaving
    // them in place would make the v23 step's ADD COLUMN collide.
    if (version >= 17 && version < 23) {
      for (final statement in _dropKeystoneColumns) {
        await db.customStatement(statement);
      }
    }
    // Likewise every version below 24 predates the social vault column.
    if (version >= 17 && version < 24) {
      for (final statement in _dropSocialVaultColumn) {
        await db.customStatement(statement);
      }
    }
    for (final statement in downgradeStatements) {
      await db.customStatement(statement);
    }
    await db.customStatement('PRAGMA user_version = $version;');
    await db.close();
  }

  test(
    'upgrade from schema 22 adds the Keystone fingerprint columns',
    () async {
      await seedDbAtVersion(22);

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final wallets = await db.getAllWallets();
      expect(wallets, hasLength(1));
      expect(wallets.single.masterFingerprint, isNull);

      // Both new columns are writable and the account lookup reads its own.
      await db.upsertAccount(
        AccountsCompanion.insert(
          id: 'ks-account',
          kind: 'keystone',
          name: 'Account 02',
          avatarSeed: 'seed',
          createdAt: 1700000000,
          derivationIndex: const Value(0),
          masterFingerprint: const Value(0x12345678),
        ),
      );
      await db.upsertWalletEntry(
        WalletsCompanion.insert(
          id: 'ks-wallet',
          accountId: const Value('ks-account'),
          address: 'KeystoneAddre55',
          name: 'Solana',
          walletType: 'keystone',
          createdAt: 1700000000,
          masterFingerprint: const Value(0x12345678),
        ),
      );
      expect((await db.getKeystoneAccount(0x12345678, 0))?.id, 'ks-account');
      expect(await db.getKeystoneAccount(0x9ABCDEF0, 0), isNull);
      expect(
        (await db.getWalletById('ks-wallet'))?.masterFingerprint,
        0x12345678,
      );
    },
  );

  test('upgrade from schema 23 adds the social vault link', () async {
    await seedDbAtVersion(23);

    final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    final wallets = await db.getAllWallets();
    expect(wallets, hasLength(1), reason: 'wallet rows must survive');
    expect(wallets.single.socialVaultId, isNull);

    await db.setWalletsSocialVaultLink(['wallet-1'], 'vault-id');
    expect((await db.getWalletById('wallet-1'))?.socialVaultId, 'vault-id');
  });

  group('upgrade to schema 25 marks wallets from the older sign-in', () {
    WalletsCompanion social(String id, {String? vaultId}) =>
        WalletsCompanion.insert(
          id: id,
          address: 'addr-$id',
          name: 'Google Wallet',
          walletType: 'social',
          socialProvider: const Value('google'),
          socialVaultId: Value(vaultId),
          createdAt: 1700000000,
        );

    test('from 24: a social wallet without a vault is marked, one with a '
        'vault and a non-social wallet are not', () async {
      await seedDbAtVersion(
        24,
        extraWallets: [
          social('older'),
          social('vault', vaultId: 'vault-id'),
          WalletsCompanion.insert(
            id: 'imported',
            address: 'addr-imported',
            name: 'Imported',
            walletType: 'imported_key',
            createdAt: 1700000000,
          ),
        ],
      );

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final marks = {
        for (final w in await db.getAllWallets()) w.id: w.legacySocial,
      };
      expect(marks, {
        'wallet-1': false,
        'older': true,
        'vault': false,
        'imported': false,
      });
      // Nothing was lost on the way.
      expect((await db.getWalletById('vault'))?.socialVaultId, 'vault-id');
      expect((await db.getWalletById('older'))?.socialProvider, 'google');
    });

    test('from 23, the last released schema: every social wallet is one from '
        'the older sign-in', () async {
      // A release on schema 23 could not create a social vault, so the two
      // steps together mark every social wallet it holds.
      await seedDbAtVersion(23, extraWallets: [social('older')]);

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final older = await db.getWalletById('older');
      expect(older?.legacySocial, isTrue);
      expect(older?.socialVaultId, isNull);
      expect((await db.getWalletById('wallet-1'))?.legacySocial, isFalse);
    });

    test('the mark is set once: a vault wallet that loses its vault id '
        'afterwards stays unmarked', () async {
      await seedDbAtVersion(
        24,
        extraWallets: [social('vault', vaultId: 'vault-id')],
      );

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      // What deleting the wallet's backup does to its rows.
      await db.setWalletsSocialVaultLink(['vault'], null);
      final unlinked = await db.getWalletById('vault');
      expect(unlinked?.socialVaultId, isNull);
      expect(unlinked?.legacySocial, isFalse);
    });

    test('a wallet created on the current schema is unmarked', () async {
      final db = MallowDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.upsertWalletEntry(social('fresh'));
      expect((await db.getWalletById('fresh'))?.legacySocial, isFalse);
    });
  });

  group('upgrade to schema 26 adds the sign-in identity of a vault link', () {
    const identityId = '8ca57526739bfeac48d22f9d47d76f1a';

    WalletsCompanion social(String id, {String? vaultId}) =>
        WalletsCompanion.insert(
          id: id,
          address: 'addr-$id',
          name: 'Google Wallet',
          walletType: 'social',
          socialProvider: const Value('google'),
          socialVaultId: Value(vaultId),
          createdAt: 1700000000,
        );

    test('from 25: every row survives, with no identity until its next '
        'sign-in', () async {
      await seedDbAtVersion(
        25,
        extraWallets: [
          social('vault', vaultId: 'vault-id'),
          social('older'),
        ],
      );
      // What the v25 step had already done to the older-sign-in wallet.
      // (The seed is created at the current schema, where nothing marks it.)

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final wallets = {for (final w in await db.getAllWallets()) w.id: w};
      expect(wallets.keys, {'wallet-1', 'vault', 'older'});
      expect(wallets.values.map((w) => w.socialIdentityId), everyElement(null));
      expect(wallets['vault']!.socialVaultId, 'vault-id');
      expect(wallets['vault']!.legacySocial, isFalse);

      // The next sign-in records it, beside the link it belongs to.
      await db.setWalletsSocialVaultLink(
        ['vault'],
        'vault-id',
        identityId: identityId,
      );
      expect((await db.getWalletById('vault'))?.socialIdentityId, identityId);
    });

    test('from 23, the last released schema, through every step', () async {
      await seedDbAtVersion(23, extraWallets: [social('older')]);

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final older = await db.getWalletById('older');
      expect(older?.legacySocial, isTrue);
      expect(older?.socialVaultId, isNull);
      expect(older?.socialIdentityId, isNull);
    });

    test('a link written without an identity keeps the one recorded, and '
        'unlinking drops it', () async {
      final db = MallowDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.upsertWalletEntry(social('vault'));
      await db.setWalletsSocialVaultLink(
        ['vault'],
        'vault-id',
        identityId: identityId,
      );
      // Reopened from this device's own copy: no sign-in, so no identity to
      // name. The recorded one stays.
      await db.setWalletsSocialVaultLink(['vault'], 'vault-id');
      expect((await db.getWalletById('vault'))?.socialIdentityId, identityId);

      // Its backup was deleted.
      await db.setWalletsSocialVaultLink(['vault'], null);
      final unlinked = await db.getWalletById('vault');
      expect(unlinked?.socialVaultId, isNull);
      expect(unlinked?.socialIdentityId, isNull);
      expect(unlinked?.legacySocial, isFalse);
    });
  });

  // The upgrade steps are not one transaction and the schema version is written
  // after the last of them, so a process killed part-way leaves some columns
  // added and the version unchanged. The next launch runs the same steps
  // again; a plain ADD COLUMN would fail there on every launch and the
  // database would never open.
  group('an upgrade interrupted part-way runs again', () {
    WalletsCompanion social(String id) => WalletsCompanion.insert(
      id: id,
      address: 'addr-$id',
      name: 'Google Wallet',
      walletType: 'social',
      socialProvider: const Value('google'),
      createdAt: 1700000000,
    );

    const addVaultId = 'ALTER TABLE wallets ADD COLUMN social_vault_id TEXT;';
    const addLegacyMark =
        'ALTER TABLE wallets ADD COLUMN legacy_social INTEGER NOT NULL '
        'DEFAULT 0;';
    const addIdentityId =
        'ALTER TABLE wallets ADD COLUMN social_identity_id TEXT;';

    Future<MallowDatabase> expectUpgraded() async {
      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final wallets = {for (final w in await db.getAllWallets()) w.id: w};
      expect(wallets.keys, {'wallet-1', 'older'});
      expect(wallets['older']!.legacySocial, isTrue);
      expect(wallets['wallet-1']!.legacySocial, isFalse);
      expect(wallets.values.map((w) => w.socialVaultId), everyElement(null));
      expect(wallets.values.map((w) => w.socialIdentityId), everyElement(null));

      // The columns are the real ones: a link written now reads back.
      await db.setWalletsSocialVaultLink(
        ['older'],
        'vault-id',
        identityId: 'identity-id',
      );
      final linked = await db.getWalletById('older');
      expect(linked?.socialVaultId, 'vault-id');
      expect(linked?.socialIdentityId, 'identity-id');

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      return db;
    }

    test('from 23, killed after the vault id column was added', () async {
      await seedDbAtVersion(
        23,
        extraWallets: [social('older')],
        downgradeStatements: [addVaultId],
      );
      await expectUpgraded();
    });

    test('from 23, killed after the older-sign-in column was added and '
        'before its rows were marked', () async {
      await seedDbAtVersion(
        23,
        extraWallets: [social('older')],
        downgradeStatements: [addVaultId, addLegacyMark],
      );
      await expectUpgraded();
    });

    test('from 23, killed after every step and before the version was '
        'written: the marks are the same the second time', () async {
      await seedDbAtVersion(
        23,
        extraWallets: [social('older')],
        downgradeStatements: [
          addVaultId,
          addLegacyMark,
          "UPDATE wallets SET legacy_social = 1 WHERE wallet_type = 'social' "
              'AND social_vault_id IS NULL;',
          addIdentityId,
        ],
      );
      await expectUpgraded();
    });

    test('from 22, killed between the two Keystone columns', () async {
      await seedDbAtVersion(
        22,
        extraWallets: [social('older')],
        downgradeStatements: [
          'ALTER TABLE accounts ADD COLUMN master_fingerprint INTEGER;',
        ],
      );
      final db = await expectUpgraded();
      expect((await db.getWalletById('wallet-1'))?.masterFingerprint, isNull);
    });

    test('from 21, killed after the volume column was added', () async {
      final seed = MallowDatabase.forTesting(NativeDatabase(dbFile));
      await seed.upsertWalletEntry(
        WalletsCompanion.insert(
          id: 'wallet-1',
          address: 'So1anaAddre55',
          name: 'Account 01',
          walletType: 'hd',
          createdAt: 1700000000,
        ),
      );
      // The table keeps its volume column, as if the step had already run.
      for (final statement in [
        ..._dropKeystoneColumns,
        ..._dropSocialIdentityColumn,
        ..._dropLegacySocialColumn,
        ..._dropSocialVaultColumn,
      ]) {
        await seed.customStatement(statement);
      }
      await seed.customStatement('PRAGMA user_version = 21;');
      await seed.close();

      final db = MallowDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);
      expect(await db.getAllWallets(), hasLength(1));
      expect(await db.getJupiterTokenListCacheTime(), isNull);
    });
  });

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
    for (final statement in [
      ..._dropKeystoneColumns,
      ..._dropSocialIdentityColumn,
      ..._dropLegacySocialColumn,
      ..._dropSocialVaultColumn,
    ]) {
      await seed.customStatement(statement);
    }
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
