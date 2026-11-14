import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/social_vault/platform_backup_guard.dart';
import 'package:mallow_wallet/core/social_vault/platform_slot_store.dart';

/// The state machine that keeps a phone backup of slot secrets honest, run
/// against a stand-in for Block Store: entries with a cloud-backup flag, and
/// an end-to-end encryption state the test turns on and off.
void main() {
  late _Store store;
  late _Storage storage;
  late PlatformBackupGuard guard;
  late DateTime now;

  setUp(() {
    store = _Store();
    storage = _Storage();
    now = DateTime.utc(2026, 11, 10, 12);
    guard = PlatformBackupGuard(store, storage, clock: () => now);
  });

  /// An entry written while the backup was encrypted, the way the vault
  /// service writes one: added, then noted.
  Future<void> write(String vaultId, String slotId) async {
    final cloudBacked = await store.add(vaultId, _entry(slotId));
    await guard.recordWrite(vaultId, slotId, cloudBacked: cloudBacked);
  }

  test('an encrypted backup with entries in it is left alone', () async {
    await write('v1', 's1');
    final status = await guard.check();

    expect(status.encrypted, isTrue);
    expect(status.paused, isFalse);
    expect(status.exposedVaultIds, isEmpty);
    expect(status.isCloudBacked('v1', 's1'), isTrue);
    expect(store.rewrites, isEmpty);
  });

  group('the backup loses its encryption', () {
    test('every entry is rewritten as device-only and the backup is '
        'paused', () async {
      await write('v1', 's1');
      await write('v2', 's2');
      store.encrypted = false;

      final status = await guard.check();

      expect(store.cloud, {'v1.s1': false, 'v2.s2': false});
      expect(status.encrypted, isFalse);
      expect(status.paused, isTrue);
      expect(status.pausedVaultIds, {'v1', 'v2'});
      expect(status.pausedSince, now);
      expect(status.isCloudBacked('v1', 's1'), isFalse);
      // The same values, nothing deleted.
      expect(store.entries.keys, {'v1.s1', 'v2.s2'});
      expect(store.deletes, 0);
    });

    test('entries that were in the cloud backup mark their vaults as '
        'exposed, with the time first seen', () async {
      await write('v1', 's1');
      store.encrypted = false;

      final status = await guard.check();

      expect(status.exposedVaultIds, {'v1'});
      expect(status.exposedSince, now);
      expect(status.replacementOffered, isFalse);
      // Not offered while the phone still has no screen lock: a replacement
      // could not make a new device key.
      expect(status.replacementOfferDue({'v1'}), isFalse);
    });

    test('an entry written device-only is not an exposure', () async {
      store.encrypted = false;
      // The native side keeps such an entry out of the cloud backup.
      await write('v1', 's1');
      expect(store.cloud['v1.s1'], isFalse);

      final status = await guard.check();

      expect(status.paused, isTrue);
      expect(status.exposedVaultIds, isEmpty);
      expect(store.rewrites, isEmpty);
    });

    test('an entry this device has no record of counts as in the cloud '
        'backup', () async {
      // Restored from a backup, say: in the store, never noted.
      await store.add('v1', _entry('s1'));
      store.encrypted = false;

      final status = await guard.check();

      expect(store.cloud['v1.s1'], isFalse);
      expect(status.exposedVaultIds, {'v1'});
    });

    test('the time first seen is kept across later checks', () async {
      await write('v1', 's1');
      store.encrypted = false;
      await guard.check();
      final first = now;
      now = now.add(const Duration(hours: 3));

      final status = await guard.check();

      expect(status.pausedSince, first);
      expect(status.exposedSince, first);
      // Already device-only: nothing is rewritten twice.
      expect(store.rewrites, hasLength(1));
    });

    test('with no entries nothing is paused', () async {
      store.encrypted = false;
      final status = await guard.check();
      expect(status.encrypted, isFalse);
      expect(status.paused, isFalse);
      expect(status.pausedSince, isNull);
    });
  });

  group('the encryption comes back', () {
    setUp(() async {
      await write('v1', 's1');
      store.encrypted = false;
      await guard.check();
      store.encrypted = true;
      now = now.add(const Duration(days: 1));
    });

    test('entries go back into the cloud backup and the pause ends', () async {
      final status = await guard.check();

      expect(store.cloud, {'v1.s1': true});
      expect(status.encrypted, isTrue);
      expect(status.paused, isFalse);
      expect(status.pausedSince, isNull);
      expect(status.isCloudBacked('v1', 's1'), isTrue);
    });

    test('the exposure is still remembered, and now offered', () async {
      final status = await guard.check();

      expect(status.exposedVaultIds, {'v1'});
      expect(status.replacementOfferDue({'v1'}), isTrue);
      // Only for a vault a wallet here uses.
      expect(status.replacementOfferDue({'other'}), isFalse);
    });

    test('the offer is made once', () async {
      await guard.check();
      await guard.markReplacementOffered();

      expect(guard.status.value.replacementOfferDue({'v1'}), isFalse);
      // …and the next check does not bring it back.
      final status = await guard.check();
      expect(status.replacementOfferDue({'v1'}), isFalse);
      // The advice itself stays until the keys are replaced or dismissed.
      expect(status.exposedVaultIds, {'v1'});
    });

    test('replacing the keys clears the exposure', () async {
      await guard.check();
      await guard.keysReplaced('v1');

      final status = guard.status.value;
      expect(status.exposedVaultIds, isEmpty);
      expect(status.exposedSince, isNull);
      expect((await guard.check()).exposedVaultIds, isEmpty);
    });

    test('dismissing clears the exposure', () async {
      await guard.check();
      await guard.dismissExposure();

      expect(guard.status.value.exposedVaultIds, isEmpty);
      expect((await guard.check()).exposedVaultIds, isEmpty);
    });

    test('a second unprotected period is offered again', () async {
      await guard.check();
      await guard.markReplacementOffered();
      await guard.keysReplaced('v1');

      store.encrypted = false;
      await guard.check();
      store.encrypted = true;
      final status = await guard.check();

      expect(status.exposedVaultIds, {'v1'});
      expect(status.replacementOfferDue({'v1'}), isTrue);
    });
  });

  group('errors read as not encrypted, and delete nothing', () {
    test('a rewrite that fails leaves the entry, and is retried', () async {
      await write('v1', 's1');
      store
        ..encrypted = false
        ..failRewrites = true;

      final status = await guard.check();

      expect(status.paused, isTrue);
      expect(status.exposedVaultIds, {'v1'});
      // Still where it was, as far as this device knows.
      expect(status.isCloudBacked('v1', 's1'), isTrue);
      expect(store.entries.keys, {'v1.s1'});
      expect(store.deletes, 0);

      store.failRewrites = false;
      await guard.check();
      expect(store.cloud['v1.s1'], isFalse);
    });

    test('a store that cannot be listed pauses on what is recorded, and '
        'never throws', () async {
      await write('v1', 's1');
      store
        ..encrypted = false
        ..failList = true;

      final status = await guard.check();

      expect(status.encrypted, isFalse);
      expect(status.pausedVaultIds, {'v1'});
      expect(status.exposedVaultIds, {'v1'});
      expect(store.rewrites, isEmpty);
      expect(store.deletes, 0);
    });

    test('an unreadable record is no record: entries count as in the cloud '
        'backup', () async {
      await store.add('v1', _entry('s1'));
      storage.value = 'not json';
      store.encrypted = false;

      final status = await guard.check();

      expect(store.cloud['v1.s1'], isFalse);
      expect(status.exposedVaultIds, {'v1'});
    });

    test('the native side never backs up while unencrypted, whatever is '
        'asked', () async {
      await write('v1', 's1');
      store.encrypted = false;
      await guard.check();
      // The app reads "encrypted" while the store itself still says no (the
      // state changed between the two calls).
      store
        ..encrypted = true
        ..refuseCloud = true;

      final status = await guard.check();

      expect(store.cloud['v1.s1'], isFalse);
      expect(status.isCloudBacked('v1', 's1'), isFalse);
    });
  });

  test('entries that are gone drop out of the record and the '
      'exposure', () async {
    await write('v1', 's1');
    store.encrypted = false;
    await guard.check();
    await store.delete('v1', 's1');
    store.encrypted = true;

    final status = await guard.check();

    expect(status.cloudBacked, isEmpty);
    expect(status.exposedVaultIds, isEmpty);
  });

  test('the record survives a restart', () async {
    await write('v1', 's1');
    store.encrypted = false;
    await guard.check();

    final again = PlatformBackupGuard(store, storage, clock: () => now);
    store.encrypted = true;
    final status = await again.check();

    expect(status.exposedVaultIds, {'v1'});
    expect(status.replacementOfferDue({'v1'}), isTrue);
    // Nothing secret is in it: ids, flags and times.
    final record = jsonDecode(storage.value!) as Map<String, dynamic>;
    expect(record.keys.toSet(), {
      'v',
      'cloud',
      'pausedSince',
      'exposed',
      'exposedSince',
      'offered',
    });
  });

  test('concurrent checks share one run', () async {
    await write('v1', 's1');
    store.encrypted = false;
    final results = await Future.wait([guard.check(), guard.check()]);
    expect(identical(results[0], results[1]), isTrue);
    expect(store.rewrites, hasLength(1));
  });

  test('a platform whose backup cannot lose its encryption is never '
      'asked', () async {
    store.canLoseEncryption = false;
    await store.add('v1', _entry('s1'));

    final status = await guard.check();
    await guard.recordWrite('v1', 's1', cloudBacked: true);
    await guard.dismissExposure();

    expect(status.encrypted, isTrue);
    expect(status.paused, isFalse);
    expect(store.encryptionReads, 0);
    expect(store.lists, 0);
    expect(storage.value, isNull);
  });
}

