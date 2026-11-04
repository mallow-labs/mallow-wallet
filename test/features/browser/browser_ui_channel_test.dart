import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/features/browser/services/browser_ui_channel.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';

void main() {
  const webApp = 'https://mallow.art';
  const production = Environment.production;
  const staging = Environment.staging;
  const development = Environment.development;

  // Tailscale's MagicDNS domain. Kept out of the literals below: the release
  // tree's deny-list reads a dotted `ts` as a TypeScript file name.
  const magicDns = 'ts.net';

  bool firstParty(String url, Environment environment) =>
      isFirstPartyOrigin(Uri.parse(url), environment);

  group('first-party origin', () {
    test('the built-in hosts are bare lowercase hosts, the apex and www '
        'among them', () {
      expect(
        browserFirstPartyHosts,
        containsAll(['mallow.art', 'www.mallow.art']),
      );
      for (final host in browserFirstPartyHosts) {
        expect(host, matches(RegExp(r'^[a-z0-9]+(\.[a-z0-9-]+)+$')));
        expect(browserFirstPartyOrigins, contains('https://$host'));
      }
      expect(
        browserFirstPartyOrigins,
        hasLength(browserFirstPartyHosts.length),
      );
    });

    test(
      'pre-release hosts are first-party outside production builds only',
      () {
        expect(browserFirstPartyHostsFor(production), browserFirstPartyHosts);
        expect(
          browserFirstPartyOriginsFor(production),
          browserFirstPartyOrigins,
        );
        for (final host in browserPreReleaseFirstPartyHosts) {
          expect(browserFirstPartyHosts, isNot(contains(host)));
          expect(host, matches(RegExp(r'^[a-z0-9]+(\.[a-z0-9-]+)+$')));
          expect(firstParty('https://$host/', production), isFalse);
          expect(
            browserUiOriginRules(production, android: true),
            browserFirstPartyOrigins.toSet(),
          );
          for (final environment in [staging, development]) {
            expect(browserFirstPartyHostsFor(environment), contains(host));
            expect(firstParty('https://$host/', environment), isTrue);
            expect(firstParty('https://$host:8443/', environment), isFalse);
            expect(firstParty('http://$host/', environment), isFalse);
            expect(firstParty('https://cdn.$host/', environment), isFalse);
          }
          expect(
            browserUiGrantScript(environment: production, dark: false),
            isNot(contains(host)),
          );
        }
      },
    );

    for (final environment in Environment.values) {
      test('every built-in host is first-party in ${environment.name} builds, '
          'on any path, on the default port only', () {
        for (final host in browserFirstPartyHosts) {
          expect(firstParty('https://$host', environment), isTrue);
          expect(
            firstParty('https://$host/artwork/1?x=2#y', environment),
            isTrue,
          );
          expect(firstParty('https://$host:443/', environment), isTrue);
          expect(
            firstParty('https://${host.toUpperCase()}/', environment),
            isTrue,
          );
          expect(firstParty('https://$host:8443/', environment), isFalse);
          expect(firstParty('http://$host/', environment), isFalse);
          expect(firstParty('https://user@$host/', environment), isFalse);
          expect(firstParty('https://user:pass@$host/', environment), isFalse);
          expect(firstParty('wss://$host/', environment), isFalse);
          expect(firstParty('https://cdn.$host/', environment), isFalse);
          expect(
            firstParty('https://$host.evil.example/', environment),
            isFalse,
          );
          expect(firstParty('https://evil$host/', environment), isFalse);
          expect(firstParty('https://$host./', environment), isFalse);
        }
      });
    }

    for (final url in [
      'https://gateway.mallow.art/ipfs/x',
      'https://docs.mallow.art/',
      'https://wallet.mallow.art/',
      'https://example.org/',
      'https://mallow.art.evil.example/',
      'about:blank',
    ]) {
      test('$url is third-party in every build', () {
        for (final environment in Environment.values) {
          expect(firstParty(url, environment), isFalse);
        }
      });
    }

    test('nothing at all is third-party', () {
      expect(isFirstPartyOrigin(null, development), isFalse);
    });

    // Local and private hosts: first-party in development builds only.
    for (final url in [
      'https://localhost/',
      'https://localhost:3000/',
      'https://LOCALHOST:8443/x',
      'https://app.localhost:5173/',
      'https://a.b.localhost/',
      'https://127.0.0.1/',
      'https://127.255.255.254:8443/',
      'https://10.0.0.1:5173/',
      'https://10.255.255.255/',
      'https://172.16.0.1/',
      'https://172.31.255.255:3000/',
      'https://192.168.1.20:5173/',
      'https://169.254.10.1/',
      'https://100.64.0.1/',
      'https://100.101.102.103:8443/',
      'https://100.127.255.255/',
      'https://[::1]/',
      'https://[::1]:5173/',
      'https://[0:0:0:0:0:0:0:1]/',
      'https://[fd7a:115c:a1e0::1]:8443/',
      'https://[fc00::1]/',
      'https://[fdff:ffff::1]/',
      'https://[fe80::1]/',
      'https://[febf:ffff::1]:3000/',
      'https://dev-box.tail1234.$magicDns/',
      'https://dev-box.tail1234.$magicDns:8443/',
      'https://macbook.local:5173/',
    ]) {
      test('$url is first-party in development builds only', () {
        expect(firstParty(url, development), isTrue);
        expect(firstParty(url, staging), isFalse);
        expect(firstParty(url, production), isFalse);
      });
    }

    for (final url in [
      // Next to a private range, but public.
      'https://100.63.255.255/',
      'https://100.128.0.1/',
      'https://172.15.255.255/',
      'https://172.32.0.1/',
      'https://11.0.0.1/',
      'https://9.255.255.255/',
      'https://192.169.0.1/',
      'https://169.253.0.1/',
      'https://128.0.0.1/',
      'https://8.8.8.8/',
      // Not an IPv4 address the way it reads.
      'https://010.0.0.1/',
      'https://127.1/',
      'https://0x7f.0.0.1/',
      'https://256.0.0.1/',
      'https://10.0.0.1.evil.example/',
      // Look-alike names.
      'https://localhost.evil.com/',
      'https://localhost.evil.com:3000/',
      'https://evillocalhost/',
      'https://ts.net.evil.com/',
      'https://evilts.net/',
      'https://ts.net/',
      'https://local/',
      'https://evil.localx/',
      'https://box.local.evil.com/',
      // Public, unspecified or mapped IPv6.
      'https://[2001:db8::1]/',
      'https://[::]/',
      'https://[::2]/',
      'https://[fec0::1]/',
      'https://[ff02::1]/',
      'https://[::ffff:127.0.0.1]/',
      'https://[::ffff:7f00:1]/',
      'https://[::ffff:192.168.1.1]/',
      // Right host, wrong scheme or credentials.
      'http://localhost:3000/',
      'http://192.168.1.20/',
      'http://[::1]/',
      'ws://localhost/',
      'https://user@localhost/',
      'https://user:pass@192.168.1.20/',
    ]) {
      test('$url is third-party even in development builds', () {
        expect(firstParty(url, development), isFalse);
      });
    }

    test('bracketed and bare IPv6 hosts read the same', () {
      expect(isLocalDevelopmentHost('[::1]'), isTrue);
      expect(isLocalDevelopmentHost('::1'), isTrue);
      expect(isLocalDevelopmentHost('[fe80::1]'), isTrue);
      expect(isLocalDevelopmentHost('fe80::1'), isTrue);
      expect(isLocalDevelopmentHost('[fe80::1%25en0]'), isFalse);
      expect(isLocalDevelopmentHost('[::1'), isFalse);
      expect(isLocalDevelopmentHost('[]'), isFalse);
      expect(isLocalDevelopmentHost(''), isFalse);
    });
  });

  group('ui envelope', () {
    final document = Uri.parse('$webApp/artwork/1');
    Map<String, dynamic> envelope({
      Object? namespace = 'ui',
      Object? method = 'setOverlay',
      Object? params = const {'active': true},
      Object? token = 'token',
    }) => {
      'id': '1',
      'namespace': namespace,
      'method': method,
      'params': params,
      'documentToken': token,
    };

    BrowserUiCommand? decode(
      Map<String, dynamic> message, {
      Uri? source,
      Uri? committed,
      String token = 'token',
      bool mainFrame = true,
      Environment environment = production,
    }) => browserUiCommand(
      message,
      source: source ?? Uri.parse(webApp),
      document: committed ?? document,
      documentToken: token,
      mainFrame: mainFrame,
      environment: environment,
    );

    test('accepts setOverlay from the committed first-party document', () {
      expect(decode(envelope()), const BrowserUiSetOverlay(active: true));
      expect(
        decode(envelope(params: const {'active': false})),
        const BrowserUiSetOverlay(active: false),
      );
    });

    test('drops a stale or missing document token', () {
      expect(decode(envelope(token: 'old')), isNull);
      expect(decode(envelope(token: null)), isNull);
      expect(decode(envelope(token: ''), token: ''), isNull);
    });

    test('drops a third-party document, whatever it sends', () {
      final third = Uri.parse('https://evil.example');
      expect(decode(envelope(), source: third, committed: third), isNull);
      expect(
        decode(
          envelope(),
          source: Uri.parse('https://gateway.mallow.art'),
          committed: Uri.parse('https://gateway.mallow.art/ipfs/x'),
        ),
        isNull,
      );
    });

    test('drops a sender that is not the committed document', () {
      expect(
        decode(envelope(), source: Uri.parse('https://evil.example')),
        isNull,
      );
      expect(
        decode(envelope(), committed: Uri.parse('https://evil.example/')),
        isNull,
      );
      expect(decode(envelope(), mainFrame: false), isNull);
    });

    test('accepts the other built-in host, but never across hosts', () {
      final www = Uri.parse('https://www.mallow.art');
      expect(
        decode(envelope(), source: www, committed: www.resolve('/x')),
        const BrowserUiSetOverlay(active: true),
      );
      expect(decode(envelope(), source: www), isNull);
    });

    test('a local host is first-party in development builds only, and '
        'only from the committed origin', () {
      final local = Uri.parse('https://192.168.1.20:5173');
      final committed = local.resolve('/artwork/1');
      for (final environment in [production, staging]) {
        expect(
          decode(
            envelope(),
            source: local,
            committed: committed,
            environment: environment,
          ),
          isNull,
        );
      }
      expect(
        decode(
          envelope(),
          source: local,
          committed: committed,
          environment: development,
        ),
        const BrowserUiSetOverlay(active: true),
      );
      expect(
        decode(
          envelope(),
          source: Uri.parse('https://192.168.1.20:5174'),
          committed: committed,
          environment: development,
        ),
        isNull,
      );
      expect(
        decode(
          envelope(),
          source: Uri.parse('https://localhost:5173'),
          committed: committed,
          environment: development,
        ),
        isNull,
      );
    });

    test('drops other namespaces, methods and malformed params', () {
      expect(decode(envelope(namespace: null)), isNull);
      expect(decode(envelope(namespace: 'eip155')), isNull);
      expect(decode(envelope(method: 'connect')), isNull);
      expect(decode(envelope(params: null)), isNull);
      expect(decode(envelope(params: const <String, Object?>{})), isNull);
      expect(decode(envelope(params: const {'active': 'true'})), isNull);
      expect(decode(envelope(params: const {'active': 1})), isNull);
    });
  });

  group('scripts', () {
    test('the grant asks the document check, with the exact origins, and '
        'names the theme', () {
      final source = browserUiGrantScript(environment: production, dark: false);
      expect(
        source,
        endsWith('(${jsonEncode(browserFirstPartyOrigins)}, false), "light");'),
      );
      expect(source, contains('firstParty !== true'));
      expect(source, contains('window.opener != null'));
      expect(source, contains('window !== window.top'));
      expect(source, contains("location.protocol !== 'https:'"));
      expect(source, contains('origins.includes(location.origin)'));
      expect(
        browserUiGrantScript(environment: staging, dark: true),
        endsWith(
          '(${jsonEncode(browserFirstPartyOriginsFor(staging))}, false), '
          '"dark");',
        ),
      );
      expect(
        browserUiGrantScript(environment: development, dark: true),
        endsWith(
          '(${jsonEncode(browserFirstPartyOriginsFor(development))}, true), '
          '"dark");',
        ),
      );
    });

    test('Android gates the grant natively outside development; development '
        'and iOS rely on the script and native checks', () {
      final exact = browserFirstPartyOrigins.toSet();
      expect(exact, containsAll([webApp, 'https://www.mallow.art']));
      expect(browserUiOriginRules(production, android: true), exact);
      expect(
        browserUiOriginRules(staging, android: true),
        browserFirstPartyOriginsFor(staging).toSet(),
      );
      expect(browserUiOriginRules(development, android: true), {'*'});
      for (final environment in Environment.values) {
        expect(browserUiOriginRules(environment, android: false), {'*'});
      }
    });

    test('the theme and scrim scripts call only the page hooks', () {
      expect(
        browserUiThemeScript(dark: true),
        'window.__mallowUiSetTheme && window.__mallowUiSetTheme("dark");',
      );
      expect(
        browserUiThemeScript(dark: false),
        'window.__mallowUiSetTheme && window.__mallowUiSetTheme("light");',
      );
      expect(
        browserUiScrimTapScript,
        "window.dispatchEvent(new CustomEvent('mallow:scrim-tap'));",
      );
    });
  });

  group('bridge routing', () {
    final document = Uri.parse('https://app.example/artwork/1');
    const token = 'token';
    Map<String, Object?> ui({bool active = false, String? documentToken}) => {
      'id': '1',
      'namespace': 'ui',
      'method': 'setOverlay',
      'params': {'active': active},
      'documentToken': documentToken ?? token,
    };
    final dapp = <String, Object?>{
      'id': '2',
      'method': 'connect',
      'params': <String, Object?>{},
      'documentToken': token,
    };
    BrowserBridgeRoute route(
      Object? raw, {
      Uri? origin,
      bool mainFrame = true,
      bool ready = true,
      Uri? committed,
      bool popupPending = false,
    }) => browserBridgeRoute(
      raw,
      origin: origin ?? Uri.parse(document.origin),
      mainFrame: mainFrame,
      ready: ready,
      document: committed ?? document,
      documentToken: token,
      popupPending: popupPending,
    );

    test('a release gets through while a popup decision is pending; a '
        'wallet request does not', () {
      expect(route(ui(), popupPending: true), BrowserBridgeRoute.ui);
      expect(
        route(ui(active: true), popupPending: true),
        BrowserBridgeRoute.ui,
      );
      expect(route(dapp, popupPending: true), BrowserBridgeRoute.rejected);
      expect(route(dapp), BrowserBridgeRoute.dapp);
    });

    test('the document checks still come first for ui messages', () {
      expect(
        route(ui(documentToken: 'stale'), popupPending: true),
        BrowserBridgeRoute.rejected,
      );
      expect(route(ui(), mainFrame: false), BrowserBridgeRoute.rejected);
      expect(route(ui(), ready: false), BrowserBridgeRoute.rejected);
      expect(
        route(ui(), origin: Uri.parse('https://example.org')),
        BrowserBridgeRoute.rejected,
      );
      expect(
        route(ui(), committed: Uri.parse('about:blank')),
        BrowserBridgeRoute.rejected,
      );
      expect(route('not a map'), BrowserBridgeRoute.rejected);
    });

    test('iOS: a ui message needs the committed origin, a wallet request the '
        'committed URL', () {
      // The page has changed its URL, and the change has not reached the
      // native host yet.
      final moved = Uri.parse('https://app.example/collection/2');
      expect(browserBridgeRequestUrlCurrent(ui(), moved, document), isTrue);
      expect(browserBridgeRequestUrlCurrent(dapp, moved, document), isFalse);
      expect(browserBridgeRequestUrlCurrent(dapp, document, document), isTrue);
      expect(
        browserBridgeRequestUrlCurrent(
          ui(),
          Uri.parse('https://example.org/'),
          document,
        ),
        isFalse,
      );
      expect(
        browserBridgeRequestUrlCurrent(
          ui(),
          Uri.parse('about:blank'),
          document,
        ),
        isFalse,
      );
      expect(browserBridgeRequestUrlCurrent(ui(), null, document), isFalse);
    });
  });

  test('the start theme script sets the theme through the page hook, for '
      'the web app only', () {
    final source = browserUiStartThemeScript(
      environment: production,
      dark: true,
    );
    expect(
      source,
      endsWith('(${jsonEncode(browserFirstPartyOrigins)}, false), "dark");'),
    );
    expect(source, contains('firstParty !== true'));
    expect(source, contains('origins.includes(location.origin)'));
    expect(source, contains('__mallowUiSetTheme'));
    expect(
      browserUiStartThemeScript(environment: development, dark: false),
      endsWith(
        '(${jsonEncode(browserFirstPartyOriginsFor(development))}, true), '
        '"light");',
      ),
    );
  });
}
