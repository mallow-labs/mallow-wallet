import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/widgets/artwork_model_viewer.dart';
import 'package:mallow_wallet/features/browser/services/browser_visibility.dart';

class _FakeApi implements MallowApiClient {
  _FakeApi(this._item);

  final NftDetail _item;

  @override
  Future<ApiResponse<ArtworkResult>> getArtworkByMint(
    String mintAccount,
  ) async => ApiResponse<ArtworkResult>(result: ArtworkResult(item: _item));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records what the viewer runs in the page and the handler it registers, so
/// a test can play the page's side of the conversation.
class _Controller extends Mock implements InAppWebViewController {
  final scripts = <String>[];
  Function? _handler;

  /// Calls the registered handler as the plugin would.
  void send(JavaScriptHandlerFunctionData data) =>
      Function.apply(_handler!, [data]);

  void post(Map<String, Object?> message) => send(_report([message]));

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) => _handler = callback;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    scripts.add(source);
    return null;
  }
}

class _WebViewPlatform extends InAppWebViewPlatform {
  final created = <PlatformInAppWebViewWidgetCreationParams>[];

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    created.add(params);
    return _WebView(params);
  }
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();
  @override
  void dispose() {}
}

/// A report from the viewer page, as the plugin delivers it.
JavaScriptHandlerFunctionData _report([List<dynamic> args = const []]) =>
    JavaScriptHandlerFunctionData(
      args: args,
      isMainFrame: true,
      origin: WebUri('about:blank'),
      requestUrl: WebUri('about:blank'),
    );

NavigationAction _navigation(String url, {bool mainFrame = true}) =>
    NavigationAction(
      request: URLRequest(url: WebUri(url)),
      isForMainFrame: mainFrame,
    );

