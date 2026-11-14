import 'dart:async';

import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/social_vault/passkey_prf.dart';
import 'package:mallow_wallet/core/social_vault/platform_slot_store.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_api.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_crypto.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_service.dart';

/// Runs the real slot and payload crypto end to end against in-memory stand-ins
/// for the backend, the platform keychain and the authenticator.
void main() {
  late _Backend backend;
  late _Platform platform;
  late _Passkeys passkeys;
  late _Storage storage;
  late SocialVaultService service;
  late DateTime now;
  int? androidSdk;

  /// The backend this build talks to, and another one.
  const here = 'https://backend.test:443';
  const elsewhere = 'https://staging.test:443';
  String? origin;

  const payload = SocialVaultPayload(
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about',
  );

  setUp(() {
    Config.debugOverrides['PASSKEY_RP_ID'] = 'example.test';
    Config.debugOverrides['API_V2_BASE_URL'] = 'https://backend.test/v2';
    backend = _Backend();
    platform = _Platform();
    passkeys = _Passkeys();
    storage = _Storage();
    service = SocialVaultService(
      backend,
      platform,
      passkeys,
      storage,
      deviceName: () async => 'Test phone',
      clock: () => now,
      androidSdkInt: () async => androidSdk,
      apiOrigin: () => origin,
    );
    now = DateTime.utc(2026, 11, 10, 12);
    androidSdk = null;
    origin = here;
  });

  tearDown(Config.debugOverrides.clear);

  Future<UnlockedSocialVault> create() => service.create(
    identityToken: 'identity',
    payload: payload,
    userName: 'person@example.test',
  );

  /// A vault with this device's platform slot and a passkey.
  Future<(UnlockedSocialVault, api.SocialVault)> twoSlots() async {
    final created = await create();
    final withPasskey = await service.addPasskeySlot(
      created.vault,
      created.dataKey,
      userName: 'person',
    );
    backend.created = api.SocialVaultCreateRequest(
      identityToken: '',
      vaultId: withPasskey.vaultId,
      payloadNonce: withPasskey.payloadNonce,
      payloadCiphertext: withPasskey.payloadCiphertext,
      vaultPublicKey: withPasskey.vaultPublicKey,
      slots: [
        for (final s in withPasskey.slots)
          api.SocialVaultNewSlot.fromJson(s.toJson()),
      ],
    );
    await service.persist(created, provider: 'google');
    return (created, withPasskey);
  }

  /// Sweep the entries of [opened]'s vault. The sweep reads the slot list
  /// itself, with a status read; the backend answers with the vault as it
  /// was created unless a test set another record.
  Future<void> sweep(UnlockedSocialVault opened) {
    backend.statusVault ??= opened.vault;
    return service.sweepPlatformEntries(opened.vault.vaultId, opened.dataKey);
  }

  test('creates with a platform slot written before the vault', () async {
    platform.onWrite = () => expect(backend.created, isNull);
    final created = await create();
    expect(created.vault.slots.single.kind, api.SocialVaultSlotKind.platform);
    expect(created.vault.slots.single.label, endsWith(' · Test phone'));
    expect(platform.count, 1);
    expect(passkeys.registrations, 0);

    final unlocked = await service.unlock(created.vault);
    expect(unlocked.dataKey, created.dataKey);
    expect(unlocked.payload.mnemonic, payload.mnemonic);
  });

  test('falls back to a passkey slot without a platform slot', () async {
    platform.available = false;
    final created = await create();
    final slot = created.vault.slots.single;
    expect(slot.kind, api.SocialVaultSlotKind.passkeyPrf);
    expect(slot.rpId, 'example.test');
    expect(slot.prfSalt, isNotNull);

    final unlocked = await service.unlock(created.vault);
    expect(unlocked.dataKey, created.dataKey);
    expect(passkeys.assertions, 1);
  });

  test('creates nothing when no slot is possible here', () async {
    platform.available = false;
    passkeys.supported = false;
    await expectLater(create(), throwsA(isA<SocialVaultUnlockException>()));
    expect(backend.created, isNull);
  });

  test('a vault no slot here opens says so', () async {
    final created = await create();
    platform.entries.clear();
    passkeys.supported = false;
    await expectLater(
      service.unlock(created.vault),
      throwsA(isA<SocialVaultUnlockException>()),
    );
  });

  test(
    'a refused create frees the platform entry; no answer keeps it',
    () async {
      backend.createError = const SocialVaultApiException(
        SocialVaultApiError.vaultExists,
        status: 409,
        code: 'vault_exists',
      );
      await expectLater(create(), throwsA(isA<SocialVaultApiException>()));
      expect(platform.count, 0);

      backend.createError = const SocialVaultApiException(
        SocialVaultApiError.unavailable,
      );
      await expectLater(create(), throwsA(isA<SocialVaultApiException>()));
      expect(platform.count, 1, reason: 'the vault may exist');
    },
  );

  test('a new device gets its own platform slot after a passkey', () async {
    platform.available = false;
    final created = await create();
    platform.available = true;
    final updated = await service.ensurePlatformSlot(
      created.vault,
      created.dataKey,
    );
    expect(updated.slots.map((s) => s.kind), [
      api.SocialVaultSlotKind.passkeyPrf,
      api.SocialVaultSlotKind.platform,
    ]);
    expect(platform.count, 1);
    // Idempotent once the device has a live one.
    final again = await service.ensurePlatformSlot(updated, created.dataKey);
    expect(again.slots, hasLength(2));
  });

  test('refuses a data key that is not the vault\'s', () async {
    final created = await create();
    final tampered = api.SocialVault.fromJson({
      ...created.vault.toJson(),
      'vaultPublicKey': SocialVaultCrypto.base64UrlNoPad(Uint8List(32)),
    });
    await expectLater(
      service.unlock(tampered),
      throwsA(isA<SocialVaultCryptoException>()),
    );
  });

  group('platform entries', () {
    test('unlock tries every entry the device can read', () async {
      final created = await create();
      final vaultId = created.vault.vaultId;
      // A stale entry from a slot that is no longer in the vault, read first.
      final real = platform.entries[vaultId]!;
      platform.entries[vaultId] = {
        'stale': PlatformSlotEntry(slotId: 'stale', secret: Uint8List(32)),
        ...real,
      };
      final unlocked = await service.unlock(created.vault);
      expect(unlocked.dataKey, created.dataKey);
    });

    test('a device sharing the keychain reuses the synced slot', () async {
      final created = await create();
      final again = await service.ensurePlatformSlot(
        created.vault,
        created.dataKey,
      );
      expect(again.slots, hasLength(1));
      expect(platform.count, 1);
    });

    test('a new slot never replaces an existing entry', () async {
      final created = await create();
      final vaultId = created.vault.vaultId;
      final first = platform.entries[vaultId]!.values.single;
      // The vault no longer lists that slot (say it was removed elsewhere).
      final without = api.SocialVault.fromJson({
        ...created.vault.toJson(),
        'slots': <Object>[],
      });
      await service.ensurePlatformSlot(without, created.dataKey);
      expect(platform.count, 2);
      expect(platform.entries[vaultId]![first.slotId]!.secret, first.secret);
    });

    test('an entry is deleted only after its slot is gone', () async {
      platform.available = false;
      final created = await create();
      platform.available = true;
      final withPlatform = await service.ensurePlatformSlot(
        created.vault,
        created.dataKey,
      );
      final platformSlot = withPlatform.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.platform,
      );
      backend.created = api.SocialVaultCreateRequest(
        identityToken: '',
        vaultId: created.vault.vaultId,
        payloadNonce: created.vault.payloadNonce,
        payloadCiphertext: created.vault.payloadCiphertext,
        vaultPublicKey: created.vault.vaultPublicKey,
        slots: [
          for (final s in withPlatform.slots)
            api.SocialVaultNewSlot.fromJson(s.toJson()),
        ],
      );

      backend.removeError = const SocialVaultApiException(
        SocialVaultApiError.unavailable,
      );
      await expectLater(
        service.removeSlot(withPlatform, created.dataKey, platformSlot.slotId),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(platform.count, 1, reason: 'the slot may still be live');

      backend.removeError = null;
      await service.removeSlot(
        withPlatform,
        created.dataKey,
        platformSlot.slotId,
      );
      expect(platform.count, 0);
    });
  });

  group('renaming a key', () {
    test('sends the trimmed label signed with the vault key, and keeps the '
        'answer', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      final slotId = created.vault.slots.single.slotId;

      final renamed = await service.renameSlot(
        created.vault,
        created.dataKey,
        slotId,
        '  Work phone ',
      );

      expect(backend.renamed, [(slotId, 'Work phone', created.vault.revision)]);
      expect(renamed.slots.single.label, 'Work phone');
      expect(renamed.revision, created.vault.revision + 1);
      final cached = await service.cached(created.vault.vaultId);
      expect(cached!.vault.slots.single.label, 'Work phone');
      // Only the label: the slot still opens the vault.
      final unlocked = await service.unlock(renamed);
      expect(unlocked.dataKey, created.dataKey);
    });

    test('an empty name clears the label', () async {
      final created = await create();
      final slotId = created.vault.slots.single.slotId;
      final cleared = await service.renameSlot(
        created.vault,
        created.dataKey,
        slotId,
        '   ',
      );
      expect(backend.renamed.single.$2, '');
      expect(cleared.slots.single.label, isNull);
    });

    test('a name over 64 code points is refused with a typed error, before '
        'anything is sent', () async {
      final created = await create();
      final slotId = created.vault.slots.single.slotId;
      await expectLater(
        service.renameSlot(created.vault, created.dataKey, slotId, 'é' * 65),
        throwsA(
          isA<SocialVaultLabelException>()
              .having((e) => e.length, 'length', 65)
              .having((e) => e.maxLength, 'maxLength', 64),
        ),
      );
      expect(backend.renamed, isEmpty);
      await service.renameSlot(
        created.vault,
        created.dataKey,
        slotId,
        'é' * 64,
      );
      expect(backend.renamed, hasLength(1));
    });

    test('the limit counts code points, as the backend does: 40 flags are '
        '80', () async {
      final created = await create();
      final slotId = created.vault.slots.single.slotId;
      const flag = '\u{1F1EB}\u{1F1F7}';
      await expectLater(
        service.renameSlot(created.vault, created.dataKey, slotId, flag * 40),
        throwsA(
          isA<SocialVaultLabelException>().having(
            (e) => e.length,
            'length',
            80,
          ),
        ),
      );
      expect(SocialVaultService.normalizeSlotLabel(flag * 32), flag * 32);
      expect(backend.renamed, isEmpty);
    });

    test('a name is one line of plain text: controls and direction '
        'overrides never reach the backend', () async {
      final created = await create();
      final slotId = created.vault.slots.single.slotId;
      await service.renameSlot(
        created.vault,
        created.dataKey,
        slotId,
        ' Work\nphone\t\u202Egnp.exe\u202C \u200F\u2066x\u2069\u0000\u0085y\u061C ',
      );
      expect(backend.renamed.single.$2, 'Work phone gnp.exe x y');
    });

    test('the one rule, for the field and the service alike', () {
      expect(SocialVaultService.normalizeSlotLabel('  Phone  '), 'Phone');
      expect(SocialVaultService.normalizeSlotLabel(' \n\t '), '');
      expect(
        SocialVaultService.normalizeSlotLabel('a\u202Eb\u2066c\u200Ed\u007Fe'),
        'abcde',
      );
      // What is counted is what would be stored.
      expect(
        SocialVaultService.normalizeSlotLabel('${'x' * 64}\u202E\u200F '),
        'x' * 64,
      );
      expect(
        () => SocialVaultService.normalizeSlotLabel('x' * 65),
        throwsA(isA<SocialVaultLabelException>()),
      );
      // Letters of right-to-left scripts and emoji are ordinary text.
      expect(SocialVaultService.normalizeSlotLabel('هاتف 📱'), 'هاتف 📱');
    });

    test('a label another client stored is cleaned before it is handed '
        'out or kept', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      final vaultId = created.vault.vaultId;
      backend.statusVault = api.SocialVault.fromJson({
        ...created.vault.toJson(),
        'revision': 2,
        'slots': [
          {
            ...created.vault.slots.single.toJson(),
            'label': 'Phone\u202E\nevil\u0007',
          },
          {
            ...created.vault.slots.single.toJson(),
            'slotId': 'AAAAAAAAAAAAAAAAAAAAAA',
            'label': '\u200F\u0000',
          },
        ],
      });
      expect(
        await service.checkStatus(vaultId, force: true),
        SocialVaultStatus.current,
      );
      final slots = (await service.cached(vaultId))!.vault.slots;
      expect(slots.first.label, 'Phone evil');
      expect(
        slots.last.label,
        isNull,
        reason: 'nothing left: reads as its kind',
      );
      expect(
        (await service.unseenSlots(vaultId)).single.label,
        isNull,
        reason: 'what a notice draws is cleaned too',
      );

      // A record an earlier build kept is cleaned when it is read.
      storage.values['cache:$vaultId'] = storage.values['cache:$vaultId']!
          .replaceFirst('Phone evil', r'Phone\u202eevil');
      expect(
        (await service.cached(vaultId))!.vault.slots.first.label,
        'Phoneevil',
      );
    });
  });

  group('a data key that no longer signs', () {
    api.SocialVault rotatedElsewhere(api.SocialVault v, {int revision = 7}) =>
        api.SocialVault.fromJson({
          ...v.toJson(),
          'revision': revision,
          'vaultPublicKey': SocialVaultCrypto.base64UrlNoPad(Uint8List(32)),
        });

    test('a refused signature drops the key and says so', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      backend.addError = const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
      );
      await expectLater(
        service.addPasskeySlot(created.vault, created.dataKey, userName: 'x'),
        throwsA(isA<SocialVaultStaleKeyException>()),
      );
      expect(await service.loadDataKey(created.vault.vaultId), isNull);
      expect(
        storage.values['mnemonic:${created.vault.vaultId}'],
        payload.mnemonic,
        reason: 'the wallet itself is kept',
      );
    });

    test('a conflict under another vault key is a stale key, and the '
        'cache takes the current vault', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      final current = rotatedElsewhere(created.vault);
      backend.addError = SocialVaultConflictException(current);
      await expectLater(
        service.addPasskeySlot(created.vault, created.dataKey, userName: 'x'),
        throwsA(isA<SocialVaultStaleKeyException>()),
      );
      expect((await service.cached(created.vault.vaultId))!.vault.revision, 7);
      expect(await service.loadDataKey(created.vault.vaultId), isNull);
    });

    test(
      'a final conflict under the same key still refreshes the cache',
      () async {
        final created = await create();
        await service.persist(created, provider: 'google');
        final newer = api.SocialVault.fromJson({
          ...created.vault.toJson(),
          'revision': 9,
        });
        backend.addError = SocialVaultConflictException(newer);
        await expectLater(
          service.addPasskeySlot(created.vault, created.dataKey, userName: 'x'),
          throwsA(isA<SocialVaultConflictException>()),
        );
        expect(
          (await service.cached(created.vault.vaultId))!.vault.revision,
          9,
        );
        expect(await service.loadDataKey(created.vault.vaultId), isNotNull);
      },
    );

    test('a cached record under another key makes the key unusable — and '
        'deletes nothing: the record is this device\'s memory, not an '
        'answer', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      expect(await service.hasUsableDataKey(created.vault.vaultId), isTrue);
      storage.values['cache:${created.vault.vaultId}'] = CachedSocialVault(
        vault: rotatedElsewhere(created.vault),
        provider: 'google',
        emailHint: null,
      ).toJsonString();
      expect(await service.hasUsableDataKey(created.vault.vaultId), isFalse);
      expect(
        await service.loadDataKey(created.vault.vaultId),
        created.dataKey,
        reason: 'only an answer from the backend drops a key',
      );
      expect(
        await service.deleteVaultWithLocalKey(created.vault.vaultId),
        SocialVaultDeletion.noKey,
      );
      expect(backend.deletedRevisions, isEmpty);
    });
  });

  group('sweeping and a full store', () {
    test('opening a vault sweeps entries of slots that are gone', () async {
      final created = await create();
      final vaultId = created.vault.vaultId;
      platform.entries[vaultId]!['gone'] = PlatformSlotEntry(
        slotId: 'gone',
        secret: Uint8List(32),
      );
      await sweep(created);
      expect(platform.entries[vaultId]!.keys, [
        created.vault.slots.single.slotId,
      ]);
      platform.entries['deleted'] = {
        'x': PlatformSlotEntry(slotId: 'x', secret: Uint8List(32)),
      };
      await service.forgetPlatformEntries('deleted');
      expect(platform.entries['deleted'], isEmpty);
    });

    test('a full Block Store is reported as such', () async {
      platform.fullError = true;
      passkeys.supported = false;
      await expectLater(
        create(),
        throwsA(
          isA<SocialVaultUnlockException>().having(
            (e) => e.platformStoreFull,
            'platformStoreFull',
            isTrue,
          ),
        ),
      );
    });
  });

  group('the phone backup of a device key (Android)', () {
    setUp(() => platform.android = true);

    test('a new entry is noted as in the cloud backup, and its label '
        'claims no backup', () async {
      final created = await create();
      final slot = created.vault.slots.single;

      expect(
        service.platformBackup.value.isCloudBacked(
          created.vault.vaultId,
          slot.slotId,
        ),
        isTrue,
      );
      // The label outlives the state: whether the entry is in Google's
      // backup changes with the screen lock, so it does not say.
      expect(slot.label, isNot(contains('backup')));
      expect(slot.label, endsWith(' · Test phone'));
    });

    test('the backup is checked before an entry is written, and entries '
        'already here are pulled out of an unencrypted one', () async {
      final first = await create();
      final firstKey =
          '${first.vault.vaultId}.${first.vault.slots.single.slotId}';
      expect(platform.cloud[firstKey], isTrue);

      // The screen lock is removed; then a second wallet is created.
      platform.encrypted = false;
      final second = await create();

      // No platform slot is made in a backup that is not encrypted…
      expect(
        second.vault.slots.single.kind,
        api.SocialVaultSlotKind.passkeyPrf,
      );
      // …and the first wallet's entry is on this device alone now.
      expect(platform.cloud[firstKey], isFalse);
      expect(platform.entries[first.vault.vaultId], hasLength(1));
      final status = service.platformBackup.value;
      expect(status.paused, isTrue);
      expect(status.exposedVaultIds, {first.vault.vaultId});
    });

    test('a rotation clears the exposure of its vault', () async {
      final created = await create();
      final vaultId = created.vault.vaultId;
      platform.encrypted = false;
      await service.checkPlatformBackup();
      platform.encrypted = true;
      expect((await service.checkPlatformBackup()).exposedVaultIds, {vaultId});

      // Replace the keys: the rotation a removal of this phone's key runs.
      final plan = await service.planRemoval(
        created.vault,
        created.vault.slots.single.slotId,
      );
      expect(plan.newPlatformSlot, isTrue);
      final rotation = await service.rotateRemoving(
        vault: created.vault,
        dataKey: created.dataKey,
        plan: plan,
      );

      expect(service.platformBackup.value.exposedVaultIds, isEmpty);
      // The new device key is in the (encrypted again) cloud backup.
      final newSlot = rotation.vault.slots.single;
      expect(newSlot.slotId, isNot(created.vault.slots.single.slotId));
      expect(platform.cloud['$vaultId.${newSlot.slotId}'], isTrue);
    });

    test('dismissing the advice clears it without changing a key', () async {
      final created = await create();
      platform.encrypted = false;
      await service.checkPlatformBackup();
      await service.dismissBackupExposure(created.vault.vaultId);

      expect(service.platformBackup.value.exposedVaultIds, isEmpty);
      expect(platform.entries[created.vault.vaultId], hasLength(1));
      expect(backend.rotated, isNull);
    });
  });

  group('an Android version without encrypted backup or passkeys', () {
    setUp(() {
      platform
        ..android = true
        ..encrypted = false;
      passkeys.supported = false;
    });

    test('Android 8 fails closed, and says it is the version', () async {
      androidSdk = 27;
      await expectLater(
        create(),
        throwsA(
          isA<SocialVaultUnlockException>()
              .having((e) => e.creating, 'creating', isTrue)
              .having((e) => e.platformTooOld, 'platformTooOld', isTrue),
        ),
      );
      expect(backend.created, isNull);
      expect(platform.count, 0);
    });

    test('Android 9 with no screen lock is not "too old"', () async {
      androidSdk = 28;
      await expectLater(
        create(),
        throwsA(
          isA<SocialVaultUnlockException>()
              .having((e) => e.creating, 'creating', isTrue)
              .having((e) => e.platformTooOld, 'platformTooOld', isFalse),
        ),
      );
    });
  });

  group('removal by rotation', () {
    test('re-keys and keeps only what this device re-creates', () async {
      final (created, vault) = await twoSlots();
      final oldPlatform = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.platform,
      );
      final plan = await service.planRemoval(vault, oldPlatform.slotId);
      expect(plan.dropped.map((s) => s.slotId), [oldPlatform.slotId]);
      expect(plan.passkeysToConfirm, hasLength(1));
      expect(plan.newPlatformSlot, isTrue);

      // The old entry is older than the sweep's grace period by now.
      now = now.add(const Duration(minutes: 11));
      final rotated = await service.rotateRemoving(
        vault: vault,
        dataKey: created.dataKey,
        plan: plan,
      );
      final request = backend.rotated!;
      expect(request.revision, vault.revision);
      expect(request.vaultPublicKey, isNot(vault.vaultPublicKey));
      expect(
        request.slots.map((s) => s.slotId),
        isNot(contains(oldPlatform.slotId)),
        reason: 'every slot id is new',
      );
      expect(request.slots.map((s) => s.kind).toSet(), {
        api.SocialVaultSlotKind.platform,
        api.SocialVaultSlotKind.passkeyPrf,
      });

      // The new data key is stored, opens the vault, and the old platform
      // entry is gone once its slot is.
      final newKey = await service.loadDataKey(vault.vaultId);
      expect(newKey, isNot(created.dataKey));
      expect(rotated.unconfirmedPasskeys, isEmpty);
      final reopened = await service.unlock(rotated.vault);
      expect(reopened.dataKey, newKey);
      expect(reopened.payload.mnemonic, payload.mnemonic);
      expect(
        platform.entries[vault.vaultId]!.keys,
        isNot(contains(oldPlatform.slotId)),
      );
    });

    test('a passkey the user does not confirm is dropped', () async {
      final (created, vault) = await twoSlots();
      final oldPlatform = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.platform,
      );
      passkeys.cancelAssertions = true;
      final rotation = await service.rotateRemoving(
        vault: vault,
        dataKey: created.dataKey,
        plan: await service.planRemoval(vault, oldPlatform.slotId),
      );
      expect(backend.rotated!.slots.map((s) => s.kind), [
        api.SocialVaultSlotKind.platform,
      ]);
      expect(rotation.unconfirmedPasskeys, hasLength(1));
    });

    test('a different passkey answering is dropped, not re-created', () async {
      final (created, vault) = await twoSlots();
      final oldPlatform = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.platform,
      );
      passkeys.answerAs = 'someone-else';
      final rotation = await service.rotateRemoving(
        vault: vault,
        dataKey: created.dataKey,
        plan: await service.planRemoval(vault, oldPlatform.slotId),
      );
      expect(backend.rotated!.slots.map((s) => s.kind), [
        api.SocialVaultSlotKind.platform,
      ]);
      expect(rotation.unconfirmedPasskeys, hasLength(1));
    });

    test('a refused rotation changes nothing here', () async {
      final (created, vault) = await twoSlots();
      final passkey = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
      );
      final entriesBefore = Map.of(platform.entries[vault.vaultId]!);
      backend.rotateError = const SocialVaultApiException(
        SocialVaultApiError.rejected,
        status: 400,
        code: 'same_vault_key',
      );
      await expectLater(
        service.rotateRemoving(
          vault: vault,
          dataKey: created.dataKey,
          plan: await service.planRemoval(vault, passkey.slotId),
        ),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(await service.loadDataKey(vault.vaultId), created.dataKey);
      expect(platform.entries[vault.vaultId], entriesBefore);
    });

    test('a rotation refused for its signature drops the stale key', () async {
      final (created, vault) = await twoSlots();
      final passkey = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
      );
      backend.rotateError = const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
      );
      await expectLater(
        service.rotateRemoving(
          vault: vault,
          dataKey: created.dataKey,
          plan: await service.planRemoval(vault, passkey.slotId),
        ),
        throwsA(isA<SocialVaultStaleKeyException>()),
      );
      expect(await service.loadDataKey(vault.vaultId), isNull);
    });

    test('sends nothing when nothing could be kept', () async {
      final (created, vault) = await twoSlots();
      final oldPlatform = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.platform,
      );
      platform.available = false;
      passkeys.cancelAssertions = true;
      await expectLater(
        service.rotateRemoving(
          vault: vault,
          dataKey: created.dataKey,
          plan: await service.planRemoval(vault, oldPlatform.slotId),
        ),
        throwsA(isA<SocialVaultUnlockException>()),
      );
      expect(backend.rotated, isNull);
    });
  });

  group('a wrong clock', () {
    const stale = SocialVaultApiException(
      SocialVaultApiError.staleTimestamp,
      status: 401,
      code: 'stale_vault_timestamp',
    );

    test('a write refused for its timestamp keeps the data key', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      final before = storage.values['cache:${created.vault.vaultId}'];
      backend.addError = stale;
      await expectLater(
        service.addPasskeySlot(created.vault, created.dataKey, userName: 'x'),
        throwsA(
          isA<SocialVaultApiException>().having(
            (e) => e.error,
            'error',
            SocialVaultApiError.staleTimestamp,
          ),
        ),
      );
      expect(
        await service.loadDataKey(created.vault.vaultId),
        created.dataKey,
        reason: 'a wrong clock says nothing about the key',
      );
      expect(await service.hasUsableDataKey(created.vault.vaultId), isTrue);
      expect(storage.values['cache:${created.vault.vaultId}'], before);
    });

    test('a rotation refused for its timestamp keeps the data key and the '
        'new platform entry is freed', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      backend.rotateError = stale;
      await expectLater(
        service.rotateRemoving(
          vault: created.vault,
          dataKey: created.dataKey,
          plan: SocialVaultRemovalPlan(
            removing: created.vault.slots.single,
            newPlatformSlot: true,
            passkeysToConfirm: const [],
            dropped: created.vault.slots,
          ),
        ),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(await service.loadDataKey(created.vault.vaultId), created.dataKey);
      expect(platform.entries[created.vault.vaultId]!.keys, [
        created.vault.slots.single.slotId,
      ]);
    });

    test('a status read refused for its timestamp changes nothing', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      backend.statusError = stale;
      expect(
        await service.checkStatus(created.vault.vaultId),
        SocialVaultStatus.failed,
      );
      expect(await service.loadDataKey(created.vault.vaultId), created.dataKey);
    });

    test('a delete refused for its timestamp deletes nothing', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      backend.deleteError = stale;
      await expectLater(
        service.deleteVaultWithLocalKey(created.vault.vaultId),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(await service.loadDataKey(created.vault.vaultId), created.dataKey);
      expect(platform.count, 1, reason: 'the slot secret stays');
    });
  });

  group('sweeping safely', () {
    test('an entry younger than the grace period is never swept', () async {
      final created = await create();
      final vaultId = created.vault.vaultId;
      // Another device wrote this a minute ago and has not added its slot
      // yet: the vault record does not list it.
      platform.entries[vaultId]!['syncing'] = PlatformSlotEntry(
        slotId: 'syncing',
        secret: Uint8List(32),
        createdAt: now.subtract(const Duration(minutes: 1)),
      );
      await sweep(created);
      expect(platform.entries[vaultId]!.keys, contains('syncing'));

      // Still unlisted once the grace period has passed: stale.
      now = now.add(const Duration(minutes: 10));
      await sweep(created);
      expect(platform.entries[vaultId]!.keys, [
        created.vault.slots.single.slotId,
      ]);
    });

    test('an entry with no creation time is old', () async {
      final created = await create();
      final vaultId = created.vault.vaultId;
      platform.entries[vaultId]!['legacy'] = PlatformSlotEntry(
        slotId: 'legacy',
        secret: Uint8List(32),
      );
      await sweep(created);
      expect(platform.entries[vaultId]!.keys, isNot(contains('legacy')));
    });

    test('a live slot is never swept, whatever its age', () async {
      final created = await create();
      now = now.add(const Duration(days: 400));
      await sweep(created);
      expect(platform.count, 1);
    });

    test('an entry carries its creation time, and one without still '
        'parses', () async {
      final created = await create();
      final entry = platform.entries[created.vault.vaultId]!.values.single;
      expect(entry.createdAt, now);
      final parsed = PlatformSlotEntry.tryParse(entry.toJsonString())!;
      expect(parsed.createdAt, now);
      expect(parsed.secret, entry.secret);

      final legacy = PlatformSlotEntry.tryParse(
        PlatformSlotEntry(slotId: 's', secret: Uint8List(32)).toJsonString(),
      )!;
      expect(legacy.createdAt, isNull);
      expect(legacy.slotId, 's');
    });
  });

  group('a creation that was never confirmed', () {
    /// A create whose request got no answer: the entry stays.
    Future<String> unanswered() async {
      backend.createError = const SocialVaultApiException(
        SocialVaultApiError.unavailable,
      );
      await expectLater(create(), throwsA(isA<SocialVaultApiException>()));
      backend.createError = null;
      return platform.entries.keys.single;
    }

    test('is left alone for a day, then deleted once the backend says the '
        'vault does not exist', () async {
      final vaultId = await unanswered();
      expect(platform.count, 1);

      now = now.add(const Duration(hours: 23));
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.notFound,
        status: 404,
      );
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(platform.count, 1, reason: 'not a day old yet');
      expect(backend.statusCalls, 0);

      now = now.add(const Duration(hours: 2));
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(platform.count, 0);
      expect(await service.loadDataKey(vaultId), isNull);
      expect(backend.statusCalls, 1);

      // Settled: nothing left to ask about.
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(backend.statusCalls, 1);
    });

    test('keeps the entry of a vault that does exist', () async {
      final vaultId = await unanswered();
      now = now.add(const Duration(hours: 25));
      backend.statusVault = api.SocialVault.fromJson({
        'vaultId': vaultId,
        'revision': 1,
        'payloadNonce': 'AAAAAAAAAAAAAAAA',
        'payloadCiphertext': 'AAAA',
        'vaultPublicKey': 'PK',
        'slots': [
          {
            'slotId': platform.entries[vaultId]!.keys.single,
            'kind': 'platform',
            'nonce': 'AAAAAAAAAAAAAAAA',
            'wrappedKey': 'AAAA',
            'createdAt': '',
          },
        ],
        'pendingDeletion': null,
        'createdAt': '',
        'updatedAt': '',
      });
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(platform.count, 1, reason: 'it is a live slot secret');
      // Settled: it is not asked about again.
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(backend.statusCalls, 1);
    });

    test('keeps the entry when the backend cannot be asked', () async {
      await unanswered();
      now = now.add(const Duration(hours: 25));
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.unavailable,
      );
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(platform.count, 1);
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.staleTimestamp,
        status: 401,
      );
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(platform.count, 1);
    });

    test('keeps the entry and the key of a vault a wallet here uses', () async {
      final vaultId = await unanswered();
      now = now.add(const Duration(hours: 25));
      await service.sweepAbandonedCreates(referencedVaultIds: {vaultId});
      expect(platform.count, 1);
      expect(await service.loadDataKey(vaultId), isNotNull);
      expect(backend.statusCalls, 0);
    });

    test('never touches an entry this device has no record of '
        'creating', () async {
      // The entry of a wallet removed from this device, restored after a
      // reinstall, or synced from another device: no wallet here uses its
      // vault, and it may be the only thing that opens it.
      platform.entries['someone'] = {
        'x': PlatformSlotEntry(slotId: 'x', secret: Uint8List(32)),
      };
      now = now.add(const Duration(days: 30));
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.notFound,
        status: 404,
      );
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(platform.count, 1);
      expect(backend.statusCalls, 0);
    });

    test('a confirmed or refused create leaves nothing to sweep', () async {
      final created = await create();
      expect(
        await service.loadDataKey(created.vault.vaultId),
        isNull,
        reason: 'kept only once the wallet is stored',
      );
      backend.createError = const SocialVaultApiException(
        SocialVaultApiError.vaultExists,
        status: 409,
        code: 'vault_exists',
      );
      await expectLater(create(), throwsA(isA<SocialVaultApiException>()));
      expect(storage.values.keys.where((k) => k.startsWith('key:')), isEmpty);
      now = now.add(const Duration(days: 2));
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(backend.statusCalls, 0);
      expect(platform.count, 1, reason: 'the created vault keeps its entry');
    });

    test('a vault being created right now is not swept', () async {
      // The entry is written, the request is in flight, and a sweep runs.
      backend.onCreate = () async {
        now = now.add(const Duration(days: 2));
        backend.statusError = const SocialVaultApiException(
          SocialVaultApiError.notFound,
          status: 404,
        );
        await service.sweepAbandonedCreates(referencedVaultIds: const {});
        expect(platform.count, 1);
        expect(backend.statusCalls, 0);
      };
      await create();
      expect(platform.count, 1);
    });
  });

  group('status', () {
    Future<UnlockedSocialVault> persisted() async {
      final created = await create();
      await service.persist(created, provider: 'google', emailHint: 'e');
      backend.statusVault = created.vault;
      return created;
    }

    api.SocialVault withJson(api.SocialVault v, Map<String, Object?> patch) =>
        api.SocialVault.fromJson({...v.toJson(), ...patch});

    test('is read at most once per interval for each vault', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      expect(await service.checkStatus(vaultId), SocialVaultStatus.current);
      now = now.add(const Duration(minutes: 14));
      expect(await service.checkStatus(vaultId), SocialVaultStatus.skipped);
      expect(backend.statusCalls, 1);
      now = now.add(const Duration(minutes: 1));
      expect(await service.checkStatus(vaultId), SocialVaultStatus.current);
      expect(backend.statusCalls, 2);
      expect(
        await service.checkStatus(vaultId, force: true),
        SocialVaultStatus.current,
      );
      expect(backend.statusCalls, 3);
    });

    test('a failed read counts against the interval too', () async {
      final created = await persisted();
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.unavailable,
      );
      expect(
        await service.checkStatus(created.vault.vaultId),
        SocialVaultStatus.failed,
      );
      expect(
        await service.checkStatus(created.vault.vaultId),
        SocialVaultStatus.skipped,
      );
      expect(backend.statusCalls, 1);
    });

    test('is skipped without a data key', () async {
      final created = await create();
      expect(
        await service.checkStatus(created.vault.vaultId),
        SocialVaultStatus.skipped,
      );
      expect(backend.statusCalls, 0);
    });

    test('signs the last known revision and caches the answer', () async {
      final created = await persisted();
      backend.statusVault = withJson(created.vault, {
        'revision': 6,
        'pendingDeletion': {
          'requestedAt': '2026-11-10T00:00:00Z',
          'appliesAt': '2026-11-17T00:00:00Z',
        },
      });
      await service.checkStatus(created.vault.vaultId);
      expect(backend.statusRevisions, [1]);
      final cached = await service.cached(created.vault.vaultId);
      expect(cached!.vault.revision, 6);
      expect(cached.emailHint, 'e', reason: 'what the sign-in stored stays');
      expect(
        (await service.unacknowledgedDeletion(
          created.vault.vaultId,
        ))?.appliesAt,
        '2026-11-17T00:00:00Z',
      );
    });

    test('a vault under another key drops the stale data key', () async {
      final created = await persisted();
      backend.statusVault = withJson(created.vault, {
        'revision': 4,
        'vaultPublicKey': SocialVaultCrypto.base64UrlNoPad(Uint8List(32)),
      });
      expect(
        await service.checkStatus(created.vault.vaultId),
        SocialVaultStatus.staleKey,
      );
      expect(await service.loadDataKey(created.vault.vaultId), isNull);
      expect(
        storage.values['mnemonic:${created.vault.vaultId}'],
        payload.mnemonic,
      );
    });

    test('a signature the backend cannot verify drops the data key', () async {
      final created = await persisted();
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
      );
      expect(
        await service.checkStatus(created.vault.vaultId),
        SocialVaultStatus.staleKey,
      );
      expect(await service.loadDataKey(created.vault.vaultId), isNull);
    });

    test('never throws', () async {
      final created = await persisted();
      backend.statusThrows = StateError('boom');
      expect(
        await service.checkStatus(created.vault.vaultId),
        SocialVaultStatus.failed,
      );
    });
  });

  // "Not found" cannot be authenticated, and it is what a build pointed at
  // the wrong backend, or a backend restored from an older copy, answers for
  // every vault. Believed at once it would cost every platform-only wallet
  // its backup. So it is acted on in steps, each of which can be taken back.
  group('a vault the backend says it does not have', () {
    const notFound = SocialVaultApiException(
      SocialVaultApiError.notFound,
      status: 404,
    );

    Future<UnlockedSocialVault> persisted() async {
      final created = await create();
      await service.persist(created, provider: 'google', emailHint: 'e');
      backend.statusVault = created.vault;
      return created;
    }

    void later(Duration by) => now = now.add(by);

    Future<SocialVaultStatus> check(String vaultId) =>
        service.checkStatus(vaultId, force: true);

    void expectUntouched(UnlockedSocialVault created) {
      expect(platform.count, 1, reason: 'the slot secret stays');
      expect(storage.values['key:${created.vault.vaultId}'], isNotNull);
      expect(storage.values['mnemonic:${created.vault.vaultId}'], isNotNull);
      expect(storage.values['cache:${created.vault.vaultId}'], isNotNull);
    }

    test('one "not found" does nothing', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      expectUntouched(created);

      // Asked again the same day, however often: still nothing.
      later(const Duration(hours: 23, minutes: 59));
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      expectUntouched(created);
      expect(await service.retiredVaults(), isEmpty);
    });

    test('a second one, a day after the first, reports the vault gone — '
        'and still deletes nothing here', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      later(const Duration(hours: 24));
      expect(await check(vaultId), SocialVaultStatus.gone);
      expectUntouched(created);
    });

    test('the vault turning up in between starts the count over', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);

      later(const Duration(hours: 12));
      backend.statusError = null;
      expect(await check(vaultId), SocialVaultStatus.current);

      later(const Duration(hours: 13));
      backend.statusError = notFound;
      expect(
        await check(vaultId),
        SocialVaultStatus.unconfirmedGone,
        reason: 'a day after the first, but the first no longer counts',
      );
      later(const Duration(hours: 23));
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      later(const Duration(hours: 1));
      expect(await check(vaultId), SocialVaultStatus.gone);
    });

    test('a write the backend answers for the vault starts the count '
        'over too', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);

      // A conflict carries the vault: it exists.
      backend.addError = SocialVaultConflictException(
        api.SocialVault.fromJson({...created.vault.toJson(), 'revision': 9}),
      );
      await expectLater(
        service.addPasskeySlot(created.vault, created.dataKey, userName: 'x'),
        throwsA(isA<SocialVaultConflictException>()),
      );
      later(const Duration(hours: 25));
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
    });

    test('a replayed signature shows the vault exists; a wrong clock and '
        'no answer show nothing', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);

      // Neither says anything about the vault: the first one still counts.
      for (final error in const [
        SocialVaultApiError.staleTimestamp,
        SocialVaultApiError.unavailable,
        SocialVaultApiError.rateLimited,
      ]) {
        backend.statusError = SocialVaultApiException(error);
        expect(await check(vaultId), SocialVaultStatus.failed);
      }
      later(const Duration(hours: 24));
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.gone);

      // The backend checked a signature against the vault's key: it is there.
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.replayedSignature,
        status: 401,
      );
      expect(await check(vaultId), SocialVaultStatus.failed);
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
    });

    test('a refused signature starts the count over', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
      );
      expect(await check(vaultId), SocialVaultStatus.staleKey);

      // Signed in again; a day after the first "not found", another one.
      await service.persist(created, provider: 'google');
      later(const Duration(hours: 25));
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
    });

    test('the first sighting survives a restart', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);

      later(const Duration(hours: 24));
      final restarted = SocialVaultService(
        backend,
        platform,
        passkeys,
        storage,
        clock: () => now,
        androidSdkInt: () async => null,
      );
      expect(await restarted.checkStatus(vaultId), SocialVaultStatus.gone);
    });

    test('a clock that went backwards proves no age', () async {
      final created = await persisted();
      final vaultId = created.vault.vaultId;
      backend.statusError = notFound;
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      now = now.subtract(const Duration(days: 3));
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      later(const Duration(hours: 23));
      expect(await check(vaultId), SocialVaultStatus.unconfirmedGone);
      later(const Duration(hours: 1));
      expect(await check(vaultId), SocialVaultStatus.gone);
    });

    group('once its wallet is unlinked', () {
      /// What the unlink does in this class: set the key aside and write the
      /// vault down, then drop the vault's own items.
      Future<UnlockedSocialVault> retired() async {
        final created = await persisted();
        await service.retire(
          created.vault.vaultId,
          accountId: 'account-1',
          provider: 'google',
          identityId: 'identity-1',
        );
        await service.forgetLocal(created.vault.vaultId);
        return created;
      }

      test('keeps the platform entries and sets the data key aside', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        expect(platform.count, 1, reason: 'no slot secret is deleted');
        expect(
          await service.loadDataKey(vaultId),
          isNull,
          reason: 'to the rest of the app the wallet holds no data key',
        );
        expect(await service.hasUsableDataKey(vaultId), isFalse);
        expect(await service.checkStatus(vaultId), SocialVaultStatus.skipped);
        expect(
          storage.values['retired-key:$vaultId'],
          SocialVaultCrypto.base64UrlNoPad(created.dataKey),
        );
        final record = (await service.retiredVaults()).single;
        expect(record.vaultId, vaultId);
        expect(record.accountId, 'account-1');
        expect(record.provider, 'google');
        expect(record.identityId, 'identity-1');
        expect(record.emailHint, 'e');
        expect(record.unlinkedAt, now);
        expect(record.announced, isFalse);

        await service.markRetiredAnnounced(vaultId);
        expect((await service.retiredVaults()).single.announced, isTrue);
      });

      test('is asked about again at most once a day', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        backend
          ..statusCalls = 0
          ..statusError = notFound;
        later(const Duration(hours: 23));
        await service.checkRetired(vaultId);
        expect(backend.statusCalls, 0);
        later(const Duration(hours: 1));
        await service.checkRetired(vaultId);
        await service.checkRetired(vaultId);
        expect(backend.statusCalls, 1);
        later(const Duration(hours: 24));
        await service.checkRetired(vaultId);
        expect(backend.statusCalls, 2);
        expect(platform.count, 1);
      });

      test('"not found" for 29 days deletes nothing', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        backend.statusError = notFound;
        for (var day = 1; day <= 29; day++) {
          later(const Duration(days: 1));
          final check = await service.checkRetired(vaultId);
          expect(check.entriesDeleted, isFalse);
          expect(check.unlocked, isNull);
        }
        expect(platform.count, 1);
        expect(await service.retiredVaults(), hasLength(1));
        expect(storage.values['retired-key:$vaultId'], isNotNull);
      });

      test(
        '30 days old and "not found" again: the entries are deleted',
        () async {
          final created = await retired();
          final vaultId = created.vault.vaultId;
          later(const Duration(days: 30));
          backend.statusError = notFound;
          final check = await service.checkRetired(vaultId);
          expect(check.entriesDeleted, isTrue);
          expect(platform.count, 0);
          expect(await service.retiredVaults(), isEmpty);
          expect(storage.values['retired-key:$vaultId'], isNull);
        },
      );

      test('30 days old is not enough without a fresh "not found"', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        later(const Duration(days: 45));
        for (final error in const [
          SocialVaultApiError.unavailable,
          SocialVaultApiError.rateLimited,
          SocialVaultApiError.staleTimestamp,
          SocialVaultApiError.rejected,
        ]) {
          backend.statusError = SocialVaultApiException(error);
          final check = await service.checkRetired(vaultId);
          expect(check.entriesDeleted, isFalse);
          expect(platform.count, 1, reason: '${error.name} deletes nothing');
          expect(await service.retiredVaults(), hasLength(1));
        }
        backend
          ..statusError = null
          ..statusThrows = StateError('offline');
        await service.checkRetired(vaultId);
        expect(platform.count, 1);
      });

      test('without the key set aside nothing can be asked, so nothing is '
          'deleted', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        storage.values.remove('retired-key:$vaultId');
        later(const Duration(days: 60));
        backend
          ..statusCalls = 0
          ..statusError = notFound;
        final check = await service.checkRetired(vaultId);
        expect(check.entriesDeleted, isFalse);
        expect(backend.statusCalls, 0);
        expect(platform.count, 1);
      });

      test('a vault that is there after all is handed back opened, with '
          'everything still in place', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        later(const Duration(days: 40));
        backend.statusError = null;
        final check = await service.checkRetired(vaultId);
        expect(check.entriesDeleted, isFalse);
        expect(check.unlocked!.payload.mnemonic, payload.mnemonic);
        expect(check.unlocked!.dataKey, created.dataKey);
        expect(platform.count, 1);

        // Linking the wallet back keeps the key and stops the watch.
        await service.persist(check.unlocked!, provider: 'google');
        expect(await service.loadDataKey(vaultId), created.dataKey);
        expect(await service.retiredVaults(), isEmpty);
        expect(storage.values['retired-key:$vaultId'], isNull);
        expect(platform.count, 1);
      });

      test('a vault that is there under another key is no longer watched, '
          'and keeps its entries', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        later(const Duration(days: 40));
        backend.statusVault = api.SocialVault.fromJson({
          ...created.vault.toJson(),
          'vaultPublicKey': SocialVaultCrypto.base64UrlNoPad(Uint8List(32)),
        });
        final check = await service.checkRetired(vaultId);
        expect(check.unlocked, isNull);
        expect(check.entriesDeleted, isFalse);
        expect(platform.count, 1);
        expect(await service.retiredVaults(), isEmpty);
        expect(storage.values['retired-key:$vaultId'], isNull);
      });

      test('a wallet that left the device stops the watch without touching '
          'the entries', () async {
        final created = await retired();
        await service.forgetRetired(created.vault.vaultId);
        expect(await service.retiredVaults(), isEmpty);
        expect(storage.values['retired-key:${created.vault.vaultId}'], isNull);
        expect(platform.count, 1);
      });

      test('a clock that went backwards proves no age', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        now = now.subtract(const Duration(days: 90));
        backend.statusError = notFound;
        final check = await service.checkRetired(vaultId);
        expect(check.entriesDeleted, isFalse);
        expect(platform.count, 1);
      });
    });
  });

  group('a pending deletion', () {
    const pending = {
      'requestedAt': '2026-11-10T00:00:00Z',
      'appliesAt': '2026-11-17T00:00:00Z',
    };

    Future<String> pendingVault() async {
      final created = await create();
      await service.persist(created, provider: 'google');
      backend.statusVault = api.SocialVault.fromJson({
        ...created.vault.toJson(),
        'pendingDeletion': pending,
      });
      await service.checkStatus(created.vault.vaultId);
      return created.vault.vaultId;
    }

    test('is reported until "it was me" is said for that request', () async {
      final vaultId = await pendingVault();
      expect(await service.unacknowledgedDeletion(vaultId), isNotNull);
      await service.acknowledgeDeletion(vaultId, '2026-11-10T00:00:00Z');
      expect(await service.unacknowledgedDeletion(vaultId), isNull);

      // A status read of the same request does not bring it back.
      await service.checkStatus(vaultId, force: true);
      expect(await service.unacknowledgedDeletion(vaultId), isNull);

      // A new request does.
      backend.statusVault = api.SocialVault.fromJson({
        ...backend.statusVault!.toJson(),
        'pendingDeletion': {...pending, 'requestedAt': '2026-12-01T00:00:00Z'},
      });
      await service.checkStatus(vaultId, force: true);
      expect(await service.unacknowledgedDeletion(vaultId), isNotNull);
    });

    test('is cancelled with a signed write, retried on a conflict', () async {
      final vaultId = await pendingVault();
      // Another device wrote first: the cancel is re-signed for its revision.
      backend.cancelConflictAt = 5;
      final kept = await service.cancelDeletion(vaultId);
      expect(backend.cancelRevisions, [1, 5]);
      expect(kept.pendingDeletion, isNull);
      expect(await service.unacknowledgedDeletion(vaultId), isNull);
      expect((await service.cached(vaultId))!.vault.revision, 6);
    });

    test('cannot be cancelled without the data key', () async {
      final created = await create();
      await expectLater(
        service.cancelDeletion(created.vault.vaultId),
        throwsA(isA<SocialVaultStaleKeyException>()),
      );
      expect(backend.cancelRevisions, isEmpty);
    });

    test('a cancel refused for its timestamp keeps the data key', () async {
      final vaultId = await pendingVault();
      backend.cancelError = const SocialVaultApiException(
        SocialVaultApiError.staleTimestamp,
        status: 401,
      );
      await expectLater(
        service.cancelDeletion(vaultId),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(await service.loadDataKey(vaultId), isNotNull);
      expect(await service.unacknowledgedDeletion(vaultId), isNotNull);
    });
  });

  group('sign-in keys this device has seen', () {
    api.SocialVault withSlot(api.SocialVault v, String slotId) =>
        api.SocialVault.fromJson({
          ...v.toJson(),
          'revision': v.revision + 1,
          'slots': [
            for (final s in v.slots) s.toJson(),
            {
              'slotId': slotId,
              'kind': 'passkey-prf',
              'nonce': 'AAAAAAAAAAAAAAAA',
              'wrappedKey': 'AAAA',
              'label': 'Passkey · Elsewhere',
              'createdAt': '2026-11-10T09:00:00Z',
            },
          ],
        });

    test('the first record a device sees is its baseline, silently', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      expect(await service.unseenSlots(created.vault.vaultId), isEmpty);
      expect((await service.cached(created.vault.vaultId))!.seenSlotIds, [
        created.vault.slots.single.slotId,
      ]);
    });

    test('a key added elsewhere is unseen until the user is told', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      final vaultId = created.vault.vaultId;
      backend.statusVault = withSlot(created.vault, 'elsewhere');
      await service.checkStatus(vaultId);
      expect((await service.unseenSlots(vaultId)).map((s) => s.slotId), [
        'elsewhere',
      ]);

      // Another read does not make it seen.
      await service.checkStatus(vaultId, force: true);
      expect(await service.unseenSlots(vaultId), hasLength(1));

      await service.acknowledgeSlots(vaultId, ['elsewhere']);
      expect(await service.unseenSlots(vaultId), isEmpty);
    });

    test('a sign-in that returns an unseen key keeps it unseen', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      final later = withSlot(created.vault, 'elsewhere');
      await service.persist(created.withVault(later), provider: 'google');
      expect(
        (await service.unseenSlots(created.vault.vaultId)).single.slotId,
        'elsewhere',
      );
    });

    test('a key this device adds is seen without a notice', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      final updated = await service.addPasskeySlot(
        created.vault,
        created.dataKey,
        userName: 'x',
      );
      expect(updated.slots, hasLength(2));
      expect(await service.unseenSlots(created.vault.vaultId), isEmpty);
    });

    test('a write that also returns another device\'s key leaves that one '
        'unseen', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      backend.addAlsoReturns = {
        'slotId': 'elsewhere',
        'kind': 'platform',
        'nonce': 'AAAAAAAAAAAAAAAA',
        'wrappedKey': 'AAAA',
        'createdAt': '2026-11-10T09:00:00Z',
      };
      await service.addPasskeySlot(
        created.vault,
        created.dataKey,
        userName: 'x',
      );
      expect(
        (await service.unseenSlots(created.vault.vaultId)).map((s) => s.slotId),
        ['elsewhere'],
      );
    });

    test('no record means no baseline, never "all seen"', () async {
      final created = await create();
      final vaultId = created.vault.vaultId;
      await service.persist(created, provider: 'google');
      // The record is lost (the plugin store was cleared), and a status read
      // then returns a vault with a key added in the meantime.
      storage.values.remove('cache:$vaultId');
      expect(await service.unseenSlots(vaultId), isEmpty);
      backend.statusVault = withSlot(created.vault, 'elsewhere');
      await service.checkStatus(vaultId);
      expect(
        await service.unseenSlots(vaultId),
        isEmpty,
        reason: 'nothing to compare against: this record is the baseline',
      );
      expect((await service.cached(vaultId))!.seenSlotIds, hasLength(2));
    });

    test('a record written before the list existed has no baseline', () async {
      final created = await create();
      final vaultId = created.vault.vaultId;
      storage.values['cache:$vaultId'] =
          '{"vault":${created.vault.toString()},"provider":"google",'
          '"emailHint":null}';
      expect((await service.cached(vaultId))!.seenSlotIds, isNull);
      expect(await service.unseenSlots(vaultId), isEmpty);
    });

    test('a rotation by this device shows no notice', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      now = now.add(const Duration(minutes: 11));
      await service.rotateRemoving(
        vault: created.vault,
        dataKey: created.dataKey,
        plan: await service.planRemoval(
          created.vault,
          created.vault.slots.single.slotId,
        ),
      );
      expect(await service.unseenSlots(created.vault.vaultId), isEmpty);
    });
  });

  group('deleting the vault', () {
    test('signs the delete and forgets the platform entries, but keeps this '
        'device\'s copy for the caller to drop after unlinking', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      final vaultId = created.vault.vaultId;
      expect(
        await service.deleteVaultWithLocalKey(vaultId),
        SocialVaultDeletion.deleted,
      );
      expect(backend.deletedRevisions, [1]);
      expect(platform.count, 0, reason: 'a signed delete frees them at once');
      expect(await service.loadDataKey(vaultId), created.dataKey);
      expect(await service.hasMnemonic(vaultId), isTrue);

      await service.keepMnemonicForAccount(vaultId, 'account-1');
      expect(storage.values['account-mnemonic:account-1'], payload.mnemonic);
      await service.forgetLocal(vaultId);
      expect(await service.loadDataKey(vaultId), isNull);
      expect(await service.hasMnemonic(vaultId), isFalse);
      expect(await service.cached(vaultId), isNull);
    });

    test('a delete answered "not found" deletes nothing: this device did '
        'not see one go through', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      backend.deleteError = const SocialVaultApiException(
        SocialVaultApiError.notFound,
        status: 404,
      );
      expect(
        await service.deleteVaultWithLocalKey(created.vault.vaultId),
        SocialVaultDeletion.notFound,
      );
      expect(platform.count, 1, reason: 'the slot secret stays');
      expect(await service.loadDataKey(created.vault.vaultId), created.dataKey);
    });

    test('a delete with no answer deletes nothing here', () async {
      final created = await create();
      await service.persist(created, provider: 'google');
      backend.deleteError = const SocialVaultApiException(
        SocialVaultApiError.unavailable,
      );
      await expectLater(
        service.deleteVaultWithLocalKey(created.vault.vaultId),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(platform.count, 1);
    });
  });

  test('a passkey that reports its id in another spelling still matches its '
      'slot', () async {
    platform.available = false;
    final created = await create();
    final slot = created.vault.slots.single;
    expect(slot.credentialId, isNot(contains('=')));
    // The authenticator answers with the same id, padded.
    passkeys.answerAs = '${slot.credentialId}==';
    final unlocked = await service.unlock(created.vault);
    expect(unlocked.dataKey, created.dataKey);
    expect(
      SocialVaultCrypto.canonicalCredentialId('ab+/cd=='),
      'ab-_cd',
      reason: 'base64 and base64url, padded or not, are one id',
    );
  });

  test('persist keeps the data key and phrase in the vault store', () async {
    final created = await create();
    await service.persist(created, provider: 'google', emailHint: 'e');
    expect(await service.loadDataKey(created.vault.vaultId), created.dataKey);
    expect(
      storage.values['mnemonic:${created.vault.vaultId}'],
      payload.mnemonic,
    );
    final cached = await service.cached(created.vault.vaultId);
    expect(cached!.vault.vaultId, created.vault.vaultId);
    expect(cached.emailHint, 'e');
    expect(
      cached.toJsonString(),
      isNot(contains(payload.mnemonic)),
      reason: 'the cache holds only what the backend already serves',
    );
  });

  // ---------------------------------------------------------------------------
  // What follows pins the rules a wrong answer, or two things happening at
  // once, must not be able to break.
  // ---------------------------------------------------------------------------

  /// Let everything that can run without an answer run.
  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Wait until [reached], which something already started brings about.
  Future<void> until(bool Function() reached) async {
    for (var i = 0; i < 2000 && !reached(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(reached(), isTrue, reason: 'never got there');
  }

  /// A wallet kept on this device: created, persisted, and known to the
  /// backend.
  Future<UnlockedSocialVault> kept() async {
    final created = await create();
    await service.persist(created, provider: 'google', emailHint: 'e');
    backend.statusVault = created.vault;
    return created;
  }

  /// Rewrite a stored JSON record as an earlier build left it: without the
  /// backend it belongs to.
  void forgetOrigin(String key) {
    storage.values[key] = storage.values[key]!.replaceAll(
      '"apiOrigin":"$here"',
      '"apiOrigin":null',
    );
    expect(storage.values[key], isNot(contains(here)));
  }

  // The backend's own answer: a 404 carrying its code.
  const noSuchVault = SocialVaultApiException(
    SocialVaultApiError.notFound,
    status: 404,
    code: 'vault_not_found',
  );
  // What the API layer makes of any other 404: a proxy's, a backend without
  // the routes (no code), or one that names something else.
  const bare404 = SocialVaultApiException(
    SocialVaultApiError.unavailable,
    status: 404,
  );
  const other404 = SocialVaultApiException(
    SocialVaultApiError.unavailable,
    status: 404,
    code: 'not_found',
  );

  group('"no such vault" is believed only as the backend\'s own answer, '
      'from the backend the vault lives on', () {
    void expectUntouched(UnlockedSocialVault created) {
      final vaultId = created.vault.vaultId;
      expect(platform.count, 1, reason: 'the slot secret stays');
      expect(storage.values['key:$vaultId'], isNotNull);
      expect(storage.values['mnemonic:$vaultId'], isNotNull);
      expect(storage.values['cache:$vaultId'], isNotNull);
      expect(
        storage.values['missing'] ?? '',
        isNot(contains(vaultId)),
        reason: 'not even written down',
      );
    }

    test('the origin is scheme, host and port in one spelling', () {
      expect(SocialVaultService.originOf('https://backend.test/v2'), here);
      expect(SocialVaultService.originOf('HTTPS://Backend.Test:443/v2/'), here);
      expect(
        SocialVaultService.originOf('https://backend.test:8443/v2'),
        'https://backend.test:8443',
      );
      expect(
        SocialVaultService.originOf('http://backend.test/v2'),
        'http://backend.test:80',
      );
      expect(SocialVaultService.originOf(''), isNull);
      expect(SocialVaultService.originOf('/v2'), isNull);
    });

    test('every record of a vault names the backend that showed it', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      expect((await service.cached(vaultId))!.apiOrigin, here);
      expect(await service.checkStatus(vaultId), SocialVaultStatus.current);
      expect((await service.cached(vaultId))!.apiOrigin, here);
    });

    group('a status read', () {
      test('a 404 that is not the backend\'s own never adds up to '
          '"gone"', () async {
        final created = await kept();
        final vaultId = created.vault.vaultId;
        for (final answer in const [bare404, other404]) {
          backend.statusError = answer;
          for (var day = 0; day < 3; day++) {
            expect(
              await service.checkStatus(vaultId, force: true),
              SocialVaultStatus.failed,
            );
            now = now.add(const Duration(hours: 25));
          }
          expectUntouched(created);
        }
        // The backend's own answer is still acted on, in its two steps.
        backend.statusError = noSuchVault;
        expect(
          await service.checkStatus(vaultId, force: true),
          SocialVaultStatus.unconfirmedGone,
        );
      });

      test('a vault that lives on another backend is not asked about, '
          'whatever that backend would say', () async {
        final created = await kept();
        final vaultId = created.vault.vaultId;
        origin = elsewhere;
        backend
          ..statusCalls = 0
          ..statusError = noSuchVault;
        for (var day = 0; day < 3; day++) {
          expect(
            await service.checkStatus(vaultId, force: true),
            SocialVaultStatus.skipped,
          );
          now = now.add(const Duration(hours: 25));
        }
        expect(backend.statusCalls, 0);
        expectUntouched(created);

        // Another port on the same host is another backend.
        origin = 'https://backend.test:8443';
        expect(
          await service.checkStatus(vaultId, force: true),
          SocialVaultStatus.skipped,
        );
        // And so is a build that names none.
        origin = null;
        expect(
          await service.checkStatus(vaultId, force: true),
          SocialVaultStatus.skipped,
        );
        expect(backend.statusCalls, 0);

        // Back on its own backend, the count starts only now.
        origin = here;
        expect(
          await service.checkStatus(vaultId, force: true),
          SocialVaultStatus.unconfirmedGone,
        );
      });

      test('a record that names no backend takes this one only from an '
          'answer that shows the vault here — never from a 404', () async {
        final created = await kept();
        final vaultId = created.vault.vaultId;
        forgetOrigin('cache:$vaultId');
        expect((await service.cached(vaultId))!.apiOrigin, isNull);

        backend.statusError = noSuchVault;
        for (var day = 0; day < 3; day++) {
          expect(
            await service.checkStatus(vaultId, force: true),
            SocialVaultStatus.failed,
          );
          now = now.add(const Duration(hours: 25));
        }
        expectUntouched(created);
        expect((await service.cached(vaultId))!.apiOrigin, isNull);

        backend.statusError = null;
        expect(
          await service.checkStatus(vaultId, force: true),
          SocialVaultStatus.current,
        );
        expect((await service.cached(vaultId))!.apiOrigin, here);
        backend.statusError = noSuchVault;
        expect(
          await service.checkStatus(vaultId, force: true),
          SocialVaultStatus.unconfirmedGone,
        );
      });

      test('a signature the backend checked against the vault\'s key shows '
          'the vault here too', () async {
        for (final refusal in const [
          SocialVaultApiError.replayedSignature,
          SocialVaultApiError.signatureRejected,
        ]) {
          final created = await kept();
          final vaultId = created.vault.vaultId;
          forgetOrigin('cache:$vaultId');
          backend.statusError = SocialVaultApiException(refusal, status: 401);
          await service.checkStatus(vaultId, force: true);
          expect(
            (await service.cached(vaultId))!.apiOrigin,
            here,
            reason: refusal.name,
          );
        }
      });

      test('a wrong clock shows nothing', () async {
        final created = await kept();
        final vaultId = created.vault.vaultId;
        forgetOrigin('cache:$vaultId');
        backend.statusError = const SocialVaultApiException(
          SocialVaultApiError.staleTimestamp,
          status: 401,
        );
        await service.checkStatus(vaultId, force: true);
        expect((await service.cached(vaultId))!.apiOrigin, isNull);
      });
    });

    group('the sweep of a creation that was never confirmed', () {
      Future<String> unanswered() async {
        backend.createError = const SocialVaultApiException(
          SocialVaultApiError.unavailable,
        );
        await expectLater(create(), throwsA(isA<SocialVaultApiException>()));
        backend.createError = null;
        now = now.add(const Duration(hours: 25));
        return platform.entries.keys.single;
      }

      test('a 404 that is not the backend\'s own deletes nothing', () async {
        final vaultId = await unanswered();
        for (final answer in const [bare404, other404]) {
          backend.statusError = answer;
          await service.sweepAbandonedCreates(referencedVaultIds: const {});
          expect(platform.count, 1);
          expect(await service.loadDataKey(vaultId), isNotNull);
        }
        expect(backend.statusCalls, 2, reason: 'still asked about next time');

        backend.statusError = noSuchVault;
        await service.sweepAbandonedCreates(referencedVaultIds: const {});
        expect(platform.count, 0);
        expect(await service.loadDataKey(vaultId), isNull);
      });

      test('a creation sent to another backend is not asked about', () async {
        final vaultId = await unanswered();
        origin = elsewhere;
        backend.statusError = noSuchVault;
        await service.sweepAbandonedCreates(referencedVaultIds: const {});
        expect(backend.statusCalls, 0);
        expect(platform.count, 1);
        expect(await service.loadDataKey(vaultId), isNotNull);
      });

      test('a record that names no backend is asked about, and only "it '
          'exists" is acted on', () async {
        final vaultId = await unanswered();
        forgetOrigin('pending-creates');
        backend.statusError = noSuchVault;
        await service.sweepAbandonedCreates(referencedVaultIds: const {});
        expect(backend.statusCalls, 1);
        expect(platform.count, 1);
        expect(await service.loadDataKey(vaultId), isNotNull);

        backend
          ..statusError = null
          ..statusVault = api.SocialVault.fromJson({
            'vaultId': vaultId,
            'revision': 1,
            'payloadNonce': 'AAAAAAAAAAAAAAAA',
            'payloadCiphertext': 'AAAA',
            'vaultPublicKey': 'PK',
            'slots': [
              {
                'slotId': platform.entries[vaultId]!.keys.single,
                'kind': 'platform',
                'nonce': 'AAAAAAAAAAAAAAAA',
                'wrappedKey': 'AAAA',
                'createdAt': '',
              },
            ],
            'pendingDeletion': null,
            'createdAt': '',
            'updatedAt': '',
          });
        await service.sweepAbandonedCreates(referencedVaultIds: const {});
        expect(platform.count, 1, reason: 'a live slot secret');
        await service.sweepAbandonedCreates(referencedVaultIds: const {});
        expect(backend.statusCalls, 2, reason: 'settled');
      });

      test('an answer about another vault settles nothing', () async {
        final vaultId = await unanswered();
        final other = await create();
        platform.entries.remove(other.vault.vaultId);
        backend.statusVault = other.vault;
        await service.sweepAbandonedCreates(referencedVaultIds: const {});
        expect(platform.entries[vaultId], hasLength(1));
        expect(await service.loadDataKey(vaultId), isNotNull);
        await service.sweepAbandonedCreates(referencedVaultIds: const {});
        expect(backend.statusCalls, 2, reason: 'still asked about');
      });
    });

    group('a vault whose wallet was unlinked', () {
      Future<UnlockedSocialVault> retired() async {
        final created = await kept();
        await service.retire(
          created.vault.vaultId,
          accountId: 'account-1',
          provider: 'google',
        );
        await service.forgetLocal(created.vault.vaultId);
        backend.statusCalls = 0;
        return created;
      }

      test('its record names the backend itself: the cached record is gone '
          'by the time it is asked about', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        expect(await service.cached(vaultId), isNull);
        expect((await service.retiredVaults()).single.apiOrigin, here);

        final restarted = SocialVaultService(
          backend,
          platform,
          passkeys,
          storage,
          clock: () => now,
          androidSdkInt: () async => null,
          apiOrigin: () => elsewhere,
        );
        now = now.add(const Duration(days: 45));
        backend.statusError = noSuchVault;
        final check = await restarted.checkRetired(vaultId);
        expect(check.entriesDeleted, isFalse);
        expect(backend.statusCalls, 0, reason: 'another backend is not asked');
        expect(platform.count, 1);
        expect(storage.values['retired-key:$vaultId'], isNotNull);
        expect(await service.retiredVaults(), hasLength(1));

        // On its own backend that answer frees the entries.
        expect((await service.checkRetired(vaultId)).entriesDeleted, isTrue);
        expect(platform.count, 0);
      });

      test('a 404 that is not the backend\'s own frees nothing, however '
          'old the unlink', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        for (final answer in const [bare404, other404]) {
          now = now.add(const Duration(days: 45));
          backend.statusError = answer;
          final check = await service.checkRetired(vaultId);
          expect(check.entriesDeleted, isFalse);
          expect(platform.count, 1);
          expect(await service.retiredVaults(), hasLength(1));
          expect(storage.values['retired-key:$vaultId'], isNotNull);
        }
        expect(backend.statusCalls, 2);
      });

      test('a record that names no backend never frees the entries on a '
          '"not found", and still finds a vault that is there', () async {
        final created = await retired();
        final vaultId = created.vault.vaultId;
        forgetOrigin('missing');
        expect((await service.retiredVaults()).single.apiOrigin, isNull);

        now = now.add(const Duration(days: 45));
        backend.statusError = noSuchVault;
        expect((await service.checkRetired(vaultId)).entriesDeleted, isFalse);
        expect(platform.count, 1);
        // Asked, and not again the same day.
        await service.checkRetired(vaultId);
        expect(backend.statusCalls, 1);

        now = now.add(const Duration(days: 1));
        backend.statusError = null;
        final check = await service.checkRetired(vaultId);
        expect(check.unlocked!.dataKey, created.dataKey);
        expect(platform.count, 1);
      });

      test('an answer about another vault is no answer', () async {
        final created = await retired();
        final other = await create();
        platform.entries.remove(other.vault.vaultId);
        now = now.add(const Duration(days: 45));
        backend.statusVault = other.vault;
        final check = await service.checkRetired(created.vault.vaultId);
        expect(check.unlocked, isNull);
        expect(check.entriesDeleted, isFalse);
        expect(await service.retiredVaults(), hasLength(1));
        expect(platform.count, 1);
      });
    });

    group('a delete the user asked for', () {
      test('a 404 that is not the backend\'s own is a failed delete: '
          'nothing is reported done and nothing is deleted', () async {
        final created = await kept();
        final vaultId = created.vault.vaultId;
        for (final answer in const [bare404, other404]) {
          backend.deleteError = answer;
          await expectLater(
            service.deleteVaultWithLocalKey(vaultId),
            throwsA(
              isA<SocialVaultApiException>().having(
                (e) => e.error,
                'error',
                SocialVaultApiError.unavailable,
              ),
            ),
          );
          expect(platform.count, 1);
          expect(await service.loadDataKey(vaultId), created.dataKey);
          expect(await service.cached(vaultId), isNotNull);
        }
        // The backend's own answer is "not found", and still deletes
        // nothing here.
        backend.deleteError = noSuchVault;
        expect(
          await service.deleteVaultWithLocalKey(vaultId),
          SocialVaultDeletion.notFound,
        );
        expect(platform.count, 1);
      });

      test('is not sent to a backend the vault does not live on', () async {
        final created = await kept();
        final vaultId = created.vault.vaultId;
        origin = elsewhere;
        backend.statusCalls = 0;
        for (final answer in <SocialVaultApiException?>[null, noSuchVault]) {
          backend.deleteError = answer;
          await expectLater(
            service.deleteVaultWithLocalKey(vaultId),
            throwsA(isA<SocialVaultApiException>()),
          );
        }
        expect(backend.deleteCalls, 0);
        expect(backend.statusCalls, 0);
        expect(platform.count, 1);
        expect(await service.loadDataKey(vaultId), created.dataKey);
      });

      test('for a record that names no backend, the vault must first be '
          'seen here', () async {
        final created = await kept();
        final vaultId = created.vault.vaultId;
        forgetOrigin('cache:$vaultId');
        backend
          ..statusCalls = 0
          ..statusError = noSuchVault
          ..deleteError = noSuchVault;
        await expectLater(
          service.deleteVaultWithLocalKey(vaultId),
          throwsA(isA<SocialVaultApiException>()),
        );
        expect(backend.statusCalls, 1);
        expect(backend.deleteCalls, 0, reason: 'never shown to exist here');
        expect(platform.count, 1);

        backend
          ..statusError = null
          ..deleteError = null;
        expect(
          await service.deleteVaultWithLocalKey(vaultId),
          SocialVaultDeletion.deleted,
        );
        expect(platform.count, 0);
      });
    });
  });

  // A 4xx with no code of the backend's on it is what a proxy, or a backend
  // without these routes, answers. The request may never have reached the
  // backend that holds the vault — or may have been carried out there.
  group('only a refusal by the backend itself undoes what a request '
      'prepared', () {
    test('create: the entry and the key kept for it stay, to be settled '
        'by asking later', () async {
      for (final answer in const [
        bare404,
        other404,
        SocialVaultApiException(SocialVaultApiError.rejected, status: 400),
      ]) {
        backend.createError = answer;
        await expectLater(create(), throwsA(isA<SocialVaultApiException>()));
      }
      expect(platform.count, 3, reason: 'each may be a vault\'s only slot');
      for (final vaultId in platform.entries.keys) {
        expect(await service.loadDataKey(vaultId), isNotNull);
      }
      expect(backend.created, isNull);

      // A day on the backend says, in its own words, that none exists.
      backend.createError = null;
      now = now.add(const Duration(hours: 25));
      backend.statusError = noSuchVault;
      await service.sweepAbandonedCreates(referencedVaultIds: const {});
      expect(platform.count, 0);
      expect(storage.values.keys.where((k) => k.startsWith('key:')), isEmpty);
    });

    test('create: the backend\'s own refusal frees them', () async {
      backend.createError = const SocialVaultApiException(
        SocialVaultApiError.identityRejected,
        status: 401,
        code: 'invalid_identity_token',
      );
      await expectLater(create(), throwsA(isA<SocialVaultApiException>()));
      expect(platform.count, 0);
      expect(storage.values.keys.where((k) => k.startsWith('key:')), isEmpty);
    });

    test('a platform slot for this device: its entry stays', () async {
      platform.available = false;
      final created = await create();
      platform.available = true;
      for (final answer in const [bare404, other404]) {
        backend.addError = answer;
        await expectLater(
          service.ensurePlatformSlot(created.vault, created.dataKey),
          throwsA(isA<SocialVaultApiException>()),
        );
      }
      expect(platform.count, 2, reason: 'either slot may have been added');

      backend.addError = noSuchVault;
      await expectLater(
        service.ensurePlatformSlot(created.vault, created.dataKey),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(platform.count, 2, reason: 'the backend\'s own refusal frees it');
    });

    test('a rotation: the new entry stays', () async {
      final (created, vault) = await twoSlots();
      final passkey = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
      );
      final before = platform.entries[vault.vaultId]!.length;
      backend.rotateError = bare404;
      await expectLater(
        service.rotateRemoving(
          vault: vault,
          dataKey: created.dataKey,
          plan: await service.planRemoval(vault, passkey.slotId),
        ),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(
        platform.entries[vault.vaultId],
        hasLength(before + 1),
        reason: 'the rotation may have happened',
      );
      expect(await service.loadDataKey(vault.vaultId), created.dataKey);

      backend.rotateError = noSuchVault;
      await expectLater(
        service.rotateRemoving(
          vault: vault,
          dataKey: created.dataKey,
          plan: await service.planRemoval(vault, passkey.slotId),
        ),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect(platform.entries[vault.vaultId], hasLength(before + 1));
    });
  });

  group('an answer must be about the vault that was asked about', () {
    api.SocialVault another(api.SocialVault v) => api.SocialVault.fromJson({
      ...v.toJson(),
      'vaultId': 'ERITFBUWFxgZGhscHR4fIA',
      'revision': 40,
      'vaultPublicKey': SocialVaultCrypto.base64UrlNoPad(Uint8List(32)),
    });

    test('a status answer about another vault is a failed read: nothing is '
        'cached under either id, and the data key stays', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      backend.statusVault = another(created.vault);
      expect(
        await service.checkStatus(vaultId, force: true),
        SocialVaultStatus.failed,
      );
      expect(await service.loadDataKey(vaultId), created.dataKey);
      expect((await service.cached(vaultId))!.vault.revision, 1);
      expect(await service.cached('ERITFBUWFxgZGhscHR4fIA'), isNull);
    });

    test('a status answer without its slots is a failed read', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      backend.statusVault = api.SocialVault.fromJson(
        {...created.vault.toJson(), 'revision': 2}..remove('slots'),
      );
      expect(
        await service.checkStatus(vaultId, force: true),
        SocialVaultStatus.failed,
      );
      expect((await service.cached(vaultId))!.vault.slots, hasLength(1));
      expect(await service.loadDataKey(vaultId), created.dataKey);
    });

    test('a conflict that carries another vault fails the write: its '
        'revision is not adopted, nothing is cached, the key stays', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      backend.addError = SocialVaultConflictException(another(created.vault));
      await expectLater(
        service.addPasskeySlot(created.vault, created.dataKey, userName: 'x'),
        throwsA(
          isA<SocialVaultApiException>()
              .having(
                (e) => e is SocialVaultConflictException,
                'conflict',
                false,
              )
              .having(
                (e) => e.error,
                'error',
                SocialVaultApiError.malformedResponse,
              ),
        ),
      );
      expect(backend.addCalls, 1, reason: 'not re-signed for that revision');
      expect(await service.loadDataKey(vaultId), created.dataKey);
      expect((await service.cached(vaultId))!.vault.revision, 1);
      expect(await service.cached('ERITFBUWFxgZGhscHR4fIA'), isNull);
    });

    test('a write answered with another vault\'s record is a failed '
        'write', () async {
      final created = await kept();
      backend.cancelError = null;
      backend.statusVault = another(created.vault);
      await expectLater(
        service.cancelDeletion(created.vault.vaultId),
        throwsA(isA<SocialVaultApiException>()),
      );
      expect((await service.cached(created.vault.vaultId))!.vault.revision, 1);
      expect(await service.cached('ERITFBUWFxgZGhscHR4fIA'), isNull);
    });
  });

  // A status read is signed with the data key as it is when the read starts,
  // and a rotation replaces that key. Crossed, the read's answer — "that
  // signature does not verify", or the record from before the rotation —
  // would be acted on against the new key.
  group('a read and a write on one vault never cross', () {
    test('a status read asked for during a rotation waits for it, and is '
        'then signed with the new key', () async {
      final (created, vault) = await twoSlots();
      final vaultId = vault.vaultId;
      final passkey = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
      );
      final plan = await service.planRemoval(vault, passkey.slotId);
      backend
        ..live = vault
        ..rotateGate = Completer<void>();

      final rotation = service.rotateRemoving(
        vault: vault,
        dataKey: created.dataKey,
        plan: plan,
      );
      await until(() => backend.rotateCalls == 1);
      // The app comes back to the foreground: a status check starts.
      final read = service.checkStatus(vaultId, force: true);
      await settle();
      expect(backend.statusCalls, 0, reason: 'not while the rotation is out');

      backend.rotateGate!.complete();
      final rotated = (await rotation).vault;
      expect(await read, SocialVaultStatus.current);
      expect(backend.statusSignedBy, [rotated.vaultPublicKey]);
      final key = await service.loadDataKey(vaultId);
      expect(key, isNotNull, reason: 'the new key was not dropped');
      expect(key, isNot(created.dataKey));
      expect(await service.hasUsableDataKey(vaultId), isTrue);
      expect((await service.cached(vaultId))!.vault.revision, rotated.revision);
    });

    test('a rotation asked for during a status read waits for its '
        'answer', () async {
      final (created, vault) = await twoSlots();
      final vaultId = vault.vaultId;
      final passkey = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
      );
      final plan = await service.planRemoval(vault, passkey.slotId);
      backend
        ..live = vault
        ..statusGate = Completer<void>();

      final read = service.checkStatus(vaultId, force: true);
      await until(() => backend.statusCalls == 1);
      final rotation = service.rotateRemoving(
        vault: vault,
        dataKey: created.dataKey,
        plan: plan,
      );
      await settle();
      expect(backend.rotateCalls, 0, reason: 'not while the read is out');

      backend.statusGate!.complete();
      expect(await read, SocialVaultStatus.current);
      final rotated = (await rotation).vault;
      expect(backend.statusSignedBy, [vault.vaultPublicKey]);
      final key = await service.loadDataKey(vaultId);
      expect(key, isNotNull);
      expect(key, isNot(created.dataKey));
      expect((await service.cached(vaultId))!.vault.revision, rotated.revision);
    });

    test('a refusal is about the key that signed: a newer key stored since '
        'is not the one dropped', () async {
      final (created, vault) = await twoSlots();
      final vaultId = vault.vaultId;
      final passkey = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
      );
      final rotated = await service.rotateRemoving(
        vault: vault,
        dataKey: created.dataKey,
        plan: await service.planRemoval(vault, passkey.slotId),
      );
      final newKey = await service.loadDataKey(vaultId);

      // A screen still holding the key from before the rotation writes
      // with it, and the backend refuses that signature.
      backend.addError = const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
        code: 'invalid_vault_signature',
      );
      await expectLater(
        service.addPasskeySlot(
          rotated.vault,
          created.dataKey,
          userName: 'person',
        ),
        throwsA(isA<SocialVaultStaleKeyException>()),
      );
      expect(await service.loadDataKey(vaultId), newKey);
      expect(await service.hasUsableDataKey(vaultId), isTrue);
    });

    test('an answer older than the cached record never replaces it, and is '
        'no evidence about the key in use now', () async {
      final (created, vault) = await twoSlots();
      final vaultId = vault.vaultId;
      final passkey = vault.slots.firstWhere(
        (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
      );
      final rotated = (await service.rotateRemoving(
        vault: vault,
        dataKey: created.dataKey,
        plan: await service.planRemoval(vault, passkey.slotId),
      )).vault;
      final newKey = await service.loadDataKey(vaultId);

      // The record from before the rotation, under the old vault key.
      backend
        ..live = null
        ..statusVault = vault;
      expect(
        await service.checkStatus(vaultId, force: true),
        SocialVaultStatus.failed,
      );
      expect((await service.cached(vaultId))!.vault.revision, rotated.revision);
      expect(
        (await service.cached(vaultId))!.vault.vaultPublicKey,
        rotated.vaultPublicKey,
      );
      expect(await service.loadDataKey(vaultId), newKey);
      expect(await service.hasUsableDataKey(vaultId), isTrue);
      expect(await service.staleKeyNoticeDue(vaultId), isFalse);

      // The same for a conflict that carries an older record.
      backend.addError = SocialVaultConflictException(
        api.SocialVault.fromJson({...rotated.toJson(), 'revision': 1}),
      );
      await expectLater(
        service.addPasskeySlot(rotated, newKey!, userName: 'person'),
        throwsA(isA<SocialVaultConflictException>()),
      );
      expect((await service.cached(vaultId))!.vault.revision, rotated.revision);
      expect(await service.loadDataKey(vaultId), newKey);
    });

    test('a key this device adds is never announced to it, however a '
        'status read falls', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      backend
        ..live = created.vault
        ..addGate = Completer<void>();
      final adding = service.addPasskeySlot(
        created.vault,
        created.dataKey,
        userName: 'person',
      );
      await until(() => backend.addCalls == 1);
      final read = service.checkStatus(vaultId, force: true);
      await settle();
      expect(backend.statusCalls, 0);

      backend.addGate!.complete();
      final added = await adding;
      expect(await read, SocialVaultStatus.current);
      expect(added.slots, hasLength(2));
      expect((await service.cached(vaultId))!.vault.slots, hasLength(2));
      expect(
        await service.unseenSlots(vaultId),
        isEmpty,
        reason: 'the user\'s own new passkey is not "a key that was added"',
      );
    });

    test('a notice acknowledged while a status answer arrives loses '
        'neither', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      backend.statusVault = api.SocialVault.fromJson({
        ...created.vault.toJson(),
        'revision': 2,
        'slots': [
          created.vault.slots.single.toJson(),
          {
            ...created.vault.slots.single.toJson(),
            'slotId': 'AAAAAAAAAAAAAAAAAAAAAA',
          },
        ],
      });
      // The acknowledgement has read the record and not yet written it.
      storage.cacheReadGate = Completer<void>();
      final gate = storage.cacheReadGate!;
      final acknowledged = service.acknowledgeDeletion(vaultId, 'request-1');
      final read = service.checkStatus(vaultId, force: true);
      await until(() => backend.statusCalls == 1);
      await settle();
      gate.complete();
      await acknowledged;
      expect(await read, SocialVaultStatus.current);

      final cached = (await service.cached(vaultId))!;
      expect(cached.vault.revision, 2, reason: 'the newer record is kept');
      expect(cached.acknowledgedDeletion, 'request-1');
      expect(
        (await service.unseenSlots(vaultId)).single.slotId,
        'AAAAAAAAAAAAAAAAAAAAAA',
      );
    });

    test('a sweep does not take the key a sign-in is in the middle of '
        'keeping', () async {
      // A create whose answer was lost: the vault exists, the entry and the
      // key kept for asking about it are here.
      backend.createError = const SocialVaultApiException(
        SocialVaultApiError.unavailable,
      );
      await expectLater(create(), throwsA(isA<SocialVaultApiException>()));
      backend.createError = null;
      final vaultId = platform.entries.keys.single;
      final dataKey = (await service.loadDataKey(vaultId))!;
      final vault = api.SocialVault.fromJson({
        'vaultId': vaultId,
        'revision': 1,
        'payloadNonce': 'AAAAAAAAAAAAAAAA',
        'payloadCiphertext': 'AAAA',
        'vaultPublicKey': 'PK',
        'slots': [
          {
            'slotId': platform.entries[vaultId]!.keys.single,
            'kind': 'platform',
            'nonce': 'AAAAAAAAAAAAAAAA',
            'wrappedKey': 'AAAA',
            'createdAt': '',
          },
        ],
        'pendingDeletion': null,
        'createdAt': '',
        'updatedAt': '',
      });
      now = now.add(const Duration(hours: 25));
      backend.statusVault = vault;

      // The sign-in has opened the vault and stored its data key; it has
      // not yet settled the creation.
      storage.mnemonicWriteGate = Completer<void>();
      final gate = storage.mnemonicWriteGate!;
      final persisting = service.persist(
        UnlockedSocialVault(
          vault: vault,
          dataKey: dataKey,
          payload: payload,
          openedWithSlotId: vault.slots.single.slotId,
        ),
        provider: 'google',
      );
      await settle();
      // The sweep runs, with a wallet list read before the sign-in stored
      // its rows. The backend would tell it the vault exists, and it would
      // drop the key "kept for asking" — the wallet's key by now.
      final sweeping = service.sweepAbandonedCreates(
        referencedVaultIds: const {},
      );
      await settle();
      expect(backend.statusCalls, 0, reason: 'not while the sign-in is at it');
      gate.complete();
      await persisting;
      await sweeping;

      expect(
        await service.loadDataKey(vaultId),
        dataKey,
        reason: 'the wallet\'s key now',
      );
      expect(backend.statusCalls, 0, reason: 'settled: nothing to ask about');
      expect(platform.count, 1);
    });
  });

  // A sign-in fetches the vault record and then waits on the user, for as
  // long as they like. On a shared iCloud Keychain another device's new
  // entry arrives meanwhile, before this device has heard of its slot.
  group('the entry sweep reads the slot list itself', () {
    PlatformSlotEntry entryOf(String slotId) => PlatformSlotEntry(
      slotId: slotId,
      secret: Uint8List(32),
      createdAt: now.subtract(const Duration(minutes: 30)),
    );

    test('an entry of a slot added since the record in hand was read is '
        'kept', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      // Added on another device while this one sat on a passkey sheet.
      platform.entries[vaultId]!['AAAAAAAAAAAAAAAAAAAAAA'] = entryOf(
        'AAAAAAAAAAAAAAAAAAAAAA',
      );
      platform.entries[vaultId]!['stale'] = entryOf('stale');
      backend.statusVault = api.SocialVault.fromJson({
        ...created.vault.toJson(),
        'revision': 2,
        'slots': [
          created.vault.slots.single.toJson(),
          {
            ...created.vault.slots.single.toJson(),
            'slotId': 'AAAAAAAAAAAAAAAAAAAAAA',
          },
        ],
      });
      backend.statusCalls = 0;

      await service.sweepPlatformEntries(vaultId, created.dataKey);
      expect(backend.statusCalls, 1);
      expect(
        platform.entries[vaultId]!.keys,
        unorderedEquals([
          created.vault.slots.single.slotId,
          'AAAAAAAAAAAAAAAAAAAAAA',
        ]),
        reason: 'only the entry of no slot is swept',
      );
    });

    test('an answer older than the record this device holds sweeps '
        'nothing', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      // This device has seen revision 2, with a second slot.
      platform.entries[vaultId]!['AAAAAAAAAAAAAAAAAAAAAA'] = entryOf(
        'AAAAAAAAAAAAAAAAAAAAAA',
      );
      backend.statusVault = api.SocialVault.fromJson({
        ...created.vault.toJson(),
        'revision': 2,
        'slots': [
          created.vault.slots.single.toJson(),
          {
            ...created.vault.slots.single.toJson(),
            'slotId': 'AAAAAAAAAAAAAAAAAAAAAA',
          },
        ],
      });
      await service.sweepPlatformEntries(vaultId, created.dataKey);
      expect(platform.entries[vaultId], hasLength(2));

      // A copy of the vault from before that slot was added answers next:
      // its list lacks the slot, and must not cost the slot its entry.
      backend.statusVault = created.vault;
      await service.sweepPlatformEntries(vaultId, created.dataKey);
      expect(
        platform.entries[vaultId]!.keys,
        contains('AAAAAAAAAAAAAAAAAAAAAA'),
      );
      expect((await service.cached(vaultId))!.vault.revision, 2);
    });

    test('without a record read now, nothing is swept', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      platform.entries[vaultId]!['stale'] = entryOf('stale');

      for (final answer in const [
        SocialVaultApiException(SocialVaultApiError.unavailable),
        SocialVaultApiException(SocialVaultApiError.rateLimited, status: 429),
        bare404,
        noSuchVault,
        SocialVaultApiException(
          SocialVaultApiError.signatureRejected,
          status: 401,
        ),
      ]) {
        backend.statusError = answer;
        await service.sweepPlatformEntries(vaultId, created.dataKey);
        expect(platform.entries[vaultId], hasLength(2), reason: '$answer');
      }
      expect(await service.loadDataKey(vaultId), created.dataKey);

      // A record under another vault key, or of another vault, is not one
      // this key speaks for.
      backend.statusError = null;
      for (final patch in <Map<String, Object?>>[
        {'vaultPublicKey': SocialVaultCrypto.base64UrlNoPad(Uint8List(32))},
        {'vaultId': 'ERITFBUWFxgZGhscHR4fIA'},
      ]) {
        backend.statusVault = api.SocialVault.fromJson({
          ...created.vault.toJson(),
          ...patch,
        });
        await service.sweepPlatformEntries(vaultId, created.dataKey);
        expect(platform.entries[vaultId], hasLength(2));
      }
    });
  });

  group('a key found stale without the user asking', () {
    test('is said once: by a status read, until told or signed in '
        'again', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      expect(await service.staleKeyNoticeDue(vaultId), isFalse);
      backend.statusError = const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
      );
      expect(
        await service.checkStatus(vaultId, force: true),
        SocialVaultStatus.staleKey,
      );
      expect(await service.staleKeyNoticeDue(vaultId), isTrue);
      // Still due at the next check, which has no key to read with.
      expect(await service.checkStatus(vaultId), SocialVaultStatus.skipped);
      expect(await service.staleKeyNoticeDue(vaultId), isTrue);

      await service.markStaleKeyAnnounced(vaultId);
      expect(await service.staleKeyNoticeDue(vaultId), isFalse);

      // A second occurrence is said again.
      await service.persist(created, provider: 'google');
      await service.checkStatus(vaultId, force: true);
      expect(await service.staleKeyNoticeDue(vaultId), isTrue);
      // Signing in again answers it.
      await service.persist(created, provider: 'google');
      expect(await service.staleKeyNoticeDue(vaultId), isFalse);
    });

    test('a record under another key marks it too', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      backend.statusVault = api.SocialVault.fromJson({
        ...created.vault.toJson(),
        'revision': 4,
        'vaultPublicKey': SocialVaultCrypto.base64UrlNoPad(Uint8List(32)),
      });
      expect(
        await service.checkStatus(vaultId, force: true),
        SocialVaultStatus.staleKey,
      );
      expect(await service.staleKeyNoticeDue(vaultId), isTrue);
    });

    test('a write the user made reports it there and then, with no notice '
        'to follow', () async {
      final created = await kept();
      backend.addError = const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
      );
      await expectLater(
        service.addPasskeySlot(created.vault, created.dataKey, userName: 'x'),
        throwsA(isA<SocialVaultStaleKeyException>()),
      );
      expect(await service.staleKeyNoticeDue(created.vault.vaultId), isFalse);
    });
  });

  group('an unlink is written down until it is finished', () {
    test('begun, it is remembered across a restart; dropping this '
        'device\'s copy crosses it out', () async {
      final created = await kept();
      final vaultId = created.vault.vaultId;
      await service.beginUnlink(vaultId, 'account-1');
      final restarted = SocialVaultService(
        backend,
        platform,
        passkeys,
        storage,
        clock: () => now,
        androidSdkInt: () async => null,
      );
      final pending = (await restarted.pendingUnlinks()).single;
      expect(pending.vaultId, vaultId);
      expect(pending.accountId, 'account-1');

      await service.forgetLocal(vaultId);
      expect(await service.pendingUnlinks(), isEmpty);
      expect(await service.loadDataKey(vaultId), isNull);
    });

    test('a sign-in that links the wallet again crosses it out', () async {
      final created = await kept();
      await service.beginUnlink(created.vault.vaultId, 'account-1');
      await service.persist(created, provider: 'google');
      expect(await service.pendingUnlinks(), isEmpty);
      expect(await service.loadDataKey(created.vault.vaultId), isNotNull);
    });

    test('an unlink that cannot be written down is not begun', () async {
      final created = await kept();
      storage.failMissingWrites = true;
      await expectLater(
        service.beginUnlink(created.vault.vaultId, 'account-1'),
        throwsA(isA<PlatformException>()),
      );
      storage.failMissingWrites = false;
      expect(await service.pendingUnlinks(), isEmpty);
    });
  });
}

