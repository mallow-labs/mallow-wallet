import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/pin_hasher.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

void main() {
  // The PIN is persisted under this key (mirrors SecureWalletStorage._pinKey).
  const pinKey = 'mallow_pin';

  late _MockFss fss;
  late SecureWalletStorage storage;
  // In-memory backing store so verify -> migrate -> re-verify round-trips.
  final store = <String, String>{};

  setUp(() {
    fss = _MockFss();
    store.clear();

    when(
      () => fss.read(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((inv) async => store[inv.namedArguments[#key] as String]);

    when(
      () => fss.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((inv) async {
      store[inv.namedArguments[#key] as String] =
          inv.namedArguments[#value] as String;
    });

    // Real hasher, deterministic RNG, KDF run inline so the test is fast.
    storage = SecureWalletStorage.withHasher(
      fss,
      _MockVault(),
      PinHasher.withRandom(Random(7)),
    );
  });

  group('SecureWalletStorage PIN hashing', () {
    test('storePinHash never persists the plaintext PIN', () async {
      await storage.storePinHash('4321');

      final raw = store[pinKey];
      expect(raw, isNotNull);
      expect(raw!.contains('4321'), isFalse);
      expect(PinHasher.isEncoded(raw), isTrue);
    });

    test('verifyPin matches the stored hash and rejects wrong PINs', () async {
      await storage.storePinHash('4321');

      expect(await storage.verifyPin('4321'), isTrue);
      expect(await storage.verifyPin('0000'), isFalse);
    });

    test('verifyPin returns false when no PIN is set', () async {
      expect(await storage.verifyPin('4321'), isFalse);
    });

    test(
      'legacy plaintext PIN verifies, then migrates to a hash on disk',
      () async {
        // Simulate a user onboarded before hashing shipped.
        store[pinKey] = '4321';

        expect(await storage.verifyPin('4321'), isTrue);

        // After the first correct entry the plaintext is gone, replaced by a
        // v1$ hash — and the user is not re-prompted next time.
        final migrated = store[pinKey]!;
        expect(PinHasher.isEncoded(migrated), isTrue);
        expect(migrated.contains('4321'), isFalse);
        expect(await storage.verifyPin('4321'), isTrue);
        expect(await storage.verifyPin('0000'), isFalse);
      },
    );

    test(
      'a wrong PIN against a legacy plaintext value does not migrate',
      () async {
        store[pinKey] = '4321';

        expect(await storage.verifyPin('0000'), isFalse);
        // Untouched — a failed attempt must not rewrite/migrate the stored value.
        expect(store[pinKey], '4321');
      },
    );
  });
}
