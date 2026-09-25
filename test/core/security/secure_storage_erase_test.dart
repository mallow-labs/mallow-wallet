import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart' as db;
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/biometric_auth.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

class _MockBiometric extends Mock implements BiometricAuthService {}

class _MockDb extends Mock implements db.MallowDatabase {}

/// The explicit wipes (Reset app, reinstall "Start fresh") must leave no
/// secret behind — including items the app has lost the ids of. Before the
/// enumeration sweep, Start fresh deleted the account graph (the only index)
/// and left every `mallow_mnemonic_seed_*` / `mallow_pk_*` in the Keychain
/// forever: access destroyed, material not. And a wipe must be best-effort:
/// stopping at the first error left the user half-wiped and still signed in.
void main() {
  late _MockFss fss;
  late _MockVault vault;
  late SecureWalletStorage storage;
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
      () => fss.delete(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((inv) async {
      fssStore.remove(inv.namedArguments[#key] as String);
    });
    when(
      () => fss.readAll(
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((_) async => Map<String, String>.from(fssStore));

    when(
      () => vault.read(any(), prompt: any(named: 'prompt')),
    ).thenAnswer((inv) async => vaultStore[inv.positionalArguments[0]]);
    when(() => vault.write(any(), any())).thenAnswer((inv) async {
      vaultStore[inv.positionalArguments[0] as String] =
          inv.positionalArguments[1] as String;
    });
    when(() => vault.delete(any())).thenAnswer((inv) async {
      vaultStore.remove(inv.positionalArguments[0] as String);
    });
    when(
      () => vault.listKeys(),
    ).thenAnswer((_) async => vaultStore.keys.toList());

    storage = SecureWalletStorage(fss, vault);
  });

  test('erases vault items nobody passed ids for (orphans)', () async {
    // A seed whose id the app no longer knows (graph gone), an imported key,
    // the legacy per-account key, and the DB-key backup.
    vaultStore['mallow_mnemonic_seed_lost-id'] = 'seed words';
    vaultStore['mallow_pk_lost-wallet'] = 'pk';
    vaultStore['mallow_db_encryption_key'] = 'dbkey';
    vaultStore['mallow_account_graph'] = '{}';
    vaultStore['mallow_pin'] = 'v1\$x\$y';
    fssStore['mallow_mnemonic_legacy-account'] = 'legacy';
    // Pre-migration copies of the keys that now live in the vault.
    fssStore['mallow_account_graph'] = '{}';
    fssStore['mallow_db_encryption_key'] = 'dbkey';
    fssStore['mallow_pin'] = 'v1\$x\$y';

    final failures = await storage.eraseAllSecrets();

    expect(failures, isEmpty);
    expect(vaultStore, isEmpty);
    expect(fssStore, isEmpty);
  });

  test(
    'still deletes the explicitly listed ids and the legacy duplicates',
    () async {
      vaultStore['mallow_mnemonic_seed_s1'] = 'seed';
      fssStore['mallow_mnemonic_seed_s1'] = 'legacy-dup';
      vaultStore['mallow_pk_w1'] = 'pk';

      final failures = await storage.eraseAllSecrets(
        seedPhraseIds: ['s1'],
        walletIds: ['w1'],
      );

      expect(failures, isEmpty);
      expect(vaultStore, isEmpty);
      expect(fssStore, isEmpty);
    },
  );

  test('a failing step does not stop the rest, and is reported', () async {
    vaultStore['mallow_mnemonic_seed_a'] = 'secret-seed-words';
    vaultStore['mallow_mnemonic_seed_b'] = 'other-seed-words';
    fssStore['mallow_pin'] = 'hash';
    // One vault delete fails with an OS status; everything else must still go.
    when(() => vault.delete('mallow_mnemonic_seed_a')).thenThrow(
      PlatformException(code: 'write_failed', message: 'status -25308'),
    );

    final failures = await storage.eraseAllSecrets();

    expect(vaultStore.keys, ['mallow_mnemonic_seed_a']);
    expect(fssStore, isEmpty);
    expect(failures, hasLength(1));
    expect(failures.single.step, 'vault.delete');
    // Codes and statuses only — never the stored value.
    expect(failures.single.detail, 'write_failed: status -25308');
    expect(failures.single.toString(), isNot(contains('secret-seed-words')));
  });

  test(
    'an unenumerable vault is reported but the plugin store is still swept',
    () async {
      when(
        () => vault.listKeys(),
      ).thenThrow(PlatformException(code: 'list_failed'));
      fssStore['mallow_pin'] = 'hash';
      fssStore['mallow_account_graph'] = '{}';

      final failures = await storage.eraseAllSecrets();

      expect(fssStore, isEmpty);
      expect(failures.map((f) => f.step), ['vault.listKeys']);
    },
  );

  test(
    'the in-memory DB-key bootstrap is dropped so the next open mints',
    () async {
      fssStore['mallow_db_encryption_key'] = 'old-key';
      final before = await storage.getOrCreateDbEncryptionKey(
        dbFileExists: true,
      );
      expect(before, 'old-key');

      await storage.eraseAllSecrets();

      // Without dropping the cached bootstrap this would hand back 'old-key'
      // and the fresh database file would be encrypted with an erased key.
      final after = await storage.getOrCreateDbEncryptionKey(
        dbFileExists: false,
      );
      expect(after, isNot('old-key'));
      expect(fssStore['mallow_db_encryption_key'], after);
    },
  );

  test(
    'the app-lock reset that follows a wipe leaves nothing behind',
    () async {
      // The wipe callers await the erase and only then dispatch
      // AppLockEvent.reset, so anything that handler *writes* lands after the
      // sweep and survives it — and on iOS a Keychain item outlives an app
      // reinstall, so the survivor would greet the next install.
      vaultStore['mallow_pin'] = 'hash';
      vaultStore['mallow_biometric_enabled'] = 'true';
      fssStore['mallow_failed_pin_attempts'] = '3';
      fssStore['mallow_pin_cooldown_until'] = '2026-01-01T00:00:00.000Z';

      await storage.eraseAllSecrets();
      expect(fssStore, isEmpty);
      expect(vaultStore, isEmpty);

      final bloc = AppLockBloc(storage, _MockBiometric(), _MockDb());
      bloc.add(const AppLockEvent.reset());
      // Drain the queued event.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<AppLockStateNoPinSet>());
      expect(fssStore, isEmpty);
      expect(vaultStore, isEmpty);

      await bloc.close();
    },
  );
}