class _Backend implements SocialVaultApi {
  api.SocialVaultCreateRequest? created;
  SocialVaultApiException? createError;

  /// Runs while a create request is in flight.
  Future<void> Function()? onCreate;

  @override
  Future<api.SocialVault> create(api.SocialVaultCreateRequest request) async {
    await onCreate?.call();
    if (createError != null) throw createError!;
    created = request;
    return api.SocialVault(
      vaultId: request.vaultId,
      revision: 1,
      payloadNonce: request.payloadNonce,
      payloadCiphertext: request.payloadCiphertext,
      vaultPublicKey: request.vaultPublicKey,
      slots: [for (final s in request.slots) _slot(s)],
      pendingDeletion: null,
      createdAt: '',
      updatedAt: '',
    );
  }

  /// Thrown by every addSlot call while set.
  SocialVaultApiException? addError;

  /// Held open while set: the request is sent and its answer has not come.
  Completer<void>? addGate;
  Completer<void>? statusGate;
  Completer<void>? rotateGate;

  /// The vault as the last write left it. With [live] set, a status read
  /// answers with it — or, signed by a key that is not its vault key, is
  /// refused the way the backend refuses one.
  api.SocialVault? live;

  /// The vault public key each status read was signed with.
  final statusSignedBy = <String>[];
  int addCalls = 0;
  int rotateCalls = 0;

