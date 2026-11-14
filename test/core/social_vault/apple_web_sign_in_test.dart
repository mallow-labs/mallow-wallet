import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/social_vault/apple_web_sign_in.dart';

/// An unsigned JWT with [claims] as its payload. The app reads one claim of
/// the payload and verifies nothing; the backend does that.
String _jwt(Map<String, Object?> claims) {
  String part(Object? value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'RS256'})}.${part(claims)}.c2ln';
}

/// The site's return page with [fields] in its fragment, the way the
/// backend's relay redirects to it.
Uri _returnLink(Map<String, String> fields) => Uri(
  scheme: 'https',
  host: 'site.example',
  path: AppleWebSignIn.returnPath,
  fragment: Uri(queryParameters: fields).query,
);

void main() {
  late List<Uri> launched;
  late bool launchSucceeds;
  late AppleWebSignIn signIn;

  setUp(() {
    Config.debugOverrides['APPLE_SERVICES_ID'] = 'services.example';
    Config.debugOverrides['API_V2_BASE_URL'] = 'https://backend.example/v2';
    launched = [];
    launchSucceeds = true;
    signIn = AppleWebSignIn(
      launch: (uri) async {
        launched.add(uri);
        return launchSucceeds;
      },
    );
  });

  tearDown(Config.debugOverrides.clear);

  /// Start a sign-in and wait until its tab was opened.
  Future<({Future<AppleWebCredential?> result, String state, String nonceHash})>
  start() async {
    final result = signIn.signIn();
    // Errors are the test's to inspect, not the zone's.
    unawaited(result.then((_) {}, onError: (_) {}));
    await pumpEventQueue();
    final query = launched.last.queryParameters;
    return (result: result, state: query['state']!, nonceHash: query['nonce']!);
  }

  group('the request', () {
    test('opens Apple’s authorize page for the relay, with a fresh state and '
        'a hashed nonce', () async {
      final first = await start();
      final uri = launched.single;

      expect(uri.scheme, 'https');
      expect(uri.host, 'appleid.apple.com');
      expect(uri.path, '/auth/authorize');
      expect(uri.queryParameters, {
        'response_type': 'code id_token',
        'response_mode': 'form_post',
        'client_id': 'services.example',
        // No `package` query: the relay returns through the site's page.
        'redirect_uri':
            'https://backend.example/v2/social-vault/apple/callback',
        'scope': 'email',
        'state': first.state,
        'nonce': first.nonceHash,
      });
      // 128 bits of state, base64url.
      expect(base64Url.decode(base64Url.normalize(first.state)), hasLength(16));
      // The SHA-256 of the raw nonce, never the raw nonce.
      expect(first.nonceHash, matches(RegExp(r'^[0-9a-f]{64}$')));

      final second = await start();
      expect(second.state, isNot(first.state));
      expect(second.nonceHash, isNot(first.nonceHash));
    });

    test('a tab that cannot be opened fails the sign-in and leaves nothing '
        'waiting', () async {
      launchSucceeds = false;
      await expectLater(
        signIn.signIn(),
        throwsA(isA<AppleWebSignInException>()),
      );
      expect(signIn.isPending, isFalse);
    });
  });

  group('the answer', () {
    test('with this request’s state and nonce yields the ID token', () async {
      final request = await start();
      final token = _jwt({'sub': 'apple-user', 'nonce': request.nonceHash});

      signIn.handleReturn(
        _returnLink({
          'code': 'auth-code',
          'id_token': token,
          'state': request.state,
          'user': '{"email":"person@example.test"}',
        }),
      );

      final credential = await request.result;
      expect(credential!.idToken, token);
      // The raw nonce the token's claim is the hash of.
      expect(AppleWebSignIn.nonceHash(credential.rawNonce), request.nonceHash);
      expect(signIn.isPending, isFalse);
    });

    test('with another state is dropped, and the request keeps '
        'waiting', () async {
      final request = await start();
      var done = false;
      unawaited(request.result.whenComplete(() => done = true));

      signIn.handleReturn(
        _returnLink({
          'id_token': _jwt({'nonce': request.nonceHash}),
          'state': 'someone-elses-state',
        }),
      );
      // A forged link must not be able to cancel a sign-in either.
      signIn.handleReturn(
        _returnLink({'error': 'user_cancelled_authorize', 'state': 'forged'}),
      );
      signIn.handleReturn(_returnLink({'id_token': 'x'}));
      await pumpEventQueue();

      expect(done, isFalse);
      expect(signIn.isPending, isTrue);

      // The real one still completes it.
      final token = _jwt({'nonce': request.nonceHash});
      signIn.handleReturn(
        _returnLink({'id_token': token, 'state': request.state}),
      );
      expect((await request.result)!.idToken, token);
    });

    test('with no sign-in waiting is dropped', () async {
      // A cold start, or a link nobody asked for.
      signIn.handleReturn(
        _returnLink({
          'id_token': _jwt({'nonce': 'x'}),
          'state': 's',
        }),
      );
      expect(signIn.isPending, isFalse);
    });

    test('a duplicate and a late answer are dropped', () async {
      final request = await start();
      final token = _jwt({'nonce': request.nonceHash});
      final link = _returnLink({'id_token': token, 'state': request.state});

      signIn.handleReturn(link);
      signIn.handleReturn(link);

      expect((await request.result)!.idToken, token);
      expect(signIn.isPending, isFalse);

      // A new request does not accept the old one's answer.
      final next = await start();
      signIn.handleReturn(link);
      await pumpEventQueue();
      expect(signIn.isPending, isTrue);
      signIn.handleReturn(_returnLink({'error': 'x', 'state': next.state}));
      expect(await next.result, isNull);
    });

    test('with an error field is a cancel', () async {
      final request = await start();
      signIn.handleReturn(
        _returnLink({
          'error': 'user_cancelled_authorize',
          'state': request.state,
        }),
      );
      expect(await request.result, isNull);
      expect(signIn.isPending, isFalse);
    });

    test('whose token carries another nonce is refused', () async {
      final request = await start();
      signIn.handleReturn(
        _returnLink({
          'id_token': _jwt({'nonce': AppleWebSignIn.nonceHash('not-ours')}),
          'state': request.state,
        }),
      );
      await expectLater(
        request.result,
        throwsA(isA<AppleWebSignInException>()),
      );
      expect(signIn.isPending, isFalse);
    });

    test('whose token has no nonce, or is not a token, is refused', () async {
      for (final token in [
        _jwt({'sub': 'apple-user'}),
        'not-a-jwt',
        'a.b',
        'a.!!!.c',
      ]) {
        final request = await start();
        signIn.handleReturn(
          _returnLink({'id_token': token, 'state': request.state}),
        );
        await expectLater(
          request.result,
          throwsA(isA<AppleWebSignInException>()),
          reason: token,
        );
      }
    });

    test('without a token is refused', () async {
      final request = await start();
      signIn.handleReturn(
        _returnLink({'code': 'auth-code', 'state': request.state}),
      );
      await expectLater(
        request.result,
        throwsA(isA<AppleWebSignInException>()),
      );
    });

    test('an error never names what the link carried', () async {
      final request = await start();
      final token = _jwt({'nonce': 'wrong'});
      signIn.handleReturn(
        _returnLink({'id_token': token, 'state': request.state}),
      );
      Object? error;
      try {
        await request.result;
      } catch (e) {
        error = e;
      }
      expect(error.toString(), isNot(contains(token)));
      expect(error.toString(), isNot(contains(request.state)));
    });

    test('nothing is logged, whatever the link holds', () async {
      final printed = <String?>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
      addTearDown(() => debugPrint = original);

      await runZoned(
        () async {
          // No request, a wrong state, an error, a bad token, a good one.
          signIn.handleReturn(_returnLink({'id_token': 'a', 'state': 'b'}));
          var request = await start();
          signIn.handleReturn(_returnLink({'id_token': 'a', 'state': 'b'}));
          signIn.handleReturn(
            _returnLink({'error': 'x', 'state': request.state}),
          );
          request = await start();
          signIn.handleReturn(
            _returnLink({'id_token': 'bad', 'state': request.state}),
          );
          request = await start();
          signIn.handleReturn(
            _returnLink({
              'id_token': _jwt({'nonce': request.nonceHash}),
              'state': request.state,
            }),
          );
          await request.result;
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );

      // Starting a request reads the build config, which says so in a debug
      // build; that line is the only one, and it is not about the link.
      expect(printed.where((line) => !line!.startsWith('[Config] ')), isEmpty);
      expect(printed.join('\n'), isNot(contains('id_token')));
    });

    test('a credential does not print its token', () {
      const credential = AppleWebCredential(idToken: 'tok', rawNonce: 'raw');
      expect(credential.toString(), isNot(contains('tok')));
      expect(credential.toString(), isNot(contains('raw')));
    });
  });

  group('a request without an answer ends', () {
    // Real, short timers: the waits below are a few tens of milliseconds.
    AppleWebSignIn quick({
      Duration timeout = const Duration(minutes: 5),
      Duration returnGrace = const Duration(seconds: 5),
    }) => AppleWebSignIn(
      launch: (uri) async {
        launched.add(uri);
        return true;
      },
      timeout: timeout,
      returnGrace: returnGrace,
    );

    Future<void> wait(int milliseconds) =>
        Future<void>.delayed(Duration(milliseconds: milliseconds));

    test('after the timeout', () async {
      final signIn = quick(timeout: const Duration(milliseconds: 60));
      var done = false;
      final result = signIn.signIn();
      unawaited(result.whenComplete(() => done = true));

      await wait(20);
      expect(done, isFalse);
      expect(signIn.isPending, isTrue);

      expect(await result, isNull);
      expect(signIn.isPending, isFalse);
    });

    test('shortly after the app is back in front with the tab gone', () async {
      final signIn = quick(returnGrace: const Duration(milliseconds: 60));
      var done = false;
      final result = signIn.signIn();
      unawaited(result.whenComplete(() => done = true));
      await pumpEventQueue();

      // A resume before the app ever left is not a return.
      signIn.appResumed();
      await wait(120);
      expect(done, isFalse);

      signIn
        ..appPaused()
        ..appResumed();
      await wait(20);
      expect(done, isFalse);

      expect(await result, isNull);
      expect(signIn.isPending, isFalse);
    });

    test('but an answer that arrives with the resume wins', () async {
      final signIn = quick(returnGrace: const Duration(milliseconds: 60));
      final result = signIn.signIn();
      await pumpEventQueue();
      final query = launched.single.queryParameters;
      final token = _jwt({'nonce': query['nonce']});

      signIn
        ..appPaused()
        ..appResumed();
      await wait(10);
      signIn.handleReturn(
        _returnLink({'id_token': token, 'state': query['state']!}),
      );
      await wait(120);

      expect((await result)?.idToken, token);
    });

    test('when a new sign-in starts', () async {
      final first = await start();
      final second = await start();

      expect(await first.result, isNull);
      expect(signIn.isPending, isTrue);
      signIn.handleReturn(_returnLink({'error': 'x', 'state': second.state}));
      expect(await second.result, isNull);
    });
  });

  test('the nonce check reads the claim and nothing else', () {
    final hash = AppleWebSignIn.nonceHash('raw');
    expect(
      AppleWebSignIn.idTokenCarriesNonce(_jwt({'nonce': hash}), hash),
      isTrue,
    );
    expect(
      AppleWebSignIn.idTokenCarriesNonce(_jwt({'nonce': 'raw'}), hash),
      isFalse,
    );
    expect(
      AppleWebSignIn.idTokenCarriesNonce(_jwt({'nonce': 7}), hash),
      isFalse,
    );
    // SHA-256("raw"), lowercase hex.
    expect(
      hash,
      'd7439bee24773bcbfa2d0a97947ee36227b10d1022b1a55847e928965bb6bfde',
    );
  });
}
