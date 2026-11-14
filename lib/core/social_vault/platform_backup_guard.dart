import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:injectable/injectable.dart';

import '../observability/app_logger.dart';
import '../security/secure_storage.dart';
import 'platform_slot_store.dart';

/// Keeps the phone backup that carries social vault platform entries honest.
///
/// On Android a platform entry — a slot secret — rides in Google's backup of
/// the phone. That backup is end-to-end encrypted only while the phone has a
/// screen lock, the store offers no "encrypted or not at all" option, and the
/// lock can be removed after an entry was written. An entry in an unencrypted
/// backup is a slot secret Google can read, and Google is also the identity
/// provider: together they open the vault. So the state is read again every
/// time the app comes forward and before every write of an entry
/// ([check]), and acted on:
///
/// - **Not encrypted**: every entry this device holds is rewritten as
///   device-only (same value, cloud backup off), and the backup counts as
///   paused ([PlatformBackupStatus.paused]) until the lock is back.
/// - **Encrypted again**: every entry is rewritten with cloud backup on, and
///   the pause ends.
/// - **Not encrypted while an entry was in the cloud backup**: that entry may
///   have been uploaded unprotected. The vault it belongs to is remembered
///   ([PlatformBackupStatus.exposedVaultIds]) until its keys are replaced by
///   a rotation or the user dismisses the advice.
///
/// Every failure reads as "not encrypted": a state this code cannot read is
/// never taken for a safe one. Nothing here deletes an entry, and nothing
/// here can change an entry's value.
///
/// What this device knows is one small record in the plugin store: per entry
/// whether it is in the cloud backup, and the two markers above. An entry the
/// record does not know is taken to be in the cloud backup — it was written
/// by a build that did not record it, or restored from a backup, which is
/// where it came from.
///
/// iOS has none of this. iCloud Keychain is end-to-end encrypted or off, so
/// there [check] answers "protected" without asking the platform anything.
@lazySingleton
class PlatformBackupGuard {
  PlatformBackupGuard(
    this._platform,
    this._storage, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  @factoryMethod
  static PlatformBackupGuard forInjection(
    PlatformSlotStore platform,
    SecureWalletStorage storage,
  ) => PlatformBackupGuard(platform, storage);

  static const _tag = 'PlatformBackup';

  final PlatformSlotStore _platform;
  final SecureWalletStorage _storage;
  final DateTime Function() _clock;

  /// What the last [check] found. Starts as "protected": nothing is claimed
  /// about a backup before it was looked at.
  final ValueNotifier<PlatformBackupStatus> status =
      ValueNotifier<PlatformBackupStatus>(PlatformBackupStatus.protected);

  Future<void> _queue = Future<void>.value();

  /// One record operation at a time: a check, a write's note and a dismissal
  /// all read, change and store the same record.
  Future<T> _serialized<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<PlatformBackupStatus>? _check;

  /// Read the backup's encryption state and bring this device's entries in
  /// line with it. Never throws; concurrent calls share one run.
  Future<PlatformBackupStatus> check() {
    if (!_platform.backupCanLoseEncryption) {
      return Future<PlatformBackupStatus>.value(status.value);
    }
    return _check ??= _serialized(_run).whenComplete(() => _check = null);
  }

  Future<PlatformBackupStatus> _run() async {
    try {
      final encrypted = await _platform.isBackupEncrypted();
      // Null when the store cannot be listed: then nothing can be rewritten
      // either, and what the record knows has to do.
      List<PlatformSlotRef>? listed;
      try {
        listed = await _platform.listAll();
      } catch (e) {
        AppLogger.warn(_tag, 'platform entries not listed: ${e.runtimeType}');
      }
      final record = await _load();
      if (listed != null) {
        final present = {for (final ref in listed) ref.key};
        record.cloud.removeWhere((key, _) => !present.contains(key));
      }
      final entries =
          listed ??
          [for (final key in record.cloud.keys) ?PlatformSlotRef.tryParse(key)];
      final now = _clock().toUtc();

      if (!encrypted) {
        for (final ref in entries) {
          if (record.cloud[ref.key] == false) continue;
          // In the cloud backup — or not known to be out of it — while the
          // backup is not encrypted.
          if (record.exposed.add(ref.vaultId)) {
            record.exposedSince ??= now;
            record.offered = false;
          }
          if (listed == null) continue;
          try {
            record.cloud[ref.key] = await _platform.setCloudBackup(
              ref.vaultId,
              ref.slotId,
              enabled: false,
            );
          } catch (e) {
            // Still in the cloud backup, as far as this device knows. The
            // next check tries again.
            AppLogger.warn(_tag, 'entry not pulled back: ${e.runtimeType}');
          }
        }
        if (entries.isNotEmpty) record.pausedSince ??= now;
      } else {
        for (final ref in entries) {
          if (record.cloud[ref.key] == true || listed == null) continue;
          try {
            record.cloud[ref.key] = await _platform.setCloudBackup(
              ref.vaultId,
              ref.slotId,
              enabled: true,
            );
          } catch (e) {
            AppLogger.warn(_tag, 'entry not backed up: ${e.runtimeType}');
          }
        }
        record.pausedSince = null;
      }

      if (listed != null) {
        // A vault with no entry left here has nothing of this device's to
        // replace.
        final vaults = {for (final ref in listed) ref.vaultId};
        record.exposed.removeWhere((vaultId) => !vaults.contains(vaultId));
        record.settleExposure();
      }
      await _store(record);
      return _publish(
        record,
        encrypted: encrypted,
        pausedVaultIds: encrypted
            ? const <String>{}
            : {for (final ref in entries) ref.vaultId},
      );
    } catch (e) {
      AppLogger.warn(_tag, 'backup state not checked: ${e.runtimeType}');
      return status.value;
    }
  }

  /// Note how a new entry was just written: in the cloud backup
  /// ([cloudBacked]) or on this device alone. The other write path beside
  /// [check]'s rewrites; both keep the same record.
  Future<void> recordWrite(
    String vaultId,
    String slotId, {
    required bool cloudBacked,
  }) {
    return _change((record) {
      record.cloud[PlatformSlotRef(vaultId: vaultId, slotId: slotId).key] =
          cloudBacked;
    });
  }

  /// [vaultId]'s keys were replaced by a rotation: whatever an unprotected
  /// backup held for it opens nothing any more.
  ///
  /// From now on, that is. The rotation sealed the same recovery phrase
  /// under a new key, so it does nothing about a backup that was read and
  /// used before it — the offer says so, and that is what makes dropping the
  /// advice here honest.
  Future<void> keysReplaced(String vaultId) => _change((record) {
    record.exposed.remove(vaultId);
    record.settleExposure();
  });

  /// The user was told about the unprotected period and chose to leave the
  /// keys as they are. For [vaultId], or for every vault.
  Future<void> dismissExposure([String? vaultId]) => _change((record) {
    if (vaultId == null) {
      record.exposed.clear();
    } else {
      record.exposed.remove(vaultId);
    }
    record.settleExposure();
  });

  /// The offer to replace the keys was shown. It is shown once per
  /// unprotected period; the Sign-in keys screen keeps the advice until the
  /// keys are replaced or it is dismissed.
  Future<void> markReplacementOffered() =>
      _change((record) => record.offered = true);

  Future<void> _change(void Function(_BackupRecord record) apply) {
    if (!_platform.backupCanLoseEncryption) return Future<void>.value();
    return _serialized(() async {
      try {
        final record = await _load();
        apply(record);
        await _store(record);
        _publish(
          record,
          encrypted: status.value.encrypted,
          pausedVaultIds: status.value.pausedVaultIds,
        );
      } catch (e) {
        AppLogger.warn(_tag, 'backup record not updated: ${e.runtimeType}');
      }
    });
  }

  PlatformBackupStatus _publish(
    _BackupRecord record, {
    required bool encrypted,
    required Set<String> pausedVaultIds,
  }) => status.value = PlatformBackupStatus(
    encrypted: encrypted,
    pausedVaultIds: Set.unmodifiable(pausedVaultIds),
    pausedSince: record.pausedSince,
    exposedVaultIds: Set.unmodifiable(record.exposed),
    exposedSince: record.exposedSince,
    replacementOffered: record.offered,
    cloudBacked: Map.unmodifiable(record.cloud),
  );

  Future<_BackupRecord> _load() async {
    try {
      final raw = await _storage.loadSocialVaultBackupState();
      if (raw == null || raw.isEmpty) return _BackupRecord();
      return _BackupRecord.fromJson(jsonDecode(raw));
    } catch (e) {
      // Unreadable is "nothing known": every entry then counts as being in
      // the cloud backup.
      AppLogger.warn(_tag, 'backup record unreadable: ${e.runtimeType}');
      return _BackupRecord();
    }
  }

  Future<void> _store(_BackupRecord record) async {
    try {
      await _storage.storeSocialVaultBackupState(jsonEncode(record.toJson()));
    } catch (e) {
      AppLogger.warn(_tag, 'backup record not saved: ${e.runtimeType}');
    }
  }
}

/// What this device knows about the phone backup of its platform entries.
/// Not secret.
class PlatformBackupStatus {
  const PlatformBackupStatus({
    required this.encrypted,
    required this.pausedVaultIds,
    required this.pausedSince,
    required this.exposedVaultIds,
    required this.exposedSince,
    required this.replacementOffered,
    required this.cloudBacked,
  });