  @override
  Future<api.SocialVault> addSlot({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
    required api.SocialVaultNewSlot slot,
  }) async {
    addCalls++;
    await addGate?.future;
    if (addError != null) throw addError!;
    final request = created!;
    return live = api.SocialVault(
      vaultId: vaultId,
      revision: revision + 1,
      payloadNonce: request.payloadNonce,
      payloadCiphertext: request.payloadCiphertext,
      vaultPublicKey: request.vaultPublicKey,
      slots: [
        for (final s in request.slots) _slot(s),
        if (addAlsoReturns != null)
          api.SocialVaultSlot.fromJson(addAlsoReturns!),
        _slot(slot),
      ],
      pendingDeletion: null,
      createdAt: '',
      updatedAt: '',
    );
  }

  /// A slot another device added, returned by the next addSlot beside the
  /// one this device adds.
  Map<String, dynamic>? addAlsoReturns;

  api.SocialVault? statusVault;
  SocialVaultApiException? statusError;
  Object? statusThrows;
  int statusCalls = 0;
  final statusRevisions = <int>[];

  @override
  Future<api.SocialVault> status({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
  }) async {
    statusCalls++;
    statusRevisions.add(revision);
    final signedBy = await SocialVaultCrypto.vaultPublicKey(vaultKey);
    statusSignedBy.add(signedBy);
    await statusGate?.future;
    if (statusThrows != null) throw statusThrows!;
    if (statusError != null) throw statusError!;
    final live = this.live;
    if (live == null) return statusVault!;
    if (live.vaultPublicKey != signedBy) {
      throw const SocialVaultApiException(
        SocialVaultApiError.signatureRejected,
        status: 401,
        code: 'invalid_vault_signature',
      );
    }
    return live;
  }

