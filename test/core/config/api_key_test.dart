import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';

/// `MALLOW_API_KEY` exists so a reader who holds a key can run the app against
/// a mallow-operated backend instead of implementing the contract first.
///
/// It is a *spendable* credential, unlike every other build-identifying header
/// here, so where it may travel is the property these tests pin — at the set
/// level. The wiring that actually attaches it is tested separately in
/// `test/core/network/api_key_interceptor_test.dart`; both halves are needed,
/// because a correct getter reached through the wrong host set still leaks.
void main() {
  tearDown(Config.debugOverrides.clear);

  group('Config.apiKeyHeadersFor', () {
    setUp(() {
      Config.debugOverrides['API_BASE_URL'] = 'https://api.test';
      Config.debugOverrides['MALLOW_API_KEY'] = 'KEY123';
    });

    test('carries the key to the v1 API host', () {
      expect(Config.apiKeyHeadersFor(Uri.parse('https://api.test/v1/user')), {
        'x-api-key': 'KEY123',
      });
    });

    test('carries the key to the derived v2 API host', () {
      // v2 is a separate service, but on the same host off an https base, and
      // it is the surface a key-holder actually reads. Deriving the host set
      // from both getters is what makes that work with one variable set.
      final v2 = Uri.parse(Config.apiV2BaseUrl);

      expect(Config.apiKeyHeadersFor(v2), {'x-api-key': 'KEY123'});
    });

    test('sends nothing to a third-party host', () {
      expect(
        Config.apiKeyHeadersFor(Uri.parse('https://api.jup.ag/tokens/v2')),
        isEmpty,
      );
    });

    test('sends nothing to a FIRST_PARTY_HOSTS proxy', () {
      // 🛑 The gate is `sessionHosts`, not `firstPartyHosts`. `FIRST_PARTY_HOSTS`
      // is build configuration — it lets a deployment declare its RPC, gas or
      // IPFS proxies first-party so they receive the client-id header, which
      // only says which build is calling. Gating a backend key there would let
      // one line of config hand a third party a key it can spend, which is
      // precisely the split `sessionHosts` was created to hold.
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.test,pin.test';
      Config.debugOverrides['CLIENT_ID_HEADER'] = 'X-Client';
      Config.debugOverrides['CLIENT_ID_IOS'] = 'example.client';
      Config.debugOverrides['CLIENT_ID_ANDROID'] = 'example.client';

      // Precondition: the proxy really is inside the wider gate, so the
      // absence below is the narrow gate working and not a typo'd host.
      expect(
        Config.clientIdHeadersFor(Uri.parse('https://rpc.test')),
        isNot(isEmpty),
      );

      expect(Config.apiKeyHeadersFor(Uri.parse('https://rpc.test')), isEmpty);
      expect(
        Config.apiKeyHeadersFor(Uri.parse('https://pin.test/upload')),
        isEmpty,
      );
      // ...and the API host is unaffected by the widening.
      expect(
        Config.apiKeyHeadersFor(Uri.parse('https://api.test/v1/user')),
        isNotEmpty,
      );
    });

    test('an unconfigured build sends no header at all', () {
      // Blank means omitted, not empty: an empty header value is a different
      // request on the wire and a gateway may reject it as malformed rather
      // than treat it as an anonymous caller. Same rule as the client id.
      Config.debugOverrides.remove('MALLOW_API_KEY');

      expect(
        Config.apiKeyHeadersFor(Uri.parse('https://api.test/v1/user')),
        isEmpty,
      );
    });
  });

  group('a key on its own is not a configured build', () {
    test('with API_BASE_URL unset the key reaches no host', () {
      // `API_BASE_URL` has no compiled-in default and no host is compiled into
      // Dart, so a key alone resolves an empty session-host set. The reader
      // sets both values together — the key is issued with the base URL it
      // works against.
      //
      // NB the getter does not throw; it returns '' and the API layer raises
      // `Config.missingApiBaseUrl`. What is asserted here is the security half:
      // a half-configured build sends the credential *nowhere* rather than to
      // whatever host a relative request happens to resolve against.
      Config.debugOverrides['MALLOW_API_KEY'] = 'KEY123';

      expect(Config.apiBaseUrl, isEmpty);
      expect(Config.sessionHosts, isEmpty);
      expect(
        Config.apiKeyHeadersFor(Uri.parse('https://api.test/v1')),
        isEmpty,
      );
      expect(Config.apiKeyHeadersFor(Uri.parse('https://anything/')), isEmpty);
    });

    test('the missing-base-URL error names both ways to satisfy it', () {
      // "There is no default backend" on its own reads as "write a backend
      // first", which is the wall this variable exists to remove. The message
      // must offer the short path too — and must name neither the host nor the
      // key, since a host in an error string is a compiled-in deployment host
      // by another route and a key in one is a credential in every log.
      final message = Config.missingApiBaseUrl.message.toString();

      expect(message, contains('API_BASE_URL'));
      expect(message, contains('MALLOW_API_KEY'));
      expect(message, isNot(contains('http')));
    });
  });
}
