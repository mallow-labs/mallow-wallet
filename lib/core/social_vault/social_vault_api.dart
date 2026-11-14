import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import 'social_vault_crypto.dart';

/// The social-vault routes, with the request signing and error mapping the
/// generated client cannot do on its own.
///
/// Every write after creation is signed by the vault key over a message that
/// includes the SHA-256 of the **exact** request body. The Retrofit client
/// serializes the body itself, as `jsonEncode(request.toJson())` (Dio's JSON
/// transformer), so this class hashes that same encoding of the same request
/// object. `social_vault_api_test.dart` pins that the bytes on the wire are
/// the bytes signed.
@lazySingleton
class SocialVaultApi {
  SocialVaultApi(this._client, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  @factoryMethod
  static SocialVaultApi forInjection(api.MallowApiV2Client client) =>
      SocialVaultApi(client);

  final api.MallowApiV2Client _client;
  final DateTime Function() _clock;

  /// Full paths, as the backend reads them when it rebuilds the signed
  /// message. The client's own paths omit the `/v2` prefix (its base URL
  /// carries it); the signature does not.
  static const addSlotPath = '/v2/social-vault/slots/add';
  static const removeSlotPath = '/v2/social-vault/slots/remove';
  static const renameSlotPath = '/v2/social-vault/slots/rename';
  static const deletePath = '/v2/social-vault/delete';
  static const rotatePath = '/v2/social-vault/rotate';
  static const statusPath = '/v2/social-vault/status';
  static const cancelDeletionPath = '/v2/social-vault/deletion/cancel';

  /// Verify a provider ID token and fetch the identity's vault.
  ///
  /// A null `vault` in the answer means the identity has none, and the caller
  /// offers to create a wallet on it. So the answer is believed only when the
  /// body says it outright: `vault` present and null, or present and a
  /// well-formed vault. A body without the field, or with a vault missing
  /// what a vault must carry, throws [SocialVaultApiError.malformedResponse]
  /// — it is never read as "no vault".
  Future<api.SocialVaultOpenResponse> open(String idToken) async {
    try {
      final response = await _client.openSocialVault(
        api.SocialVaultOpenRequest(idToken: idToken),
      );
      requireWellFormedOpen(response.response.data);
      return response.data.result;
    } on DioException catch (e) {
      throw SocialVaultApiException.fromDio(e);
    } on SocialVaultApiException {
      rethrow;
    } catch (_) {
      // The generated parser refused the body (a required field missing or
      // of the wrong type) before the check above could.
      throw const SocialVaultApiException(
        SocialVaultApiError.malformedResponse,
        status: 200,
      );
    }
  }

  static final _identityId = RegExp(r'^[0-9a-f]{32}$');

  /// Throws unless [body] is an `open` answer a caller may act on. See
  /// [open].
  @visibleForTesting
  static void requireWellFormedOpen(Object? body) {
    const malformed = SocialVaultApiException(
      SocialVaultApiError.malformedResponse,
      status: 200,
    );
    final result = body is Map ? body['result'] : null;
    if (result is! Map) throw malformed;
    final identityId = result['identityId'];
    if (identityId is! String || !_identityId.hasMatch(identityId)) {
      throw malformed;
    }
    final identityToken = result['identityToken'];
    if (identityToken is! String || identityToken.isEmpty) throw malformed;
    if (!result.containsKey('vault')) throw malformed;
    final vault = result['vault'];
    if (vault != null && !isWellFormedVault(vault)) throw malformed;
  }

  /// Whether [vault] carries everything a vault record must: its id, a
  /// revision, the sealed payload, the vault public key, at least one slot
  /// (a vault always has one: the backend refuses to remove the last), each
  /// naming itself, the two timestamps, and the `pendingDeletion` field (null
  /// or a request).
  ///
  /// It covers every field the generated parser casts, with the type it
  /// casts to — so a body that passes here parses, and one that would make
  /// the parser throw is refused here first, as a malformed answer.
  @visibleForTesting
  static bool isWellFormedVault(Object? vault) {
    if (vault is! Map) return false;
    bool text(Object? v) => v is String && v.isNotEmpty;
    bool optionalText(Object? v) => v == null || v is String;
    for (final key in const [
      'vaultId',
      'payloadNonce',
      'payloadCiphertext',
      'vaultPublicKey',
    ]) {
      if (!text(vault[key])) return false;
    }
    for (final key in const ['createdAt', 'updatedAt']) {
      if (vault[key] is! String) return false;
    }
    final revision = vault['revision'];
    if (revision is! int || revision < 1) return false;
    final slots = vault['slots'];
    if (slots is! List || slots.isEmpty) return false;
    for (final slot in slots) {
      if (slot is! Map) return false;
      for (final key in const ['slotId', 'kind', 'nonce', 'wrappedKey']) {
        if (!text(slot[key])) return false;
      }
      if (slot['createdAt'] is! String) return false;
      for (final key in const ['prfSalt', 'credentialId', 'rpId', 'label']) {
        if (!optionalText(slot[key])) return false;
      }
    }
    if (!vault.containsKey('pendingDeletion')) return false;
    final pending = vault['pendingDeletion'];
    if (pending == null) return true;
    return pending is Map &&
        text(pending['requestedAt']) &&
        text(pending['appliesAt']);
  }

  /// [vault], when it is a record of [vaultId] that a caller may act on;
  /// throws [SocialVaultApiError.malformedResponse] otherwise.
  ///
  /// Every vault record a signed route or `create` answers with goes through
  /// this, after the generated parser. The parser cannot be asked what the
  /// body lacked — a missing `slots` reads as an empty list — so the checks
  /// here are on what a real record always has: the id that was asked about
  /// (an answer about another vault is not an answer), a revision, the
  /// sealed payload, the vault public key and at least one slot.
  static api.SocialVault requireRecordOf(
    String vaultId,
    api.SocialVault vault,
  ) {
    final wellFormed =
        vault.vaultId == vaultId &&
        vault.revision >= 1 &&
        vault.payloadNonce.isNotEmpty &&
        vault.payloadCiphertext.isNotEmpty &&
        vault.vaultPublicKey.isNotEmpty &&
        vault.slots.isNotEmpty &&
        vault.slots.every(
          (s) =>
              s.slotId.isNotEmpty &&
              s.nonce.isNotEmpty &&
              s.wrappedKey.isNotEmpty,
        );
    if (!wellFormed) {
      throw const SocialVaultApiException(
        SocialVaultApiError.malformedResponse,
        status: 200,
      );
    }
    return vault;
  }

  /// Create the identity's vault. Throws [SocialVaultApiException] with
  /// [SocialVaultApiError.vaultExists] when another device created one first.
  Future<api.SocialVault> create(api.SocialVaultCreateRequest request) =>
      _mapped(
        () async => requireRecordOf(
          request.vaultId,
          (await _client.createSocialVault(request)).result,
        ),
      );

  Future<api.SocialVault> addSlot({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
    required api.SocialVaultNewSlot slot,
  }) {
    final request = api.SocialVaultAddSlotRequest(
      vaultId: vaultId,
      revision: revision,
      slot: slot,
    );
    return _signed(
      vaultKey: vaultKey,
      path: addSlotPath,
      vaultId: vaultId,
      revision: revision,
      body: request.toJson(),
      send: (signature, timestamp) async => requireRecordOf(
        vaultId,
        (await _client.addSocialVaultSlot(
          request,
          signature: signature,
          timestamp: timestamp,
        )).result,
      ),
    );
  }

  Future<api.SocialVault> removeSlot({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
    required String slotId,
  }) {
    final request = api.SocialVaultRemoveSlotRequest(
      vaultId: vaultId,
      revision: revision,
      slotId: slotId,
    );
    return _signed(
      vaultKey: vaultKey,
      path: removeSlotPath,
      vaultId: vaultId,
      revision: revision,
      body: request.toJson(),
      send: (signature, timestamp) async => requireRecordOf(
        vaultId,
        (await _client.removeSocialVaultSlot(
          request,
          signature: signature,
          timestamp: timestamp,
        )).result,
      ),
    );
  }

  /// Replace [slotId]'s label; an empty [label] clears it.
  Future<api.SocialVault> renameSlot({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
    required String slotId,
    required String label,
  }) {
    final request = api.SocialVaultRenameSlotRequest(
      vaultId: vaultId,
      revision: revision,
      slotId: slotId,
      label: label,
    );
    return _signed(
      vaultKey: vaultKey,
      path: renameSlotPath,
      vaultId: vaultId,
      revision: revision,
      body: request.toJson(),
      send: (signature, timestamp) async => requireRecordOf(
        vaultId,
        (await _client.renameSocialVaultSlot(
          request,
          signature: signature,
          timestamp: timestamp,
        )).result,
      ),
    );
  }

  Future<void> delete({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
  }) {
    final request = api.SocialVaultDeleteRequest(
      vaultId: vaultId,
      revision: revision,
    );
    return _signed(
      vaultKey: vaultKey,
      path: deletePath,
      vaultId: vaultId,
      revision: revision,
      body: request.toJson(),
      send: (signature, timestamp) => _client.deleteSocialVault(
        request,
        signature: signature,
        timestamp: timestamp,
      ),
    );
  }

  /// The current vault, for a holder of the vault key: a signed read, with no
  /// sign-in. [revision] is the caller's last known revision; it is part of
  /// the signed message, but the backend does not compare it, so this never
  /// throws a [SocialVaultConflictException]. [SocialVaultApiError.notFound]
  /// means the backend said, with its own code, that it has no such vault.
  Future<api.SocialVault> status({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
  }) {
    final request = api.SocialVaultStatusRequest(
      vaultId: vaultId,
      revision: revision,
    );
    return _signed(
      vaultKey: vaultKey,
      path: statusPath,
      vaultId: vaultId,
      revision: revision,
      body: request.toJson(),
      send: (signature, timestamp) async => requireRecordOf(
        vaultId,
        (await _client.socialVaultStatus(
          request,
          signature: signature,
          timestamp: timestamp,
        )).result,
      ),
    );
  }

  /// Cancel a pending deletion request — one the vault key did not sign —
  /// and record that a holder of the key refused it. A signed write; it
  /// succeeds when nothing is pending.
  Future<api.SocialVault> cancelDeletion({
    required SimpleKeyPair vaultKey,
    required String vaultId,
    required int revision,
  }) {
    final request = api.SocialVaultCancelDeletionRequest(
      vaultId: vaultId,
      revision: revision,
    );
    return _signed(
      vaultKey: vaultKey,
      path: cancelDeletionPath,
      vaultId: vaultId,
      revision: revision,
      body: request.toJson(),
      send: (signature, timestamp) async => requireRecordOf(
        vaultId,
        (await _client.cancelSocialVaultDeletion(
          request,
          signature: signature,
          timestamp: timestamp,
        )).result,
      ),
    );
  }

  /// Replace the vault's payload, vault key and live slots in one write.
  /// Signed by the CURRENT vault key ([currentVaultKey]); the request names
  /// the new public key. Not retried on a conflict: a conflict means another
  /// device changed the slots, and rotating over that would drop its change
  /// unseen.
  Future<api.SocialVault> rotate({
    required SimpleKeyPair currentVaultKey,
    required api.SocialVaultRotateRequest request,
  }) => _signed(
    vaultKey: currentVaultKey,
    path: rotatePath,
    vaultId: request.vaultId,
    revision: request.revision,
    body: request.toJson(),
    send: (signature, timestamp) async => requireRecordOf(
      request.vaultId,
      (await _client.rotateSocialVault(
        request,
        signature: signature,
        timestamp: timestamp,
      )).result,
    ),
  );

  /// Run a signed write, retrying on a revision conflict.
  ///
  /// A conflict means another device wrote first. Every write this app makes
  /// (add a slot, remove one, delete the vault) is still meaningful against
  /// the newer revision, so it is re-signed for that revision and sent again
  /// — but only when the conflicting vault is [vaultId] and carries the same
  /// public key, i.e. it is still the vault this device holds the key for.
  /// Anything else is surfaced: a revision is never taken from a record of
  /// another vault.
  static Future<T> retryOnConflict<T>({
    required String vaultId,
    required int revision,
    required String vaultPublicKey,
    required Future<T> Function(int revision) attempt,
    int maxAttempts = 3,
  }) async {
    var current = revision;
    for (var i = 1; ; i++) {
      try {
        return await attempt(current);
      } on SocialVaultConflictException catch (e) {
        if (i >= maxAttempts ||
            e.vault.vaultId != vaultId ||
            e.vault.vaultPublicKey != vaultPublicKey) {
          rethrow;
        }
        current = e.vault.revision;
      }
    }
  }

  Future<T> _signed<T>({
    required SimpleKeyPair vaultKey,
    required String path,
    required String vaultId,
    required int revision,
    required Map<String, dynamic> body,
    required Future<T> Function(String signature, String timestamp) send,
  }) async {
    final bytes = wireBody(body);
    Future<T> attempt() async {
      final timestamp = _timestampFor(
        '$path\n$vaultId\n$revision\n${crypto.sha256.convert(bytes)}',
      );
      final signature = await SocialVaultCrypto.signRequest(
        keyPair: vaultKey,
        method: 'POST',
        path: path,
        vaultId: vaultId,
        revision: revision,
        body: bytes,
        timestamp: timestamp,
      );
      return _mapped(() => send(signature, '$timestamp'));
    }

    try {
      return await attempt();
    } on SocialVaultApiException catch (e) {
      // A replay means this exact signature was already accepted once — the
      // key is right, and only the timestamp collided (this process lost
      // [_lastSignedAt] in a restart, or another client of the same vault
      // signed the same request in the same second). [_timestampFor] hands
      // out a strictly later one, so the second signature is new. Once: a
      // second replay is surfaced.
      if (e.error != SocialVaultApiError.replayedSignature) rethrow;
      return attempt();
    }
  }

  /// The last timestamp signed for each (path, vault, revision, body).
  ///
  /// Ed25519 is deterministic, so the same request signed in the same second
  /// is the same signature, and the backend accepts each signature once. A
  /// retry of an identical request therefore gets a timestamp past the last
  /// one used for it — a fresh signature, never a replay of the first.
  final Map<String, int> _lastSignedAt = {};

  int _timestampFor(String request) {
    var timestamp = _clock().millisecondsSinceEpoch ~/ 1000;
    final last = _lastSignedAt[request];
    if (last != null && timestamp <= last) timestamp = last + 1;
    _lastSignedAt[request] = timestamp;
    return timestamp;
  }

  /// The bytes the client sends for a JSON request [body].
  static List<int> wireBody(Map<String, dynamic> body) =>
      utf8.encode(jsonEncode(body));

  static Future<T> _mapped<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      throw SocialVaultApiException.fromDio(e);
    } on SocialVaultApiException {
      rethrow;
    } catch (_) {
      // The generated parser refused a 2xx body: a required field missing
      // or of the wrong type. Typed, so that callers' handling of a failed
      // request (and the cleanup that goes with it) runs for this too.
      throw const SocialVaultApiException(
        SocialVaultApiError.malformedResponse,
        status: 200,
      );
    }
  }
}