  SocialVaultApiException? cancelError;
  int? cancelConflictAt;
  final cancelRevisions = <int>[];

  @override
  Future<api.SocialVault> cancelDeletion({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
  }) async {
    cancelRevisions.add(revision);
    if (cancelError != null) throw cancelError!;
    final conflictAt = cancelConflictAt;
    if (conflictAt != null && revision != conflictAt) {
      throw SocialVaultConflictException(
        api.SocialVault.fromJson({
          ...statusVault!.toJson(),
          'revision': conflictAt,
        }),
      );
    }
    return api.SocialVault.fromJson({
      ...statusVault!.toJson(),
      'revision': revision + 1,
      'pendingDeletion': null,
    });
  }

  SocialVaultApiException? deleteError;
  final deletedRevisions = <int>[];
  int deleteCalls = 0;

  @override
  Future<void> delete({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
  }) async {
    deleteCalls++;
    if (deleteError != null) throw deleteError!;
    deletedRevisions.add(revision);
  }

  SocialVaultApiException? removeError;
  SocialVaultApiException? rotateError;
  api.SocialVaultRotateRequest? rotated;

  @override
  Future<api.SocialVault> rotate({
    required SimpleKeyPair currentVaultKey,
    required api.SocialVaultRotateRequest request,
  }) async {
    rotateCalls++;
    await rotateGate?.future;
    if (rotateError != null) throw rotateError!;
    rotated = request;
    return live = api.SocialVault(
      vaultId: request.vaultId,
      revision: request.revision + 1,
      payloadNonce: request.payloadNonce,
      payloadCiphertext: request.payloadCiphertext,
      vaultPublicKey: request.vaultPublicKey,
      slots: [for (final s in request.slots) _slot(s)],
      pendingDeletion: null,
      createdAt: '',
      updatedAt: '',
    );
  }

