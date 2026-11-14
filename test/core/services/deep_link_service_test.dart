import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/services/deep_link_handler_registry.dart';
import 'package:mallow_wallet/core/services/deep_link_service.dart';
import 'package:mallow_wallet/core/services/twitter_connect_notifier.dart';
import 'package:mallow_wallet/core/social_vault/apple_web_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Feeds warm-start links, standing in for the platform channel.
class _FakeAppLinks extends Fake implements AppLinks {
  final _controller = StreamController<Uri>.broadcast();

  /// The link that launched the app, for a cold start.
  Uri? initial;

  @override
  Future<Uri?> getInitialLink() async => initial;

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

  // The return of Sign in with Apple's web flow is the one link here that
  // carries an ID token. It must reach the sign-in that is waiting for it and
  // nothing else: not the debug log line, not the origin check's fallthrough,
  // not a feature's handler, not the X connect callback, not the router.
  group('DeepLinkService and the Sign in with Apple return', () {
    late GoRouter router;
    late _FakeAppLinks links;
    late TwitterConnectNotifier twitterNotifier;
    late List<String> twitterTokens;
    late DeepLinkHandlerRegistry registry;
    late List<Uri> offeredToHandlers;
    late AppleWebSignIn appleSignIn;
    late List<Uri> launched;
    late List<String?> printed;
    late DeepLinkService service;

    String jwt(Map<String, Object?> claims) {
      String part(Object? value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      return '${part({'alg': 'RS256'})}.${part(claims)}.c2ln';
    }

    /// The site's return page with [fields] in its fragment — and, to prove
    /// the generic steps never see it, a query the X connect step would act
    /// on.
    Uri returnLink(Map<String, String> fields) => Uri(
      scheme: 'https',
      host: 'mallow.art',
      path: '/auth/apple',
      queryParameters: const {'twitter': 'confirm', 'token': 'not-for-x'},
      fragment: Uri(queryParameters: fields).query,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Config.debugOverrides['APPLE_SERVICES_ID'] = 'services.example';
      Config.debugOverrides['API_V2_BASE_URL'] = 'https://backend.example/v2';
      router = GoRouter(
        initialLocation: AppRoutes.home,
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
        ],
      );
      links = _FakeAppLinks();
      twitterTokens = [];
      twitterNotifier = TwitterConnectNotifier.withCompleter(
        (token) async => twitterTokens.add(token),
      );
      // A connect in progress, so a `twitter=confirm` link that got through
      // WOULD be acted on.
      await twitterNotifier.markConnectStarted();
      offeredToHandlers = [];
      registry = DeepLinkHandlerRegistry()
        ..register((uri, {required replay}) {
          offeredToHandlers.add(uri);
          return false;
        });
      launched = [];
      appleSignIn = AppleWebSignIn(
        launch: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      printed = [];
      final original = debugPrint;
      // Reading the build config says so in a debug build (starting a
      // sign-in does); every other line would be about a link.
      debugPrint = (String? message, {int? wrapWidth}) {
        if (!(message ?? '').startsWith('[Config] ')) printed.add(message);
      };
      addTearDown(() => debugPrint = original);
      service = DeepLinkService(
        router: router,
        twitterConnectNotifier: twitterNotifier,
        appLinks: links,
        handlerRegistry: registry,
        appleWebSignIn: appleSignIn,
      );
    });

    tearDown(() {
      service.dispose();
      router.dispose();
      Config.debugOverrides.clear();
    });

    void expectUntouched(Object? configurationBefore) {
      expect(printed, isEmpty, reason: 'the link must never be logged');
      expect(offeredToHandlers, isEmpty);
      expect(twitterTokens, isEmpty);
      expect(
        router.routerDelegate.currentConfiguration,
        same(configurationBefore),
      );
    }

    test('only the site’s exact https page is the return link', () {
      bool isReturn(String uri) =>
          DeepLinkService.isAppleReturnLink(Uri.parse(uri));

      expect(isReturn('https://mallow.art/auth/apple#id_token=x'), isTrue);
      expect(isReturn('https://MALLOW.ART/auth/apple'), isTrue);
      // Any app can send the custom scheme: it is not a form of this link.
      expect(isReturn('mallowwallet://auth/apple#id_token=x'), isFalse);
      expect(isReturn('mallowwallet://mallow.art/auth/apple'), isFalse);
      expect(isReturn('http://mallow.art/auth/apple'), isFalse);
      expect(isReturn('https://app.mallow.art/auth/apple'), isFalse);
      expect(isReturn('https://mallow.art.evil.example/auth/apple'), isFalse);
      expect(isReturn('https://mallow.art/auth/apple/more'), isFalse);
      expect(isReturn('https://mallow.art/auth/callback'), isFalse);
    });

    test('the answer goes to the waiting sign-in, before every other '
        'step', () async {
      await service.start();
      final before = router.routerDelegate.currentConfiguration;
      final result = appleSignIn.signIn();
      await pumpEventQueue();
      final query = launched.single.queryParameters;
      final token = jwt({'nonce': query['nonce']});

      links.emit(returnLink({'id_token': token, 'state': query['state']!}));

      expect((await result)!.idToken, token);
      expectUntouched(before);
    });

    test('with another state it is dropped, silently, and the sign-in keeps '
        'waiting', () async {
      await service.start();
      final before = router.routerDelegate.currentConfiguration;
      unawaited(appleSignIn.signIn());
      await pumpEventQueue();

      links.emit(
        returnLink({
          'id_token': jwt({'nonce': 'x'}),
          'state': 'forged',
        }),
      );
      await pumpEventQueue();

      expect(appleSignIn.isPending, isTrue);
      expectUntouched(before);
    });

    test('a cold start on the link, with no sign-in waiting, does '
        'nothing', () async {
      links.initial = returnLink({
        'id_token': jwt({'nonce': 'x'}),
        'state': 'from-a-previous-process',
      });
      await service.start();
      // app_links replays the cold-start link on its stream.
      links.emit(links.initial!);
      await pumpEventQueue();

      expect(appleSignIn.isPending, isFalse);
      expect(printed, isEmpty);
      expect(offeredToHandlers, isEmpty);
      expect(twitterTokens, isEmpty);
    });

    test('the custom scheme is no way into the sign-in', () async {
      await service.start();
      unawaited(appleSignIn.signIn());
      await pumpEventQueue();
      final query = launched.single.queryParameters;

      links.emit(
        Uri.parse(
          'mallowwallet://auth/apple#id_token=x&state=${query['state']}',
        ),
      );
      await pumpEventQueue();

      // Not consumed by the sign-in, even with the right state.
      expect(appleSignIn.isPending, isTrue);
    });

    test('without a sign-in service the link is still consumed', () async {
      service.dispose();
      service = DeepLinkService(
        router: router,
        twitterConnectNotifier: twitterNotifier,
        appLinks: links,
        handlerRegistry: registry,
      );
      await service.start();
      final before = router.routerDelegate.currentConfiguration;

      links.emit(returnLink({'id_token': 'x', 'state': 'y'}));
      await pumpEventQueue();

      expectUntouched(before);
    });
  });

