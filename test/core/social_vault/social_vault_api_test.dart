import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/social_vault/social_vault_api.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_crypto.dart';

/// The vault-key signature covers the SHA-256 of the raw request body, so the
/// bytes Dio puts on the wire must be exactly the bytes [SocialVaultApi]
/// signed. These tests run the real generated Retrofit client over a recording
/// adapter and verify the signature against what was actually sent.
void main() {
  late _Adapter adapter;
  late SocialVaultApi vaultApi;
  late SimpleKeyPair vaultKey;
  const vaultId = 'EBESExQVFhcYGRobHB0eHw';
  final now = DateTime.utc(2026, 11, 9, 12);

  setUp(() async {
    adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://backend.test/v2'))
      ..httpClientAdapter = adapter;
    vaultApi = SocialVaultApi(
      api.MallowApiV2Client(dio, baseUrl: 'https://backend.test/v2'),
      clock: () => now,
    );
    vaultKey = await SocialVaultCrypto.vaultKeyPair(
      dataKey: Uint8List(32),
      vaultId: vaultId,
    );
  });

  Future<void> expectSignedOver(String path, int revision) async {
    final request = adapter.requests.single;
    expect(request.options.uri.path, path);
    final timestamp = request.options.headers['x-vault-timestamp'] as String;
    expect(timestamp, '${now.millisecondsSinceEpoch ~/ 1000}');
    final signature = SocialVaultCrypto.decodeBase64UrlNoPad(
      request.options.headers['x-vault-signature'] as String,
    );
    final message = SocialVaultCrypto.requestMessage(
      method: 'POST',
      path: path,
      vaultId: vaultId,
      revision: revision,
      body: request.body,
      timestamp: int.parse(timestamp),
    );
    final verified = await Ed25519().verify(
      utf8.encode(message),
      signature: Signature(
        signature,
        publicKey: await vaultKey.extractPublicKey(),
      ),
    );
    expect(verified, isTrue, reason: 'signature must cover the sent bytes');
  }

  test('add slot signs the exact body it sends', () async {
    adapter.respond(200, {'result': _vaultJson(revision: 4)});
    final vault = await vaultApi.addSlot(
      vaultKey: vaultKey,
      vaultId: vaultId,
      revision: 3,
      slot: const api.SocialVaultNewSlot(
        slotId: 'AAAAAAAAAAAAAAAAAAAAAA',
        kind: api.SocialVaultSlotKind.passkeyPrf,
        nonce: 'AAAAAAAAAAAAAAAA',
        wrappedKey: 'AAAA',
        prfSalt: 'AAAA',
        credentialId: 'Y3JlZA',
        rpId: 'example.test',
        label: 'Phone — ünïcode',
      ),
    );
    expect(vault.revision, 4);
    await expectSignedOver(SocialVaultApi.addSlotPath, 3);
  });

  test('remove slot and delete sign the exact body they send', () async {
    adapter.respond(200, {'result': _vaultJson(revision: 2)});
    await vaultApi.removeSlot(
      vaultKey: vaultKey,
      vaultId: vaultId,
      revision: 1,
      slotId: 'AAAAAAAAAAAAAAAAAAAAAA',
    );
    await expectSignedOver(SocialVaultApi.removeSlotPath, 1);

    adapter
      ..requests.clear()
      ..respond(204, null);
    await vaultApi.delete(vaultKey: vaultKey, vaultId: vaultId, revision: 2);
    await expectSignedOver(SocialVaultApi.deletePath, 2);
  });

  test('rename slot signs the exact body it sends', () async {
    adapter.respond(200, {'result': _vaultJson(revision: 6)});
    final vault = await vaultApi.renameSlot(
      vaultKey: vaultKey,
      vaultId: vaultId,
      revision: 5,
      slotId: 'AAAAAAAAAAAAAAAAAAAAAA',
      label: 'Work phone — ünïcode',
    );
    expect(vault.revision, 6);
    await expectSignedOver(SocialVaultApi.renameSlotPath, 5);
    expect(jsonDecode(utf8.decode(adapter.requests.single.body)), {
      'vaultId': vaultId,
      'revision': 5,
      'slotId': 'AAAAAAAAAAAAAAAAAAAAAA',
      'label': 'Work phone — ünïcode',
    });
  });

  test('status and cancel deletion sign the exact body they send', () async {
    adapter.respond(200, {'result': _vaultJson(revision: 7)});
    final current = await vaultApi.status(
      vaultKey: vaultKey,
      vaultId: vaultId,
      revision: 3,
    );
    // The signed revision is the caller's last known one; the answer is the
    // current vault, whatever its revision.
    expect(current.revision, 7);
    await expectSignedOver(SocialVaultApi.statusPath, 3);
    expect(jsonDecode(utf8.decode(adapter.requests.single.body)), {
      'vaultId': vaultId,
      'revision': 3,
    });

    adapter
      ..requests.clear()
      ..respond(200, {'result': _vaultJson(revision: 8)});
    final kept = await vaultApi.cancelDeletion(
      vaultKey: vaultKey,
      vaultId: vaultId,
      revision: 7,
    );
    expect(kept.revision, 8);
    expect(kept.pendingDeletion, isNull);
    await expectSignedOver(SocialVaultApi.cancelDeletionPath, 7);
  });

  test('a pending deletion is read off the vault', () async {
    adapter.respond(200, {
      'result': {
        ..._vaultJson(revision: 2),
        'pendingDeletion': {
          'requestedAt': '2026-11-10T00:00:00Z',
          'appliesAt': '2026-11-17T00:00:00Z',
        },
      },
    });
    final vault = await vaultApi.status(
      vaultKey: vaultKey,
      vaultId: vaultId,
      revision: 2,
    );
    expect(vault.pendingDeletion?.appliesAt, '2026-11-17T00:00:00Z');
  });

  group('the three signature refusals', () {
    Future<SocialVaultApiError> refusal(String code) async {
      adapter
        ..requests.clear()
        ..respond(401, {
          'error': {'message': 'x', 'code': code},
        });
      try {
        await vaultApi.status(
          vaultKey: vaultKey,
          vaultId: vaultId,
          revision: 1,
        );
      } on SocialVaultApiException catch (e) {
        return e.error;
      }
      fail('expected a SocialVaultApiException');
    }

    test('are told apart', () async {
      expect(
        await refusal('invalid_vault_signature'),
        SocialVaultApiError.signatureRejected,
      );
      expect(
        await refusal('stale_vault_timestamp'),
        SocialVaultApiError.staleTimestamp,
      );
      expect(
        await refusal('replayed_vault_signature'),
        SocialVaultApiError.replayedSignature,
      );
    });

    test('a stale timestamp is not retried', () async {
      await refusal('stale_vault_timestamp');
      expect(adapter.requests, hasLength(1));
    });

    test('a replay is re-signed with a strictly later timestamp, '
        'once', () async {
      adapter.respondInOrder([
        (
          401,
          {
            'error': {'message': 'x', 'code': 'replayed_vault_signature'},
          },
        ),
        (200, {'result': _vaultJson(revision: 4)}),
      ]);
      final vault = await vaultApi.status(
        vaultKey: vaultKey,
        vaultId: vaultId,
        revision: 4,
      );
      expect(vault.revision, 4);
      expect(adapter.requests, hasLength(2));
      final first = adapter.requests[0].options.headers;
      final second = adapter.requests[1].options.headers;
      expect(
        int.parse(second['x-vault-timestamp'] as String),
        greaterThan(int.parse(first['x-vault-timestamp'] as String)),
      );
      expect(second['x-vault-signature'], isNot(first['x-vault-signature']));
    });

    test('a second replay is surfaced', () async {
      expect(
        await refusal('replayed_vault_signature'),
        SocialVaultApiError.replayedSignature,
      );
      expect(adapter.requests, hasLength(2), reason: 'retried exactly once');
    });
  });

  test('a repeated identical write is signed afresh', () async {
    // The backend accepts each signature once, and Ed25519 is deterministic:
    // the same request in the same second must not reuse its signature.
    adapter.respond(204, null);
    await vaultApi.delete(vaultKey: vaultKey, vaultId: vaultId, revision: 2);
    await vaultApi.delete(vaultKey: vaultKey, vaultId: vaultId, revision: 2);
    final first = adapter.requests[0].options.headers;
    final second = adapter.requests[1].options.headers;
    expect(
      int.parse(second['x-vault-timestamp'] as String),
      int.parse(first['x-vault-timestamp'] as String) + 1,
    );
    expect(second['x-vault-signature'], isNot(first['x-vault-signature']));
  });

  test('rotate is signed by the current key over the rotate path', () async {
    adapter.respond(200, {'result': _vaultJson(revision: 6)});
    final vault = await vaultApi.rotate(
      currentVaultKey: vaultKey,
      request: const api.SocialVaultRotateRequest(
        vaultId: vaultId,
        revision: 5,
        payloadNonce: 'AAAAAAAAAAAAAAAA',
        payloadCiphertext: 'AAAA',
        vaultPublicKey: 'NEWKEY',
        slots: [
          api.SocialVaultNewSlot(
            slotId: 'AAAAAAAAAAAAAAAAAAAAAA',
            kind: api.SocialVaultSlotKind.platform,
            nonce: 'AAAAAAAAAAAAAAAA',
            wrappedKey: 'AAAA',
          ),
        ],
      ),
    );
    expect(vault.revision, 6);
    await expectSignedOver(SocialVaultApi.rotatePath, 5);
  });

  test('a revision conflict carries the current vault', () async {
    adapter.respond(409, {
      'error': {'message': 'stale', 'code': 'revision_conflict'},
      'vault': _vaultJson(revision: 9),
    });
    await expectLater(
      vaultApi.delete(vaultKey: vaultKey, vaultId: vaultId, revision: 2),
      throwsA(
        isA<SocialVaultConflictException>().having(
          (e) => e.vault.revision,
          'revision',
          9,
        ),
      ),
    );
  });

  test('retryOnConflict re-signs for the newer revision of the same '
      'vault only', () async {
    final seen = <int>[];
    final result = await SocialVaultApi.retryOnConflict(
      vaultId: vaultId,
      revision: 1,
      vaultPublicKey: 'PK',
      attempt: (revision) async {
        seen.add(revision);
        if (revision == 1) {
          throw SocialVaultConflictException(
            api.SocialVault.fromJson(_vaultJson(revision: 5)),
          );
        }
        return revision;
      },
    );
    expect(result, 5);
    expect(seen, [1, 5]);

    await expectLater(
      SocialVaultApi.retryOnConflict(
        vaultId: vaultId,
        revision: 1,
        vaultPublicKey: 'ANOTHER',
        attempt: (_) async => throw SocialVaultConflictException(
          api.SocialVault.fromJson(_vaultJson(revision: 5)),
        ),
      ),
      throwsA(isA<SocialVaultConflictException>()),
    );

    // A conflict that carries another vault's record: its revision is not
    // this vault's, so nothing is re-signed for it.
    final attempts = <int>[];
    await expectLater(
      SocialVaultApi.retryOnConflict(
        vaultId: 'ERITFBUWFxgZGhscHR4fIA',
        revision: 1,
        vaultPublicKey: 'PK',
        attempt: (revision) async {
          attempts.add(revision);
          throw SocialVaultConflictException(
            api.SocialVault.fromJson(_vaultJson(revision: 5)),
          );
        },
      ),
      throwsA(isA<SocialVaultConflictException>()),
    );
    expect(attempts, [1]);
  });

  test('maps error codes', () async {
    Future<SocialVaultApiError> errorFor(int status, String? code) async {
      adapter
        ..requests.clear()
        ..respond(status, {
          'error': {'message': 'x', 'code': ?code},
        });
      try {
        await vaultApi.open('token');
      } on SocialVaultApiException catch (e) {
        return e.error;
      }
      fail('expected a SocialVaultApiException');
    }

    expect(
      await errorFor(401, 'invalid_id_token'),
      SocialVaultApiError.identityRejected,
    );
    expect(
      await errorFor(401, 'invalid_vault_signature'),
      SocialVaultApiError.signatureRejected,
    );
    expect(
      await errorFor(409, 'vault_exists'),
      SocialVaultApiError.vaultExists,
    );
    expect(await errorFor(400, 'last_slot'), SocialVaultApiError.lastSlot);
    expect(
      await errorFor(404, 'vault_not_found'),
      SocialVaultApiError.notFound,
    );
    expect(await errorFor(429, null), SocialVaultApiError.rateLimited);
    expect(await errorFor(503, null), SocialVaultApiError.unavailable);
    expect(await errorFor(400, 'bad'), SocialVaultApiError.rejected);
  });

  // Callers act on "no such vault": they unlink a wallet from its backup,
  // and in time delete slot secrets. A proxy, a backend without these routes
  // and a build pointed at the wrong host all answer 404 too.
  group('only the backend\'s own "no such vault" is one', () {
    Future<SocialVaultApiException> statusAnswered(
      int status,
      Object? body,
    ) async {
      adapter
        ..requests.clear()
        ..respond(status, body);
      try {
        await vaultApi.status(
          vaultKey: vaultKey,
          vaultId: vaultId,
          revision: 1,
        );
      } on SocialVaultApiException catch (e) {
        return e;
      }
      fail('expected a SocialVaultApiException');
    }

    test('a 404 with the code is "not found", and a refusal by the '
        'backend', () async {
      final e = await statusAnswered(404, {
        'error': {'message': 'No such vault.', 'code': 'vault_not_found'},
      });
      expect(e.error, SocialVaultApiError.notFound);
      expect(e.refusedByBackend, isTrue);
    });

    test('a 404 with no body, with a page, with no code or with another '
        'code is not', () async {
      for (final body in <Object?>[
        null,
        '<html><body>404 Not Found</body></html>',
        <String, Object?>{},
        {'message': 'Not Found'},
        {
          'error': {'message': 'Not Found'},
        },
        {
          'error': {'message': 'Not Found', 'code': 'not_found'},
        },
        {
          'error': {'message': 'x', 'code': 'VAULT_NOT_FOUND'},
        },
        // The code in the wrong place is not the code.
        {'code': 'vault_not_found'},
      ]) {
        final e = await statusAnswered(404, body);
        expect(e.error, SocialVaultApiError.unavailable, reason: '$body');
        expect(e.status, 404);
      }
    });

    test('the same holds for a delete and for every other signed '
        'write', () async {
      adapter.respond(404, null);
      await expectLater(
        vaultApi.delete(vaultKey: vaultKey, vaultId: vaultId, revision: 2),
        throwsA(
          isA<SocialVaultApiException>().having(
            (e) => e.error,
            'error',
            SocialVaultApiError.unavailable,
          ),
        ),
      );
      adapter.respond(404, {
        'error': {'message': 'No such vault.', 'code': 'vault_not_found'},
      });
      await expectLater(
        vaultApi.delete(vaultKey: vaultKey, vaultId: vaultId, revision: 2),
        throwsA(
          isA<SocialVaultApiException>().having(
            (e) => e.error,
            'error',
            SocialVaultApiError.notFound,
          ),
        ),
      );
    });

    test('a 4xx with no code of the backend\'s is not a refusal by '
        'it', () async {
      expect((await statusAnswered(404, null)).refusedByBackend, isFalse);
      expect(
        (await statusAnswered(400, {
          'error': {'message': 'bad'},
        })).refusedByBackend,
        isFalse,
      );
      expect(
        (await statusAnswered(403, 'Forbidden')).refusedByBackend,
        isFalse,
      );
      expect(
        (await statusAnswered(400, {
          'error': {'message': 'x', 'code': 'last_slot'},
        })).refusedByBackend,
        isTrue,
      );
      expect((await statusAnswered(503, null)).refusedByBackend, isFalse);
    });
  });

  group('a vault record in an answer', () {
    Future<void> expectMalformed(Future<Object?> call) => expectLater(
      call,
      throwsA(
        isA<SocialVaultApiException>().having(
          (e) => e.error,
          'error',
          SocialVaultApiError.malformedResponse,
        ),
      ),
    );

    Future<api.SocialVault> status() =>
        vaultApi.status(vaultKey: vaultKey, vaultId: vaultId, revision: 1);

    test('must be the vault that was asked about', () async {
      adapter.respond(200, {
        'result': {
          ..._vaultJson(revision: 3),
          'vaultId': 'ERITFBUWFxgZGhscHR4fIA',
        },
      });
      await expectMalformed(status());
      await expectMalformed(
        vaultApi.cancelDeletion(
          vaultKey: vaultKey,
          vaultId: vaultId,
          revision: 1,
        ),
      );
    });

    test('must carry its slots: a missing list is not an empty one', () async {
      adapter.respond(200, {
        'result': {..._vaultJson(revision: 3)}..remove('slots'),
      });
      await expectMalformed(status());
      adapter.respond(200, {
        'result': {..._vaultJson(revision: 3), 'slots': <Object>[]},
      });
      await expectMalformed(status());
    });

    test('a body the parser refuses is a typed error, not a cast '
        'failure', () async {
      for (final missing in const ['createdAt', 'updatedAt', 'revision']) {
        adapter.respond(200, {
          'result': {..._vaultJson(revision: 3)}..remove(missing),
        });
        await expectMalformed(status());
      }
      adapter.respond(200, {'result': 'none'});
      await expectMalformed(status());
    });

    test('a conflict about another vault is not read as one', () async {
      adapter.respond(409, {
        'error': {'message': 'stale', 'code': 'revision_conflict'},
        'vault': {
          ..._vaultJson(revision: 9),
          'vaultId': 'ERITFBUWFxgZGhscHR4fIA',
        },
      });
      await expectLater(
        vaultApi.delete(vaultKey: vaultKey, vaultId: vaultId, revision: 2),
        throwsA(
          isA<SocialVaultApiException>()
              .having(
                (e) => e is SocialVaultConflictException,
                'conflict',
                false,
              )
              .having((e) => e.error, 'error', SocialVaultApiError.rejected),
        ),
      );
    });

    test('a conflict whose vault lacks a timestamp, or carries a field of '
        'the wrong type, is a plain refusal — never a cast failure', () async {
      for (final vault in <Map<String, dynamic>>[
        {..._vaultJson(revision: 9)}..remove('createdAt'),
        {..._vaultJson(revision: 9)}..remove('updatedAt'),
        {..._vaultJson(revision: 9), 'updatedAt': 12},
        {
          ..._vaultJson(revision: 9),
          'slots': [
            {
              'slotId': 'AAAAAAAAAAAAAAAAAAAAAA',
              'kind': 'platform',
              'nonce': 'AAAAAAAAAAAAAAAA',
              'wrappedKey': 'AAAA',
            },
          ],
        },
        {
          ..._vaultJson(revision: 9),
          'slots': [
            {
              'slotId': 'AAAAAAAAAAAAAAAAAAAAAA',
              'kind': 'platform',
              'nonce': 'AAAAAAAAAAAAAAAA',
              'wrappedKey': 'AAAA',
              'createdAt': '2026-11-09T00:00:00Z',
              'label': 7,
            },
          ],
        },
      ]) {
        adapter.respond(409, {
          'error': {'message': 'stale', 'code': 'revision_conflict'},
          'vault': vault,
        });
        await expectLater(
          vaultApi.addSlot(
            vaultKey: vaultKey,
            vaultId: vaultId,
            revision: 2,
            slot: const api.SocialVaultNewSlot(
              slotId: 'AAAAAAAAAAAAAAAAAAAAAA',
              kind: api.SocialVaultSlotKind.platform,
              nonce: 'AAAAAAAAAAAAAAAA',
              wrappedKey: 'AAAA',
            ),
          ),
          throwsA(
            isA<SocialVaultApiException>()
                .having(
                  (e) => e is SocialVaultConflictException,
                  'conflict',
                  false,
                )
                .having((e) => e.error, 'error', SocialVaultApiError.rejected)
                .having((e) => e.refusedByBackend, 'refused', isTrue),
          ),
        );
      }
    });
  });

  test('a conflict whose vault is malformed is not read as one', () async {
    adapter.respond(409, {
      'error': {'message': 'stale', 'code': 'revision_conflict'},
      'vault': {'vaultId': 'EBESExQVFhcYGRobHB0eHw'},
    });
    await expectLater(
      vaultApi.delete(vaultKey: vaultKey, vaultId: vaultId, revision: 2),
      throwsA(
        isA<SocialVaultApiException>()
            .having((e) => e is SocialVaultConflictException, 'conflict', false)
            .having((e) => e.error, 'error', SocialVaultApiError.rejected),
      ),
    );
  });

  group('open', () {
    Map<String, dynamic> openJson({Object? vault = _absent}) => {
      'provider': 'google',
      'emailHint': 'a@example.test',
      'identityId': _identityId,
      'identityToken': 'id',
      if (!identical(vault, _absent)) 'vault': vault,
    };

    Future<void> expectMalformed(Map<String, dynamic> result) async {
      adapter.respond(200, {'result': result});
      await expectLater(
        vaultApi.open('token'),
        throwsA(
          isA<SocialVaultApiException>().having(
            (e) => e.error,
            'error',
            SocialVaultApiError.malformedResponse,
          ),
        ),
      );
    }

    test('sends only the ID token, and returns the identity id', () async {
      adapter.respond(200, {'result': openJson(vault: null)});
      final opened = await vaultApi.open('token');
      expect(opened.vault, isNull);
      expect(opened.identityToken, 'id');
      expect(opened.identityId, _identityId);
      expect(jsonDecode(utf8.decode(adapter.requests.single.body)), {
        'idToken': 'token',
      });
    });

    test('returns a well-formed vault', () async {
      adapter.respond(200, {
        'result': openJson(vault: _vaultJson(revision: 3)),
      });
      expect((await vaultApi.open('token')).vault?.revision, 3);
    });

    test(
      'an answer without the vault field is an error, never '
      '"no vault"',
      () => expectMalformed(openJson()),
    );

    test('a vault missing what a vault carries is an error', () async {
      await expectMalformed(
        openJson(vault: {..._vaultJson(revision: 3)}..remove('vaultPublicKey')),
      );
      await expectMalformed(
        openJson(vault: {..._vaultJson(revision: 3)}..remove('slots')),
      );
      await expectMalformed(
        openJson(
          vault: {..._vaultJson(revision: 3)}..remove('pendingDeletion'),
        ),
      );
      await expectMalformed(
        openJson(vault: {..._vaultJson(revision: 3), 'revision': 0}),
      );
      await expectMalformed(openJson(vault: 'none'));
    });

    test('an answer without a usable identity id is an error', () async {
      await expectMalformed(openJson(vault: null)..remove('identityId'));
      await expectMalformed({
        ...openJson(vault: null),
        'identityId': 'person@example.test',
      });
    });

    test('a refused ID token is recognisable', () async {
      adapter.respond(401, {
        'error': {'message': 'x', 'code': 'invalid_id_token'},
      });
      await expectLater(
        vaultApi.open('token'),
        throwsA(
          isA<SocialVaultApiException>()
              .having((e) => e.idTokenRefused, 'idTokenRefused', isTrue)
              .having(
                (e) => e.error,
                'error',
                SocialVaultApiError.identityRejected,
              ),
        ),
      );
    });
  });
}