  @override
  Future<api.SocialVault> removeSlot({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
    required String slotId,
  }) async {
    if (removeError != null) throw removeError!;
    final request = created!;
    return api.SocialVault(
      vaultId: vaultId,
      revision: revision + 1,
      payloadNonce: request.payloadNonce,
      payloadCiphertext: request.payloadCiphertext,
      vaultPublicKey: request.vaultPublicKey,
      slots: [
        for (final s in request.slots)
          if (s.slotId != slotId) _slot(s),
      ],
      pendingDeletion: null,
      createdAt: '',
      updatedAt: '',
    );
  }

  final renamed = <(String, String, int)>[];

  @override
  Future<api.SocialVault> renameSlot({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
    required String slotId,
    required String label,
  }) async {
    renamed.add((slotId, label, revision));
    final request = created!;
    return api.SocialVault(
      vaultId: vaultId,
      revision: revision + 1,
      payloadNonce: request.payloadNonce,
      payloadCiphertext: request.payloadCiphertext,
      vaultPublicKey: request.vaultPublicKey,
      slots: [
        for (final s in request.slots)
          s.slotId == slotId
              ? api.SocialVaultSlot.fromJson({
                  ...s.toJson(),
                  'label': label.isEmpty ? null : label,
                  'createdAt': '',
                })
              : _slot(s),
      ],
      pendingDeletion: null,
      createdAt: '',
      updatedAt: '',
    );
  }

