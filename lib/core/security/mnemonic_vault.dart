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
/// Errors:
///   PlatformException(write_failed) — keychain/keystore write failed
///   PlatformException(read_failed)  — keychain/keystore read/decrypt failed
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

  /// Delete the value for [key]. No-op if not found.
  Future<void> delete(String key) async {
    await _channel.invokeMethod<void>('delete', {'key': key});
  }
}