/// The identity id the backend derives for issuer
/// `https://accounts.google.com` and subject `1234567890`. The app never
/// computes it; it stores and compares what `open` returns.
const _identityId = '8ca57526739bfeac48d22f9d47d76f1a';

const Object _absent = Object();

Map<String, dynamic> _vaultJson({required int revision}) => {
  'vaultId': 'EBESExQVFhcYGRobHB0eHw',
  'revision': revision,
  'payloadNonce': 'AAAAAAAAAAAAAAAA',
  'payloadCiphertext': 'AAAA',
  'vaultPublicKey': 'PK',
  // A vault always has a slot: the backend refuses to remove the last one.
  'slots': <Object>[
    {
      'slotId': 'AAAAAAAAAAAAAAAAAAAAAA',
      'kind': 'platform',
      'nonce': 'AAAAAAAAAAAAAAAA',
      'wrappedKey': 'AAAA',
      'createdAt': '2026-11-09T00:00:00Z',
    },
  ],
  'pendingDeletion': null,
  'createdAt': '2026-11-09T00:00:00Z',
  'updatedAt': '2026-11-09T00:00:00Z',
};

class _Recorded {
  _Recorded(this.options, this.body);
  final RequestOptions options;
  final List<int> body;
}

class _Adapter implements HttpClientAdapter {
  final requests = <_Recorded>[];
  int _status = 200;
  Object? _body;

  final _queue = <(int, Object?)>[];

  void respond(int status, Object? body) {
    _queue.clear();
    _status = status;
    _body = body;
  }

  /// Answer the next requests with [responses], one each, in order.
  void respondInOrder(List<(int, Object?)> responses) => _queue
    ..clear()
    ..addAll(responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = requestStream == null
        ? <int>[]
        : (await requestStream.toList()).expand((c) => c).toList();
    requests.add(_Recorded(options, body));
    if (_queue.isNotEmpty) {
      final (status, body) = _queue.removeAt(0);
      _status = status;
      _body = body;
    }
    return ResponseBody.fromString(
      _body == null ? '' : jsonEncode(_body),
      _status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
