import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

/// The account graph is the only index of the vault's per-seed and
/// imported-key items. Every caller of the read acts on null as "there is no
/// graph": one routes the launch to onboarding, another lets the next sync
/// write a graph built from the database alone. Either way the vault items of
/// every seed the graph was carrying are orphaned — the material is still
/// there and nothing can find it again.
///
/// So the graph lives in the vault, whose write is update-or-add. The plugin
/// store's overwrite is delete-then-add on iOS and delete-on-read-error on
/// Android: either one can lose the index outright.
///
/// iOS can also report an existing-but-inaccessible Keychain item as *not
/// found*, so this read must refuse to answer while the keystore is in that
/// state rather than answer "absent". These tests fail if the guard is
/// dropped, or if the graph moves back into the plugin store.
void main() {
  // Mirrors SecureWalletStorage._accountGraphKey.
  const graphKey = 'mallow_account_graph';
  const graphJson = '{"version":3,"seedPhrases":[],"accounts":[],"wallets":[]}';

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
    when(() => vault.delete(any())).thenAnswer((inv) async {
      vaultStore.remove(inv.positionalArguments[0] as String);
    });

    storage = SecureWalletStorage(fss, vault);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('locked protected data throws instead of reading absent', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // The graph is on the device; the keystore just will not surface it.
    vaultStore[graphKey] = graphJson;
    when(
      () => fss.isCupertinoProtectedDataAvailable(),
    ).thenAnswer((_) async => false);

    await expectLater(
      storage.loadAccountGraph(),
      throwsA(isA<DbEncryptionKeyUnavailable>()),
    );
    // Nothing is read while the keystore can misreport items as missing —
    // a null from either store is indistinguishable from "the user has no
    // graph".
    verifyNever(() => vault.read(any(), prompt: any(named: 'prompt')));
    verifyNever(
      () => fss.read(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    );
  });

  test('reads the graph once protected data becomes available', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    vaultStore[graphKey] = graphJson;
    var polls = 0;
    when(
      () => fss.isCupertinoProtectedDataAvailable(),
    ).thenAnswer((_) async => ++polls >= 2);

    expect(await storage.loadAccountGraph(), graphJson);
  });

  test('an absent graph on an unlocked device still reads null', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    when(
      () => fss.isCupertinoProtectedDataAvailable(),
    ).thenAnswer((_) async => true);

    expect(await storage.loadAccountGraph(), isNull);
  });

  test('off Apple platforms the read is unguarded', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    vaultStore[graphKey] = graphJson;

    expect(await storage.loadAccountGraph(), graphJson);
    verifyNever(() => fss.isCupertinoProtectedDataAvailable());
  });

  test('a vault read error propagates instead of falling back', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // A pre-migration copy is still in the plugin store, but the vault could
    // not answer: "unknown" must not be reported as this older graph, and
    // above all must not be reported as absent.
    fssStore[graphKey] = graphJson;
    when(
      () => vault.read(graphKey, prompt: any(named: 'prompt')),
    ).thenThrow(StateError('keystore unavailable'));

    await expectLater(storage.loadAccountGraph(), throwsA(isA<StateError>()));
  });

  group('legacy plugin-store copy', () {
    test('is migrated into the vault and dropped on first read', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fssStore[graphKey] = graphJson;

      expect(await storage.loadAccountGraph(), graphJson);

      // Now in the vault, and gone from the store that can lose it.
      expect(vaultStore[graphKey], graphJson);
      expect(fssStore.containsKey(graphKey), isFalse);

      // The second read is served by the vault alone.
      expect(await storage.loadAccountGraph(), graphJson);
    });

    test('is still returned when the migrating write fails', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fssStore[graphKey] = graphJson;
      when(() => vault.write(any(), any())).thenThrow(StateError('boom'));

      // The migration is an optimisation; a failed one must not turn a
      // readable graph into a throw, and must leave the legacy copy alone.
      expect(await storage.loadAccountGraph(), graphJson);
      expect(fssStore[graphKey], graphJson);
    });
  });

  group('storeAccountGraph', () {
    test('writes the vault and never the plugin store', () async {
      await storage.storeAccountGraph(graphJson);

      expect(vaultStore[graphKey], graphJson);
      verifyNever(
        () => fss.write(
          key: graphKey,
          value: any(named: 'value'),
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      );
    });

    test('drops a legacy copy only after the vault write lands', () async {
      fssStore[graphKey] = '{"version":2}';

      await storage.storeAccountGraph(graphJson);

      // Order is the point: nothing is ever deleted before the new value is
      // stored, and the stale copy must not survive to be migrated back over
      // the current graph by a later read.
      verifyInOrder([
        () => vault.write(graphKey, graphJson),
        () => fss.delete(
          key: graphKey,
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      ]);
      expect(fssStore.containsKey(graphKey), isFalse);
    });

    test('a failed legacy drop does not fail the write', () async {
      when(
        () => fss.delete(
          key: any(named: 'key'),
          iOptions: any(named: 'iOptions'),
          aOptions: any(named: 'aOptions'),
        ),
      ).thenThrow(StateError('boom'));

      await storage.storeAccountGraph(graphJson);

      expect(vaultStore[graphKey], graphJson);
    });
  });

  test('deleteAccountGraph deletes both copies', () async {
    vaultStore[graphKey] = graphJson;
    fssStore[graphKey] = graphJson;

    await storage.deleteAccountGraph();

    expect(vaultStore.containsKey(graphKey), isFalse);
    expect(fssStore.containsKey(graphKey), isFalse);
  });
}
