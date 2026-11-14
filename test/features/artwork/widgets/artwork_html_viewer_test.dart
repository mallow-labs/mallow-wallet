import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/widgets/artwork_html_viewer.dart';

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

class _Controller extends Mock implements InAppWebViewController {}

/// Stands in for the platform view and keeps the parameters the viewer built
/// it with, so a test can call the callbacks the native side would.
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

NavigationAction _navigation(String url, {bool mainFrame = true}) =>
    NavigationAction(
      request: URLRequest(url: WebUri(url)),
      isForMainFrame: mainFrame,
    );

void main() {
  const solanaMint = '7y64aHkbVYfK6efj1LDhMZ2tAMAffe74aonV6s5nbx9P';
  const page =
      'https://arweave.net/S6t8kqB2pcF3_ExUYNVFNtIPVcaHpaAqnPqtBjEeIZ8';

  group('artworkHtmlSourceCandidates', () {
    test('a Solana artwork gets its mint as mintKey on every candidate', () {
      final sources = artworkHtmlSourceCandidates(
        '$page?ext=html',
        mintAccount: solanaMint,
        chain: 'solana',
      );
      expect(sources, isNotEmpty);
      expect(sources.first, '$page?ext=html&mintKey=$solanaMint');
      for (final source in sources) {
        expect(source, endsWith('mintKey=$solanaMint'));
      }
    });

    test('mintKey goes ahead of a fragment, as the query it belongs to', () {
      final sources = artworkHtmlSourceCandidates(
        '$page#seed=1',
        mintAccount: solanaMint,
      );
      expect(sources.first, '$page?mintKey=$solanaMint#seed=1');
    });

    test('a non-Solana token id is not passed as mintKey', () {
      // The webapp appends it only for a Solana public key; an EVM or Tezos
      // contract-and-token id means nothing to the page.
      final sources = artworkHtmlSourceCandidates(
        'https://ipfs.io/ipfs/QmbcKdVAWdPGXLPpG3vokehsvY8BRpLKqu7bGkqZmP9hWe',
        mintAccount: 'KT1D23q4L43kXSQ7N6vmsZntejU5JWfQaqtC-9',
        chain: 'tezos',
      );
      expect(sources, isNotEmpty);
      expect(sources.any((s) => s.contains('mintKey')), isFalse);
    });

    test('ipfs:// resolves onto a gateway', () {
      final sources = artworkHtmlSourceCandidates(
        'ipfs://QmbcKdVAWdPGXLPpG3vokehsvY8BRpLKqu7bGkqZmP9hWe',
        mintAccount: solanaMint,
      );
      expect(sources, isNotEmpty);
      expect(sources.every((s) => s.startsWith('https://')), isTrue);
    });

    test('only https sources survive', () {
      // A plain-http page is mixed content the web view refuses, and a data:
      // or javascript: page has no gateway behind it.
      for (final url in [
        'http://example.com/art.html',
        'data:text/html,<p>hi</p>',
        'javascript:alert(1)',
        '',
      ]) {
        expect(
          artworkHtmlSourceCandidates(url, mintAccount: solanaMint),
          isEmpty,
          reason: url,
        );
      }
    });
  });

  // `/v1/artwork/byMint` already ships `htmlUrl` (the webapp reads it from the
  // same payload); the field was missing from the model, so the parse dropped
  // it. Built from raw JSON for that reason.
  test('htmlUrl survives the byMint parse into the detail model', () async {
    Future<String?> htmlUrlFor(Map<String, dynamic> wire) async {
      final details = await ArtworkRepository(
        _FakeApi(
          NftDetail.fromJson({
            'mintAccount': solanaMint,
            'name': 'Artwork',
            ...wire,
          }),
        ),
      ).getArtworkDetail(solanaMint);
      return details.htmlUrl;
    }

    expect(await htmlUrlFor({'htmlUrl': page}), page);
    expect(await htmlUrlFor({}), isNull);
  });

  group('artworkNavigationPolicy', () {
    const allow = NavigationActionPolicy.ALLOW;
    const cancel = NavigationActionPolicy.CANCEL;

    test('before a page commits, any https main-frame load goes ahead', () {
      // A path gateway's redirect to its subdomain form lands here.
      expect(
        artworkNavigationPolicy(_navigation('https://cid.ipfs.example/')),
        allow,
      );
      expect(
        artworkNavigationPolicy(_navigation('http://example.com/')),
        cancel,
      );
    });

    test('once a page commits, the main frame stays on its origin', () {
      const origin = 'https://gateway.example';
      expect(
        artworkNavigationPolicy(
          _navigation('$origin/ipfs/cid/page2.html'),
          committedOrigin: origin,
        ),
        allow,
      );
      for (final url in [
        'https://bank.example/transfer?to=attacker',
        'https://gateway.example:8443/',
        'https://sub.gateway.example/',
        'intent://scan#Intent;end',
        'about:blank',
      ]) {
        expect(
          artworkNavigationPolicy(_navigation(url), committedOrigin: origin),
          cancel,
          reason: url,
        );
      }
    });

    test('subframes keep their document-local schemes and any https', () {
      for (final url in [
        'https://other.example/frame',
        'about:blank',
        'data:text/html,<p>',
        'blob:https://gateway.example/1',
      ]) {
        expect(
          artworkNavigationPolicy(
            _navigation(url, mainFrame: false),
            committedOrigin: 'https://gateway.example',
          ),
          allow,
          reason: url,
        );
      }
      expect(
        artworkNavigationPolicy(
          _navigation('mailto:a@example.com', mainFrame: false),
        ),
        cancel,
      );
    });
  });

  group('the artwork web view', () {
    late _WebViewPlatform platform;
    InAppWebViewPlatform? previous;

    setUp(() {
      previous = InAppWebViewPlatform.instance;
      platform = _WebViewPlatform();
      InAppWebViewPlatform.instance = platform;
    });
    tearDown(() {
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });

    Future<PlatformInAppWebViewWidgetCreationParams> mount(
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ArtworkHtmlViewer(
            sources: ['https://gateway.example/ipfs/cid/'],
            placeholder: SizedBox(),
          ),
        ),
      );
      expect(platform.created, isNotEmpty);
      return platform.created.last;
    }

    testWidgets('answers every page dialog itself, so none is shown', (
      tester,
    ) async {
      final params = await mount(tester);
      final controller = _Controller();

      // A handler that returns null, or is missing, makes the platform build
      // its own untitled dialog. prompt() would then hand typed text back to
      // the page.
      final prompt = await params.onJsPrompt!(
        controller,
        JsPromptRequest(message: 'Enter your recovery phrase'),
      );
      expect(prompt!.handledByClient, isTrue);
      expect(prompt.action, JsPromptResponseAction.CANCEL);
      expect(prompt.value, isNull);

      final confirm = await params.onJsConfirm!(
        controller,
        JsConfirmRequest(message: 'Continue?'),
      );
      expect(confirm!.handledByClient, isTrue);
      expect(confirm.action, JsConfirmResponseAction.CANCEL);

      final alert = await params.onJsAlert!(
        controller,
        JsAlertRequest(message: 'hi'),
      );
      expect(alert!.handledByClient, isTrue);

      final unload = await params.onJsBeforeUnload!(
        controller,
        JsBeforeUnloadRequest(message: 'Stay?'),
      );
      expect(unload!.handledByClient, isTrue);
      expect(unload.action, JsBeforeUnloadResponseAction.CONFIRM);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the web view claims every touch that starts on it', (
      tester,
    ) async {
      // Without the claim the enclosing scroll view won every vertical swipe,
      // so an artwork could never receive one.
      final params = await mount(tester);
      expect(
        params.gestureRecognizers!.single.constructor(),
        isA<EagerGestureRecognizer>(),
      );
      expect(params.initialSettings!.disallowOverScroll, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'the poster leaves drags to the page until the artwork paints',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: ListView(
              controller: scroll,
              children: const [
                SizedBox(
                  height: 300,
                  child: ArtworkHtmlViewer(
                    sources: ['https://gateway.example/ipfs/cid/'],
                    placeholder: ColoredBox(color: Colors.grey),
                  ),
                ),
                SizedBox(height: 2000),
              ],
            ),
          ),
        );

        await tester.dragFrom(const Offset(200, 150), const Offset(0, -100));
        await tester.pump();
        expect(scroll.offset, greaterThan(0));

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('locks the main frame to the first committed origin', (
      tester,
    ) async {
      final params = await mount(tester);
      final controller = _Controller();
      Future<NavigationActionPolicy?> navigate(String url) async =>
          params.shouldOverrideUrlLoading!(controller, _navigation(url));

      // The gateway redirects before the first commit.
      expect(
        await navigate('https://cid.ipfs.gateway.example/'),
        NavigationActionPolicy.ALLOW,
      );
      params.onPageCommitVisible!(
        controller,
        WebUri('https://cid.ipfs.gateway.example/'),
      );
      expect(
        await navigate('https://cid.ipfs.gateway.example/next.html'),
        NavigationActionPolicy.ALLOW,
      );
      expect(
        await navigate('https://bank.example/transfer'),
        NavigationActionPolicy.CANCEL,
      );

      await tester.pumpWidget(const SizedBox());
    });
  });
}
