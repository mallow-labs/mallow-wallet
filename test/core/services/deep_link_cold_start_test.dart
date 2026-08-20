import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/services/deep_link_service.dart';
import 'package:mallow_wallet/core/services/twitter_connect_notifier.dart';

/// Serves a canned cold-start link, standing in for the platform channel.
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

GoRouter _buildRouter() => GoRouter(
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
  // A deep link that lands on a top-level route must leave `home` underneath it
  // so the in-page back button and the OS back/swipe have somewhere to go.
  // Without that, back is a dead tap and the user is stranded on the artwork.
  testWidgets('cold-start deep link stacks the destination on top of home', (
    tester,
  ) async {
    final router = _buildRouter();
    final service = DeepLinkService(
      router: router,
      twitterConnectNotifier: TwitterConnectNotifier(),
      appLinks: _FakeAppLinks(Uri.parse('https://mallow.art/artwork/Mint1')),
    );

    // Cold start: the link is captured before the Router widget mounts, so the
    // router delegate has no configuration to push onto yet.
    await service.start();
    // The app is still on its pre-router splash for a frame or two while
    // initialization finishes — the Router (and its delegate configuration)
    // does not exist yet.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('s'))));
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('artwork'), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.matches.length, 2);

    service.dispose();
  });

  testWidgets('warm-start deep link stacks the destination on top of home', (
    tester,
  ) async {
    final router = _buildRouter();
    final links = _FakeAppLinks(null);
    final service = DeepLinkService(
      router: router,
      twitterConnectNotifier: TwitterConnectNotifier(),
      appLinks: links,
    );

    unawaited(service.start());
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    links.emit(Uri.parse('https://mallow.art/artwork/Mint1'));
    await tester.pumpAndSettle();

    expect(find.text('artwork'), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.matches.length, 2);

    service.dispose();
  });
}
