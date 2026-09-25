import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/router/auth_state_notifier.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockWalletManager extends Mock implements WalletManager {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockDb extends Mock implements MallowDatabase {}

class _MockWalletRepo extends Mock implements WalletRepository {}

/// The startup Keychain/DB mismatch handling must never destroy secrets.
/// The "nothing recoverable" branch can be reached through a transient
/// Keychain misread (graph and mnemonic both reading as absent for one
/// launch), so it may only clear re-creatable session keys — wiping the
/// account graph there orphans the per-seed mnemonics still in the vault.
void main() {
  late _MockWalletManager walletManager;
  late _MockStorage storage;
  late _MockDb db;
  late _MockWalletRepo walletRepo;
  late AuthStateNotifier notifier;

  setUp(() {
    walletManager = _MockWalletManager();
    storage = _MockStorage();
    db = _MockDb();
    walletRepo = _MockWalletRepo();
    notifier = AuthStateNotifier(walletManager, storage, db, walletRepo);

    // Baseline: empty DB, no legacy wallet, onboarding not completed.
    when(() => db.hasAnyWallets()).thenAnswer((_) async => false);
    when(() => walletManager.hasWallet()).thenAnswer((_) async => false);
    when(
      () => storage.loadOnboardingCompleted(),
    ).thenAnswer((_) async => false);
  });

  test('nothing-recoverable mismatch clears only session keys, '
      'never secrets', () async {
    // Keychain claims a wallet (e.g. a surviving selected-wallet address)
    // but neither the graph nor the mnemonic is readable right now.
    when(() => storage.hasWallet()).thenAnswer((_) async => true);
    when(() => storage.loadAccountGraph()).thenAnswer((_) async => null);
    when(() => storage.loadMnemonic()).thenAnswer((_) async => null);
    when(() => storage.clearWalletSessionKeys()).thenAnswer((_) async {});

    await notifier.initialize();

    expect(notifier.hasWallet, isFalse);
    expect(notifier.hasStaleKeychain, isFalse);
    expect(notifier.hasCompletedOnboarding, isFalse);

    verify(() => storage.clearWalletSessionKeys()).called(1);
    // The destructive calls this branch used to make must be gone.
    verifyNever(
      () => storage.clearAll(
        seedPhraseIds: any(named: 'seedPhraseIds'),
        walletIds: any(named: 'walletIds'),
      ),
    );
    verifyNever(() => storage.deleteAccountGraph());
    verifyNever(() => storage.deleteMnemonic());
  });

  test(
    'a DB with wallets restores dormant graph entries once per process',
    () async {
      // The graph carries over what the DB does not know; a launch with wallets
      // is where those come back. Once only — a boot Retry re-runs initialize().
      when(() => db.hasAnyWallets()).thenAnswer((_) async => true);
      when(() => storage.loadAccountGraph()).thenAnswer((_) async => '{"v":3}');
      when(
        () => walletRepo.restoreDormantFromGraph(
          graphJson: any(named: 'graphJson'),
        ),
      ).thenAnswer((_) async => const DormantRestoreResult());

      await notifier.initialize();
      await notifier.initialize();

      verify(
        () => walletRepo.restoreDormantFromGraph(
          graphJson: any(named: 'graphJson'),
        ),
      ).called(1);
      // No graph mutation from the notifier itself.
      verifyNever(() => walletRepo.syncWalletGraph());
    },
  );

  // The restore prunes the graph and then deletes vault entries. A second
  // initialize() that merely *skipped* would return mid-prune and let routing
  // resume over a half-finished restore; it must wait for the first one.
  test('a second initialize joins the in-flight restore, never skips '
      'past it', () async {
    when(() => db.hasAnyWallets()).thenAnswer((_) async => true);
    when(() => storage.loadAccountGraph()).thenAnswer((_) async => '{"v":3}');
    final gate = Completer<DormantRestoreResult>();
    var finished = false;
    when(
      () => walletRepo.restoreDormantFromGraph(
        graphJson: any(named: 'graphJson'),
      ),
    ).thenAnswer((_) async {
      final result = await gate.future;
      finished = true;
      return result;
    });

    final first = notifier.initialize();
    // Let the first run reach the restore and park on the gate.
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);

    var secondDone = false;
    final second = notifier.initialize().then((_) => secondDone = true);
    await Future<void>.delayed(Duration.zero);
    // This is the assertion that fails on a skip: it would have returned here,
    // with the restore still mid-flight.
    expect(secondDone, isFalse);
    expect(finished, isFalse);

    gate.complete(const DormantRestoreResult());
    await Future.wait([first, second]);

    expect(secondDone, isTrue);
    expect(finished, isTrue);
    verify(
      () => walletRepo.restoreDormantFromGraph(
        graphJson: any(named: 'graphJson'),
      ),
    ).called(1);
  });

  // Both the backfill check and the restore need the graph blob, and each read
  // is a protected-data probe plus a Keychain fetch on the boot path. One read,
  // handed on — not two.
  test('hands the graph it read to the dormant restore', () async {
    when(() => db.hasAnyWallets()).thenAnswer((_) async => true);
    when(() => storage.loadAccountGraph()).thenAnswer((_) async => '{"v":3}');
    when(
      () => walletRepo.restoreDormantFromGraph(
        graphJson: any(named: 'graphJson'),
      ),
    ).thenAnswer((_) async => const DormantRestoreResult());

    await notifier.initialize();

    verify(() => storage.loadAccountGraph()).called(1);
    verify(
      () => walletRepo.restoreDormantFromGraph(graphJson: '{"v":3}'),
    ).called(1);
  });

  // A read that throws says "this keystore cannot be read right now", not
  // "there is no graph". Running the restore anyway would have it read the
  // same unreadable blob and conclude nothing is dormant — and a launch that
  // concludes that while a graph exists is the one that strands wallets.
  test('skips the dormant restore when the graph read throws', () async {
    when(() => db.hasAnyWallets()).thenAnswer((_) async => true);
    when(
      () => storage.loadAccountGraph(),
    ).thenThrow(Exception('keychain unavailable'));

    await notifier.initialize();

    expect(notifier.hasWallet, isTrue); // boot is not blocked by the failure
    verifyNever(
      () => walletRepo.restoreDormantFromGraph(
        graphJson: any(named: 'graphJson'),
      ),
    );
    verifyNever(() => walletRepo.syncWalletGraph());
  });

  test('an empty DB never runs the dormant restore (that is the Restore '
      'screen\'s job)', () async {
    when(() => storage.hasWallet()).thenAnswer((_) async => true);
    when(() => storage.loadAccountGraph()).thenAnswer((_) async => '{"v":3}');

    await notifier.initialize();

    verifyNever(
      () => walletRepo.restoreDormantFromGraph(
        graphJson: any(named: 'graphJson'),
      ),
    );
  });

  // The stale-Keychain branch reads the graph to decide whether anything is
  // recoverable, and an unreadable keystore is not an empty one. Letting the
  // throw out fails the launch onto the boot error screen, whose Retry re-runs
  // this. A try/catch here would instead fall through to the "nothing
  // recoverable" arm and send a user with wallets to onboarding.
  test('a keystore-locked graph read fails the launch instead of clearing '
      'session keys', () async {
    when(() => storage.hasWallet()).thenAnswer((_) async => true);
    when(
      () => storage.loadAccountGraph(),
    ).thenThrow(const DbEncryptionKeyUnavailable());

    await expectLater(
      notifier.initialize(),
      throwsA(isA<DbEncryptionKeyUnavailable>()),
    );

    verifyNever(() => storage.clearWalletSessionKeys());
    verifyNever(() => storage.loadMnemonic());
    verifyNever(() => storage.deleteAccountGraph());
  });

  test(
    'a recoverable account graph flags stale Keychain without deleting',
    () async {
      when(() => storage.hasWallet()).thenAnswer((_) async => true);
      when(
        () => storage.loadAccountGraph(),
      ).thenAnswer((_) async => '{"accounts":[]}');

      await notifier.initialize();

      expect(notifier.hasStaleKeychain, isTrue);
      verifyNever(() => storage.clearWalletSessionKeys());
      verifyNever(
        () => storage.clearAll(
          seedPhraseIds: any(named: 'seedPhraseIds'),
          walletIds: any(named: 'walletIds'),
        ),
      );
    },
  );

  // Every caller of onLogout has already destroyed the wallets by the time it
  // runs, and each one waits on the listener notification to leave the
  // signed-in tree: Reset app has no navigation of its own, and Start fresh
  // keeps a full-screen spinner up. An unguarded throw on this last Keychain
  // call therefore left the router pointing at a wallet that no longer exists.
  test('onLogout clears the flags and notifies even when the storage delete '
      'throws', () async {
    when(
      () => storage.deleteOnboardingCompleted(),
    ).thenThrow(Exception('keychain unavailable'));
    var notified = 0;
    notifier.addListener(() => notified++);

    await notifier.onLogout();

    expect(notified, 1);
    expect(notifier.hasWallet, isFalse);
    expect(notifier.hasCompletedOnboarding, isFalse);
  });

  test('a healthy database skips the mismatch path entirely', () async {
    when(() => db.hasAnyWallets()).thenAnswer((_) async => true);
    when(
      () => storage.loadAccountGraph(),
    ).thenAnswer((_) async => '{"accounts":[]}');

    await notifier.initialize();

    expect(notifier.hasWallet, isTrue);
    expect(notifier.hasStaleKeychain, isFalse);
    verifyNever(() => storage.clearWalletSessionKeys());
    verifyNever(() => walletRepo.syncWalletGraph());
  });
}
