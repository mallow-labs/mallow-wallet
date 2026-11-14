import 'dart:convert';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';
import 'package:passkeys_platform_interface/passkeys_platform_interface.dart';
import 'package:passkeys_platform_interface/types/credential.dart';
import 'package:passkeys_platform_interface/types/pubkeycred_param.dart';
import 'package:passkeys_platform_interface/types/types.dart';

import 'social_vault_crypto.dart';

/// Passkeys with the WebAuthn PRF extension: the passkey-prf slot of a social
/// vault.
///
/// A PRF passkey returns 32 bytes that depend only on the credential and the
/// salt it is asked to evaluate. The vault wraps its data key under a key
/// derived from those bytes, so the slot secret is never stored anywhere —
/// it is recomputed by the authenticator on each unlock, on any device the
/// passkey syncs to, including a browser.
///
/// No server checks these assertions: the challenge is random and discarded.
/// What protects the vault is that only the authenticator can produce the PRF
/// output.
///
/// Platform support:
/// - iOS 18+ (AuthenticationServices PRF). Earlier iOS creates passkeys but
///   cannot evaluate PRF, so [isSupported] is false there and those devices
///   use the platform slot only.
/// - Android 9+ through Credential Manager. Whether a given provider (Google
///   Password Manager, a third-party one) implements PRF is only known after
///   the fact, so [register] checks for an output and refuses a passkey that
///   produced none: a passkey without PRF must never become a slot.
///
/// The plugin evaluates one salt per request (no `evalByCredential`). With
/// several passkey slots, [authenticate] asks once with every credential
/// allowed and the newest slot's salt; when the user picks a passkey whose
/// slot has a different salt, it asks that passkey again with its own salt.
/// At most two prompts, usually one.
@lazySingleton
class PasskeyPrfAuthenticator {
  PasskeyPrfAuthenticator() : this.withBackend(const _PluginPasskeyBackend());

  @visibleForTesting
  PasskeyPrfAuthenticator.withBackend(
    this._backend, {
    Future<bool> Function()? platformSupportsPrf,
  }) : _platformSupportsPrf = platformSupportsPrf ?? _defaultPlatformSupport;

  final PasskeyBackend _backend;
  final Future<bool> Function() _platformSupportsPrf;

