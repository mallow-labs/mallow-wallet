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
