import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/social_vault/passkey_prf.dart';
import 'package:mallow_wallet/core/social_vault/platform_slot_store.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_crypto.dart';
import 'package:passkeys_platform_interface/types/types.dart';

void main() {
  final saltA = Uint8List.fromList(List.filled(32, 1));
  final saltB = Uint8List.fromList(List.filled(32, 2));
  final outA = Uint8List.fromList(List.filled(32, 0xAA));
  final outB = Uint8List.fromList(List.filled(32, 0xBB));

  PasskeyPrfAuthenticator authenticator(_FakeBackend backend) =>
      PasskeyPrfAuthenticator.withBackend(
        backend,
        platformSupportsPrf: () async => true,
      );

  group('register', () {
    test('uses the PRF output returned at creation', () async {
      final backend = _FakeBackend()
        ..registerPrf = {
          'enabled': true,
          'results': {'first': SocialVaultCrypto.base64UrlNoPad(outA)},
        };
      final result = await authenticator(backend).register(
        rpId: 'example.test',
        userId: 'dXNlcg',
        userName: 'user',
        salt: saltA,
      );
      expect(result.credentialId, 'cred-new');
      expect(result.output, outA);
      expect(
        backend.lastRegister!.prf,
        SocialVaultCrypto.base64UrlNoPad(saltA),
      );
      expect(backend.assertions, isEmpty);
    });

    test('evaluates PRF by assertion when creation only reports '
        'support', () async {
      final backend = _FakeBackend()
        ..registerPrf = {'enabled': true}
        ..assertOutputs = {saltA: outA};
      final result = await authenticator(backend).register(
        rpId: 'example.test',
        userId: 'dXNlcg',
        userName: 'user',
        salt: saltA,
      );
      expect(result.output, outA);
      expect(backend.assertions.single.allowCredentials!.single.id, 'cred-new');
    });

    test('refuses a passkey without PRF', () async {
      final backend = _FakeBackend()..registerPrf = {'enabled': false};
      await expectLater(
        authenticator(backend).register(
          rpId: 'example.test',
          userId: 'dXNlcg',
          userName: 'user',
          salt: saltA,
        ),
        throwsA(
          isA<PasskeyPrfException>().having(
            (e) => e.error,
            'error',
            PasskeyPrfError.prfUnsupported,
          ),
        ),
      );
    });

    test('refuses when the assertion yields no PRF output either', () async {
      final backend = _FakeBackend()..registerPrf = null;
      await expectLater(
        authenticator(backend).register(
          rpId: 'example.test',
          userId: 'dXNlcg',
          userName: 'user',
          salt: saltA,
        ),
        throwsA(isA<PasskeyPrfException>()),
      );
    });
  });

  group('authenticate', () {
    test('one prompt when the chosen passkey has the asked salt', () async {
      final backend = _FakeBackend()
        ..pickCredential = 'a'
        ..assertOutputs = {saltA: outA, saltB: outB};
      final result = await authenticator(backend).authenticate(
        rpId: 'example.test',
        candidates: [
          PasskeyPrfCandidate(credentialId: 'a', salt: saltA),
          PasskeyPrfCandidate(credentialId: 'b', salt: saltB),
        ],
      );
      expect(result.credentialId, 'a');
      expect(result.output, outA);
      expect(backend.assertions, hasLength(1));
      expect(backend.assertions.single.allowCredentials!.map((c) => c.id), [
        'a',
        'b',
      ]);
    });

    test('asks the chosen passkey again with its own salt', () async {
      final backend = _FakeBackend()
        ..pickCredential = 'b'
        ..assertOutputs = {saltA: outA, saltB: outB};
      final result = await authenticator(backend).authenticate(
        rpId: 'example.test',
        candidates: [
          PasskeyPrfCandidate(credentialId: 'a', salt: saltA),
          PasskeyPrfCandidate(credentialId: 'b', salt: saltB),
        ],
      );
      expect(result.credentialId, 'b');
      expect(result.output, outB);
      expect(backend.assertions, hasLength(2));
      expect(
        backend.assertions.last.prf,
        SocialVaultCrypto.base64UrlNoPad(saltB),
      );
      expect(backend.assertions.last.allowCredentials!.single.id, 'b');
    });

    test('maps a cancel', () async {
      final backend = _FakeBackend()..throwCode = 'cancelled';
      await expectLater(
        authenticator(backend).authenticate(
          rpId: 'example.test',
          candidates: [PasskeyPrfCandidate(credentialId: 'a', salt: saltA)],
        ),
        throwsA(
          isA<PasskeyPrfException>().having(
            (e) => e.error,
            'error',
            PasskeyPrfError.cancelled,
          ),
        ),
      );
    });

    test('accepts padded standard base64 output', () async {
      final backend = _FakeBackend()
        ..pickCredential = 'a'
        ..standardBase64 = true
        ..assertOutputs = {saltA: outA};
      final result = await authenticator(backend).authenticate(
        rpId: 'example.test',
        candidates: [PasskeyPrfCandidate(credentialId: 'a', salt: saltA)],
      );
      expect(result.output, outA);
    });
  });

  test('results never print the secret', () {
    final result = PasskeyPrfResult(credentialId: 'a', output: outA);
    expect(result.toString(), isNot(contains('170')));
    expect(result.toString(), contains('<redacted>'));
    final entry = PlatformSlotEntry(slotId: 's', secret: outA);
    expect(entry.toString(), contains('<redacted>'));
    expect(
      entry.toString(),
      isNot(contains(SocialVaultCrypto.base64UrlNoPad(outA))),
    );
  });

  test('platform slot entries round-trip and reject garbage', () {
    final entry = PlatformSlotEntry(slotId: 'slot', secret: outA);
    final parsed = PlatformSlotEntry.tryParse(entry.toJsonString())!;
    expect(parsed.slotId, 'slot');
    expect(parsed.secret, outA);
    expect(PlatformSlotEntry.tryParse('not json'), isNull);
    expect(PlatformSlotEntry.tryParse('{"v":2}'), isNull);
    expect(
      PlatformSlotEntry.tryParse('{"v":1,"slotId":"s","secret":"AAAA"}'),
      isNull,
    );
  });
}