  // `mallowwallet://auth` was once the redirect of a sign-in SDK, dropped on
  // sight. The SDK is gone and so is that branch: the `auth` host has no
  // handling of its own, so a link shaped like the old redirect falls through
  // every step and does nothing.
  group('DeepLinkService and the mallowwallet://auth host', () {
    test('a link shaped like the old sign-in redirect does nothing', () async {
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

      final before = router.routerDelegate.currentConfiguration;
      links.emit(Uri.parse('mallowwallet://auth?b64Params=abc'));
      links.emit(Uri.parse('mallowwallet://auth#b64Params=abc'));
      await pumpEventQueue();

      // No X callback, and no route.
      expect(emitted, isEmpty);
      expect(
        DeepLinkService.mapToLocation(Uri.parse('mallowwallet://auth')),
        isNull,
      );
      expect(router.routerDelegate.currentConfiguration, same(before));

      await sub.cancel();
      service.dispose();
      router.dispose();
    });
  });

  // The backend callback redirects with `twitter=confirm&token=…`; the token is
  // what the signed complete call spends, so it has to reach the notifier.
  group('DeepLinkService and the X connect callback', () {
    // A confirm link is acted on only for a connect started on this install.
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await TwitterConnectNotifier.withCompleter(
        (_) async {},
      ).markConnectStarted();
    });

    test('confirm hands the completion token to the notifier', () async {
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
      final sent = <String>[];
      final twitterNotifier = TwitterConnectNotifier.withCompleter(
        (token) async => sent.add(token),
      );
      final emitted = <TwitterConnectStatus>[];
      final sub = twitterNotifier.results.listen(emitted.add);
      final service = DeepLinkService(
        router: router,
        twitterConnectNotifier: twitterNotifier,
        appLinks: links,
      );

      await service.start();
      links.emit(
        Uri.parse(
          'https://mallow.art/auth/callback?twitter=confirm'
          '&token=feedfacefeedfacefeedfacefeedface',
        ),
      );
      await pumpEventQueue();

      expect(sent, ['feedfacefeedfacefeedfacefeedface']);
      expect(emitted, [TwitterConnectStatus.success]);

      await sub.cancel();
      service.dispose();
      router.dispose();
    });

    // The website's /auth/callback page links here when the app link opened in
    // the browser instead of the app. Same handler, same token.
    test('mallowwallet://auth/callback reaches the same handler', () async {
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
      final sent = <String>[];
      final twitterNotifier = TwitterConnectNotifier.withCompleter(
        (token) async => sent.add(token),
      );
      final emitted = <TwitterConnectStatus>[];
      final sub = twitterNotifier.results.listen(emitted.add);
      final service = DeepLinkService(
        router: router,
        twitterConnectNotifier: twitterNotifier,
        appLinks: links,
      );

      await service.start();
      links.emit(
        Uri.parse(
          'mallowwallet://auth/callback?twitter=confirm'
          '&token=feedfacefeedfacefeedfacefeedface',
        ),
      );
      await pumpEventQueue();
      links.emit(
        Uri.parse('mallowwallet://auth/callback?twitter=error_user_exists'),
      );
      await pumpEventQueue();

      expect(sent, ['feedfacefeedfacefeedfacefeedface']);
      expect(emitted, [
        TwitterConnectStatus.success,
        TwitterConnectStatus.userExists,
      ]);

      await sub.cancel();
      service.dispose();
      router.dispose();
    });
  });
}
