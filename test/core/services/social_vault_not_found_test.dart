import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/social_vault/passkey_prf.dart';
import 'package:mallow_wallet/core/social_vault/platform_slot_store.dart';
import 'package:mallow_wallet/core/social_vault/social_identity.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_api.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

/// The identity id the backend derives for issuer
/// `https://accounts.google.com`, subject `1234567890`.
const _identityId = '8ca57526739bfeac48d22f9d47d76f1a';

/// What a wallet goes through when the backend says its vault does not
/// exist, end to end: the real wallet repository (on an in-memory database),
/// the real vault service and the real sign-in orchestration, against
/// stand-ins for the backend, the platform keychain and the provider.
///
/// The answer cannot be authenticated, and a wrong one — a build pointed at
/// the wrong backend, a backend restored from an older copy — arrives for
/// every vault at once. So nothing here may be destroyed on it: not at once,
/// and not in a way a sign-in cannot undo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MallowDatabase db;
  late SecureWalletStorage storage;
  late WalletRepository repo;
  late _Backend backend;
  late _Platform platform;
  late _Prompts prompts;
  late SocialVaultService vaults;
  late SocialAuthService auth;
  late DateTime now;

  /// The backend this build talks to, and the one the test's wallets are
  /// created on.
  const here = 'https://backend.test:443';
  late String origin;

  /// While set, the recovery graph cannot be written.
  late bool graphUnwritable;

  final fssStore = <String, String>{};
  final vaultStore = <String, String>{};

  setUp(() async {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    final fss = _MockFss();
    final vault = _MockVault();
    fssStore.clear();
    vaultStore.clear();
    SharedPreferences.setMockInitialValues({});
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
    when(() => vault.read(any(), prompt: any(named: 'prompt'))).thenAnswer(
      (inv) async => vaultStore[inv.positionalArguments[0] as String],
    );
    graphUnwritable = false;
    when(() => vault.write(any(), any())).thenAnswer((inv) async {
      final key = inv.positionalArguments[0] as String;
      if (graphUnwritable && key == 'mallow_account_graph') {
        throw PlatformException(code: 'write_failed');
      }
      vaultStore[key] = inv.positionalArguments[1] as String;
    });
    when(() => vault.delete(any())).thenAnswer((inv) async {
      vaultStore.remove(inv.positionalArguments[0] as String);
    });
    when(
      () => vault.listKeys(),
    ).thenAnswer((_) async => vaultStore.keys.toList());

    storage = SecureWalletStorage(fss, vault);
    repo = WalletRepository(db, storage, await PreferencesService.create());
    GetIt.instance.registerSingleton<WalletRepository>(repo);

    now = DateTime.utc(2026, 11, 10, 12);
    backend = _Backend();
    platform = _Platform();
    prompts = _Prompts();
    vaults = SocialVaultService(
      backend,
      platform,
      _NoPasskeys(),
      storage,
      deviceName: () async => 'Test phone',
      clock: () => now,
      androidSdkInt: () async => null,
      apiOrigin: () => origin,
    );
    origin = here;
    auth = SocialAuthService(_Identity(), vaults)..prompts = prompts;
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await db.close();
  });

  Future<List<WalletInfo>> socialRows() async => (await repo.getAllWallets())
      .where((w) => w.walletType == WalletType.social)
      .toList();

  /// A Google wallet created by a first sign-in: three rows, linked to the
  /// vault the backend now holds, opened by this device's platform entry.
  Future<({String accountId, String vaultId, List<String> rowIds})>
  signedIn() async {
    final result = await auth.signInWithGoogle();
    final rows = await socialRows();
    expect(rows, hasLength(3));
    expect(rows.map((w) => w.socialVaultId).toSet(), {backend.vault!.vaultId});
    expect(rows.map((w) => w.socialIdentityId).toSet(), {_identityId});
    expect(platform.count, 1);
    return (
      accountId: result!.wallet.accountId!,
      vaultId: backend.vault!.vaultId,
      rowIds: [for (final w in rows) w.id]..sort(),
    );
  }

  /// The backend answers "not found" to two status reads a day apart, and
  /// the wallet is unlinked.
  Future<void> notFoundTwice() async {
    backend.missing = true;
    await auth.checkVaults();
    now = now.add(const Duration(hours: 24));
    await auth.checkVaults();
  }

  test('linked, not found twice, unlinked with its entries kept, signed in '
      'again: linked again, same account, no duplicate rows', () async {
    final wallet = await signedIn();
    final vaultId = wallet.vaultId;
    final phrase = await storage.loadSocialVaultMnemonic(vaultId);
    expect(phrase, isNotNull);

    // One "not found": nothing changes and nothing is shown.
    backend.missing = true;
    await auth.checkVaults();
    expect((await socialRows()).map((w) => w.socialVaultId).toSet(), {vaultId});
    expect(platform.count, 1);
    expect(await vaults.loadDataKey(vaultId), isNotNull);
    expect(prompts.backupGone, isEmpty);

    // Still "not found" later the same day: the same.
    now = now.add(const Duration(hours: 23));
    await auth.checkVaults();
    expect((await socialRows()).map((w) => w.socialVaultId).toSet(), {vaultId});
    expect(prompts.backupGone, isEmpty);

    // A day after the first: the wallet is unlinked, and that is all.
    now = now.add(const Duration(hours: 1));
    await auth.checkVaults();
    final unlinked = await socialRows();
    expect(unlinked, hasLength(3));
    expect(unlinked.map((w) => w.socialVaultId), everyElement(isNull));
    expect(unlinked.map((w) => w.socialIdentityId), everyElement(isNull));
    expect(
      unlinked.map((w) => w.isLegacySocialWallet),
      everyElement(isFalse),
      reason: 'never mistaken for a wallet from the older sign-in',
    );
    expect(platform.count, 1, reason: 'the slot secret is kept');
    expect(await vaults.loadDataKey(vaultId), isNull);
    expect(await vaults.hasUsableDataKey(vaultId), isFalse);
    expect(await storage.loadSocialVaultRetiredKey(vaultId), isNotNull);
    expect(await storage.loadSocialAccountMnemonic(wallet.accountId), phrase);
    // The wallet still signs: its keys never left.
    for (final w in unlinked) {
      expect(await storage.loadPrivateKey(w.id), isNotNull);
    }
    expect((await vaults.retiredVaults()).single.vaultId, vaultId);
    expect(prompts.backupGone, ['google'], reason: 'told once');

    await auth.checkVaults();
    expect(prompts.backupGone, ['google']);

    // The backend is itself again, and the user signs in.
    backend.missing = false;
    final again = await auth.signInWithGoogle();
    expect(again!.existed, isTrue);
    expect(again.wallet.accountId, wallet.accountId);

    final relinked = await socialRows();
    expect([for (final w in relinked) w.id]..sort(), wallet.rowIds);
    expect(relinked.map((w) => w.accountId).toSet(), {wallet.accountId});
    expect(relinked.map((w) => w.socialVaultId).toSet(), {vaultId});
    expect(relinked.map((w) => w.socialIdentityId).toSet(), {_identityId});
    expect(
      (await repo.getAccountViews()).where((a) => a.kind == AccountKind.social),
      hasLength(1),
    );
    expect(await vaults.loadDataKey(vaultId), isNotNull);
    expect((await vaults.cached(vaultId))!.vault.vaultId, vaultId);
    expect(await vaults.retiredVaults(), isEmpty);
    expect(await storage.loadSocialVaultRetiredKey(vaultId), isNull);
    expect(platform.count, 1);
    expect(backend.creates, 1, reason: 'no second vault was created');
  });

  test('a vault that turns up again links the wallet back without a '
      'sign-in', () async {
    final wallet = await signedIn();
    await notFoundTwice();
    expect(
      (await socialRows()).map((w) => w.socialVaultId),
      everyElement(isNull),
    );

    // A fixed build, a repaired backend: the next daily look finds it.
    backend.missing = false;
    now = now.add(const Duration(hours: 24));
    await auth.checkVaults();

    final rows = await socialRows();
    expect([for (final w in rows) w.id]..sort(), wallet.rowIds);
    expect(rows.map((w) => w.socialVaultId).toSet(), {wallet.vaultId});
    expect(rows.map((w) => w.socialIdentityId).toSet(), {_identityId});
    expect(await vaults.loadDataKey(wallet.vaultId), isNotNull);
    expect(await vaults.retiredVaults(), isEmpty);
    expect(platform.count, 1);
  });

  test('the kept entries are deleted only after 30 days of "not found", on '
      'a fresh one', () async {
    final wallet = await signedIn();
    await notFoundTwice();
    final unlinkedAt = now;

    // Every day for 29 days the backend still says "not found".
    for (var day = 1; day <= 29; day++) {
      now = unlinkedAt.add(Duration(days: day));
      await auth.checkVaults();
      expect(platform.count, 1, reason: 'day $day');
    }

    // Day 30, and no answer: the age alone deletes nothing.
    now = unlinkedAt.add(const Duration(days: 30));
    backend.offline = true;
    await auth.checkVaults();
    expect(platform.count, 1);

    // Day 30, and "not found" once more.
    backend.offline = false;
    await auth.checkVaults();
    expect(platform.count, 0);
    expect(await vaults.retiredVaults(), isEmpty);
    expect(await storage.loadSocialVaultRetiredKey(wallet.vaultId), isNull);
    // The wallet is where it was: on this phone, unlinked, with its phrase.
    final rows = await socialRows();
    expect([for (final w in rows) w.id]..sort(), wallet.rowIds);
    expect(
      await storage.loadSocialAccountMnemonic(wallet.accountId),
      isNotNull,
    );
  });

  test('a delete this device signed deletes the entries at once', () async {
    final wallet = await signedIn();
    await auth.deleteWalletBackup(wallet.accountId);

    expect(backend.vault, isNull);
    expect(platform.count, 0);
    expect(await vaults.retiredVaults(), isEmpty);
    expect(await storage.loadSocialVaultRetiredKey(wallet.vaultId), isNull);
    expect(
      (await socialRows()).map((w) => w.socialVaultId),
      everyElement(isNull),
    );
    expect(prompts.backupGone, isEmpty);
  });

  // A proxy, a backend without the vault routes and a build pointed at the
  // wrong host all answer 404, to every request, for as long as they are in
  // the way. None of it is the backend saying the vault is gone.
  group('a 404 that is not the backend\'s own "no such vault"', () {
    Future<void> expectStillBackedUp(
      ({String accountId, String vaultId, List<String> rowIds}) wallet,
    ) async {
      expect((await socialRows()).map((w) => w.socialVaultId).toSet(), {
        wallet.vaultId,
      });
      expect(platform.count, 1, reason: 'the slot secret stays');
      expect(await vaults.loadDataKey(wallet.vaultId), isNotNull);
      expect(await storage.loadSocialVaultMnemonic(wallet.vaultId), isNotNull);
      expect(await vaults.retiredVaults(), isEmpty);
      expect(await vaults.pendingUnlinks(), isEmpty);
      expect(prompts.backupGone, isEmpty);
    }

    test('for two months of status checks: the wallet stays linked and '
        'nothing is deleted or shown', () async {
      final wallet = await signedIn();
      backend.bare404 = true;
      for (var day = 0; day < 60; day++) {
        await auth.checkVaults();
        now = now.add(const Duration(days: 1));
      }
      await expectStillBackedUp(wallet);

      // The proxy is out of the way: the vault was there all along.
      backend.bare404 = false;
      await auth.checkVaults();
      await expectStillBackedUp(wallet);
      expect(
        (await vaults.cached(wallet.vaultId))!.vault.vaultId,
        wallet.vaultId,
      );
    });

    test('a build pointed at another backend, which says "no such vault" in '
        'the backend\'s own words, changes nothing either', () async {
      final wallet = await signedIn();
      origin = 'https://staging.test:443';
      backend
        ..missing = true
        ..signedRequests = 0;
      for (var day = 0; day < 60; day++) {
        await auth.checkVaults();
        now = now.add(const Duration(days: 1));
      }
      await expectStillBackedUp(wallet);
      expect(backend.signedRequests, 0, reason: 'it is not even asked');
    });

    test('to Delete wallet backup: the delete fails, and the wallet is not '
        'recorded as having no backup', () async {
      final wallet = await signedIn();
      backend.bare404 = true;
      await expectLater(
        auth.deleteWalletBackup(wallet.accountId),
        throwsA(isA<SocialVaultApiException>()),
      );
      await expectStillBackedUp(wallet);
      expect(backend.vault, isNotNull);

      // Nothing was set aside to link back later, silently: once the
      // backend answers, the wallet is simply still backed up, and the user
      // can delete the backup for real.
      backend.bare404 = false;
      now = now.add(const Duration(days: 2));
      await auth.checkVaults();
      await expectStillBackedUp(wallet);
      await auth.deleteWalletBackup(wallet.accountId);
      expect(backend.vault, isNull);
      expect(platform.count, 0);
    });

    test('a Delete wallet backup on a build pointed at another backend '
        'sends nothing', () async {
      final wallet = await signedIn();
      origin = 'https://staging.test:443';
      backend.signedRequests = 0;
      for (final missing in [false, true]) {
        backend.missing = missing;
        await expectLater(
          auth.deleteWalletBackup(wallet.accountId),
          throwsA(isA<SocialVaultApiException>()),
        );
      }
      expect(backend.signedRequests, 0);
      await expectStillBackedUp(wallet);
      expect(backend.vault, isNotNull);
    });

    test('a wallet unlinked on the backend\'s own answer is not linked '
        'back, nor its entries freed, by a build pointed elsewhere', () async {
      final wallet = await signedIn();
      await notFoundTwice();
      expect(
        (await socialRows()).map((w) => w.socialVaultId),
        everyElement(isNull),
      );
      expect(await vaults.cached(wallet.vaultId), isNull);
      expect((await vaults.retiredVaults()).single.apiOrigin, here);

      origin = 'https://staging.test:443';
      final requests = backend.signedRequests;
      for (var day = 1; day <= 45; day++) {
        now = now.add(const Duration(days: 1));
        await auth.checkVaults();
      }
      expect(backend.signedRequests, requests);
      expect(platform.count, 1);
      expect(await vaults.retiredVaults(), hasLength(1));
      expect(
        (await socialRows()).map((w) => w.socialVaultId),
        everyElement(isNull),
      );
    });
  });

  // Unlinking writes the wallet's rows and then the recovery graph, and
  // only then drops this device's copy of the vault. The graph write can
  // fail with the rows already unlinked — after which nothing names the
  // vault any more.
  group('a Delete wallet backup cut short after the rows were unlinked', () {
    Future<({String accountId, String vaultId, List<String> rowIds})>
    cutShort() async {
      final wallet = await signedIn();
      graphUnwritable = true;
      await expectLater(
        auth.deleteWalletBackup(wallet.accountId),
        throwsA(isA<GraphSyncException>()),
      );
      // The backend deleted the vault and the rows are unlinked...
      expect(backend.vault, isNull);
      expect(
        (await socialRows()).map((w) => w.socialVaultId),
        everyElement(isNull),
      );
      // ...with the phrase already safe under the account...
      expect(
        await storage.loadSocialAccountMnemonic(wallet.accountId),
        isNotNull,
      );
      // ...but the vault's data key and its own copy of the phrase are
      // still here, and the stored graph still names the vault.
      expect(await vaults.loadDataKey(wallet.vaultId), isNotNull);
      expect(await storage.loadSocialVaultMnemonic(wallet.vaultId), isNotNull);
      expect(vaultStore['mallow_account_graph'], contains(wallet.vaultId));
      expect((await vaults.pendingUnlinks()).single.vaultId, wallet.vaultId);
      return wallet;
    }

    Future<void> expectFinished(
      ({String accountId, String vaultId, List<String> rowIds}) wallet,
    ) async {
      expect(await vaults.loadDataKey(wallet.vaultId), isNull);
      expect(await storage.loadSocialVaultMnemonic(wallet.vaultId), isNull);
      expect(await vaults.cached(wallet.vaultId), isNull);
      expect(
        vaultStore['mallow_account_graph'],
        isNot(contains(wallet.vaultId)),
      );
      expect(await vaults.pendingUnlinks(), isEmpty);
      expect(
        await storage.loadSocialAccountMnemonic(wallet.accountId),
        isNotNull,
        reason: 'the phrase is the wallet\'s only backup now',
      );
      final rows = await socialRows();
      expect([for (final w in rows) w.id]..sort(), wallet.rowIds);
      for (final w in rows) {
        expect(await storage.loadPrivateKey(w.id), isNotNull);
      }
    }

    test('asking again finishes it', () async {
      final wallet = await cutShort();

      // Still failing: the retry says so instead of "done".
      await expectLater(
        auth.deleteWalletBackup(wallet.accountId),
        throwsA(isA<GraphSyncException>()),
      );
      expect(await vaults.loadDataKey(wallet.vaultId), isNotNull);

      graphUnwritable = false;
      await auth.deleteWalletBackup(wallet.accountId);
      await expectFinished(wallet);
      // And once more is a no-op.
      await auth.deleteWalletBackup(wallet.accountId);
      await expectFinished(wallet);
    });

    test('the next vault check finishes it, without being asked', () async {
      final wallet = await cutShort();
      await auth.checkVaults();
      expect(
        await vaults.loadDataKey(wallet.vaultId),
        isNotNull,
        reason: 'not while the graph still cannot be written',
      );

      graphUnwritable = false;
      await auth.checkVaults();
      await expectFinished(wallet);
      expect(prompts.backupGone, isEmpty);
    });

    test('an unlink on "not found" that was cut short is finished the same '
        'way, and keeps the entries', () async {
      final wallet = await signedIn();
      backend.missing = true;
      await auth.checkVaults();
      now = now.add(const Duration(hours: 24));
      graphUnwritable = true;
      await auth.checkVaults();
      expect(
        (await socialRows()).map((w) => w.socialVaultId),
        everyElement(isNull),
      );
      expect(await vaults.loadDataKey(wallet.vaultId), isNotNull);

      graphUnwritable = false;
      await auth.checkVaults();
      await expectFinished(wallet);
      expect(platform.count, 1, reason: 'kept, as after any "not found"');
      expect(
        await storage.loadSocialVaultRetiredKey(wallet.vaultId),
        isNotNull,
      );
    });

    test('a wallet that is linked again before the unlink was finished '
        'keeps its copy of the vault', () async {
      final wallet = await signedIn();
      // Written down, and then the app died before the rows were touched.
      await vaults.beginUnlink(wallet.vaultId, wallet.accountId);
      await auth.checkVaults();
      expect(await vaults.pendingUnlinks(), isEmpty);
      expect((await socialRows()).map((w) => w.socialVaultId).toSet(), {
        wallet.vaultId,
      });
      expect(await vaults.loadDataKey(wallet.vaultId), isNotNull);
      expect(await storage.loadSocialVaultMnemonic(wallet.vaultId), isNotNull);
    });
  });

  group('a device whose sign-in key was replaced elsewhere', () {
    test('is told once, and again only if it happens again', () async {
      final wallet = await signedIn();
      backend.rotatedElsewhere = true;
      await auth.checkVaults();
      expect(await vaults.loadDataKey(wallet.vaultId), isNull);
      expect(prompts.keyReplaced, ['google']);

      // Later checks have no key to read with, and say nothing more.
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(hours: 1));
        await auth.checkVaults();
      }
      expect(prompts.keyReplaced, ['google']);

      // Signed in again, and replaced again.
      backend.rotatedElsewhere = false;
      await auth.signInWithGoogle();
      backend.rotatedElsewhere = true;
      now = now.add(const Duration(hours: 1));
      await auth.checkVaults();
      expect(prompts.keyReplaced, ['google', 'google']);
    });

    test('a notice that could not be shown stays due', () async {
      await signedIn();
      backend.rotatedElsewhere = true;
      prompts.canShow = false;
      await auth.checkVaults();
      expect(prompts.keyReplaced, isEmpty);

      prompts.canShow = true;
      now = now.add(const Duration(hours: 1));
      await auth.checkVaults();
      expect(prompts.keyReplaced, ['google']);
    });

    test('a shell that does not show this notice is not asked, and the '
        'check goes on', () async {
      final wallet = await signedIn();
      auth.prompts = _PromptsWithoutKeyNotice();
      backend.rotatedElsewhere = true;
      await auth.checkVaults();
      expect(await vaults.staleKeyNoticeDue(wallet.vaultId), isTrue);
    });
  });

  test('a delete the backend answers "not found" unlinks the wallet and '
      'keeps the entries', () async {
    final wallet = await signedIn();
    backend.missing = true;
    await auth.deleteWalletBackup(wallet.accountId);

    expect(
      (await socialRows()).map((w) => w.socialVaultId),
      everyElement(isNull),
    );
    expect(platform.count, 1, reason: 'no delete was seen to go through');
    expect((await vaults.retiredVaults()).single.announced, isTrue);
    await auth.checkVaults();
    expect(prompts.backupGone, isEmpty, reason: 'the user did this');
  });
}

