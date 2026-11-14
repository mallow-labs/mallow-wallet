import 'dart:async';
import 'dart:io' show Platform;
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

import 'social_vault_crypto.dart';

/// The platform slots of social vaults: random secrets kept in the
/// platform's end-to-end encrypted, synced keychain — iCloud Keychain on iOS,
/// Block Store with cloud backup on Android.
///
/// This is the one place this app stores anything that leaves the device on
/// purpose, and what it stores cannot open a wallet by itself: a slot secret
/// unwraps a vault's data key only together with the vault's ciphertext, and
/// the backend hands that out only to a fresh Google or Apple sign-in for the
/// same identity. Wallet keys and phrases stay in `MnemonicVault`, which never
/// syncs.
///
/// One entry per (vault, slot), keyed `<vaultId>.<slotId>` (`.` is not in the
/// base64url alphabet, so the split is unambiguous). Entries are add-only:
/// devices that share one iCloud account or one Google backup each add their
/// own slot, and overwriting an entry would destroy the secret behind another
/// device's slot. An entry is deleted only after its slot is gone from the
/// vault. Calls are serialized.
///
/// On Android the backup that carries an entry is end-to-end encrypted only
/// while the phone has a screen lock, and that can change after the entry was
/// written. [isBackupEncrypted] reads the state and [setCloudBackup] moves an
/// existing entry in or out of the backup without touching its value; what to
/// do with the answers is `PlatformBackupGuard`'s business. iOS has no such
/// state: iCloud Keychain is end-to-end encrypted or off.
@lazySingleton
class PlatformSlotStore {
  static const _channel = MethodChannel('art.mallow.wallet/social_vault_slot');

  /// Android's Block Store namespace for these entries.
  static const _androidPrefix = 'mallow.sv.';

  Future<void> _queue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  static String _prefix() => Platform.isAndroid ? _androidPrefix : '';

  static String _key(String vaultId, String slotId) =>
      '${_prefix()}$vaultId.$slotId';

  /// Whether a platform slot can be created here. On Android that requires
  /// Block Store's end-to-end encrypted backup, i.e. a screen lock; a slot
  /// secret in a backup Google could read would make the vault custodial.
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Whether this platform's backup can stop being end-to-end encrypted
  /// under an entry that is already in it. True on Android only.
  bool get backupCanLoseEncryption => Platform.isAndroid;