  /// Whether this device can create and use PRF passkeys at all.
  Future<bool> isSupported() async {
    try {
      return await _platformSupportsPrf();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _defaultPlatformSupport() async {
    if (Platform.isIOS) {
      final info = await DeviceInfoPlugin().iosInfo;
      final major = int.tryParse(info.systemVersion.split('.').first) ?? 0;
      return major >= 18;
    }
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt >= 28;
    }
    return false;
  }

  /// Create a passkey on [rpId] and evaluate PRF over [salt] with it.
  ///
  /// [userId] is the WebAuthn user handle (base64url): one per vault, so the
  /// platform files every passkey of a vault under one account entry.
  /// [excludeCredentialIds] stops a second passkey on an authenticator that
  /// already holds one for this vault.
  ///
  /// Throws [PasskeyPrfException] with [PasskeyPrfError.prfUnsupported] when
  /// the created passkey cannot evaluate PRF, and [PasskeyPrfError.cancelled]
  /// when the user backs out.
  Future<PasskeyPrfResult> register({
    required String rpId,
    required String userId,
    required String userName,
    required Uint8List salt,
    List<String> excludeCredentialIds = const [],
  }) async {
    final saltWire = SocialVaultCrypto.base64UrlNoPad(salt);
    final response = await _guard(
      () => _backend.register(
        RegisterRequestType(
          challenge: _challenge(),
          relyingParty: RelyingPartyType(name: 'mallow', id: rpId),
          user: UserType(displayName: userName, name: userName, id: userId),
          excludeCredentials: [
            for (final id in excludeCredentialIds)
              CredentialType(
                type: 'public-key',
                id: SocialVaultCrypto.canonicalCredentialId(id),
                transports: const [],
              ),
          ],
          authSelectionType: AuthenticatorSelectionType(
            requireResidentKey: true,
            residentKey: 'required',
            userVerification: 'required',
          ),
          pubKeyCredParams: [
            PubKeyCredParamType(type: 'public-key', alg: -7),
            PubKeyCredParamType(type: 'public-key', alg: -257),
          ],
          prf: saltWire,
        ),
      ),
    );
    final credentialId = _credentialId(response.rawId, response.id);
    final prf = _prf(response.clientExtensionResults);
    if (prf.enabled == false) {
      throw const PasskeyPrfException(PasskeyPrfError.prfUnsupported);
    }
    final atCreate = prf.first;
    if (atCreate != null) {
      return PasskeyPrfResult(credentialId: credentialId, output: atCreate);
    }
    // Many authenticators report PRF support at creation but evaluate it only
    // on assertion. Ask once, for exactly this passkey.
    final assertion = await _assert(
      rpId: rpId,
      credentialIds: [credentialId],
      salt: saltWire,
    );
    final output = _prf(assertion.clientExtensionResults).first;
    if (output == null) {
      throw const PasskeyPrfException(PasskeyPrfError.prfUnsupported);
    }
    return PasskeyPrfResult(credentialId: credentialId, output: output);
  }

  /// Evaluate PRF with one of [candidates] (newest first). Returns which
  /// credential answered, so the caller can pick its slot.
  Future<PasskeyPrfResult> authenticate({
    required String rpId,
    required List<PasskeyPrfCandidate> candidates,
  }) async {
    if (candidates.isEmpty) {
      throw const PasskeyPrfException(PasskeyPrfError.noCredential);
    }
    final first = candidates.first;
    final response = await _assert(
      rpId: rpId,
      credentialIds: [for (final c in candidates) c.credentialId],
      salt: SocialVaultCrypto.base64UrlNoPad(first.salt),
    );
    final usedId = _credentialId(response.rawId, response.id);
    final used = candidates
        .where(
          (c) =>
              SocialVaultCrypto.canonicalCredentialId(c.credentialId) == usedId,
        )
        .firstOrNull;
    if (used == null) {
      throw const PasskeyPrfException(PasskeyPrfError.noCredential);
    }
    if (_sameBytes(used.salt, first.salt)) {
      final output = _prf(response.clientExtensionResults).first;
      if (output == null) {
        throw const PasskeyPrfException(PasskeyPrfError.prfUnsupported);
      }
      return PasskeyPrfResult(credentialId: usedId, output: output);
    }
    // The user chose a passkey whose slot uses another salt; the output above
    // is for the wrong salt. Ask that passkey again with its own.
    final second = await _assert(
      rpId: rpId,
      credentialIds: [usedId],
      salt: SocialVaultCrypto.base64UrlNoPad(used.salt),
    );
    final output = _prf(second.clientExtensionResults).first;
    if (output == null) {
      throw const PasskeyPrfException(PasskeyPrfError.prfUnsupported);
    }
    return PasskeyPrfResult(credentialId: usedId, output: output);
  }

  Future<AuthenticateResponseType> _assert({
    required String rpId,
    required List<String> credentialIds,
    required String salt,
  }) => _guard(
    () => _backend.authenticate(
      AuthenticateRequestType(
        relyingPartyId: rpId,
        challenge: _challenge(),
        mediation: MediationType.Optional,
        preferImmediatelyAvailableCredentials: false,
        userVerification: 'required',
        allowCredentials: [
          for (final id in credentialIds)
            CredentialType(
              type: 'public-key',
              id: SocialVaultCrypto.canonicalCredentialId(id),
              transports: const [],
            ),
        ],
        prf: salt,
      ),
    ),
  );

  /// The id of the credential that answered, in the one form ids are
  /// compared in ([SocialVaultCrypto.canonicalCredentialId]). The plugins
  /// report it as `rawId`, `id` or both, in base64 or base64url, padded or
  /// not, depending on the platform.
  static String _credentialId(String rawId, String id) =>
      SocialVaultCrypto.canonicalCredentialId(rawId.isNotEmpty ? rawId : id);

  static String _challenge() =>
      SocialVaultCrypto.base64UrlNoPad(SocialVaultCrypto.randomBytes(32));

  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      // The plugin's codes are platform-prefixed; only the cases a caller
      // branches on are told apart. The message is not carried: it is
      // platform text that can name the credential.
      final code = e.code;
      if (code == 'cancelled' || code.contains('cancel')) {
        throw const PasskeyPrfException(PasskeyPrfError.cancelled);
      }
      if (code.contains('no-credential') || code.contains('no_credential')) {
        throw const PasskeyPrfException(PasskeyPrfError.noCredential);
      }
      if (code == 'deviceNotSupported' || code.contains('unsupported')) {
        throw const PasskeyPrfException(PasskeyPrfError.prfUnsupported);
      }
      if (code == 'domain-not-associated') {
        throw const PasskeyPrfException(PasskeyPrfError.notConfigured);
      }
      throw PasskeyPrfException(PasskeyPrfError.failed, code: code);
    }
  }

  /// Reads `clientExtensionResults.prf` as both plugins report it.
  static ({bool? enabled, Uint8List? first}) _prf(
    Map<String?, Object?>? results,
  ) {
    final prf = results?['prf'];
    if (prf is! Map) return (enabled: null, first: null);
    final enabled = prf['enabled'];
    final first = switch (prf['results']) {
      final Map<Object?, Object?> r => r['first'],
      _ => null,
    };
    final bytes = first is String && first.isNotEmpty
        ? _decodeLenient(first)
        : null;
    return (
      enabled: enabled is bool ? enabled : null,
      first: bytes != null && bytes.length == SocialVaultCrypto.keyLength
          ? bytes
          : null,
    );
  }

  /// base64url or base64, padded or not: the two platforms' JSON encoders
  /// differ, and a PRF output is 32 bytes either way.
  static Uint8List? _decodeLenient(String value) {
    final normalized = value.replaceAll('+', '-').replaceAll('/', '_');
    final unpadded = normalized.replaceAll('=', '');
    try {
      return base64Url.decode(
        unpadded.padRight((unpadded.length + 3) ~/ 4 * 4, '='),
      );
    } on FormatException {
      return null;
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// One passkey slot a vault can be opened with.
class PasskeyPrfCandidate {
  const PasskeyPrfCandidate({required this.credentialId, required this.salt});

  final String credentialId;
  final Uint8List salt;
}

/// The PRF output of one passkey and which passkey produced it.
/// [credentialId] is in canonical form (base64url, no padding).
///
/// Hand-written with a redacted [toString]: [output] is a slot secret.
class PasskeyPrfResult {
  const PasskeyPrfResult({required this.credentialId, required this.output});

  final String credentialId;
  final Uint8List output;

  @override
  String toString() =>
      'PasskeyPrfResult(credentialId: $credentialId, output: <redacted>)';
}

enum PasskeyPrfError {
  cancelled,

  /// None of the allowed passkeys is available here.
  noCredential,

  /// The device or the passkey provider cannot evaluate PRF.
  prfUnsupported,

  /// The app is not associated with the RP ID's domain.
  notConfigured,

  failed,
}

class PasskeyPrfException implements Exception {
  const PasskeyPrfException(this.error, {this.code});

  final PasskeyPrfError error;
  final String? code;

  @override
  String toString() => 'PasskeyPrfException(${error.name}, code: $code)';
}

/// The two plugin calls, behind a seam so the PRF logic is testable without a
/// device.
abstract interface class PasskeyBackend {
  Future<RegisterResponseType> register(RegisterRequestType request);
  Future<AuthenticateResponseType> authenticate(
    AuthenticateRequestType request,
  );
}

class _PluginPasskeyBackend implements PasskeyBackend {
  const _PluginPasskeyBackend();

  @override
  Future<RegisterResponseType> register(RegisterRequestType request) =>
      PasskeysPlatform.instance.register(request);

  @override
  Future<AuthenticateResponseType> authenticate(
    AuthenticateRequestType request,
  ) => PasskeysPlatform.instance.authenticate(request);
}