/// What went wrong with a social-vault request, as far as the caller needs to
/// branch on it.
enum SocialVaultApiError {
  /// The provider ID token or the identity token was refused: invalid,
  /// expired, for another audience, or (ID tokens) already used.
  identityRejected,

  /// `create` lost a race: the identity already has a vault.
  vaultExists,

  /// No such vault — deleted, or never created — said by the backend itself:
  /// a 404 whose body carries the code `vault_not_found`. Callers act on
  /// this (they unlink a wallet from its backup, and in time delete slot
  /// secrets), so no other 404 is read as it: a proxy, a backend without
  /// these routes and a build pointed at the wrong host all answer 404 too,
  /// and those are [unavailable].
  notFound,

  /// `invalid_vault_signature`: the signature does not verify under the
  /// vault's current key (or its headers were malformed). The only one of the
  /// three signature refusals that says the vault key may have changed.
  signatureRejected,

  /// `stale_vault_timestamp`: the signature's timestamp is too far from the
  /// backend's clock. Says nothing about the key — this device's date and
  /// time are wrong.
  staleTimestamp,

  /// `replayed_vault_signature`: a valid signature that was already used.
  /// Says the key is right. [SocialVaultApi] re-signs with a later timestamp
  /// and retries once before this reaches a caller.
  replayedSignature,

