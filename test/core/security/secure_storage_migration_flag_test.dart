import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

/// When the DB key must be re-minted against an existing file, the open path
/// quarantines that file. On a new device (backup restore, device transfer)
/// that is the expected outcome — every `*ThisDeviceOnly` Keychain item stayed
/// behind — and must not be reported as corruption. The resolution therefore
/// says whether the Keychain held anything of ours at all.
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
      () => vault.read(any(), prompt: any(named: 'prompt')),
    ).thenAnswer((inv) async => vaultStore[inv.positionalArguments[0]]);
    when(() => vault.write(any(), any())).thenAnswer((inv) async {
      vaultStore[inv.positionalArguments[0] as String] =
          inv.positionalArguments[1] as String;
    });
    when(
      () => vault.listKeys(),
    ).thenAnswer((_) async => vaultStore.keys.toList());
    storage = SecureWalletStorage(fss, vault);
  });

  test(
    'an existing file with an empty Keychain reads as a migration',
    () async {
      final r = await storage.resolveDbEncryptionKey(dbFileExists: true);

      expect(r.mintedReplacement, isTrue);
      expect(r.migrationSuspected, isTrue);
    },
  );

  test(
    'an existing file with other vault items present is a real loss',
    () async {
      vaultStore['mallow_mnemonic_seed_x'] = 'words';

      final r = await storage.resolveDbEncryptionKey(dbFileExists: true);

      expect(r.mintedReplacement, isTrue);
      expect(r.migrationSuspected, isFalse);
    },
  );

  test(
    'an existing file with an account graph present is a real loss',
    () async {
      vaultStore['mallow_account_graph'] = '{"version":3}';

      final r = await storage.resolveDbEncryptionKey(dbFileExists: true);

      expect(r.migrationSuspected, isFalse);
    },
  );

  test('a not-yet-migrated account graph also rules out a migration', () async {
    // Pre-vault install: the graph is still the plugin store's copy, which
    // the read migrates on the way past. Either way the Keychain is not
    // empty, so the loss is real and gets the louder log.
    fssStore['mallow_account_graph'] = '{"version":3}';

    final r = await storage.resolveDbEncryptionKey(dbFileExists: true);

    expect(r.migrationSuspected, isFalse);
  });

  test('a first run is neither a re-mint nor a migration', () async {
    final r = await storage.resolveDbEncryptionKey(dbFileExists: false);

    expect(r.mintedReplacement, isFalse);
    expect(r.migrationSuspected, isFalse);
  });

  test('an unenumerable vault never claims migration', () async {
    // Doubt is logged as the louder (error) case.
    when(() => vault.listKeys()).thenThrow(StateError('boom'));

    final r = await storage.resolveDbEncryptionKey(dbFileExists: true);

    expect(r.migrationSuspected, isFalse);
  });
}