  /// Whether the backup that carries these entries is end-to-end encrypted
  /// right now. Android: Block Store's own answer, and anything short of a
  /// clear yes — no Play services, an error, a native side without the
  /// method — is a no. Everywhere else it always is, and nothing native is
  /// asked.
  Future<bool> isBackupEncrypted() async {
    if (!backupCanLoseEncryption) return true;
    try {
      return await _channel.invokeMethod<bool>('isBackupEncrypted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Every entry this device holds, of every vault, by vault and slot id —
  /// no values. A key that is not `<vaultId>.<slotId>` is skipped.
  Future<List<PlatformSlotRef>> listAll() => _serialized(() async {
    final raw = await _channel.invokeMapMethod<String, String>('list', {
      'prefix': _prefix(),
    });
    final prefix = _prefix();
    return [
      for (final key in (raw ?? const <String, String>{}).keys)
        ?PlatformSlotRef.tryParse(key.substring(prefix.length)),
    ];
  });

  /// Rewrite the existing entry of ([vaultId], [slotId]) with the value it
  /// already holds, in the cloud backup ([enabled]) or on this device alone.
  /// Returns whether it is in the cloud backup afterwards — the native side
  /// never puts an entry there while the backup is not end-to-end encrypted,
  /// whatever was asked. Throws [PlatformException] when there is no such
  /// entry or the store fails; the entry is then as it was.
  ///
  /// Android only: elsewhere there is no flag to set, and this answers true.
  Future<bool> setCloudBackup(
    String vaultId,
    String slotId, {
    required bool enabled,
  }) {
    if (!backupCanLoseEncryption) return Future<bool>.value(true);
    return _serialized(() async {
      final backedUp = await _channel.invokeMethod<bool>('setCloudBackup', {
        'key': _key(vaultId, slotId),
        'cloudBackup': enabled,
      });
      return backedUp ?? false;
    });
  }

  /// Every entry this device can read for [vaultId] — its own, and any the
  /// platform synced from the user's other devices.
  Future<List<PlatformSlotEntry>> readAll(String vaultId) =>
      _serialized(() async {
        final raw = await _channel.invokeMapMethod<String, String>('list', {
          'prefix': '${_prefix()}$vaultId.',
        });
        return [
          for (final value in (raw ?? const <String, String>{}).values)
            ?PlatformSlotEntry.tryParse(value),
        ];
      });

  /// Add [entry]. Never replaces an existing one: a key collision (or a full
  /// Block Store) throws [PlatformException].
  ///
  /// Returns whether the entry went into the cloud backup. On Android the
  /// native side decides at the moment of the write: only while the backup
  /// is end-to-end encrypted, otherwise the entry stays on this device
  /// alone. iOS answers nothing, which reads as true: the item is
  /// synchronizable, and iCloud Keychain carries it or is off.
  Future<bool> add(String vaultId, PlatformSlotEntry entry) =>
      _serialized(() async {
        final backedUp = await _channel.invokeMethod<bool>('add', {
          'key': _key(vaultId, entry.slotId),
          'value': entry.toJsonString(),
        });
        return backedUp ?? true;
      });

  /// Delete one entry, on every device the platform syncs it to. Only for a
  /// slot that is gone from the vault (removed or rotated out, and past the
  /// sweep's grace period), a slot of a vault this device deleted with a
  /// delete the backend accepted, a slot of a vault the backend has said it
  /// does not have for 30 days, or the entry of a vault creation that a
  /// signed status read shows never happened.
  Future<void> delete(String vaultId, String slotId) => _serialized(() async {
    await _channel.invokeMethod<void>('delete', {'key': _key(vaultId, slotId)});
  });
}

/// Which entry of the platform store: the vault and the slot. No secret.
class PlatformSlotRef {
  const PlatformSlotRef({required this.vaultId, required this.slotId});

  final String vaultId;
  final String slotId;

  /// The key this entry is recorded under: `<vaultId>.<slotId>`.
  String get key => '$vaultId.$slotId';

  static PlatformSlotRef? tryParse(String key) {
    final parts = key.split('.');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    return PlatformSlotRef(vaultId: parts[0], slotId: parts[1]);
  }

  @override
  bool operator ==(Object other) =>
      other is PlatformSlotRef &&
      other.vaultId == vaultId &&
      other.slotId == slotId;

  @override
  int get hashCode => Object.hash(vaultId, slotId);

  @override
  String toString() => 'PlatformSlotRef($key)';
}

/// One platform slot: which slot of the vault it is, its secret, and when
/// this entry was written.
///
/// [createdAt] is what lets a sweep tell a stale entry from one a device
/// wrote a moment ago, before the vault write that makes its slot live: on
/// iOS that entry syncs to the user's other devices first, and to them it
/// looks like an entry of no slot. Entries written before the field existed
/// carry none, and are old by now.
///
/// To the native side the whole value is one opaque string.
///
/// Hand-written with a redacted [toString]: [secret] is a slot secret.
class PlatformSlotEntry {
  const PlatformSlotEntry({
    required this.slotId,
    required this.secret,
    this.createdAt,
  });

  final String slotId;
  final Uint8List secret;

  /// When the entry was written, or null for one written before entries
  /// recorded it.
  final DateTime? createdAt;

  static PlatformSlotEntry? tryParse(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map || map['v'] != 1) return null;
      final slotId = map['slotId'];
      final secret = map['secret'];
      if (slotId is! String || secret is! String) return null;
      final bytes = SocialVaultCrypto.decodeBase64UrlNoPad(secret);
      if (bytes.length != SocialVaultCrypto.keyLength) return null;
      final createdAt = map['createdAt'];
      return PlatformSlotEntry(
        slotId: slotId,
        secret: bytes,
        // Unix seconds. Anything else is read as "no creation time", never
        // as a reason to refuse an entry that still holds a slot secret.
        createdAt: createdAt is int && createdAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  String toJsonString() => jsonEncode({
    'v': 1,
    'slotId': slotId,
    'secret': SocialVaultCrypto.base64UrlNoPad(secret),
    if (createdAt != null)
      'createdAt': createdAt!.millisecondsSinceEpoch ~/ 1000,
  });

  @override
  String toString() => 'PlatformSlotEntry(slotId: $slotId, secret: <redacted>)';
}