/// The backend: one identity, at most one vault. [missing] makes every
/// signed request for the vault answer "not found" while `open` is refused
/// too — a backend that does not know the vault. [offline] gives no answer.
class _Backend implements SocialVaultApi {
  api.SocialVault? vault;
  bool missing = false;
  bool offline = false;
  int creates = 0;

  /// Something in front of the backend answers every signed request with a
  /// 404 of its own: no code. The API layer reads that as "unavailable".
  bool bare404 = false;

  /// The vault's key was rotated on another device: a signature by this
  /// device's key no longer verifies.
  bool rotatedElsewhere = false;

  /// How many signed requests (status reads, deletes) were sent.
  int signedRequests = 0;

  static const _notFound = SocialVaultApiException(
    SocialVaultApiError.notFound,
    status: 404,
    code: 'vault_not_found',
  );

  void _reach() {
    if (offline) {
      throw const SocialVaultApiException(SocialVaultApiError.unavailable);
    }
  }

  void _reachSigned() {
    signedRequests++;
    _reach();
    if (bare404) {
      throw const SocialVaultApiException(
        SocialVaultApiError.unavailable,
        status: 404,
      );
    }
    if (rotatedElsewhere) {
      throw const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
        code: 'invalid_vault_signature',
      );
    }
  }

  @override
  Future<api.SocialVaultOpenResponse> open(String idToken) async {
    _reach();
    return api.SocialVaultOpenResponse(
      provider: api.SocialVaultProvider.google,
      emailHint: 'person@example.test',
      identityId: _identityId,
      identityToken: 'identity-token',
      vault: missing ? null : vault,
    );
  }

  @override
  Future<api.SocialVault> create(api.SocialVaultCreateRequest request) async {
    _reach();
    creates++;
    return vault = api.SocialVault(
      vaultId: request.vaultId,
      revision: 1,
      payloadNonce: request.payloadNonce,
      payloadCiphertext: request.payloadCiphertext,
      vaultPublicKey: request.vaultPublicKey,
      slots: [
        for (final s in request.slots)
          api.SocialVaultSlot.fromJson({
            ...s.toJson(),
            'createdAt': '2026-11-10T12:00:00Z',
          }),
      ],
      pendingDeletion: null,
      createdAt: '2026-11-10T12:00:00Z',
      updatedAt: '2026-11-10T12:00:00Z',
    );
  }

  @override
  Future<api.SocialVault> status({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
  }) async {
    _reachSigned();
    if (missing || vault?.vaultId != vaultId) throw _notFound;
    return vault!;
  }

  @override
  Future<void> delete({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
  }) async {
    _reachSigned();
    if (missing || vault?.vaultId != vaultId) throw _notFound;
    vault = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The platform keychain: entries per (vault, slot), never overwritten.
class _Platform implements PlatformSlotStore {
  final entries = <String, Map<String, PlatformSlotEntry>>{};

  int get count => entries.values.fold(0, (n, m) => n + m.length);

  @override
  bool get backupCanLoseEncryption => false;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> isBackupEncrypted() async => true;

  @override
  Future<List<PlatformSlotRef>> listAll() async => [
    for (final MapEntry(key: vaultId, value: slots) in entries.entries)
      for (final slotId in slots.keys)
        PlatformSlotRef(vaultId: vaultId, slotId: slotId),
  ];

  @override
  Future<bool> setCloudBackup(
    String vaultId,
    String slotId, {
    required bool enabled,
  }) async => enabled;

  @override
  Future<List<PlatformSlotEntry>> readAll(String vaultId) async => [
    ...?entries[vaultId]?.values,
  ];

  @override
  Future<bool> add(String vaultId, PlatformSlotEntry entry) async {
    final forVault = entries.putIfAbsent(vaultId, () => {});
    if (forVault.containsKey(entry.slotId)) {
      throw PlatformException(code: 'exists');
    }
    forVault[entry.slotId] = entry;
    return true;
  }

  @override
  Future<void> delete(String vaultId, String slotId) async =>
      entries[vaultId]?.remove(slotId);
}

class _NoPasskeys implements PasskeyPrfAuthenticator {
  @override
  Future<bool> isSupported() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Identity implements SocialIdentityProvider {
  int _tokens = 0;

  @override
  bool isConfigured(String provider) => true;

  @override
  Future<String?> idToken(
    String provider, {
    bool silent = false,
    bool chooseAccount = false,
  }) async => 'id-token-${++_tokens}';
}

class _Prompts extends _PromptsWithoutKeyNotice
    implements SocialVaultKeyReplacedPrompt {
  /// Whether the replaced-key notice can be shown right now.
  bool canShow = true;
  final keyReplaced = <String>[];

  @override
  Future<bool> signInKeyReplaced({required String provider}) async {
    if (!canShow) return false;
    keyReplaced.add(provider);
    return true;
  }
}

class _PromptsWithoutKeyNotice implements SocialVaultPrompts {
  final backupGone = <String>[];

  @override
  Future<bool> backupNoLongerStored({required String provider}) async {
    backupGone.add(provider);
    return true;
  }

  @override
  Future<SocialVaultCreateChoice> confirmCreate({
    required String provider,
    String? emailHint,
    bool hasWalletHere = false,
    String? walletAccountEmail,
  }) async => SocialVaultCreateChoice.create;

  @override
  Future<bool> offerPasskey(String provider) async => false;

  @override
  Future<bool> reauthenticate() async => true;

  @override
  Future<bool> wrongAccount({
    required String provider,
    String? expectedEmail,
    String? signedInEmail,
  }) async => false;

  @override
  Future<void> backupIncomplete({required String provider}) async =>
      fail('the backup step failed');

  @override
  Future<void> reviewVault(String vaultId) async {}

  @override
  Future<bool?> offerKeyReplacement() async => null;
}