class _FakeBackend implements PasskeyBackend {
  Map<String, Object?>? registerPrf;
  Map<Uint8List, Uint8List> assertOutputs = {};
  String pickCredential = 'cred-new';
  String? throwCode;
  bool standardBase64 = false;
  RegisterRequestType? lastRegister;
  final assertions = <AuthenticateRequestType>[];

  @override
  Future<RegisterResponseType> register(RegisterRequestType request) async {
    lastRegister = request;
    if (throwCode != null) throw PlatformException(code: throwCode!);
    return RegisterResponseType(
      id: 'cred-new',
      rawId: 'cred-new',
      clientDataJSON: '',
      attestationObject: '',
      transports: const [],
      clientExtensionResults: registerPrf == null ? null : {'prf': registerPrf},
    );
  }

  @override
  Future<AuthenticateResponseType> authenticate(
    AuthenticateRequestType request,
  ) async {
    assertions.add(request);
    if (throwCode != null) throw PlatformException(code: throwCode!);
    final allowed = request.allowCredentials!.map((c) => c.id).toList();
    final used = allowed.contains(pickCredential)
        ? pickCredential
        : allowed.first;
    final salt = SocialVaultCrypto.decodeBase64UrlNoPad(request.prf!);
    final output = assertOutputs.entries
        .where((e) => _eq(e.key, salt))
        .map((e) => e.value)
        .firstOrNull;
    String encode(Uint8List b) =>
        standardBase64 ? _standard(b) : SocialVaultCrypto.base64UrlNoPad(b);
    return AuthenticateResponseType(
      id: used,
      rawId: used,
      clientDataJSON: '',
      authenticatorData: '',
      signature: '',
      userHandle: '',
      clientExtensionResults: output == null
          ? null
          : {
              'prf': {
                'results': {'first': encode(output)},
              },
            },
    );
  }

  static String _standard(Uint8List b) {
    final url = SocialVaultCrypto.base64UrlNoPad(b);
    final std = url.replaceAll('-', '+').replaceAll('_', '/');
    return std.padRight((std.length + 3) ~/ 4 * 4, '=');
  }

  static bool _eq(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}
