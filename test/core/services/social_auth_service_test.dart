import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/social_vault/platform_backup_guard.dart';
import 'package:mallow_wallet/core/social_vault/social_identity.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_api.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_crypto.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_service.dart';
import 'package:mallow_wallet/core/social_vault/social_wallet_keys.dart';

/// The shared test phrase (BIP39's all-`abandon` vector): a fixed bip39 vault.
const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about';

/// A [WalletRepository] stand-in for the calls sign-in and recovery make.
class _RecordingWalletRepository implements WalletRepository {
  _RecordingWalletRepository(this.rowsByAccount);

  final Map<String, List<WalletInfo>> rowsByAccount;

  int storeCalls = 0;
  SocialChainCredential? storedSolana;
  SocialChainCredential? storedEthereum;
  SocialChainCredential? storedTezos;
  String? storedVaultId;
  String? storedIdentityId;

  final linked = <String, String?>{};

  /// Shared with the vault fake, so a test can read the order of the steps
  /// the two take.
  List<String> events = [];

  @override
  Future<List<WalletInfo>> getWalletsForAccount(String accountId) async =>
      rowsByAccount[accountId] ?? const <WalletInfo>[];

  @override
  Future<List<WalletInfo>> getAllWallets() async =>
      rowsByAccount.values.expand((rows) => rows).toList();

  @override
  Future<void> setSocialVaultId(String accountId, String? vaultId) async {
    events.add('unlink');
    linked[accountId] = vaultId;
    rowsByAccount[accountId] = [
      for (final w in rowsByAccount[accountId] ?? const <WalletInfo>[])
        w.copyWith(
          socialVaultId: vaultId,
          socialIdentityId: vaultId == null ? null : w.socialIdentityId,
        ),
    ];
  }

