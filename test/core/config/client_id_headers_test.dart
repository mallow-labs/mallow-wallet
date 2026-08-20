import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';

/// The first-party identification header is configured entirely at build time,
/// and the source ships no default for it. These tests pin the two properties
/// that make that safe to publish:
///
///  * an unconfigured build sends **no header**, rather than one with an empty
///    value — on the wire those are different requests, and a gateway is
///    entitled to reject an empty header as malformed instead of treating it
///    as an anonymous caller; and
///  * a half-configured build (name without value, or value without name) is
///    treated as unconfigured rather than producing a malformed header.
void main() {
  // `clientIdValue` reads a different define per platform, so the tests set
  // whichever one the host will actually consult.
  final valueKey = Platform.isIOS ? 'CLIENT_ID_IOS' : 'CLIENT_ID_ANDROID';

  tearDown(Config.debugOverrides.clear);

  group('Config.clientIdHeaders', () {
    test('is empty when nothing is configured', () {
      expect(Config.clientIdHeaders, isEmpty);
    });

    test('is empty when the header name is set but the value is not', () {
      Config.debugOverrides['CLIENT_ID_HEADER'] = 'X-Client';

      expect(Config.clientIdHeaders, isEmpty);
    });

    test('is empty when the value is set but the header name is not', () {
      Config.debugOverrides[valueKey] = 'example.client';

      expect(Config.clientIdHeaders, isEmpty);
    });

    test('carries the configured name and value when both are set', () {
      Config.debugOverrides['CLIENT_ID_HEADER'] = 'X-Client';
      Config.debugOverrides[valueKey] = 'example.client';

      expect(Config.clientIdHeaders, {'X-Client': 'example.client'});
    });
  });

  group('Config.extraFirstPartyHosts', () {
    test('is empty when the variable is unset', () {
      expect(Config.extraFirstPartyHosts, isEmpty);
    });

    test('splits on commas and ignores surrounding whitespace', () {
      Config.debugOverrides['FIRST_PARTY_HOSTS'] =
          ' rpc.example.com , pin.example.com ';

      expect(Config.extraFirstPartyHosts, {
        'rpc.example.com',
        'pin.example.com',
      });
    });

    test('drops empty segments rather than trusting the empty host', () {
      // A trailing comma is the likeliest hand-edit slip. An empty entry that
      // survived would match `Uri.parse('/relative/path').host`, which is ''.
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.example.com,,  ,';

      expect(Config.extraFirstPartyHosts, {'rpc.example.com'});
    });

    test('lower-cases entries so they can match a parsed URL host', () {
      // Uri normalises the host to lower case, so an upper-case entry would
      // silently never match and the header would be withheld.
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'RPC.Example.COM';

      expect(Config.extraFirstPartyHosts, {'rpc.example.com'});
      expect(
        Config.firstPartyHosts.contains(
          Uri.parse('https://RPC.Example.COM/rpc').host,
        ),
        isTrue,
      );
    });
  });

  group('Config.firstPartyHosts', () {
    test('always contains the API host, whatever the variable says', () {
      // The union shape is the security property: configuration may add
      // hosts, never remove the app's own backend. Dropping it would strip
      // the client-id header off every API request.
      Config.debugOverrides['API_BASE_URL'] = 'https://api.example.com';
      final derived = Uri.parse(Config.apiBaseUrl).host;
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.example.com';

      expect(Config.firstPartyHosts, contains(derived));
      expect(Config.firstPartyHosts, contains('rpc.example.com'));
    });
  });

  // The session `Cookie` carries the login token and one wallet-signature JWT
  // per address — credentials that identify the *user*, not the build. Every
  // other first-party header identifies only the build, which is why those may
  // widen by configuration and this one may not.
  //
  // These tests exist so that distinction is enforced rather than documented.
  // The two sets were briefly one, and collapsing them again — for the very
  // reasonable-sounding reason of "keeping the guards from drifting apart" —
  // silently hands a live session to every proxy an operator lists. That is a
  // credential exposure with no error, no crash, and nothing on screen.
  group('Config.sessionHosts', () {
    test('is exactly the two derived API hosts', () {
      Config.debugOverrides['API_BASE_URL'] = 'https://api.example.com';
      expect(Config.sessionHosts, {
        Uri.parse(Config.apiBaseUrl).host,
        Uri.parse(Config.apiV2BaseUrl).host,
      });
    });

    test('FIRST_PARTY_HOSTS cannot widen it', () {
      Config.debugOverrides['API_BASE_URL'] = 'https://api.example.com';
      final before = Config.sessionHosts;
      Config.debugOverrides['FIRST_PARTY_HOSTS'] =
          'rpc.example.com,jup.example.com,evil.example.com';

      expect(Config.sessionHosts, before);
      expect(Config.sessionHosts, isNot(contains('rpc.example.com')));
      expect(Config.sessionHosts, isNot(contains('evil.example.com')));
    });

    test('is a strict subset of firstPartyHosts once the variable is set', () {
      Config.debugOverrides['API_BASE_URL'] = 'https://api.example.com';
      // The client-id gate may be wider. The session gate may not — so any
      // host the variable adds must appear in one set and not the other.
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.example.com';

      expect(Config.firstPartyHosts, containsAll(Config.sessionHosts));
      expect(Config.firstPartyHosts.difference(Config.sessionHosts), {
        'rpc.example.com',
      });
    });

    test('still follows the API hosts when the build is repointed', () {
      // Pinning must not mean hard-coding: a fork pointed at its own backend
      // has to keep getting its own session, or login breaks entirely.
      Config.debugOverrides['API_BASE_URL'] = 'https://api.fork.example';
      Config.debugOverrides['API_V2_BASE_URL'] = 'https://v2.fork.example/v2';

      expect(Config.sessionHosts, {'api.fork.example', 'v2.fork.example'});
    });
  });

  group('Config.clientIdHeadersFor', () {
    setUp(() {
      Config.debugOverrides['CLIENT_ID_HEADER'] = 'X-Client';
      Config.debugOverrides[valueKey] = 'example.client';
    });

    test('carries the header for a listed host', () {
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.example.com';

      expect(Config.clientIdHeadersFor(Uri.parse('https://rpc.example.com/')), {
        'X-Client': 'example.client',
      });
    });

    test('withholds the header from an unlisted host', () {
      // The default RPC endpoint is a public node. A build that forgets to
      // declare its own proxy must under-send, never over-send.
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.example.com';

      expect(
        Config.clientIdHeadersFor(Uri.parse('https://api.devnet.solana.com')),
        isEmpty,
      );
    });

    test('matches the host exactly — a subdomain is a different host', () {
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'example.com';

      expect(
        Config.clientIdHeadersFor(Uri.parse('https://evil.example.com/rpc')),
        isEmpty,
      );
    });

    test('ignores the port, matching the shared Dio interceptors', () {
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'localhost';

      expect(
        Config.clientIdHeadersFor(Uri.parse('http://localhost:8899')),
        isNotEmpty,
      );
    });

    test('is empty for a listed host when the credential is unconfigured', () {
      Config.debugOverrides.remove('CLIENT_ID_HEADER');
      Config.debugOverrides.remove(valueKey);
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.example.com';

      expect(
        Config.clientIdHeadersFor(Uri.parse('https://rpc.example.com/')),
        isEmpty,
      );
    });
  });

  group('endpoint defaults are public', () {
    test('Jupiter and CoinGecko fall back to their public APIs', () {
      expect(Config.jupiterBaseUrl, 'https://api.jup.ag');
      expect(Config.coinGeckoBaseUrl, 'https://api.coingecko.com');
    });

    // Mainnet on purpose, and this used to be devnet. The devnet fallback was
    // a safety net — a build that configured nothing could not transact for
    // real — but it made the unconfigured build useless for judging the app,
    // because devnet holds none of the reader's assets and every screen came
    // back empty with no error to explain it. The public mainnet node has no
    // DAS either, so NFT surfaces are still empty until this is pointed at a
    // DAS provider; what changed is that the rest of the app is looking at the
    // network the reader expects.
    test('the Solana RPC falls back to the public mainnet node', () {
      expect(Config.rpcProxyBaseUrl, 'https://api.mainnet-beta.solana.com');
    });

    test('an override wins over the public default', () {
      Config.debugOverrides['JUPITER_BASE_URL'] = 'https://jup.example.com';

      expect(Config.jupiterBaseUrl, 'https://jup.example.com');
    });
  });

  group('Config.solanaMainnetRpcUrl', () {
    // Mainnet, not devnet, and resolved independently of RPC_PROXY_BASE_URL.
    // Its two consumers — `.sol` resolution and native staking — only exist on
    // mainnet, and both fail *quietly* against devnet: an unregistered domain
    // and an empty stake list are ordinary answers, not errors. Aliasing this
    // to the devnet-defaulting proxy URL is exactly the regression to catch.
    test('falls back to the public mainnet node', () {
      expect(Config.solanaMainnetRpcUrl, 'https://api.mainnet-beta.solana.com');
    });

    test('stays on mainnet when the environment RPC points at devnet', () {
      Config.debugOverrides['RPC_PROXY_BASE_URL'] =
          'https://rpc.example.com/devnet';

      expect(Config.solanaMainnetRpcUrl, 'https://api.mainnet-beta.solana.com');
    });

    test('honours its own override', () {
      Config.debugOverrides['SOLANA_MAINNET_RPC_URL'] =
          'https://mainnet.example.com';

      expect(Config.solanaMainnetRpcUrl, 'https://mainnet.example.com');
    });
  });

  group('Config.solanaRpcUrl', () {
    // The cluster parameter is only added off production, and `ENV` now
    // defaults to production — so these cases have to select the environment
    // rather than inherit it. Pin the precondition too: without it, a change
    // that stopped `ENV` resolving through `debugOverrides` would make both
    // assertions below pass vacuously against a mainnet build.
    setUp(() {
      Config.debugOverrides['ENV'] = 'development';
      expect(Config.isDevnet, isTrue);
    });

    test('adds the cluster parameter to a base URL with no query', () {
      Config.debugOverrides['RPC_PROXY_BASE_URL'] = 'https://rpc.example.com';

      expect(Config.solanaRpcUrl, 'https://rpc.example.com?network=devnet');
    });

    test('merges the cluster parameter into an existing query string', () {
      // The shape `.env.example` points a clone at: DAS-capable providers hand
      // out endpoints that carry the API key in the query. Appending a second
      // literal `?` folds the cluster into the key value
      // (`?api-key=abc123?network=devnet`), so the key never parses and every
      // RPC call 401s — the app looks broken with a correctly configured
      // endpoint.
      Config.debugOverrides['RPC_PROXY_BASE_URL'] =
          'https://mainnet.helius-rpc.com/?api-key=abc123';

      expect(
        Config.solanaRpcUrl,
        'https://mainnet.helius-rpc.com/?api-key=abc123&network=devnet',
      );
      expect(Uri.parse(Config.solanaRpcUrl).queryParameters, {
        'api-key': 'abc123',
        'network': 'devnet',
      });
    });
  });
}