  /// A 200 whose body is not what the route answers: a required field is
  /// missing or of the wrong type, or the vault record is not the vault that
  /// was asked about. Never read as an empty answer.
  malformedResponse,

  /// Removing the last live slot, which would make the vault unopenable.
  lastSlot,

  rateLimited,

  /// The backend could not verify the token or reach its rate limiter, the
  /// request never got an answer, or the answer was a 404 without the vault
  /// routes' own code — which says only that something other than these
  /// routes answered.
  unavailable,

  /// Any other refusal (malformed request, slot limit).
  rejected,
}

class SocialVaultApiException implements Exception {
  const SocialVaultApiException(this.error, {this.status, this.code});

  factory SocialVaultApiException.fromDio(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    final code = _errorCode(data);
    if (status == 409 && code == 'revision_conflict' && data is Map) {
      final vault = _conflictVault(data['vault'], e.requestOptions.data);
      if (vault != null) return SocialVaultConflictException(vault);
    }
    final error = switch ((status, code)) {
      (null, _) => SocialVaultApiError.unavailable,
      // A 2xx that reached here was not readable as the route's answer.
      (final int s, _) when s >= 200 && s < 300 =>
        SocialVaultApiError.malformedResponse,
      (401, 'invalid_vault_signature') => SocialVaultApiError.signatureRejected,
      (401, 'stale_vault_timestamp') => SocialVaultApiError.staleTimestamp,
      (401, 'replayed_vault_signature') =>
        SocialVaultApiError.replayedSignature,
      (401, _) => SocialVaultApiError.identityRejected,
      (404, 'vault_not_found') => SocialVaultApiError.notFound,
      // Any other 404 — no body, a page, another code — did not come from
      // the vault routes. It says nothing about any vault.
      (404, _) => SocialVaultApiError.unavailable,
      (409, 'vault_exists') => SocialVaultApiError.vaultExists,
      (400, 'last_slot') => SocialVaultApiError.lastSlot,
      (429, _) => SocialVaultApiError.rateLimited,
      (final int s, _) when s >= 500 => SocialVaultApiError.unavailable,
      _ => SocialVaultApiError.rejected,
    };
    return SocialVaultApiException(error, status: status, code: code);
  }

