import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

/// These tests encode the invariant behind the "random Restore wallet" fix:
/// the DB encryption key must only ever be minted on a genuine first run.
/// When a database file already exists, a null keystore read is a transient
/// fault until proven otherwise — re-keying against an existing file makes it
/// undecryptable, which is unrecoverable data loss.
void main() {
  // Mirrors SecureWalletStorage._dbEncryptionKeyKey.
  const dbKeyKey = 'mallow_db_encryption_key';
  const storedKey = 'deadbeef-existing-key';

  late _MockFss fss;
  late _MockVault vault;
  late SecureWalletStorage storage;
  // In-memory backing stores so heal/backfill round-trips are observable.
  final fssStore = <String, String>{};
  final vaultStore = <String, String>{};

  setUp(() {
    fss = _MockFss();
    vault = _MockVault();
    fssStore.clear();
    vaultStore.clear();

    when(
      () => fss.read(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((inv) async => fssStore[inv.namedArguments[#key] as String]);

    when(
      () => fss.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((inv) async {
      fssStore[inv.namedArguments[#key] as String] =
          inv.namedArguments[#value] as String;
    });

    when(
      () => vault.read(any(), prompt: any(named: 'prompt')),
    ).thenAnswer((inv) async => vaultStore[inv.positionalArguments.first]);

    when(() => vault.write(any(), any())).thenAnswer((inv) async {
      vaultStore[inv.positionalArguments[0] as String] =
          inv.positionalArguments[1] as String;
    });

    storage = SecureWalletStorage(fss, vault);
  });

  bool isHexKey(String value) =>
      value.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(value);

  group('primary store has the key', () {
    test('returns it without minting and backfills the vault backup', () async {
      fssStore[dbKeyKey] = storedKey;

      final key = await storage.getOrCreateDbEncryptionKey(dbFileExists: true);

      expect(key, storedKey);
      // Backup created for existing installs that predate the backup.
      expect(vaultStore[dbKeyKey], storedKey);
      // The primary copy was never rewritten.
      verifyNever(
        () => fss.write(
          key: dbKeyKey,
          value: any(named: 'value'),
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      );
    });

    test('never rewrites an existing vault backup', () async {
      fssStore[dbKeyKey] = storedKey;
      vaultStore[dbKeyKey] = storedKey;

      await storage.getOrCreateDbEncryptionKey(dbFileExists: true);

      // The iOS vault write is delete-then-add, so a boot-path rewrite of a
      // valid backup would itself be a loss window.
      verifyNever(() => vault.write(any(), any()));
    });
  });

  group('primary store is empty, vault backup present', () {
    test('returns the backup and heals the primary store', () async {
      vaultStore[dbKeyKey] = storedKey;

      final key = await storage.getOrCreateDbEncryptionKey(dbFileExists: true);

      expect(key, storedKey);
      expect(fssStore[dbKeyKey], storedKey);
    });

    test('a failed primary heal still returns the backup key', () async {
      vaultStore[dbKeyKey] = storedKey;
      when(
        () => fss.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      ).thenThrow(PlatformException(code: 'write_failed'));

      final key = await storage.getOrCreateDbEncryptionKey(dbFileExists: true);

      expect(key, storedKey);
    });
  });

  group('both stores empty', () {
    test('first run (no db file) mints and persists to both stores', () async {
      final key = await storage.getOrCreateDbEncryptionKey(dbFileExists: false);

      expect(isHexKey(key), isTrue);
      expect(fssStore[dbKeyKey], key);
      expect(vaultStore[dbKeyKey], key);
      // No db file means no reason to suspect a transient fault — one read.
      verify(
        () => fss.read(
          key: dbKeyKey,
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      ).called(1);
    });

    test('a transient not-found with an existing db file resolves on retry '
        'without re-keying', () async {
      // First read glitches to null, later reads see the real key — the
      // exact iOS behavior that used to permanently destroy the database.
      var reads = 0;
      when(
        () => fss.read(
          key: dbKeyKey,
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      ).thenAnswer((_) async => ++reads == 1 ? null : storedKey);

      final key = await storage.getOrCreateDbEncryptionKey(dbFileExists: true);

      expect(key, storedKey);
      // No mint, no heal: the primary copy was never written.
      verifyNever(
        () => fss.write(
          key: dbKeyKey,
          value: any(named: 'value'),
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      );
    });

    test('persistent absence with an existing db file mints a replacement '
        'only after exhausting retries', () async {
      final key = await storage.getOrCreateDbEncryptionKey(dbFileExists: true);

      expect(isHexKey(key), isTrue);
      expect(fssStore[dbKeyKey], key);
      expect(vaultStore[dbKeyKey], key);
      // Three read attempts against the primary store before giving up.
      verify(
        () => fss.read(
          key: dbKeyKey,
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      ).called(3);
    });
  });

  group('read errors fail the launch instead of mutating state', () {
    test('a primary-store read error propagates with no writes', () async {
      when(
        () => fss.read(
          key: any(named: 'key'),
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      ).thenThrow(PlatformException(code: '-25308'));

      await expectLater(
        storage.getOrCreateDbEncryptionKey(dbFileExists: true),
        throwsA(isA<PlatformException>()),
      );
      verifyNever(
        () => fss.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      );
      verifyNever(() => vault.write(any(), any()));
    });

    test(
      'a vault backup read error propagates when the primary is empty',
      () async {
        when(
          () => vault.read(any(), prompt: any(named: 'prompt')),
        ).thenThrow(PlatformException(code: 'read_failed'));

        await expectLater(
          storage.getOrCreateDbEncryptionKey(dbFileExists: true),
          throwsA(isA<PlatformException>()),
        );
        verifyNever(
          () => fss.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
            iOptions: any(named: 'iOptions'),
            aOptions: any(named: 'aOptions'),
          ),
        );
      },
    );
  });

  group('iOS protected-data gate', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      'locked protected data fails the launch before any key access',
      () async {
        when(
          () => fss.isCupertinoProtectedDataAvailable(),
        ).thenAnswer((_) async => false);

        await expectLater(
          storage.getOrCreateDbEncryptionKey(dbFileExists: true),
          throwsA(isA<DbEncryptionKeyUnavailable>()),
        );
        // The whole point: while the keystore can misreport items as missing,
        // nothing may be read — and certainly nothing written.
        verifyNever(
          () => fss.read(
            key: any(named: 'key'),
            iOptions: any(named: 'iOptions'),
            aOptions: any(named: 'aOptions'),
          ),
        );
        verifyNever(
          () => fss.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
            iOptions: any(named: 'iOptions'),
            aOptions: any(named: 'aOptions'),
          ),
        );
      },
    );

    test('proceeds once protected data becomes available', () async {
      var polls = 0;
      when(
        () => fss.isCupertinoProtectedDataAvailable(),
      ).thenAnswer((_) async => ++polls >= 2);
      fssStore[dbKeyKey] = storedKey;

      final key = await storage.getOrCreateDbEncryptionKey(dbFileExists: true);

      expect(key, storedKey);
    });

    test('a null availability answer is treated as available', () async {
      when(
        () => fss.isCupertinoProtectedDataAvailable(),
      ).thenAnswer((_) async => null);
      fssStore[dbKeyKey] = storedKey;

      final key = await storage.getOrCreateDbEncryptionKey(dbFileExists: true);

      expect(key, storedKey);
    });
  });
}