  /// Nothing to say: the backup is encrypted, or was not looked at yet.
  static const protected = PlatformBackupStatus(
    encrypted: true,
    pausedVaultIds: <String>{},
    pausedSince: null,
    exposedVaultIds: <String>{},
    exposedSince: null,
    replacementOffered: false,
    cloudBacked: <String, bool>{},
  );

  /// Whether the backup was end-to-end encrypted at the last check.
  final bool encrypted;

  /// The vaults with a platform entry on this device while the backup is not
  /// encrypted: their entries are kept on this device alone until it is.
  final Set<String> pausedVaultIds;

  /// When the backup was first seen without encryption, while paused.
  final DateTime? pausedSince;

  /// The vaults whose entry was in the cloud backup when it was seen without
  /// encryption, until their keys are replaced or the advice is dismissed.
  final Set<String> exposedVaultIds;

  /// When that was first seen.
  final DateTime? exposedSince;

  /// Whether the offer to replace the keys was already shown for it.
  final bool replacementOffered;

  /// Per entry (`<vaultId>.<slotId>`), whether it is in the cloud backup.
  /// An entry that is not listed is not known.
  final Map<String, bool> cloudBacked;

  /// Whether this device's backup of its sign-in keys is paused.
  bool get paused => pausedVaultIds.isNotEmpty;