  static api.SocialVaultSlot _slot(api.SocialVaultNewSlot s) =>
      api.SocialVaultSlot.fromJson({...s.toJson(), 'createdAt': ''});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformSlotStore {
  bool available = true;
  void Function()? onWrite;

  /// Stand in for Block Store rather than iCloud Keychain: the backup can
  /// lose its end-to-end encryption, and entries carry a cloud-backup flag.
  bool android = false;

  /// Whether that backup is end-to-end encrypted (a screen lock is set).
  bool encrypted = true;

  /// `<vaultId>.<slotId>` → in the cloud backup.
  final cloud = <String, bool>{};

  @override
  bool get backupCanLoseEncryption => android;

  @override
  Future<bool> isBackupEncrypted() async => !android || encrypted;

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
  }) async {
    if (entries[vaultId]?[slotId] == null) {
      throw PlatformException(code: 'not_found');
    }
    return cloud['$vaultId.$slotId'] = enabled && encrypted;
  }

  /// vaultId -> slotId -> entry, like the per-(vault, slot) native items.
  final entries = <String, Map<String, PlatformSlotEntry>>{};

  int get count => entries.values.fold(0, (n, m) => n + m.length);

  @override
  Future<bool> isAvailable() async => available && (!android || encrypted);

  @override
  Future<List<PlatformSlotEntry>> readAll(String vaultId) async =>
      available ? [...?entries[vaultId]?.values] : const [];

  bool fullError = false;

  @override
  Future<bool> add(String vaultId, PlatformSlotEntry entry) async {
    if (fullError) throw PlatformException(code: 'store_full');
    onWrite?.call();
    final forVault = entries.putIfAbsent(vaultId, () => {});
    if (forVault.containsKey(entry.slotId)) {
      throw PlatformException(code: 'exists');
    }
    forVault[entry.slotId] = entry;
    return cloud['$vaultId.${entry.slotId}'] = !android || encrypted;
  }

  @override
  Future<void> delete(String vaultId, String slotId) async =>
      entries[vaultId]?.remove(slotId);
}

