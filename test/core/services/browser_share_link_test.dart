import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/services/deep_link_service.dart';
import 'package:mallow_wallet/core/services/twitter_connect_notifier.dart';
import 'package:mallow_wallet/features/browser/models/browser_open_link.dart';

class _Links extends Fake implements AppLinks {
  _Links(this.initial);
  final Uri? initial;
  final events = StreamController<Uri>.broadcast();
  Future<void> close() => events.close();
  @override
  Future<Uri?> getInitialLink() async => initial;
  @override
  Stream<Uri> get uriLinkStream => events.stream;
}

Uri _handoff(String url, {String request = 'one'}) => Uri(
  scheme: 'mallowwallet',
  host: 'browser',
  path: '/open',
  queryParameters: {'url': url, 'request': request},
);

void main() {
  const website =
      'https://example.org/artwork/one?x=a%26b&token=a+b&next=%2F#edition';
  test(
    'preserves the website query and fragment without interpreting them',
    () {
      expect(browserOpenLinkUrl(_handoff(website)), Uri.parse(website));
    },
  );

  test(
    'decodes the native NSURLComponents handoff without changing plus signs',
    () {
      final nativeLink = Uri.parse(
        'mallowwallet://browser/open?url=https://example.org/?token%3Da%2Bb%26next%3D%252F%23art',
      );
      expect(
        browserOpenLinkUrl(nativeLink),
        Uri.parse('https://example.org/?token=a+b&next=%2F#art'),
      );
    },
  );

  for (final value in [
    '',
    'example.org',
    'http://example.org',
    'javascript:alert(1)',
    'data:text/html,hello',
    'file:///private/file',
    'mallowwallet://auth',
    'https://user:password@example.org',
    'https:///missing-host',
    'https://example.org/ with space',
  ]) {
    test('rejects unsafe or non-website input: $value', () {
      expect(browserOpenLinkUrl(_handoff(value)), isNull);
    });
  }

  for (final link in [
    'https://browser/open?url=https%3A%2F%2Fexample.org',
    'mallowwallet://browser/other?url=https%3A%2F%2Fexample.org',
    'mallowwallet://user@browser/open?url=https%3A%2F%2Fexample.org',
    'mallowwallet://browser:123/open?url=https%3A%2F%2Fexample.org',
    'mallowwallet://browser/open?url=https%3A%2F%2Fexample.org#extra',
    'mallowwallet://browser/open?url=https%3A%2F%2Fexample.org&url=https%3A%2F%2Fother.org',
    'mallowwallet://browser/open',
    'mallowwallet://browser/open?url=%FF',
  ]) {
    test('rejects a malformed handoff: $link', () {
      expect(browserOpenLinkUrl(Uri.parse(link)), isNull);
    });
  }

  for (final cold in [true, false]) {
    testWidgets(
      cold
          ? 'cold share opens the browser over the browser tab'
          : 'warm share opens the browser over the screen it came from',
      (tester) async {
        final received = <Uri>[];
        final link = _handoff(website);
        final links = _Links(cold ? link : null);
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (_, _) => const Text('home')),
            GoRoute(path: '/artwork', builder: (_, _) => const Text('artwork')),
            GoRoute(
              path: AppRoutes.browser,
              builder: (_, _) => const Text('browser start'),
              routes: [
                GoRoute(
                  path: 'open',
                  builder: (_, state) {
                    received.add((state.extra! as BrowserOpenRequest).url);
                    return const Text('website');
                  },
                ),
              ],
            ),
          ],
        );
        final service = DeepLinkService(
          router: router,
          twitterConnectNotifier: TwitterConnectNotifier(),
          appLinks: links,
        );
        addTearDown(() async {
          service.dispose();
          await links.close();
          router.dispose();
        });
        await service.start();
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        final base = cold ? 'browser start' : 'artwork';
        if (!cold) {
          unawaited(router.push('/artwork'));
          await tester.pumpAndSettle();
          links.events.add(link);
          await tester.pumpAndSettle();
        }
        expect(received.last, Uri.parse(website));
        expect(find.text('website'), findsOneWidget);
        expect(router.canPop(), isTrue);
        final before = received.length;
        if (cold) {
          links.events.add(link);
          await tester.pumpAndSettle();
          expect(
            received.length,
            before,
            reason: 'initial stream replay is ignored',
          );
        }
        links.events.add(_handoff(website, request: 'two'));
        await tester.pumpAndSettle();
        expect(
          received.length,
          greaterThan(before),
          reason: 'a new share of the same URL is handled',
        );
        // The second share went on top of the first: back leaves each in turn.
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('website'), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text(base), findsOneWidget);
        expect(find.text('website'), findsNothing);
        if (!cold) {
          router.pop();
          await tester.pumpAndSettle();
          expect(find.text('home'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('share still passes through the onboarding redirect', (
    tester,
  ) async {
    final links = _Links(_handoff(website));
    final router = GoRouter(
      initialLocation: '/',
      redirect: (_, state) =>
          state.uri.path.startsWith('/browser') ? '/welcome' : null,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        GoRoute(path: '/welcome', builder: (_, _) => const Text('welcome')),
        GoRoute(
          path: AppRoutes.browserOpen,
          builder: (_, _) => const Text('website'),
        ),
      ],
    );
    final service = DeepLinkService(
      router: router,
      twitterConnectNotifier: TwitterConnectNotifier(),
      appLinks: links,
    );
    addTearDown(() async {
      service.dispose();
      await links.close();
      router.dispose();
    });
    await service.start();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('welcome'), findsOneWidget);
    expect(find.text('website'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
