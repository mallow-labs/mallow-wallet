import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/services/deep_link_handler_registry.dart';
import 'package:mallow_wallet/core/services/deep_link_service.dart';
import 'package:mallow_wallet/core/services/twitter_connect_notifier.dart';

class _FakeAppLinks extends Fake implements AppLinks {
  _FakeAppLinks(this.initial);

  final Uri? initial;
  final _controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialLink() async => initial;

  @override
  Stream<Uri> get uriLinkStream => _controller.stream;

  void emit(Uri uri) => _controller.add(uri);
}

GoRouter _router() => GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    GoRoute(
      path: AppRoutes.home,
      builder: (_, _) => const Scaffold(body: Text('home')),
    ),
    GoRoute(
      path: AppRoutes.artworkDetail,
      builder: (_, _) => const Scaffold(body: Text('artwork')),
    ),
  ],
);

void main() {
  group('DeepLinkHandlerRegistry', () {
    test('is inert with nothing registered', () {
      final registry = DeepLinkHandlerRegistry();
      expect(
        registry.handle(Uri.parse('https://mallow.art/x'), replay: false),
        isFalse,
      );
    });

    test(
      'asks handlers in registration order and stops at the first claim',
      () {
        final registry = DeepLinkHandlerRegistry();
        final asked = <String>[];
        registry
          ..register((uri, {required replay}) {
            asked.add('first');
            return false;
          })
          ..register((uri, {required replay}) {
            asked.add('second');
            return true;
          })
          ..register((uri, {required replay}) {
            asked.add('third');
            return true;
          });

        expect(
          registry.handle(Uri.parse('https://mallow.art/x'), replay: false),
          isTrue,
        );
        expect(asked, ['first', 'second']);
      },
    );

    test('passes the replay flag through', () {
      final registry = DeepLinkHandlerRegistry();
      bool? seen;
      registry.register((uri, {required replay}) {
        seen = replay;
        return true;
      });
      registry.handle(Uri.parse('https://mallow.art/x'), replay: true);
      expect(seen, isTrue);
    });
  });

  group('DeepLinkService with a registry', () {
    testWidgets('a claimed link is not routed', (tester) async {
      final router = _router();
      final registry = DeepLinkHandlerRegistry();
      final claimed = <Uri>[];
      registry.register((uri, {required replay}) {
        if (uri.path.startsWith('/artwork/')) {
          claimed.add(uri);
          return true;
        }
        return false;
      });
      final service = DeepLinkService(
        router: router,
        twitterConnectNotifier: TwitterConnectNotifier(),
        appLinks: _FakeAppLinks(Uri.parse('https://mallow.art/artwork/M1')),
        handlerRegistry: registry,
      );

      await service.start();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(claimed, hasLength(1));
      // Consumed: the route map never ran, so the artwork page was not pushed.
      expect(find.text('artwork'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      service.dispose();
    });

    testWidgets('an unclaimed link carries on to the route map', (
      tester,
    ) async {
      final router = _router();
      final service = DeepLinkService(
        router: router,
        twitterConnectNotifier: TwitterConnectNotifier(),
        appLinks: _FakeAppLinks(Uri.parse('https://mallow.art/artwork/M1')),
        handlerRegistry: DeepLinkHandlerRegistry(),
      );

      await service.start();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.text('artwork'), findsOneWidget);
      service.dispose();
    });

    testWidgets('a link from an untrusted origin never reaches a handler', (
      tester,
    ) async {
      final router = _router();
      final registry = DeepLinkHandlerRegistry();
      var asked = 0;
      registry.register((uri, {required replay}) {
        asked++;
        return true;
      });
      final links = _FakeAppLinks(null);
      final service = DeepLinkService(
        router: router,
        twitterConnectNotifier: TwitterConnectNotifier(),
        appLinks: links,
        handlerRegistry: registry,
      );
      await service.start();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      links.emit(Uri.parse('https://evil.example/zz/ONE/TWO'));
      await tester.pump();

      expect(asked, 0);
      service.dispose();
    });

    testWidgets('the auth redirect is dropped before any handler', (
      tester,
    ) async {
      final router = _router();
      final registry = DeepLinkHandlerRegistry();
      var asked = 0;
      registry.register((uri, {required replay}) {
        asked++;
        return true;
      });
      final links = _FakeAppLinks(null);
      final service = DeepLinkService(
        router: router,
        twitterConnectNotifier: TwitterConnectNotifier(),
        appLinks: links,
        handlerRegistry: registry,
      );
      await service.start();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      links.emit(Uri.parse('mallowwallet://auth?code=x'));
      await tester.pump();

      expect(asked, 0);
      service.dispose();
    });

    testWidgets(
      'the first stream event equal to the cold-start link is flagged as a replay',
      (tester) async {
        final router = _router();
        final registry = DeepLinkHandlerRegistry();
        final seen = <(Uri, bool)>[];
        registry.register((uri, {required replay}) {
          seen.add((uri, replay));
          return true;
        });
        final initial = Uri.parse('https://mallow.art/zz/ONE/TWO?x=1');
        final links = _FakeAppLinks(initial);
        final service = DeepLinkService(
          router: router,
          twitterConnectNotifier: TwitterConnectNotifier(),
          appLinks: links,
          handlerRegistry: registry,
        );
        await service.start();
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));

        // The cold-start delivery, then the stream's replay of it, then a second
        // scan of the same link: only the replay is flagged.
        links.emit(initial);
        await tester.pump();
        links.emit(initial);
        await tester.pump();

        expect(seen.map((e) => e.$2).toList(), [false, true, false]);
        service.dispose();
      },
    );
  });
}