/// A PRF stand-in: the output is a fixed function of credential and salt,
/// which is the property the vault relies on.
class _Passkeys implements PasskeyPrfAuthenticator {
  bool supported = true;
  bool cancelAssertions = false;
  String? answerAs;
  int registrations = 0;
  int assertions = 0;

  static Uint8List _prf(String credentialId, List<int> salt) =>
      Uint8List.fromList([
        for (var i = 0; i < 32; i++)
          (salt[i] ^ credentialId.codeUnitAt(i % credentialId.length)) & 0xff,
      ]);

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<PasskeyPrfResult> register({
    required String rpId,
    required String userId,
    required String userName,
    required Uint8List salt,
    List<String> excludeCredentialIds = const [],
  }) async {
    registrations++;
    final id = 'cred$registrations';
    return PasskeyPrfResult(credentialId: id, output: _prf(id, salt));
  }

  @override
  Future<PasskeyPrfResult> authenticate({
    required String rpId,
    required List<PasskeyPrfCandidate> candidates,
  }) async {
    assertions++;
    if (cancelAssertions) {
      throw const PasskeyPrfException(PasskeyPrfError.cancelled);
    }
    final c = candidates.first;
    return PasskeyPrfResult(
      credentialId: answerAs ?? c.credentialId,
      output: _prf(c.credentialId, c.salt),
    );
  }
}