PlatformSlotEntry _entry(String slotId) =>
    PlatformSlotEntry(slotId: slotId, secret: Uint8List(32));

/// Block Store, as far as the guard can tell.
class _Store implements PlatformSlotStore {
  bool canLoseEncryption = true;
  bool encrypted = true;
  bool failRewrites = false;
  bool failList = false;

  /// The store's own view says "not encrypted" even when asked to back up.
  bool refuseCloud = false;

  final entries = <String, PlatformSlotEntry>{};
  final cloud = <String, bool>{};
  final rewrites = <String>[];
  int deletes = 0;
  int encryptionReads = 0;
  int lists = 0;

  @override
  bool get backupCanLoseEncryption => canLoseEncryption;

  @override
  Future<bool> isBackupEncrypted() async {
    encryptionReads++;
    return encrypted;
  }

  @override
  Future<bool> isAvailable() async => encrypted;

  @override
  Future<List<PlatformSlotRef>> listAll() async {
    lists++;
    if (failList) throw PlatformException(code: 'read_failed');
    return [for (final key in entries.keys) PlatformSlotRef.tryParse(key)!];
  }

  @override
  Future<List<PlatformSlotEntry>> readAll(String vaultId) async => [
    for (final e in entries.entries)
      if (e.key.startsWith('$vaultId.')) e.value,
  ];

  @override
  Future<bool> add(String vaultId, PlatformSlotEntry entry) async {
    final key = '$vaultId.${entry.slotId}';
    if (entries.containsKey(key)) throw PlatformException(code: 'exists');
    entries[key] = entry;
    return cloud[key] = encrypted;
  }

  @override
  Future<bool> setCloudBackup(
    String vaultId,
    String slotId, {
    required bool enabled,
  }) async {
    final key = '$vaultId.$slotId';
    if (failRewrites) throw PlatformException(code: 'write_failed');
    if (!entries.containsKey(key)) throw PlatformException(code: 'not_found');
    rewrites.add('$key=$enabled');
    return cloud[key] = enabled && encrypted && !refuseCloud;
  }

  @override
  Future<void> delete(String vaultId, String slotId) async {
    deletes++;
    entries.remove('$vaultId.$slotId');
    cloud.remove('$vaultId.$slotId');
  }
}

class _Storage implements SecureWalletStorage {
  String? value;

  @override
  Future<void> storeSocialVaultBackupState(String json) async => value = json;

  @override
  Future<String?> loadSocialVaultBackupState() async => value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