  @override
  Future<({List<WalletInfo> wallets, bool existed})> addSocialAccount({
    required String provider,
    required String name,
    required SocialChainCredential solana,
    required SocialChainCredential ethereum,
    required SocialChainCredential tezos,
    String? socialVaultId,
    String? socialIdentityId,
  }) async {
    storeCalls++;
    storedSolana = solana;
    storedEthereum = ethereum;
    storedTezos = tezos;
    storedVaultId = socialVaultId;
    storedIdentityId = socialIdentityId;
    return (
      wallets: [
        WalletInfo(
          id: 'new-sol',
          address: solana.address,
          name: name,
          walletType: WalletType.social,
          chain: 'solana',
          socialProvider: provider,
          socialVaultId: socialVaultId,
        ),
      ],
      existed: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

api.SocialVault _vault(String vaultId) => api.SocialVault(
  vaultId: vaultId,
  revision: 1,
  payloadNonce: 'AAAAAAAAAAAAAAAA',
  payloadCiphertext: 'AAAA',
  vaultPublicKey: 'PK',
  slots: const [],
  pendingDeletion: null,
  createdAt: '2026-11-09T00:00:00Z',
  updatedAt: '2026-11-09T00:00:00Z',
);

/// The identity id the backend derives for issuer
/// `https://accounts.google.com`, subject `1234567890`: the account the
/// wallets in these tests belong to. The app never computes it.
const _identityA = '8ca57526739bfeac48d22f9d47d76f1a';

/// Some other account.
const _identityB = '00112233445566778899aabbccddeeff';

api.SocialVaultOpenResponse _opened(
  api.SocialVault? vault, {
  String identityId = _identityA,
  String? emailHint = 'person@example.test',
}) => api.SocialVaultOpenResponse(
  provider: api.SocialVaultProvider.google,
  emailHint: emailHint,
  identityId: identityId,
  identityToken: 'identity-token',
  vault: vault,
);

class _FakeIdentity implements SocialIdentityProvider {
  int calls = 0;
  final silentFlags = <bool>[];
  final chooseFlags = <bool>[];
  Completer<void> gate = Completer<void>()..complete();
  bool cancel = false;

  @override
  bool isConfigured(String provider) => true;

  @override
  Future<String?> idToken(
    String provider, {
    bool silent = false,
    bool chooseAccount = false,
  }) async {
    calls++;
    silentFlags.add(silent);
    chooseFlags.add(chooseAccount);
    await gate.future;
    return cancel ? null : 'id-token-$calls';
  }
}

class _FakeApi implements SocialVaultApi {
  final opens = <api.SocialVaultOpenResponse>[];

  /// Thrown by the next `open` calls, one each, before any answer.
  final errors = <SocialVaultApiException>[];
  final tokens = <String>[];

  @override
  Future<api.SocialVaultOpenResponse> open(String idToken) async {
    tokens.add(idToken);
    if (errors.isNotEmpty) throw errors.removeAt(0);
    return opens.length > 1 ? opens.removeAt(0) : opens.single;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVaults implements SocialVaultService {
  _FakeVaults(this.fakeApi);

  final _FakeApi fakeApi;
  SocialVaultPayload payload = const SocialVaultPayload(_mnemonic);
  int unlockCalls = 0;
  int createCalls = 0;
  int persistCalls = 0;
  bool createLosesRace = false;
  SocialVaultPayload? createdWith;
  Uint8List? localDataKey;
  CachedSocialVault? localCache;

  @override
  SocialVaultApi get vaultApi => fakeApi;

  @override
  Future<UnlockedSocialVault> unlock(api.SocialVault vault) async {
    unlockCalls++;
    return UnlockedSocialVault(
      vault: vault,
      dataKey: Uint8List(32),
      payload: payload,
      openedWithSlotId: 'slot',
    );
  }

  @override
  Future<UnlockedSocialVault> create({
    required String identityToken,
    required SocialVaultPayload payload,
    required String userName,
  }) async {
    createCalls++;
    createdWith = payload;
    if (createLosesRace) {
      throw const SocialVaultApiException(
        SocialVaultApiError.vaultExists,
        status: 409,
        code: 'vault_exists',
      );
    }
    return UnlockedSocialVault(
      vault: _vault('created-vault'),
      dataKey: Uint8List(32),
      payload: payload,
      openedWithSlotId: 'slot',
    );
  }

  bool bumpOnPlatformSlot = false;
  int? persistedRevision;
  Object? persistError;

  @override
  Future<api.SocialVault> ensurePlatformSlot(
    api.SocialVault vault,
    Uint8List dataKey,
  ) async => bumpOnPlatformSlot
      ? api.SocialVault.fromJson({
          ...vault.toJson(),
          'revision': vault.revision + 1,
        })
      : vault;

  bool passkeysHere = false;
  int passkeysAdded = 0;

  @override
  Future<bool> passkeysAvailable() async => passkeysHere;

  @override
  Future<api.SocialVault> addPasskeySlot(
    api.SocialVault vault,
    Uint8List dataKey, {
    required String userName,
  }) async {
    events.add('addPasskey');
    passkeysAdded++;
    return vault;
  }

  /// The order of the steps that delete or keep something.
  List<String> events = [];
  final forgottenPlatformEntries = <String>[];
  final forgottenLocal = <String>[];
  int sweeps = 0;

  @override
  Future<void> sweepPlatformEntries(String vaultId, Uint8List dataKey) async =>
      sweeps++;

  /// Unlinks written down and not yet crossed out by [forgetLocal].
  final unlinking = <PendingSocialVaultUnlink>[];
  Object? beginUnlinkError;

  @override
  Future<void> beginUnlink(String vaultId, String accountId) async {
    if (beginUnlinkError != null) throw beginUnlinkError!;
    events.add('beginUnlink');
    unlinking
      ..removeWhere((u) => u.vaultId == vaultId)
      ..add(PendingSocialVaultUnlink(vaultId: vaultId, accountId: accountId));
  }

  @override
  Future<List<PendingSocialVaultUnlink>> pendingUnlinks() async => [
    ...unlinking,
  ];

  @override
  Future<void> dropPendingUnlink(String vaultId) async =>
      unlinking.removeWhere((u) => u.vaultId == vaultId);

  /// Vaults whose data key a status read found stale, not yet said.
  final staleKeyNotices = <String>{};

  @override
  Future<bool> staleKeyNoticeDue(String vaultId) async =>
      staleKeyNotices.contains(vaultId);

  @override
  Future<void> markStaleKeyAnnounced(String vaultId) async =>
      staleKeyNotices.remove(vaultId);

  @override
  Future<void> forgetPlatformEntries(String vaultId) async {
    events.add('forgetPlatformEntries');
    forgottenPlatformEntries.add(vaultId);
  }

  Object? forgetLocalError;

  @override
  Future<void> forgetLocal(String vaultId) async {
    if (forgetLocalError != null) throw forgetLocalError!;
    events.add('forgetLocal');
    forgottenLocal.add(vaultId);
    unlinking.removeWhere((u) => u.vaultId == vaultId);
  }

  bool phraseHere = true;
  final keptForAccount = <String, String>{};

  @override
  Future<bool> hasMnemonic(String vaultId) async => phraseHere;

  @override
  Future<void> keepMnemonicForAccount(String vaultId, String accountId) async {
    events.add('keepMnemonic');
    keptForAccount[vaultId] = accountId;
  }

  bool canSignDelete = true;
  Object? deleteError;

  /// What the backend answers a signed delete with.
  SocialVaultDeletion deletion = SocialVaultDeletion.deleted;

  @override
  Future<SocialVaultDeletion> deleteVaultWithLocalKey(String vaultId) async {
    if (!canSignDelete) return SocialVaultDeletion.noKey;
    if (deleteError != null) throw deleteError!;
    events.add('delete');
    return deletion;
  }

  /// The vaults wallets were unlinked from on a "not found" answer.
  final retired = <RetiredSocialVault>[];
  final retiredChecks = <String, RetiredSocialVaultCheck>{};
  final retiredChecked = <String>[];
  final forgottenRetired = <String>[];

  @override
  Future<void> retire(
    String vaultId, {
    required String accountId,
    required String provider,
    String? identityId,
    bool announced = false,
  }) async {
    events.add('retire');
    retired.add(
      RetiredSocialVault(
        vaultId: vaultId,
        accountId: accountId,
        provider: provider,
        identityId: identityId,
        emailHint: localCache?.emailHint,
        unlinkedAt: DateTime.utc(2026, 11, 10),
        lastCheckedAt: DateTime.utc(2026, 11, 10),
        announced: announced,
      ),
    );
  }

  @override
  Future<List<RetiredSocialVault>> retiredVaults() async => [...retired];

  @override
  Future<void> markRetiredAnnounced(String vaultId) async {
    final index = retired.indexWhere((r) => r.vaultId == vaultId);
    retired[index] = retired[index].copyWith(announced: true);
  }

  @override
  Future<void> forgetRetired(String vaultId) async {
    forgottenRetired.add(vaultId);
    retired.removeWhere((r) => r.vaultId == vaultId);
  }

  @override
  Future<RetiredSocialVaultCheck> checkRetired(String vaultId) async {
    retiredChecked.add(vaultId);
    return retiredChecks[vaultId] ?? const RetiredSocialVaultCheck.nothing();
  }

  final statuses = <String, SocialVaultStatus>{};
  final statusReads = <String>[];
  Completer<void>? statusGate;

  @override
  Future<SocialVaultStatus> checkStatus(
    String vaultId, {
    bool force = false,
  }) async {
    statusReads.add(vaultId);
    await statusGate?.future;
    return statuses[vaultId] ?? SocialVaultStatus.failed;
  }

  /// What the check of the phone's backup answers, and how often it ran.
  PlatformBackupStatus backupStatus = PlatformBackupStatus.protected;
  Object? backupCheckError;
  int backupChecks = 0;
  int? statusReadsBeforeBackupCheck;
  int replacementsMarkedOffered = 0;
  int exposuresDismissed = 0;

  @override
  Future<PlatformBackupStatus> checkPlatformBackup() async {
    backupChecks++;
    if (backupCheckError != null) throw backupCheckError!;
    statusReadsBeforeBackupCheck = statusReads.length;
    return backupStatus;
  }

  @override
  Future<void> markKeyReplacementOffered() async => replacementsMarkedOffered++;

  @override
  Future<void> dismissBackupExposure([String? vaultId]) async =>
      exposuresDismissed++;

  Set<String>? sweptAbandonedWith;

  @override
  Future<void> sweepAbandonedCreates({
    required Set<String> referencedVaultIds,
  }) async => sweptAbandonedWith = referencedVaultIds;

  @override
  Future<void> persist(
    UnlockedSocialVault unlocked, {
    required String provider,
    String? emailHint,
  }) async {
    persistCalls++;
    if (persistError != null) throw persistError!;
    persistedRevision = unlocked.vault.revision;
  }

  @override
  Future<Uint8List?> loadDataKey(String vaultId) async => localDataKey;

  @override
  Future<CachedSocialVault?> cached(String vaultId) async => localCache;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePrompts implements SocialVaultPrompts {
  List<String> events = [];

  bool acceptPasskey = false;
  bool reauthPasses = true;

  @override
  Future<bool> offerPasskey(String provider) async {
    events.add('offer');
    return acceptPasskey;
  }

  @override
  Future<bool> reauthenticate() async {
    events.add('reauth');
    return reauthPasses;
  }

  /// Answers to [confirmCreate], one per call; the last one repeats.
  List<SocialVaultCreateChoice> createAnswers = [
    SocialVaultCreateChoice.create,
  ];
  final createQuestions =
      <({String? emailHint, bool hasWalletHere, String? walletAccountEmail})>[];

  @override
  Future<SocialVaultCreateChoice> confirmCreate({
    required String provider,
    String? emailHint,
    bool hasWalletHere = false,
    String? walletAccountEmail,
  }) async {
    createQuestions.add((
      emailHint: emailHint,
      hasWalletHere: hasWalletHere,
      walletAccountEmail: walletAccountEmail,
    ));
    return createAnswers.length > 1
        ? createAnswers.removeAt(0)
        : createAnswers.single;
  }

  bool useAnotherAccount = false;
  final wrongAccounts = <({String? expectedEmail, String? signedInEmail})>[];

  @override
  Future<bool> wrongAccount({
    required String provider,
    String? expectedEmail,
    String? signedInEmail,
  }) async {
    wrongAccounts.add((
      expectedEmail: expectedEmail,
      signedInEmail: signedInEmail,
    ));
    return useAnotherAccount;
  }

  final reviewed = <String>[];

  @override
  Future<void> reviewVault(String vaultId) async => reviewed.add(vaultId);

  /// The answer to the key-replacement offer; null is "could not be shown".
  bool? replaceKeys = false;
  int replacementOffers = 0;

  /// Whether the "backup no longer stored" notice can be shown.
  bool canAnnounce = true;
  final backupGoneFor = <String>[];

  @override
  Future<bool> backupNoLongerStored({required String provider}) async {
    if (!canAnnounce) return false;
    backupGoneFor.add(provider);
    return true;
  }

  @override
  Future<bool?> offerKeyReplacement() async {
    replacementOffers++;
    return replaceKeys;
  }

  final incomplete = <String>[];

  @override
  Future<void> backupIncomplete({required String provider}) async =>
      incomplete.add(provider);
}

WalletInfo _wallet({
  required String id,
  required String address,
  required String chain,
  WalletType walletType = WalletType.social,
  String? socialProvider = 'google',
  String accountId = 'account-1',
}) => WalletInfo(
  id: id,
  address: address,
  name: 'Google Wallet',
  walletType: walletType,
  chain: chain,
  socialProvider: socialProvider,
  accountId: accountId,
);

/// The three rows of one social account.
List<WalletInfo> _socialAccountRows({String? provider = 'google'}) => [
  _wallet(
    id: 'sol',
    address: 'So1anaAddress11111111111111111111111111111',
    chain: 'solana',
    socialProvider: provider,
  ),
  _wallet(
    id: 'eth',
    address: '0x1111111111111111111111111111111111111111',
    chain: 'ethereum',
    socialProvider: provider,
  ),
  _wallet(
    id: 'tez',
    address: 'tz1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    chain: 'tezos',
    socialProvider: provider,
  ),
];

void main() {
  group('SocialAuthService.recoveryTargetFor', () {
    // Recovery is handed an account id and must decide, before any sign-in,
    // which identity to authenticate as and which address the recovery has to
    // reproduce. Anything it cannot answer fails there, rather than sign the
    // user in and store a key for an address the row does not represent.

    test('returns the provider and the Solana address of a social account', () {
      final target = SocialAuthService.recoveryTargetFor(_socialAccountRows());

      expect(target.provider, 'google');
      expect(
        target.solanaAddress,
        'So1anaAddress11111111111111111111111111111',
      );
    });

    test('reads the provider off whichever social row carries it', () {
      final rows = _socialAccountRows(provider: 'apple');
      expect(SocialAuthService.recoveryTargetFor(rows).provider, 'apple');
    });

    test('ignores non-social rows in the same account', () {
      final rows = [
        _wallet(
          id: 'watch',
          address: 'WatchOnly1111111111111111111111111111111111',
          chain: 'solana',
          walletType: WalletType.viewOnly,
          socialProvider: null,
        ),
        ..._socialAccountRows(),
      ];

      final target = SocialAuthService.recoveryTargetFor(rows);
      expect(target.provider, 'google');
      // The social Solana row, not the view-only one sharing the chain.
      expect(
        target.solanaAddress,
        'So1anaAddress11111111111111111111111111111',
      );
    });

    test('throws when the account holds no social row', () {
      final rows = [
        _wallet(
          id: 'hd',
          address: 'HdWallet111111111111111111111111111111111111',
          chain: 'solana',
          walletType: WalletType.hd,
          socialProvider: null,
        ),
      ];

      expect(
        () => SocialAuthService.recoveryTargetFor(rows),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('throws when the social rows carry no provider', () {
      // Nothing records which Google/Apple identity the rows came from, so
      // there is no sign-in to run.
      expect(
        () => SocialAuthService.recoveryTargetFor(
          _socialAccountRows(provider: null),
        ),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('throws on a provider this service cannot authenticate with', () {
      expect(
        () => SocialAuthService.recoveryTargetFor(
          _socialAccountRows(provider: 'facebook'),
        ),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('throws when the account has no social Solana row', () {
      final rows = _socialAccountRows()
          .where((w) => w.chain != 'solana')
          .toList();

      expect(
        () => SocialAuthService.recoveryTargetFor(rows),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('throws on an empty row list', () {
      expect(
        () => SocialAuthService.recoveryTargetFor(const []),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('says whether the account is one from the older sign-in', () {
      expect(
        SocialAuthService.recoveryTargetFor(_socialAccountRows()).legacy,
        isFalse,
      );
      final legacy = [
        for (final w in _socialAccountRows()) w.copyWith(legacySocial: true),
      ];
      final target = SocialAuthService.recoveryTargetFor(legacy);
      expect(target.legacy, isTrue);
      expect(target.vaultId, isNull);
    });
  });

  group('SocialAuthService.requireDerivedAddressMatches', () {
    // A recovery that comes back with another address is not a transient
    // error to retry: it opened a different wallet, and storing that key
    // against the row would produce valid signatures from the wrong address,
    // which fails silently downstream.

    test('accepts a login that reproduces the row address', () {
      expect(
        () => SocialAuthService.requireDerivedAddressMatches(
          expected: 'So1anaAddress11111111111111111111111111111',
          derived: 'So1anaAddress11111111111111111111111111111',
        ),
        returnsNormally,
      );
    });

    test('rejects a different derived address', () {
      expect(
        () => SocialAuthService.requireDerivedAddressMatches(
          expected: 'So1anaAddress11111111111111111111111111111',
          derived: 'Different2222222222222222222222222222222222',
        ),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('is case-sensitive — base58 addresses are', () {
      expect(
        () => SocialAuthService.requireDerivedAddressMatches(
          expected: 'So1anaAddress11111111111111111111111111111',
          derived: 'so1ANAaddress11111111111111111111111111111',
        ),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });
  });

  group('SocialAuthService with the social vault', () {
    late _RecordingWalletRepository repository;
    late _FakeIdentity identity;
    late _FakeApi fakeApi;
    late _FakeVaults vaults;
    late SocialAuthService service;
    late SocialWalletKeys bip39Keys;

    late _FakePrompts prompts;

    List<WalletInfo> rowsFor(
      String accountId,
      SocialWalletKeys keys, {
      String? vaultId = 'vault-1',
      String? identityId = _identityA,
    }) => [
      for (final (id, chain, address) in [
        ('sol', 'solana', keys.solanaAddress),
        ('eth', 'ethereum', keys.ethereumAddress),
        ('tez', 'tezos', keys.tezosAddress),
      ])
        WalletInfo(
          id: '$accountId-$id',
          address: address,
          name: 'Google Wallet',
          walletType: WalletType.social,
          chain: chain,
          socialProvider: 'google',
          socialVaultId: vaultId,
          socialIdentityId: vaultId == null ? null : identityId,
          accountId: accountId,
        ),
    ];

    setUp(() async {
      bip39Keys = await SocialWalletKeys.fromPayload(
        const SocialVaultPayload(_mnemonic),
      );
      repository = _RecordingWalletRepository({
        'account-1': rowsFor('account-1', bip39Keys),
        'account-2': rowsFor('account-2', bip39Keys, vaultId: 'vault-2'),
        // A wallet from the older sign-in: no vault, and marked.
        'legacy': [
          for (final w in _socialAccountRows())
            w.copyWith(accountId: 'legacy', legacySocial: true),
        ],
        // A vault wallet whose backup was deleted: no vault, not marked.
        'unlinked': rowsFor('unlinked', bip39Keys, vaultId: null),
      });
      GetIt.instance.registerSingleton<WalletRepository>(repository);
      identity = _FakeIdentity();
      fakeApi = _FakeApi()..opens.add(_opened(_vault('vault-1')));
      vaults = _FakeVaults(fakeApi);
      prompts = _FakePrompts();
      // One log for every step that deletes, keeps or asks something.
      final events = <String>[];
      vaults.events = events;
      repository.events = events;
      prompts.events = events;
      service = SocialAuthService(identity, vaults)..prompts = prompts;
    });

    tearDown(() async => GetIt.instance.reset());

    group('sign-in', () {
      test('opens an existing vault and stores its keys', () async {
        final results = <SocialAuthResult>[];
        final sub = service.onSignInComplete.listen(results.add);
        final result = await service.signInWithGoogle();
        await pumpEventQueue();
        await sub.cancel();

        expect(result!.wallet.address, bip39Keys.solanaAddress);
        expect(results, hasLength(1));
        expect(vaults.unlockCalls, 1);
        expect(vaults.createCalls, 0);
        expect(repository.storedVaultId, 'vault-1');
        expect(
          repository.storedIdentityId,
          _identityA,
          reason: 'the link records whose vault it is',
        );
        expect(vaults.persistCalls, 1);
        expect(prompts.createQuestions, isEmpty);
      });

      test('stores the derived keys in the imported-key formats', () async {
        await service.signInWithGoogle();
        expect(repository.storedSolana!.storedKey, bip39Keys.solanaStoredKey);
        expect(repository.storedEthereum!.storedKey, bip39Keys.ethereumKeyHex);
        expect(repository.storedTezos!.storedKey, bip39Keys.tezosSeedHex);
        expect(
          repository.storedTezos!.storedKey,
          isNot(repository.storedEthereum!.storedKey),
          reason: 'a phrase wallet derives Tezos on its own path',
        );
      });

      test('a new identity always gets a fresh phrase wallet', () async {
        // No vault for this identity. Nothing else is asked about it: one
        // sign-in, one open, one create — and what is created is a new
        // recovery phrase, whatever wallets the device already holds
        // (`legacy` above is one from the older sign-in, same provider).
        fakeApi.opens
          ..clear()
          ..add(_opened(null));
        final result = await service.signInWithGoogle();
        expect(result, isNotNull);
        expect(identity.calls, 1);
        expect(vaults.createCalls, 1);
        final created = vaults.createdWith!;
        expect(created.mnemonic.split(' '), hasLength(12));
        expect(created.mnemonic, isNot(_mnemonic));
        final keys = await SocialWalletKeys.fromPayload(created);
        expect(repository.storedSolana!.address, keys.solanaAddress);
        expect(repository.storedVaultId, 'created-vault');
        expect(
          repository.rowsByAccount['legacy']!.map((w) => w.address),
          isNot(contains(keys.solanaAddress)),
        );
      });

      test('two new identities get two different wallets', () async {
        fakeApi.opens
          ..clear()
          ..add(_opened(null));
        await service.signInWithGoogle();
        final first = vaults.createdWith!.mnemonic;
        await service.signInWithGoogle();
        expect(vaults.createdWith!.mnemonic, isNot(first));
      });

      test('losing the creation race opens the winner\'s vault', () async {
        fakeApi.opens
          ..clear()
          ..add(_opened(null))
          ..add(_opened(_vault('winner')));
        vaults.createLosesRace = true;
        await service.signInWithGoogle();
        expect(vaults.unlockCalls, 1);
        expect(identity.silentFlags, [false, true]);
        expect(repository.storedVaultId, 'winner');
      });

      test('a failed backup step still publishes the account', () async {
        vaults.persistError = StateError('keychain');
        final results = <SocialAuthResult>[];
        final sub = service.onSignInComplete.listen(results.add);
        final result = await service.signInWithGoogle();
        await pumpEventQueue();
        await sub.cancel();
        expect(result, isNotNull);
        expect(results, hasLength(1));
        expect(repository.storeCalls, 1);
        expect(prompts.incomplete, ['google']);
      });

      test(
        'a cancelled provider sheet returns null and stores nothing',
        () async {
          identity.cancel = true;
          expect(await service.signInWithGoogle(), isNull);
          expect(repository.storeCalls, 0);
        },
      );

      test('a pending deletion or an unseen key is shown right after the '
          'sign-in', () async {
        await service.signInWithGoogle();
        expect(prompts.reviewed, ['vault-1']);
      });

      test('a second sign-in for the lost race that returns another account '
          'opens nothing', () async {
        fakeApi.opens
          ..clear()
          ..add(_opened(null))
          ..add(_opened(_vault('theirs'), identityId: _identityB));
        vaults.createLosesRace = true;
        await expectLater(
          service.signInWithGoogle(),
          throwsA(isA<SocialAccountMismatchException>()),
        );
        expect(vaults.unlockCalls, 0);
        expect(repository.storeCalls, 0);
      });

      test('a silent token the backend refuses as used falls back to an '
          'interactive sign-in, once', () async {
        // The lost race signs in a second time, silently. That token is one
        // the provider's SDK had cached, and the backend takes each once.
        final scripted = _ScriptedApi([
          _opened(null),
          const SocialVaultApiException(
            SocialVaultApiError.identityRejected,
            status: 401,
            code: 'invalid_id_token',
          ),
          _opened(_vault('winner')),
        ]);
        final scriptedService = SocialAuthService(
          identity,
          _FakeVaults(scripted)..createLosesRace = true,
        )..prompts = prompts;
        await scriptedService.signInWithGoogle();
        expect(identity.silentFlags, [false, true, false]);
        expect(scripted.calls, 3);
        expect(repository.storedVaultId, 'winner');
      });
    });

    group('creating a wallet', () {
      setUp(() {
        fakeApi.opens
          ..clear()
          ..add(_opened(null, identityId: _identityB, emailHint: 'new@x.test'));
      });

      test('asks first, naming the account', () async {
        // No vault wallet for the provider on this device.
        repository.rowsByAccount
          ..remove('account-1')
          ..remove('account-2');
        await service.signInWithGoogle();
        final question = prompts.createQuestions.single;
        expect(question.emailHint, 'new@x.test');
        expect(question.hasWalletHere, isFalse);
        expect(vaults.createCalls, 1);
        expect(repository.storedIdentityId, _identityB);
      });

      test('warns when this device already holds a vault wallet for the '
          'provider, naming the account it belongs to', () async {
        vaults.localCache = CachedSocialVault(
          vault: _vault('vault-1'),
          provider: 'google',
          emailHint: 'owner@x.test',
        );
        await service.signInWithGoogle();
        final question = prompts.createQuestions.single;
        expect(question.hasWalletHere, isTrue);
        expect(question.walletAccountEmail, 'owner@x.test');
      });

      test('declined creates nothing and leaves no state', () async {
        prompts.createAnswers = [SocialVaultCreateChoice.cancel];
        final results = <SocialAuthResult>[];
        final sub = service.onSignInComplete.listen(results.add);
        expect(await service.signInWithGoogle(), isNull);
        await pumpEventQueue();
        await sub.cancel();
        expect(vaults.createCalls, 0);
        expect(vaults.persistCalls, 0);
        expect(repository.storeCalls, 0);
        expect(repository.linked, isEmpty);
        expect(results, isEmpty);
        expect(prompts.events, isEmpty);
        expect(prompts.reviewed, isEmpty);
      });

      test('with nobody to ask, nothing is created', () async {
        service.prompts = null;
        await expectLater(service.signInWithGoogle(), throwsStateError);
        expect(vaults.createCalls, 0);
        expect(repository.storeCalls, 0);
      });

      test('"use another account" signs in again with an account chooser '
          'and opens what that account has', () async {
        prompts.createAnswers = [SocialVaultCreateChoice.useAnotherAccount];
        fakeApi.opens.add(_opened(_vault('vault-1')));
        final result = await service.signInWithGoogle();
        expect(result, isNotNull);
        expect(identity.chooseFlags, [false, true]);
        expect(vaults.createCalls, 0);
        expect(vaults.unlockCalls, 1);
        expect(repository.storedVaultId, 'vault-1');
        expect(repository.storedIdentityId, _identityA);
      });

      test('backing out of the account chooser creates nothing', () async {
        prompts.createAnswers = [SocialVaultCreateChoice.useAnotherAccount];
        var calls = 0;
        final choosy = _CancellingIdentity(() => ++calls > 1);
        final choosyService = SocialAuthService(choosy, vaults)
          ..prompts = prompts;
        expect(await choosyService.signInWithGoogle(), isNull);
        expect(vaults.createCalls, 0);
        expect(repository.storeCalls, 0);
      });
    });

    group('the passkey offer', () {
      setUp(() => vaults.passkeysHere = true);

      test('adds a passkey only after re-authentication', () async {
        prompts.acceptPasskey = true;
        await service.signInWithGoogle();
        expect(vaults.passkeysAdded, 1);
        expect(prompts.events, ['offer', 'reauth', 'addPasskey']);
      });

      test('a re-authentication that is not cleared adds nothing', () async {
        prompts
          ..acceptPasskey = true
          ..reauthPasses = false;
        final result = await service.signInWithGoogle();
        expect(result, isNotNull, reason: 'the wallet is still signed in');
        expect(vaults.passkeysAdded, 0);
        expect(prompts.events, ['offer', 'reauth']);
        expect(prompts.incomplete, isEmpty);
      });

      test('a declined offer asks for nothing more', () async {
        await service.signInWithGoogle();
        expect(vaults.passkeysAdded, 0);
        expect(prompts.events, ['offer']);
      });

      test('without prompts no passkey is added', () async {
        service.prompts = null;
        await service.signInWithGoogle();
        expect(vaults.passkeysAdded, 0);
      });
    });

    group('key recovery', () {
      test('reopens from this device\'s own copy without a sign-in', () async {
        vaults
          ..localDataKey = Uint8List(32)
          ..localCache = null;
        // Without a cached record the local key alone cannot open anything.
        await service.recoverKeysForAccount('account-1');
        expect(identity.calls, 1);

        identity.calls = 0;
        final dataKey = SocialVaultCrypto.newDataKey();
        final sealed = await SocialVaultCrypto.sealPayload(
          vaultId: 'AAAAAAAAAAAAAAAAAAAAAA',
          dataKey: dataKey,
          payload: const SocialVaultPayload(_mnemonic),
        );
        repository.rowsByAccount['local'] = rowsFor(
          'local',
          bip39Keys,
          vaultId: 'AAAAAAAAAAAAAAAAAAAAAA',
        );
        vaults
          ..localDataKey = dataKey
          ..localCache = CachedSocialVault(
            vault: api.SocialVault(
              vaultId: 'AAAAAAAAAAAAAAAAAAAAAA',
              revision: 1,
              payloadNonce: sealed.nonceWire,
              payloadCiphertext: sealed.ciphertextWire,
              vaultPublicKey: 'PK',
              slots: const [],
              pendingDeletion: null,
              createdAt: '',
              updatedAt: '',
            ),
            provider: 'google',
            emailHint: null,
          );
        await service.recoverKeysForAccount('local');
        expect(identity.calls, 0, reason: 'no sign-in needed');
        expect(repository.storedVaultId, 'AAAAAAAAAAAAAAAAAAAAAA');
      });

      test('refuses a sign-in that holds a different vault', () async {
        await expectLater(
          service.recoverKeysForAccount('account-2'),
          throwsA(isA<LegacySocialWalletException>()),
        );
        expect(repository.storeCalls, 0);
      });

      test(
        'refuses keys that derive a different address on any chain',
        () async {
          repository.rowsByAccount['account-1'] = [
            ...rowsFor('account-1', bip39Keys).where((w) => w.chain != 'tezos'),
            const WalletInfo(
              id: 'account-1-tez',
              address: 'tz1NotThisWallet',
              name: 'Google Wallet',
              walletType: WalletType.social,
              chain: 'tezos',
              socialProvider: 'google',
              socialVaultId: 'vault-1',
              accountId: 'account-1',
            ),
          ];
          await expectLater(
            service.recoverKeysForAccount('account-1'),
            throwsA(isA<LegacySocialWalletException>()),
          );
          expect(repository.storeCalls, 0);
        },
      );

      test('persists the record written by the platform slot', () async {
        vaults.bumpOnPlatformSlot = true;
        await service.recoverKeysForAccount('account-1');
        expect(vaults.persistedRevision, 2);
      });

      test('a deleted vault fails clearly and stores nothing', () async {
        fakeApi.opens
          ..clear()
          ..add(_opened(null));
        await expectLater(
          service.recoverKeysForAccount('account-1'),
          throwsA(
            isA<LegacySocialWalletException>()
                .having((e) => e.message, 'message', contains('backup'))
                .having(
                  (e) => e,
                  'type',
                  isNot(isA<LegacySocialKeyUnavailableException>()),
                ),
          ),
        );
        expect(repository.storeCalls, 0);
        expect(repository.linked, isEmpty, reason: 'the rows are left alone');
      });

      test('signs in silently first', () async {
        await service.recoverKeysForAccount('account-1');
        expect(identity.silentFlags, [true]);
        expect(repository.storeCalls, 1);
        expect(repository.storedIdentityId, _identityA);
      });

      /// Nothing on this device or in the platform keychain was deleted.
      void expectNothingDeleted() {
        expect(vaults.forgottenPlatformEntries, isEmpty);
        expect(vaults.forgottenLocal, isEmpty);
        expect(vaults.events, isEmpty);
        expect(repository.linked, isEmpty);
        expect(repository.storeCalls, 0);
      }

      test('a sign-in with another account deletes nothing and names the '
          'account the wallet needs', () async {
        // The provider silently handed over another account, which has no
        // vault. That says nothing about this wallet's vault.
        fakeApi.opens
          ..clear()
          ..add(_opened(null, identityId: _identityB, emailHint: 'b@x.test'));
        vaults.localCache = CachedSocialVault(
          vault: _vault('vault-1'),
          provider: 'google',
          emailHint: 'owner@x.test',
        );
        await expectLater(
          service.recoverKeysForAccount('account-1'),
          throwsA(
            isA<SocialAccountMismatchException>()
                .having((e) => e.expectedEmail, 'expected', 'owner@x.test')
                .having(
                  (e) => e.message,
                  'message',
                  allOf(contains('owner@x.test'), contains('Nothing was')),
                ),
          ),
        );
        expect(prompts.wrongAccounts.single, (
          expectedEmail: 'owner@x.test',
          signedInEmail: 'b@x.test',
        ));
        expectNothingDeleted();
      });

      test('another account that does hold a vault is refused the same '
          'way', () async {
        fakeApi.opens
          ..clear()
          ..add(_opened(_vault('theirs'), identityId: _identityB));
        await expectLater(
          service.recoverKeysForAccount('account-1'),
          throwsA(isA<SocialAccountMismatchException>()),
        );
        expect(vaults.unlockCalls, 0);
        expectNothingDeleted();
      });

      test('choosing another account retries with an account chooser, not '
          'silently', () async {
        fakeApi.opens
          ..clear()
          ..add(_opened(null, identityId: _identityB))
          ..add(_opened(_vault('vault-1')));
        prompts.useAnotherAccount = true;
        await service.recoverKeysForAccount('account-1');
        expect(identity.silentFlags, [true, false]);
        expect(identity.chooseFlags, [false, true]);
        expect(repository.storeCalls, 1);
        expect(vaults.forgottenPlatformEntries, isEmpty);
      });

      test('"no vault" from the wallet\'s own account deletes nothing '
          'either', () async {
        fakeApi.opens
          ..clear()
          ..add(_opened(null));
        await expectLater(
          service.recoverKeysForAccount('account-1'),
          throwsA(isA<LegacySocialWalletException>()),
        );
        expect(prompts.wrongAccounts, isEmpty, reason: 'it is the account');
        expectNothingDeleted();
      });

      test('a row from before the identity was recorded treats "no vault" '
          'and another vault as a possible wrong account', () async {
        repository.rowsByAccount['old'] = rowsFor(
          'old',
          bip39Keys,
          identityId: null,
        );
        for (final answer in [_opened(null), _opened(_vault('other'))]) {
          fakeApi.opens
            ..clear()
            ..add(answer);
          await expectLater(
            service.recoverKeysForAccount('old'),
            throwsA(isA<SocialAccountMismatchException>()),
          );
        }
        expect(prompts.wrongAccounts, hasLength(2));
        expectNothingDeleted();
      });

      test('a row from before the identity was recorded picks it up when '
          'its vault opens', () async {
        repository.rowsByAccount['old'] = rowsFor(
          'old',
          bip39Keys,
          identityId: null,
        );
        await service.recoverKeysForAccount('old');
        expect(repository.storedIdentityId, _identityA);
      });

      test('a silent token refused as used falls back to an interactive '
          'sign-in, once', () async {
        fakeApi.errors.add(
          const SocialVaultApiException(
            SocialVaultApiError.identityRejected,
            status: 401,
            code: 'invalid_id_token',
          ),
        );
        await service.recoverKeysForAccount('account-1');
        expect(identity.silentFlags, [true, false]);
        expect(fakeApi.tokens, hasLength(2));
        expect(repository.storeCalls, 1);

        // A second refusal is not retried again.
        identity.silentFlags.clear();
        fakeApi.errors.addAll([
          for (var i = 0; i < 2; i++)
            const SocialVaultApiException(
              SocialVaultApiError.identityRejected,
              status: 401,
              code: 'invalid_id_token',
            ),
        ]);
        await expectLater(
          service.recoverKeysForAccount('account-1'),
          throwsA(isA<SocialVaultApiException>()),
        );
        expect(identity.silentFlags, [true, false]);
      });

      test('a wallet from the older sign-in fails with the way back, '
          'without any sign-in', () async {
        // This app has no older sign-in, so nothing can fetch the key again.
        // The failure is typed and its message is the recovery path.
        await expectLater(
          service.recoverKeysForAccount('legacy'),
          throwsA(
            isA<LegacySocialKeyUnavailableException>()
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('older Google sign-in'),
                    contains('mallow website'),
                    contains('export'),
                    contains('Import wallet'),
                  ),
                )
                // Nothing in it may send the user to a host.
                .having((e) => e.message, 'no host', isNot(contains('.art'))),
          ),
        );
        expect(identity.calls, 0, reason: 'no sign-in can help');
        expect(vaults.unlockCalls, 0);
        expect(vaults.createCalls, 0);
        expect(repository.storeCalls, 0);
      });

      test('the way back names the provider the wallet was made with', () {
        expect(
          LegacySocialKeyUnavailableException(provider: 'apple').message,
          contains('older Apple sign-in'),
        );
        // Every surface that renders a LegacySocialWalletException message
        // (the signing failure, wallet verification) renders this one.
        expect(
          LegacySocialKeyUnavailableException(),
          isA<LegacySocialWalletException>(),
        );
      });

      test('a vault wallet whose backup was deleted is not told to use the '
          'older sign-in', () async {
        await expectLater(
          service.recoverKeysForAccount('unlinked'),
          throwsA(
            isA<LegacySocialWalletException>()
                .having(
                  (e) => e,
                  'type',
                  isNot(isA<LegacySocialKeyUnavailableException>()),
                )
                .having(
                  (e) => e.message,
                  'message',
                  allOf(contains('recovery phrase'), isNot(contains('older'))),
                ),
          ),
        );
        expect(identity.calls, 0);
        expect(repository.storeCalls, 0);
      });

      test('coalesces concurrent callers for one account', () async {
        identity.gate = Completer<void>();
        final first = service.recoverKeysForAccount('account-1');
        final second = service.recoverKeysForAccount('account-1');
        await pumpEventQueue();
        expect(identity.calls, 1, reason: 'one sign-in, not two');
        identity.gate.complete();
        await Future.wait([first, second]);
        expect(repository.storeCalls, 1);
      });

      test('a cancel unwinds every caller, across accounts', () async {
        identity.gate = Completer<void>();
        final first = service.recoverKeysForAccount('account-1');
        final second = service.recoverKeysForAccount('account-1');
        final other = service.recoverKeysForAccount('account-2');
        final expectations = [
          for (final f in [first, second, other])
            expectLater(f, throwsA(isA<TransactionAuthCancelledException>())),
        ];
        await pumpEventQueue();
        expect(service.requestPending.value, isTrue);
        service.cancelPendingRequest();
        await Future.wait(expectations);
        expect(service.requestPending.value, isFalse);
      });

      test('a cancelled recovery can be retried', () async {
        identity.gate = Completer<void>();
        final cancelled = service.recoverKeysForAccount('account-1');
        final fails = expectLater(
          cancelled,
          throwsA(isA<TransactionAuthCancelledException>()),
        );
        await pumpEventQueue();
        service.cancelPendingRequest();
        await fails;

        identity.gate.complete();
        await service.recoverKeysForAccount('account-1');
        expect(identity.calls, 2, reason: 'the retry is a fresh sign-in');
        expect(repository.storeCalls, 1);
      });
    });

    group('recoveryRefusalFor', () {
      LegacySocialWalletException? refusal(
        api.SocialVaultOpenResponse opened, {
        String? identityId = _identityA,
      }) => SocialAuthService.recoveryRefusalFor(
        provider: 'google',
        vaultId: 'vault-1',
        identityId: identityId,
        opened: opened,
      );

      test('accepts the wallet\'s own account holding its vault', () {
        expect(refusal(_opened(_vault('vault-1'))), isNull);
      });

      test('another identity is a wrong account even with the same vault '
          'id', () {
        expect(
          refusal(_opened(_vault('vault-1'), identityId: _identityB)),
          isA<SocialAccountMismatchException>(),
        );
      });

      test('the own account without the vault means the backup is gone', () {
        for (final opened in [_opened(null), _opened(_vault('other'))]) {
          expect(
            refusal(opened),
            isA<LegacySocialWalletException>().having(
              (e) => e,
              'type',
              isNot(isA<SocialAccountMismatchException>()),
            ),
          );
        }
      });

      test('with no identity recorded, only the vault id can vouch', () {
        expect(refusal(_opened(_vault('vault-1')), identityId: null), isNull);
        expect(
          refusal(_opened(null), identityId: null),
          isA<SocialAccountMismatchException>(),
        );
      });
    });

    group('Delete wallet backup', () {
      test('deletes the vault, then unlinks, then drops this device\'s copy '
          '— in that order', () async {
        await service.deleteWalletBackup('account-1');
        expect(vaults.events, [
          'delete',
          'forgetPlatformEntries',
          'beginUnlink',
          'keepMnemonic',
          'unlink',
          'forgetLocal',
        ]);
        expect(vaults.keptForAccount, {'vault-1': 'account-1'});
        expect(repository.linked, {'account-1': null});
        expect(vaults.forgottenLocal, ['vault-1']);
      });

      test('an unlink that cannot be written down is not begun: the rows '
          'stay linked, and the whole of it can be asked for again', () async {
        vaults.beginUnlinkError = StateError('store');
        await expectLater(
          service.deleteWalletBackup('account-1'),
          throwsStateError,
        );
        expect(vaults.events, ['delete', 'forgetPlatformEntries']);
        expect(repository.linked, isEmpty);
        expect(vaults.forgottenLocal, isEmpty);
      });

      test('this device\'s copy failing to drop leaves the unlink written '
          'down, and the next check finishes it', () async {
        vaults.forgetLocalError = StateError('keystore');
        await expectLater(
          service.deleteWalletBackup('account-1'),
          throwsStateError,
        );
        expect(vaults.unlinking.single.vaultId, 'vault-1');
        expect(vaults.forgottenLocal, isEmpty);

        vaults.forgetLocalError = null;
        await service.checkVaults();
        expect(vaults.forgottenLocal, ['vault-1']);
        expect(vaults.unlinking, isEmpty);
      });

      test('a device that cannot sign the delete changes nothing', () async {
        vaults.canSignDelete = false;
        await expectLater(
          service.deleteWalletBackup('account-1'),
          throwsA(isA<SocialVaultStaleKeyException>()),
        );
        expect(vaults.events, isEmpty);
        expect(repository.linked, isEmpty);
      });

      test('a delete that fails leaves the wallet linked', () async {
        vaults.deleteError = const SocialVaultApiException(
          SocialVaultApiError.unavailable,
        );
        await expectLater(
          service.deleteWalletBackup('account-1'),
          throwsA(isA<SocialVaultApiException>()),
        );
        expect(vaults.events, isEmpty);
        expect(repository.linked, isEmpty);
      });

      test('a wrong clock deletes nothing', () async {
        vaults.deleteError = const SocialVaultApiException(
          SocialVaultApiError.staleTimestamp,
          status: 401,
        );
        await expectLater(
          service.deleteWalletBackup('account-1'),
          throwsA(
            isA<SocialVaultApiException>().having(
              (e) => e.error,
              'error',
              SocialVaultApiError.staleTimestamp,
            ),
          ),
        );
        expect(repository.linked, isEmpty);
      });

      test('is refused when this device does not hold the recovery '
          'phrase', () async {
        vaults.phraseHere = false;
        await expectLater(
          service.deleteWalletBackup('account-1'),
          throwsA(isA<SocialVaultPhraseUnavailableException>()),
        );
        expect(vaults.events, isEmpty, reason: 'the backup is the only copy');
      });

      test('a delete the backend answers "not found" unlinks the wallet, as '
          'asked, but keeps its platform entries', () async {
        // This device did not see a delete go through, and "not found" cannot
        // be authenticated: the slot secrets stay, as after any "not found".
        vaults.deletion = SocialVaultDeletion.notFound;
        await service.deleteWalletBackup('account-1');
        expect(vaults.events, [
          'delete',
          'retire',
          'beginUnlink',
          'keepMnemonic',
          'unlink',
          'forgetLocal',
        ]);
        expect(vaults.forgottenPlatformEntries, isEmpty);
        expect(repository.linked, {'account-1': null});
        final record = vaults.retired.single;
        expect(record.vaultId, 'vault-1');
        expect(record.accountId, 'account-1');
        expect(record.identityId, _identityA);
        expect(
          record.announced,
          isTrue,
          reason: 'the user just did this: no notice',
        );
      });

      test('a wallet already unlinked is done', () async {
        await service.deleteWalletBackup('unlinked');
        expect(vaults.events, isEmpty);
      });

      test('never touches a wallet from the older sign-in', () async {
        await service.deleteWalletBackup('legacy');
        expect(vaults.events, isEmpty);
        expect(repository.linked, isEmpty);
      });
    });

    group('the vault status check', () {
      test('one "not found" changes nothing and shows nothing', () async {
        vaults.statuses['vault-1'] = SocialVaultStatus.unconfirmedGone;
        await service.checkVaults();
        expect(vaults.events, isEmpty);
        expect(repository.linked, isEmpty);
        expect(vaults.retired, isEmpty);
        expect(vaults.forgottenPlatformEntries, isEmpty);
        expect(prompts.backupGoneFor, isEmpty);
        expect(prompts.reviewed, isNot(contains('vault-1')));
      });

      test('a vault not found twice, a day apart, is unlinked — with its '
          'platform entries kept — and the user is told once', () async {
        vaults.statuses['vault-1'] = SocialVaultStatus.gone;
        await service.checkVaults();
        expect(vaults.events, [
          'retire',
          'beginUnlink',
          'keepMnemonic',
          'unlink',
          'forgetLocal',
        ]);
        expect(
          vaults.forgottenPlatformEntries,
          isEmpty,
          reason: 'no slot secret is deleted on a "not found"',
        );
        expect(repository.linked, {'account-1': null});
        expect(vaults.keptForAccount, {'vault-1': 'account-1'});
        expect(vaults.forgottenLocal, ['vault-1']);
        final record = vaults.retired.single;
        expect(record.accountId, 'account-1');
        expect(record.provider, 'google');
        expect(record.identityId, _identityA);

        expect(prompts.backupGoneFor, ['google']);
        expect(vaults.retired.single.announced, isTrue);

        // Never again.
        await service.checkVaults();
        expect(prompts.backupGoneFor, ['google']);
        expect(vaults.statusReads.where((id) => id == 'vault-1'), hasLength(1));
      });

      test('reads every linked vault and reviews the ones it has a record '
          'of', () async {
        vaults.statuses
          ..['vault-1'] = SocialVaultStatus.current
          ..['vault-2'] = SocialVaultStatus.skipped;
        await service.checkVaults();
        expect(vaults.statusReads.toSet(), {'vault-1', 'vault-2'});
        expect(prompts.reviewed.toSet(), {'vault-1', 'vault-2'});
        expect(repository.linked, isEmpty);
      });

      test('a failed read or a stale key unlinks nothing and shows '
          'nothing', () async {
        vaults.statuses
          ..['vault-1'] = SocialVaultStatus.failed
          ..['vault-2'] = SocialVaultStatus.staleKey;
        await service.checkVaults();
        expect(vaults.events, isEmpty);
        expect(repository.linked, isEmpty);
        expect(prompts.reviewed, isEmpty);
      });

      test('cleans up unconfirmed creations, sparing every linked '
          'vault', () async {
        await service.checkVaults();
        expect(vaults.sweptAbandonedWith, {'vault-1', 'vault-2'});
      });

      test('concurrent calls share one run', () async {
        vaults.statusGate = Completer<void>();
        final first = service.checkVaults();
        final second = service.checkVaults();
        await pumpEventQueue();
        vaults.statusGate!.complete();
        await Future.wait([first, second]);
        expect(vaults.statusReads, hasLength(2), reason: 'two vaults, once');
        // And the next call runs again.
        await service.checkVaults();
        expect(vaults.statusReads, hasLength(4));
      });

      group('a vault a wallet was unlinked from on a "not found"', () {
        RetiredSocialVault record({bool announced = true}) =>
            RetiredSocialVault(
              vaultId: 'vault-9',
              accountId: 'unlinked',
              provider: 'google',
              identityId: _identityA,
              emailHint: 'owner@x.test',
              unlinkedAt: DateTime.utc(2026, 11, 10),
              lastCheckedAt: DateTime.utc(2026, 11, 10),
              announced: announced,
            );

        UnlockedSocialVault unlocked({String mnemonic = _mnemonic}) =>
            UnlockedSocialVault(
              vault: _vault('vault-9'),
              dataKey: Uint8List(32),
              payload: SocialVaultPayload(mnemonic),
              openedWithSlotId: '',
            );

        test('is asked about again, and nothing else happens while it stays '
            'gone', () async {
          vaults.retired.add(record());
          await service.checkVaults();
          expect(vaults.retiredChecked, ['vault-9']);
          expect(repository.storeCalls, 0);
          expect(vaults.forgottenPlatformEntries, isEmpty);
          expect(vaults.retired, hasLength(1));
          expect(prompts.backupGoneFor, isEmpty, reason: 'already told');
        });

        test('a notice that could not be shown is shown at the next '
            'check', () async {
          vaults.retired.add(record(announced: false));
          prompts.canAnnounce = false;
          await service.checkVaults();
          expect(vaults.retired.single.announced, isFalse);

          prompts.canAnnounce = true;
          await service.checkVaults();
          expect(prompts.backupGoneFor, ['google']);
          expect(vaults.retired.single.announced, isTrue);
        });

        test('that is there after all links the wallet back, to the same '
            'account', () async {
          vaults
            ..retired.add(record())
            ..retiredChecks['vault-9'] = RetiredSocialVaultCheck.exists(
              unlocked(),
            );
          await service.checkVaults();
          expect(repository.storeCalls, 1);
          expect(repository.storedVaultId, 'vault-9');
          expect(repository.storedIdentityId, _identityA);
          expect(repository.storedSolana!.address, bip39Keys.solanaAddress);
          expect(vaults.persistCalls, 1, reason: 'the key and record are kept');
          expect(vaults.forgottenPlatformEntries, isEmpty);
        });

        test('that holds another wallet is not linked', () async {
          vaults
            ..retired.add(record())
            ..retiredChecks['vault-9'] = RetiredSocialVaultCheck.exists(
              unlocked(
                mnemonic:
                    'legal winner thank year wave sausage worth useful '
                    'legal winner thank yellow',
              ),
            );
          await service.checkVaults();
          expect(repository.storeCalls, 0);
          expect(vaults.persistCalls, 0);
          expect(vaults.forgottenRetired, ['vault-9']);
        });

        test('whose wallet left the device is no longer watched', () async {
          vaults.retired.add(record());
          repository.rowsByAccount.remove('unlinked');
          await service.checkVaults();
          expect(vaults.forgottenRetired, ['vault-9']);
          expect(vaults.retiredChecked, isEmpty);
          expect(vaults.forgottenPlatformEntries, isEmpty);
          expect(prompts.backupGoneFor, isEmpty);
        });

        test('whose wallet a sign-in linked again is no longer watched, and '
            'gets no notice', () async {
          vaults.retired.add(record(announced: false));
          repository.rowsByAccount['unlinked'] = rowsFor(
            'unlinked',
            bip39Keys,
            vaultId: 'vault-9',
          );
          await service.checkVaults();
          expect(vaults.forgottenRetired, ['vault-9']);
          expect(prompts.backupGoneFor, isEmpty);
          expect(vaults.retiredChecked, isEmpty);
        });
      });

      test('never throws', () async {
        GetIt.instance.unregister<WalletRepository>();
        await service.checkVaults();
        GetIt.instance.registerSingleton<WalletRepository>(repository);
      });
    });

    group('the phone backup check', () {
      /// The backup held a key of [vaultId] while it was not end-to-end
      /// encrypted, and is encrypted again.
      PlatformBackupStatus exposed(
        String vaultId, {
        bool encrypted = true,
        bool offered = false,
      }) => PlatformBackupStatus(
        encrypted: encrypted,
        pausedVaultIds: encrypted ? const {} : {vaultId},
        pausedSince: null,
        exposedVaultIds: {vaultId},
        exposedSince: DateTime.utc(2026, 11, 10),
        replacementOffered: offered,
        cloudBacked: const {},
      );

      test('runs on every check, before anything is read from the '
          'backend', () async {
        await service.checkVaults();
        expect(vaults.statusReadsBeforeBackupCheck, 0);
        await service.checkVaults();
        expect(vaults.backupChecks, 2);
        expect(prompts.replacementOffers, 0);
      });

      test('a failure does not stop the status check', () async {
        vaults.backupCheckError = StateError('no Play services');
        vaults.statuses['vault-1'] = SocialVaultStatus.current;
        await service.checkVaults();
        expect(vaults.statusReads, isNotEmpty);
        expect(prompts.reviewed, contains('vault-1'));
      });

      test('offers a key replacement once the backup is encrypted again, and '
          'records that it did', () async {
        vaults.backupStatus = exposed('vault-1');
        prompts.replaceKeys = true;
        await service.checkVaults();
        expect(prompts.replacementOffers, 1);
        expect(vaults.replacementsMarkedOffered, 1);
        // Accepted: the advice stays until the keys are replaced.
        expect(vaults.exposuresDismissed, 0);
      });

      test('dismissing the offer drops the advice', () async {
        vaults.backupStatus = exposed('vault-1');
        prompts.replaceKeys = false;
        await service.checkVaults();
        expect(vaults.replacementsMarkedOffered, 1);
        expect(vaults.exposuresDismissed, 1);
      });

      test('is not offered twice, while the backup is still unencrypted, or '
          'for a vault no wallet here uses', () async {
        vaults.backupStatus = exposed('vault-1', offered: true);
        await service.checkVaults();
        vaults.backupStatus = exposed('vault-1', encrypted: false);
        await service.checkVaults();
        vaults.backupStatus = exposed('someone-elses-vault');
        await service.checkVaults();
        expect(prompts.replacementOffers, 0);
      });

      test('an offer that could not be shown is made again', () async {
        vaults.backupStatus = exposed('vault-1');
        prompts.replaceKeys = null;
        await service.checkVaults();
        expect(prompts.replacementOffers, 1);
        expect(vaults.replacementsMarkedOffered, 0);
        expect(vaults.exposuresDismissed, 0);
        await service.checkVaults();
        expect(prompts.replacementOffers, 2);
      });
    });
  });
}

/// An `open` that answers from a script: a response, or an exception to
/// throw, per call.
class _ScriptedApi extends _FakeApi {
  _ScriptedApi(this.script);

  final List<Object> script;
  int calls = 0;

  @override
  Future<api.SocialVaultOpenResponse> open(String idToken) async {
    final next = script[calls++];
    if (next is SocialVaultApiException) throw next;
    return next as api.SocialVaultOpenResponse;
  }
}

/// A provider whose sheet the user backs out of when [cancel] says so.
class _CancellingIdentity implements SocialIdentityProvider {
  _CancellingIdentity(this.cancel);

  final bool Function() cancel;

  @override
  bool isConfigured(String provider) => true;

  @override
  Future<String?> idToken(
    String provider, {
    bool silent = false,
    bool chooseAccount = false,
  }) async => cancel() ? null : 'id-token';
}