  /// The vault a conflict answer carries, or null when it is not one a
  /// caller may act on — then the answer falls through as a plain refusal.
  ///
  /// A conflict's vault is acted on like any other (its public key decides
  /// whether this device's data key is stale, its revision is what the write
  /// is re-signed for), so it must be well-formed, parse, and be the vault
  /// the request named.
  static api.SocialVault? _conflictVault(Object? vault, Object? request) {
    if (vault is! Map<String, dynamic> ||
        !SocialVaultApi.isWellFormedVault(vault)) {
      return null;
    }
    final asked = request is Map ? request['vaultId'] : null;
    if (asked is! String || vault['vaultId'] != asked) return null;
    try {
      return api.SocialVault.fromJson(vault);
    } catch (_) {
      return null;
    }
  }

  final SocialVaultApiError error;
  final int? status;
  final String? code;

  /// Whether the vault routes themselves refused the request: a 4xx whose
  /// body carries one of their codes ([_refusalCodes]). That is the only
  /// answer that says the request changed nothing, so it is the only one
  /// after which a caller may undo what it prepared for the request (a
  /// platform entry written for a slot, a data key kept for a creation).
  ///
  /// A 4xx with no code, or with a code that is not theirs — a bare 404
  /// above all — is what a proxy, or a backend that does not have these
  /// routes, answers. It is no more a refusal than no answer at all: the
  /// request may never have reached the backend that holds the vault, or
  /// may have been carried out there. The same goes for a code these routes
  /// gain later and this build does not know: kept is the safe side, and
  /// what was kept is cleaned up by the sweeps once the backend can be
  /// asked.
  bool get refusedByBackend {
    final status = this.status;
    return status != null &&
        status >= 400 &&
        status < 500 &&
        _refusalCodes.contains(code);
  }