class _Storage implements SecureWalletStorage {
  final values = <String, String>{};

  @override
  Future<void> storeSocialVaultDataKey(String vaultId, String dataKey) async =>
      values['key:$vaultId'] = dataKey;

  @override
  Future<String?> loadSocialVaultDataKey(String vaultId) async =>
      values['key:$vaultId'];

  /// Holds the next write of a vault's phrase until completed.
  Completer<void>? mnemonicWriteGate;

  @override
  Future<void> storeSocialVaultMnemonic(String vaultId, String mnemonic) async {
    final gate = mnemonicWriteGate;
    mnemonicWriteGate = null;
    await gate?.future;
    values['mnemonic:$vaultId'] = mnemonic;
  }

  @override
  Future<void> storeSocialVaultCache(String vaultId, String json) async =>
      values['cache:$vaultId'] = json;

  /// Holds the next read of a cached record until completed: the record
  /// has been read, and its reader has not got it yet.
  Completer<void>? cacheReadGate;

  @override
  Future<String?> loadSocialVaultCache(String vaultId) async {
    final gate = cacheReadGate;
    cacheReadGate = null;
    final value = values['cache:$vaultId'];
    await gate?.future;
    return value;
  }

  @override
  Future<void> deleteSocialVaultDataKey(String vaultId) async =>
      values.remove('key:$vaultId');

  @override
  Future<void> deleteSocialVaultCache(String vaultId) async =>
      values.remove('cache:$vaultId');

  @override
  Future<String?> loadSocialVaultMnemonic(String vaultId) async =>
      values['mnemonic:$vaultId'];

  @override
  Future<void> deleteSocialVaultMnemonic(String vaultId) async =>
      values.remove('mnemonic:$vaultId');

  @override
  Future<void> storeSocialAccountMnemonic(
    String accountId,
    String mnemonic,
  ) async => values['account-mnemonic:$accountId'] = mnemonic;

  /// The plugin store refuses the next writes of the missing-vault record.
  bool failMissingWrites = false;

  @override
  Future<void> storeSocialVaultMissing(String json) async {
    if (failMissingWrites) throw PlatformException(code: 'write_failed');
    values['missing'] = json;
  }

  @override
  Future<String?> loadSocialVaultMissing() async => values['missing'];

  @override
  Future<void> storeSocialVaultRetiredKey(
    String vaultId,
    String dataKey,
  ) async => values['retired-key:$vaultId'] = dataKey;

  @override
  Future<String?> loadSocialVaultRetiredKey(String vaultId) async =>
      values['retired-key:$vaultId'];

  @override
  Future<void> deleteSocialVaultRetiredKey(String vaultId) async =>
      values.remove('retired-key:$vaultId');

  @override
  Future<void> storeSocialVaultBackupState(String json) async =>
      values['backup-state'] = json;

  @override
  Future<String?> loadSocialVaultBackupState() async => values['backup-state'];

  @override
  Future<void> storeSocialVaultPendingCreates(String json) async =>
      values['pending-creates'] = json;

  @override
  Future<String?> loadSocialVaultPendingCreates() async =>
      values['pending-creates'];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