void main() {
  const mint = '7y64aHkbVYfK6efj1LDhMZ2tAMAffe74aonV6s5nbx9P';
  const model =
      'https://arweave.net/aiNQGvOvk__Ldz34ATxN9xTYGTIILgx5PBo7LgLxC4g';

  // `/v1/artwork/byMint` ships `modelUrl` beside `htmlUrl`; the field was
  // missing from the model, so the parse dropped it and 3D artworks showed
  // only their poster.
  test('modelUrl survives the byMint parse into the detail model', () async {
    Future<String?> modelUrlFor(Map<String, dynamic> wire) async {
      final details = await ArtworkRepository(
        _FakeApi(
          NftDetail.fromJson({'mintAccount': mint, 'name': 'Artwork', ...wire}),
        ),
      ).getArtworkDetail(mint);
      return details.modelUrl;
    }

    expect(await modelUrlFor({'modelUrl': model}), model);
    expect(await modelUrlFor({}), isNull);
  });

  test('the vendored bundle can be inlined in a script element', () {
    // The page inlines the bundle. A `</script` in it would end the element
    // early, and a `<script` after a `<!--` would swallow the rest of the
    // page; a bundle upgrade that brings either must not go unnoticed.
    final bundle = File(
      'assets/model_viewer/model-viewer-umd.min.js',
    ).readAsStringSync();
    expect(bundle.toLowerCase(), isNot(contains('<script')));
    expect(bundle.toLowerCase(), isNot(contains('</script')));
    expect(bundle, isNot(contains('sourceMappingURL')));
    final page = artworkModelViewerPage(bundle);
    expect(page, contains(bundle));
    expect(page, contains('<model-viewer id="m"'));
  });

  group('artworkModelNavigationPolicy', () {
    test('only the page load itself goes ahead', () {
      expect(
        artworkModelNavigationPolicy(_navigation('about:blank')),
        NavigationActionPolicy.ALLOW,
      );
      for (final url in [
        'https://example.com/',
        'intent://scan#Intent;end',
        'data:text/html,<p>',
      ]) {
        expect(
          artworkModelNavigationPolicy(_navigation(url)),
          NavigationActionPolicy.CANCEL,
          reason: url,
        );
      }
      expect(
        artworkModelNavigationPolicy(
          _navigation('about:blank', mainFrame: false),
        ),
        NavigationActionPolicy.CANCEL,
      );
    });
  });

  group('the model viewer', () {
    late _WebViewPlatform platform;
    InAppWebViewPlatform? previous;

    setUp(() {
      previous = InAppWebViewPlatform.instance;
      platform = _WebViewPlatform();
      InAppWebViewPlatform.instance = platform;
      Config.debugOverrides['IMAGE_CDN_BASE_URL'] = 'https://images.example';
    });
    tearDown(() {
      if (previous != null) InAppWebViewPlatform.instance = previous;
      Config.debugOverrides.clear();
    });

    /// Mounts the viewer and brings its page up, returning the page's
    /// controller and the parameters the view was built with.
    Future<(_Controller, PlatformInAppWebViewWidgetCreationParams)> mount(
      WidgetTester tester, {
      ValueChanged<String>? onLoaded,
      VoidCallback? onFailed,
    }) async {
      await tester.runAsync(debugLoadArtworkModelViewerPage);
      await tester.pumpWidget(
        MaterialApp(
          home: ArtworkModelViewer(
            modelUrl: model,
            placeholder: const Text('poster'),
            onLoaded: onLoaded,
            onFailed: onFailed,
          ),
        ),
      );
      // The page future completed outside the fake-async zone, so its
      // callback is a real microtask: yield to it, then build the view.
      await tester.runAsync(() async {});
      await tester.pump();
      expect(platform.created, isNotEmpty);
      final params = platform.created.last;
      final controller = _Controller();
      params.onWebViewCreated!(controller);
      params.onLoadStop!(controller, WebUri('about:blank'));
      return (controller, params);
    }

    testWidgets('loads the model through the image service', (tester) async {
      final (controller, _) = await mount(tester);
      expect(controller.scripts, [
        'mallowConfigure(true);',
        'mallowLoad("https://images.example/original/'
            '${Uri.encodeComponent('ar://aiNQGvOvk__Ldz34ATxN9xTYGTIILgx5PBo7LgLxC4g')}");',
      ]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keeps the poster up until the model has loaded', (
      tester,
    ) async {
      String? loaded;
      final (controller, _) = await mount(tester, onLoaded: (s) => loaded = s);
      controller.post({'type': 'progress', 'value': 0.4});
      await tester.pump();
      expect(find.text('poster'), findsOneWidget);
      expect(loaded, isNull);

      controller.post({'type': 'load'});
      await tester.pump();
      expect(find.text('poster'), findsNothing);
      expect(loaded, startsWith('https://images.example/original/'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('ignores reports that are not its own shape', (tester) async {
      final (controller, _) = await mount(tester);
      controller.send(_report(['load']));
      controller.send(_report());
      controller.post({'type': 'progress', 'value': 'all of it'});
      await tester.pump();
      expect(find.text('poster'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with no image service there is nothing to fall back to', (
      tester,
    ) async {
      // The probe only ever retries a failed image-service load; a model
      // fetched straight from its gateway has failed for good.
      Config.debugOverrides['IMAGE_CDN_BASE_URL'] = '';
      var failed = false;
      final (controller, _) = await mount(
        tester,
        onFailed: () => failed = true,
      );
      expect(controller.scripts.last, 'mallowLoad("$model");');
      controller.post({'type': 'error'});
      await tester.pump();
      await tester.pump();
      expect(failed, isTrue);
      expect(find.text('poster'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a dead web content process falls back to the poster', (
      tester,
    ) async {
      var failed = false;
      final (controller, params) = await mount(
        tester,
        onFailed: () => failed = true,
      );
      params.onRenderProcessGone!(
        controller,
        RenderProcessGoneDetail(didCrash: true),
      );
      await tester.pump();
      expect(failed, isTrue);
      expect(find.text('poster'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the web view claims every touch that starts on it', (
      tester,
    ) async {
      // A drag-only claim let the enclosing scroll view win any drag that
      // set off in the direction the claim did not cover.
      final (_, params) = await mount(tester);
      expect(
        params.gestureRecognizers!.single.constructor(),
        isA<EagerGestureRecognizer>(),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a drag on the box never scrolls the page, even before the '
        'web view exists', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListView(
            controller: scroll,
            children: const [
              SizedBox(
                height: 300,
                child: ArtworkModelViewer(
                  modelUrl: model,
                  placeholder: ColoredBox(
                    color: Colors.grey,
                    child: Text('poster'),
                  ),
                ),
              ),
              SizedBox(height: 2000, child: Text('below')),
            ],
          ),
        ),
      );
      // No runAsync: the page has not reached this widget, so no view yet.
      expect(platform.created, isEmpty);

      for (final offset in const [Offset(0, -150), Offset(40, -150)]) {
        await tester.dragFrom(const Offset(200, 150), offset);
        await tester.pump();
        expect(scroll.offset, 0, reason: '$offset');
      }

      // Outside the box the page still scrolls.
      await tester.dragFrom(const Offset(200, 500), const Offset(0, -150));
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    });

    group('with a session', () {
      late List<InAppWebViewKeepAlive> disposed;
      late ArtworkModelSession session;
      final navigator = GlobalKey<NavigatorState>();

      setUp(() {
        disposed = [];
        session = ArtworkModelSession(
          disposeView: (view) async => disposed.add(view),
        );
      });

      Widget viewer() => ArtworkModelViewer(
        modelUrl: model,
        session: session,
        placeholder: const Text('poster'),
      );

      /// Mounts the inline viewer and loads its model, returning its view.
      Future<PlatformInAppWebViewWidgetCreationParams> mountLoaded(
        WidgetTester tester,
      ) async {
        await tester.runAsync(debugLoadArtworkModelViewerPage);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [browserPageRouteObserver],
            home: Scaffold(body: viewer()),
          ),
        );
        await tester.runAsync(() async {});
        await tester.pump();
        final params = platform.created.last;
        final controller = _Controller();
        params.onWebViewCreated!(controller);
        params.onLoadStop!(controller, WebUri('about:blank'));
        controller.post({'type': 'load'});
        await tester.pump();
        expect(params.keepAlive, isNotNull);
        return params;
      }

      Future<void> push(WidgetTester tester, Widget page) async {
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => Scaffold(body: page)),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('fullscreen takes the loaded model over and hands it back', (
        tester,
      ) async {
        final inline = await mountLoaded(tester);
        final view = inline.keepAlive;

        await push(tester, viewer());
        final fullscreen = platform.created.last;
        expect(fullscreen, isNot(same(inline)));
        expect(fullscreen.keepAlive, same(view));
        final controller = _Controller();
        fullscreen.onWebViewCreated!(controller);
        // Already up: no poster, and nothing to load.
        expect(find.text('poster'), findsNothing);
        expect(controller.scripts, ['mallowConfigure(true);']);

        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        final back = platform.created.last;
        expect(back, isNot(same(fullscreen)));
        expect(back.keepAlive, same(view));
        final inlineAgain = _Controller();
        back.onWebViewCreated!(inlineAgain);
        expect(inlineAgain.scripts, ['mallowConfigure(true);']);
        expect(find.text('poster'), findsNothing);
        expect(disposed, isEmpty);

        await tester.pumpWidget(const SizedBox());
        session.dispose();
        await tester.pump();
        expect(disposed, [same(view)]);
      });

      testWidgets('a route that does not show the model releases it', (
        tester,
      ) async {
        final inline = await mountLoaded(tester);
        await push(tester, const Text('elsewhere'));
        expect(disposed, [same(inline.keepAlive)]);

        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        final back = platform.created.last;
        expect(back.keepAlive, isNot(same(inline.keepAlive)));
        final controller = _Controller();
        back.onWebViewCreated!(controller);
        back.onLoadStop!(controller, WebUri('about:blank'));
        expect(controller.scripts.last, startsWith('mallowLoad('));
        expect(find.text('poster'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      });

      testWidgets('the background releases the model', (tester) async {
        final inline = await mountLoaded(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // No frames run in the background: the view goes, and is disposed,
        // on the first one back.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(disposed, [same(inline.keepAlive)]);
        final back = platform.created.last;
        expect(back.keepAlive, isNot(same(inline.keepAlive)));
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      });

      testWidgets('a model still loading is not shared', (tester) async {
        await tester.runAsync(debugLoadArtworkModelViewerPage);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [browserPageRouteObserver],
            home: Scaffold(body: viewer()),
          ),
        );
        await tester.runAsync(() async {});
        await tester.pump();
        final inline = platform.created.last;
        await push(tester, viewer());
        // This viewer loads the page itself.
        await tester.runAsync(() async {});
        await tester.pump();
        final fullscreen = platform.created.last;
        expect(fullscreen, isNot(same(inline)));
        expect(fullscreen.keepAlive, isNot(same(inline.keepAlive)));
        expect(disposed, [same(inline.keepAlive)]);
        expect(find.text('poster'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      });
    });

    test('the page hands every touch to the camera', () {
      final page = artworkModelViewerPage('');
      expect(page, contains('touch-action="none"'));
      expect(page, isNot(contains('pan-y')));
    });

    test('a held press selects nothing', () {
      final page = artworkModelViewerPage('');
      expect(page, contains('-webkit-user-select:none'));
      expect(page, contains('-webkit-touch-callout:none'));
    });
  });
}