  /// Whether the entry of ([vaultId], [slotId]) is in the cloud backup, or
  /// null when this device does not know.
  bool? isCloudBacked(String vaultId, String slotId) =>
      cloudBacked[PlatformSlotRef(vaultId: vaultId, slotId: slotId).key];

  /// Whether to offer, now, replacing the keys of one of [vaultIds]: one of
  /// them was exposed, the offer was not made yet, and the backup is
  /// encrypted again — a replacement made while it is not would have no
  /// platform key to keep.
  bool replacementOfferDue(Iterable<String> vaultIds) =>
      encrypted &&
      !replacementOffered &&
      vaultIds.any(exposedVaultIds.contains);
}

/// The stored record behind [PlatformBackupStatus].
class _BackupRecord {
  _BackupRecord();

  factory _BackupRecord.fromJson(Object? raw) {
    final record = _BackupRecord();
    if (raw is! Map || raw['v'] != 1) return record;
    final cloud = raw['cloud'];
    if (cloud is Map) {
      for (final MapEntry(:key, :value) in cloud.entries) {
        if (key is String && value is bool) record.cloud[key] = value;
      }
    }
    final exposed = raw['exposed'];
    if (exposed is List) record.exposed.addAll(exposed.whereType<String>());
    record
      ..pausedSince = _time(raw['pausedSince'])
      ..exposedSince = _time(raw['exposedSince'])
      ..offered = raw['offered'] == true;
    return record;
  }

  /// `<vaultId>.<slotId>` → in the cloud backup.
  final Map<String, bool> cloud = <String, bool>{};
  final Set<String> exposed = <String>{};
  DateTime? pausedSince;
  DateTime? exposedSince;
  bool offered = false;

  /// With no exposed vault left there is no period to remember, and the next
  /// one is offered afresh.
  void settleExposure() {
    if (exposed.isNotEmpty) return;
    exposedSince = null;
    offered = false;
  }

  static DateTime? _time(Object? seconds) => seconds is int && seconds > 0
      ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
      : null;

  static int? _seconds(DateTime? time) =>
      time == null ? null : time.millisecondsSinceEpoch ~/ 1000;

  Map<String, Object?> toJson() => {
    'v': 1,
    'cloud': cloud,
    'pausedSince': _seconds(pausedSince),
    'exposed': exposed.toList(),
    'exposedSince': _seconds(exposedSince),
    'offered': offered,
  };
}