  /// The codes the vault routes put on a refusal.
  static const _refusalCodes = {
    'invalid_id_token',
    'invalid_identity_token',
    'invalid_vault_signature',
    'stale_vault_timestamp',
    'replayed_vault_signature',
    'vault_exists',
    'revision_conflict',
    'last_slot',
    'same_vault_key',
    'vault_not_found',
  };

  /// Whether the provider ID token itself was refused (`invalid_id_token`):
  /// invalid, expired, or already used. A token from a sign-in that showed no
  /// UI can be a cached one, which is refused this way.
  bool get idTokenRefused => code == 'invalid_id_token';

  static String? _errorCode(Object? data) {
    if (data is! Map) return null;
    final error = data['error'];
    if (error is! Map) return null;
    final code = error['code'];
    return code is String ? code : null;
  }

  @override
  String toString() =>
      'SocialVaultApiException(${error.name}, status: $status, code: $code)';
}

/// A write named a revision that is no longer current. Carries the current
/// vault so the caller can retry against it.
class SocialVaultConflictException extends SocialVaultApiException {
  SocialVaultConflictException(this.vault)
    : super(
        SocialVaultApiError.rejected,
        status: 409,
        code: 'revision_conflict',
      );

  final api.SocialVault vault;

  @override
  String toString() =>
      'SocialVaultConflictException(revision: ${vault.revision})';
}
