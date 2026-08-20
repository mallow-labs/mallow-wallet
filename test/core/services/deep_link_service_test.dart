import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/services/deep_link_service.dart';
import 'package:mallow_wallet/core/services/twitter_connect_notifier.dart';

/// Feeds warm-start links, standing in for the platform channel.
class _FakeAppLinks extends Fake implements AppLinks {
  final _controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get uriLinkStream => _controller.stream;

  void emit(Uri uri) => _controller.add(uri);
}

void main() {
  // These assertions pin the contract between mallow.art's canonical web URLs
  // and the in-app go_router locations. If the web path scheme changes, a
  // tapped universal/app link would silently land on the wrong screen (or the
  // error screen) — these tests catch that before a device ever sees it.
  group('DeepLinkService.mapToLocation', () {
    test('artwork link → /artwork/:mint', () {
      expect(
        DeepLinkService.mapToLocation(
          Uri.parse('https://mallow.art/artwork/MintAbc'),
        ),
        '/artwork/MintAbc',
      );
    });

    test('collection link → /collection/:id', () {
      expect(
        DeepLinkService.mapToLocation(
          Uri.parse('https://mallow.art/collection/Col123'),
        ),
        '/collection/Col123',
      );
    });

    test('username link → /u/:username', () {
      expect(
        DeepLinkService.mapToLocation(
          Uri.parse('https://mallow.art/u/satoshi'),
        ),
        '/u/satoshi',
      );
    });

    test('address link → /a/:address', () {
      expect(
        DeepLinkService.mapToLocation(
          Uri.parse('https://mallow.art/a/SoLAddr'),
        ),
        '/a/SoLAddr',
      );
    });

    test('unknown path is ignored (null) so go_router never sees it', () {
      expect(
        DeepLinkService.mapToLocation(Uri.parse('https://mallow.art/about')),
        isNull,
      );
      expect(
        DeepLinkService.mapToLocation(Uri.parse('https://mallow.art/')),
        isNull,
      );
    });

    test('known prefix without an id is ignored', () {
      expect(
        DeepLinkService.mapToLocation(Uri.parse('https://mallow.art/artwork')),
        isNull,
      );
      expect(
        DeepLinkService.mapToLocation(Uri.parse('https://mallow.art/artwork/')),
        isNull,
      );
    });
  });

  // The origin gate is the defense-in-depth that stops an attacker-crafted link
  // (e.g. a spoofed connect callback hosted on evil.com) from being acted on.
  // If this check ever loosens to accept foreign hosts, a malicious link could
  // drive in-app state — so these assertions pin which origins the app acts on.
  group('DeepLinkService.isTrustedOrigin', () {
    test('verified mallow.art over HTTPS is trusted', () {
      expect(
        DeepLinkService.isTrustedOrigin(
          Uri.parse('https://mallow.art/auth/callback?twitter=success'),
        ),
        isTrue,
      );
    });

    test('mallow.art subdomains over HTTPS are trusted', () {
      expect(
        DeepLinkService.isTrustedOrigin(
          Uri.parse('https://app.mallow.art/u/satoshi'),
        ),
        isTrue,
      );
    });

    test('mallowwallet:// custom scheme is trusted', () {
      expect(
        DeepLinkService.isTrustedOrigin(
          Uri.parse('mallowwallet://artwork/MintAbc'),
        ),
        isTrue,
      );
    });

    test('a foreign host is not trusted', () {
      expect(
        DeepLinkService.isTrustedOrigin(
          Uri.parse('https://evil.com/auth/callback?twitter=success'),
        ),
        isFalse,
      );
    });

    test('a look-alike suffix host is not trusted', () {
      expect(
        DeepLinkService.isTrustedOrigin(
          Uri.parse('https://mallow.art.evil.com/u/satoshi'),
        ),
        isFalse,
      );
      expect(
        DeepLinkService.isTrustedOrigin(
          Uri.parse('https://notmallow.art/u/satoshi'),
        ),
        isFalse,
      );
    });

    test('plain HTTP to mallow.art is not trusted', () {
      expect(
        DeepLinkService.isTrustedOrigin(Uri.parse('http://mallow.art/u/sat')),
        isFalse,
      );
    });
  });

  // The Web3Auth login redirect (`mallowwallet://auth`) is consumed natively by
  // the SDK, but app_links still delivers it to this listener. It carries
  // whatever parameters the SDK put on it, so the handler must drop it whole:
  // acting on a query parameter that happens to collide with one of ours — or
  // routing on it — would let a login round-trip drive unrelated app state.
  group('DeepLinkService and the Web3Auth redirect', () {
    test('mallowwallet://auth is ignored, whatever it carries', () async {
      final router = GoRouter(
        initialLocation: AppRoutes.home,
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
        ],
      );
      final links = _FakeAppLinks();
      final twitterNotifier = TwitterConnectNotifier();
      final emitted = <TwitterConnectStatus>[];
      final sub = twitterNotifier.results.listen(emitted.add);
      final service = DeepLinkService(
        router: router,
        twitterConnectNotifier: twitterNotifier,
        appLinks: links,
      );

      await service.start();

      // `twitter` stands in for any parameter the handler would otherwise act
      // on — the redirect must be dropped before that branch is reached. The
      // routing branch is covered by mapToLocation's own tests (this URI maps
      // to null), so the emission is the one observable side effect left.
      links.emit(
        Uri.parse('mallowwallet://auth?b64Params=abc&twitter=success'),
      );
      await pumpEventQueue();

      expect(emitted, isEmpty);

      await sub.cancel();
      service.dispose();
      router.dispose();
    });
  });
}
