import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/pin_hasher.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

/// The PIN hash is the app-lock floor: with it gone AppLockBloc reports
/// `noPinSet` and the app opens unlocked. It therefore lives in the vault,
/// whose write is update-or-add — the plugin store's overwrite deletes the
/// item before it adds the new one (iOS) and drops entries it cannot decrypt
/// (Android `resetOnError`).
void main() {
  // The PIN is persisted under this key (mirrors SecureWalletStorage._pinKey).
  const pinKey = 'mallow_pin';

  late _MockFss fss;
  late _MockVault vault;
  late SecureWalletStorage storage;
  // In-memory backing stores so verify -> migrate -> re-verify round-trips.
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
    when(() => vault.delete(any())).thenAnswer((inv) async {
      vaultStore.remove(inv.positionalArguments[0] as String);
    });

    // Real hasher, deterministic RNG, KDF run inline so the test is fast.
    storage = SecureWalletStorage.withHasher(
      fss,
      vault,
      PinHasher.withRandom(Random(7)),
    );
  });

  group('SecureWalletStorage PIN hashing', () {
    test('storePinHash never persists the plaintext PIN', () async {
      await storage.storePinHash('4321');

      final raw = vaultStore[pinKey];
      expect(raw, isNotNull);
      expect(raw!.contains('4321'), isFalse);
      expect(PinHasher.isEncoded(raw), isTrue);
    });

    test('storePinHash writes the vault, never the plugin store', () async {
      await storage.storePinHash('4321');

      expect(fssStore.containsKey(pinKey), isFalse);
      verifyNever(
        () => fss.write(
          key: pinKey,
          value: any(named: 'value'),
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      );
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
        // Simulate a user onboarded before hashing shipped — and before the
        // PIN moved to the vault, so the value is the plugin store's.
        fssStore[pinKey] = '4321';

        expect(await storage.verifyPin('4321'), isTrue);

        // After the first correct entry the plaintext is gone, replaced by a
        // v1$ hash in the vault — and the user is not re-prompted next time.
        expect(fssStore.containsKey(pinKey), isFalse);
        final migrated = vaultStore[pinKey]!;
        expect(PinHasher.isEncoded(migrated), isTrue);
        expect(migrated.contains('4321'), isFalse);
        expect(await storage.verifyPin('4321'), isTrue);
        expect(await storage.verifyPin('0000'), isFalse);
      },
    );

    test(
      'a wrong PIN against a legacy plaintext value does not migrate',
      () async {
        fssStore[pinKey] = '4321';

        expect(await storage.verifyPin('0000'), isFalse);
        // The read moves the value into the vault, but a failed attempt must
        // not re-hash it: the stored value is still the same plaintext, so
        // the correct PIN still verifies.
        expect(vaultStore[pinKey], '4321');
        expect(await storage.verifyPin('4321'), isTrue);
      },
    );

    test('an existing plugin-store hash is migrated into the vault', () async {
      // A user who set a PIN after hashing shipped but before the move.
      const encoded = 'v1\$c2FsdHk=\$aGFzaHk=';
      fssStore[pinKey] = encoded;

      expect(await storage.hasPin(), isTrue);

      expect(vaultStore[pinKey], encoded);
      expect(fssStore.containsKey(pinKey), isFalse);
    });

    test('deletePin removes both copies', () async {
      vaultStore[pinKey] = 'v1\$salt\$hash';
      fssStore[pinKey] = 'v1\$salt\$hash';

      await storage.deletePin();

      expect(vaultStore.containsKey(pinKey), isFalse);
      expect(fssStore.containsKey(pinKey), isFalse);
      expect(await storage.hasPin(), isFalse);
    });
  });

  group('SecureWalletStorage biometric flag', () {
    const flagKey = 'mallow_biometric_enabled';

    test('is stored in the vault next to the PIN hash', () async {
      // The flag and the PIN together are the app-lock floor: losing one
      // while keeping the other changes what the gate means.
      await storage.storeBiometricEnabled(true);

      expect(vaultStore[flagKey], 'true');
      expect(fssStore.containsKey(flagKey), isFalse);
      expect(await storage.loadBiometricEnabled(), isTrue);
    });

    test('a legacy plugin-store flag is migrated on read', () async {
      fssStore[flagKey] = 'true';

      expect(await storage.loadBiometricEnabled(), isTrue);

      expect(vaultStore[flagKey], 'true');
      expect(fssStore.containsKey(flagKey), isFalse);
    });

    test('deleteBiometricEnabled removes both copies', () async {
      vaultStore[flagKey] = 'true';
      fssStore[flagKey] = 'true';

      await storage.deleteBiometricEnabled();

      expect(vaultStore.containsKey(flagKey), isFalse);
      expect(fssStore.containsKey(flagKey), isFalse);
      expect(await storage.loadBiometricEnabled(), isFalse);
    });
  });

  // Every caller of these two reads treats "no PIN" as "nothing to challenge
  // with": AppLockBloc opens the session, the re-auth gate passes, and the
  // recovery phrase screen reveals the mnemonic. Onboarding cannot finish with
  // neither factor, so a PIN that reads absent on a device holding wallets is
  // far more likely a transient keystore miss than the truth — and the
  // asymmetric miss (PIN gone, biometrics on) is the one that strands a user
  // on a lock screen with no PIN pad and no way past a failed biometric.
  group('SecureWalletStorage.loadAuthFactors', () {
    const flagKey = 'mallow_biometric_enabled';

    /// Answers the [misses] first reads of [key] with null, then from the
    /// backing store — a value that is there but does not come back yet.
    void missThenAnswer(String key, int misses) {
      var seen = 0;
      when(() => vault.read(any(), prompt: any(named: 'prompt'))).thenAnswer((
        inv,
      ) async {
        final k = inv.positionalArguments[0] as String;
        if (k == key && seen++ < misses) return null;
        return vaultStore[k];
      });
    }

    test('a PIN that reads absent once is re-read, and the second read is '
        'believed', () async {
      await storage.storePinHash('4321');
      vaultStore[flagKey] = 'true';
      missThenAnswer(pinKey, 1);

      final factors = await storage.loadAuthFactors();

      // Believing the first miss would have locked a PIN+biometrics device
      // into the biometric-only lock screen, where a failed prompt has
      // nothing to fall back on.
      expect(factors.hasPin, isTrue);
      expect(factors.biometricEnabled, isTrue);
    });

    test('a device that really has no PIN still reads false, after looking '
        'again', () async {
      vaultStore[flagKey] = 'true';

      final factors = await storage.loadAuthFactors();

      // A biometric-only user is a real user: the retries must not invent a
      // PIN they would then be asked for and could not give.
      expect(factors.hasPin, isFalse);
      expect(factors.biometricEnabled, isTrue);
      // Looked more than once before concluding it — that is the whole point.
      verify(
        () => vault.read(pinKey, prompt: any(named: 'prompt')),
      ).called(greaterThan(1));
    });

    test('a biometric flag that read true is not talked back down by a later '
        'attempt', () async {
      // The device with no PIN is exactly the device that burns every
      // attempt, so its flag is read again on each one. Last-read-wins turned
      // a transient miss on the final read into `(false, false)` — the one
      // answer that drops the lock: AppLockBloc takes its `noPinSet` arm, the
      // session opens unlocked and the re-auth gate in Settings waves through.
      var flagReads = 0;
      when(() => vault.read(any(), prompt: any(named: 'prompt'))).thenAnswer((
        inv,
      ) async {
        final k = inv.positionalArguments[0] as String;
        if (k == flagKey) return flagReads++ == 0 ? 'true' : null;
        return vaultStore[k];
      });

      final factors = await storage.loadAuthFactors();

      expect(factors.hasPin, isFalse);
      expect(factors.biometricEnabled, isTrue);
    });

    test(
      'a read that fails propagates instead of answering "no PIN"',
      () async {
        when(
          () => vault.read(any(), prompt: any(named: 'prompt')),
        ).thenThrow(StateError('keychain unavailable'));

        // "Unknown" is not "absent". Swallowing this into false would hand the
        // caller the one answer that drops the lock.
        await expectLater(
          storage.loadAuthFactors(),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}
