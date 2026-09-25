import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

/// OS-keystore secret store for mnemonics and private keys.
///
/// Secrets are encrypted at rest by the OS keychain (iOS) / hardware-backed
/// AndroidKeystore, under the device-unlock tier — the same protection as the
/// DB encryption key. Reads and writes do NOT trigger an OS biometric/passcode
/// prompt and do not require a device lock screen: the user-facing gate is the
/// app's own dual-lock (PIN and/or biometric app-lock), not this store.
///
/// Writes are update-or-add on both platforms: a failed write leaves the
/// stored value as it was. Nothing here deletes before it writes.
///
/// Errors:
///   PlatformException(write_failed)  — keychain/keystore write failed
///   PlatformException(read_failed)   — keychain/keystore read/decrypt failed
///   PlatformException(delete_failed) — keychain/keystore delete failed
///   PlatformException(list_failed)   — enumeration failed
@lazySingleton
class MnemonicVault {
  static const _channel = MethodChannel('art.mallow.wallet/mnemonic_vault');

  /// Write [value] under [key].
  Future<void> write(String key, String value) async {
    await _channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  /// Read the value for [key]. Returns null if the key does not exist.
  ///
  /// [prompt] is retained for source compatibility but is no longer used —
  /// reads do not surface an OS authentication prompt.
  Future<String?> read(
    String key, {
    String prompt = 'Authenticate to access your wallet',
  }) async {
    return _channel.invokeMethod<String>('read', {
      'key': key,
      'prompt': prompt,
    });
  }

  /// Delete the value for [key]. No-op if not found; any other failure throws
  /// `PlatformException(delete_failed)`, so a wipe cannot report "clean" while
  /// a secret is still in the keystore.
  Future<void> delete(String key) async {
    await _channel.invokeMethod<void>('delete', {'key': key});
  }

  /// Every key currently stored, including ones the app has lost track of.
  ///
  /// Two callers only: the explicit wipes (Reset app, Start fresh), which
  /// sweep the store so no secret outlives the identity it belonged to; and
  /// the DB-key re-mint path, which uses an empty listing as one sign of a
  /// device migration. Nothing decides from a listing that a secret *should*
  /// exist — a normal launch never consults it.
  Future<List<String>> listKeys() async {
    final keys = await _channel.invokeListMethod<String>('listKeys');
    return keys ?? const [];
  }
}
