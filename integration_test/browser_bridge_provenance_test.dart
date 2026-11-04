import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';

/// Exercises the platform transport itself, without credentials or RPC calls.
const _useAndroidNativePopupInput = bool.fromEnvironment(
  'BROWSER_NATIVE_POPUP_INPUT',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Configure native input before each test's binding-state snapshot is taken.
  binding.shouldPropagateDevicePointerEvents =
      Platform.isAndroid &&
      const bool.fromEnvironment('BROWSER_NATIVE_POPUP_INPUT');

  testWidgets('native wallet bridge distinguishes main frames from subframes', (
    tester,
  ) async {
    final loaded = Completer<void>();
    final mainFrame = Completer<(String, bool)>();
    final childFrame = Completer<(String, bool)>();
    late InAppWebViewController controller;
    void record(String payload, String origin, bool isMainFrame) {
      // A forged origin in the payload must have no effect on native metadata.
      final target = payload.startsWith('main:') ? mainFrame : childFrame;
      if (!target.isCompleted) target.complete((origin, isMainFrame));
    }

    if (Platform.isAndroid) {
      expect(
        await WebViewFeature.isFeatureSupported(
          WebViewFeature.WEB_MESSAGE_LISTENER,
        ),
        isTrue,
        reason: 'The wallet transport requires native frame attribution.',
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InAppWebView(
            initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
            onWebViewCreated: (view) async {
              controller = view;
              if (Platform.isAndroid) {
                await view.addWebMessageListener(
                  WebMessageListener(
                    jsObjectName: 'provenanceFixture',
                    allowedOriginRules: browserWalletOriginRules,
                    onPostMessage: (message, origin, isMainFrame, reply) {
                      record(
                        message?.data as String,
                        origin.toString(),
                        isMainFrame,
                      );
                    },
                  ),
                );
              } else {
                view.addJavaScriptHandler(
                  handlerName: 'provenanceFixture',
                  callback: (JavaScriptHandlerFunctionData data) {
                    record(
                      data.args.single as String,
                      data.origin.toString(),
                      data.isMainFrame,
                    );
                    return null;
                  },
                );
              }
              await view.loadData(
                data:
                    '<!doctype html><html><body>Owned bridge fixture</body></html>',
                baseUrl: WebUri('https://browser-fixture.invalid/'),
                historyUrl: WebUri('https://browser-fixture.invalid/'),
              );
            },
            onLoadStop: (_, url) {
              if (url?.host == 'browser-fixture.invalid' &&
                  !loaded.isCompleted) {
                loaded.complete();
              }
            },
          ),
        ),
      ),
    );
    await loaded.future.timeout(const Duration(seconds: 30));
    final send = Platform.isAndroid
        ? 'provenanceFixture.postMessage'
        : "(v) => window.flutter_inappwebview.callHandler('provenanceFixture', v)";
    await controller.evaluateJavascript(
      source:
          '''
      ($send)('main:https://forged.invalid');
      const child = document.createElement('iframe');
      child.srcdoc = '<script>($send)("child:https://forged.invalid")<\/script>';
      document.body.appendChild(child);
    ''',
    );
    final main = await mainFrame.future.timeout(const Duration(seconds: 15));
    final child = await childFrame.future.timeout(const Duration(seconds: 15));
    expect(Uri.parse(main.$1).host, 'browser-fixture.invalid');
    expect(main.$2, isTrue);
    expect(Uri.parse(child.$1).host, 'browser-fixture.invalid');
    expect(child.$2, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('browser host injects mallow and routes a main-frame connect', (
    tester,
  ) async {
    final created = Completer<InAppWebViewController>();
    final navigation = Completer<void>();
    final connected = Completer<void>();
    final requests = <String>[];
    final navigations = <String>[];
    final errors = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserWebViewHost(
            tabId: 'owned-fixture',
            url: Uri.parse('https://browser-fixture.invalid/'),
            onController: created.complete,
            onNavigationStarted: (_) {},
            onNavigation: (_, url) {
              navigations.add(url.toString());
              if (!navigation.isCompleted) navigation.complete();
            },
            onRequest: (message, frame) async {
              expect(frame.origin.host, 'browser-fixture.invalid');
              expect(frame.isMainFrame, isTrue);
              requests.add(message['method'] as String);
              if (message['method'] == 'connect' && !connected.isCompleted)
                connected.complete();
              return {
                'result': {
                  'publicKey': '11111111111111111111111111111111',
                  'chains': ['solana:mainnet'],
                  'canSign': false,
                },
              };
            },
            onProgress: (_) {},
            onTitle: (_) {},
            onPopup: (_) {},
            onError: errors.add,
          ),
        ),
      ),
    );
    final controller = await created.future.timeout(
      const Duration(seconds: 30),
    );
    await controller.stopLoading();
    await controller.loadData(
      data:
          '<!doctype html><html><body>Owned provider fixture<script>window.addEventListener("mallow:document-ready",()=>window.solana.connect().catch(()=>{}));</script></body></html>',
      baseUrl: WebUri('https://browser-fixture.invalid/'),
      historyUrl: WebUri('https://browser-fixture.invalid/'),
    );
    await navigation.future.timeout(const Duration(seconds: 30));
    await connected.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () async {
        final state = await controller.evaluateJavascript(
          source:
              'JSON.stringify({provider:typeof window.solana,native:typeof window.mallowNative,token:!!window.__mallowDocumentToken,protocol:location.protocol})',
        );
        fail(
          'Owned fixture provider state: $state; native URL: ${await controller.getUrl()}; navigations: $navigations; errors: $errors',
        );
      },
    );
    expect(requests, contains('connect'));
    expect(
      await controller.evaluateJavascript(source: 'window.solana.isMallow'),
      isTrue,
    );
    expect(
      await controller.evaluateJavascript(
        source: 'window.solana.isPhantom === undefined',
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'browser host captures trusted main-frame popups without replacing the tab',
    (tester) async {
      final created = Completer<InAppWebViewController>();
      final ready = Completer<void>();
      final popups = <Uri>[];
      final walletRequests = <String>[];
      final errors = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: BrowserWebViewHost(
                tabId: 'popup-fixture',
                url: Uri.parse('https://browser-fixture.invalid/'),
                onController: created.complete,
                onNavigationStarted: (_) {},
                onNavigation: (_, _) {},
                onRequest: (message, _) async {
                  walletRequests.add(message['method'] as String);
                  return const {
                    'error': {'code': 4100, 'message': 'Fixture rejection'},
                  };
                },
                onProgress: (_) {},
                onTitle: (title) {
                  if (title == 'Popup fixture ready' && !ready.isCompleted) {
                    ready.complete();
                  }
                },
                onPopup: popups.add,
                onError: errors.add,
              ),
            ),
          ),
        ),
      );
      final controller = await created.future.timeout(
        const Duration(seconds: 30),
      );
      await controller.stopLoading();
      await controller.loadData(
        data: '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <style>
    html,body { margin: 0; padding: 0; }
    button,a,iframe { display: block; box-sizing: border-box; width: 240px; height: 56px; margin: 8px; }
    a { background: #ddd; padding: 16px; }
    iframe { border: 0; }
  </style>
</head>
<body>
  <button id="script-popup" onclick="window.fixtureOpenResult = window.open('https://button-popup.invalid/path','_blank') ? 'window' : 'null'">Open button popup</button>
  <a id="blank-link" href="https://anchor-popup.invalid/path" target="_blank">Open target blank</a>
  <iframe id="child" srcdoc="&lt;button style='width:220px;height:48px' onclick=&quot;window.open('https://iframe-popup.invalid/path','_blank')&quot;&gt;Child popup&lt;/button&gt;"></iframe>
  <script>
    window.fixtureTrustedClicks = 0;
    document.addEventListener('click', event => {
      if (event.isTrusted) window.fixtureTrustedClicks++;
    }, true);
    window.addEventListener('mallow:document-ready', () => {
      document.title = 'Popup fixture ready';
    });
  </script>
</body>
</html>
''',
        baseUrl: WebUri('https://browser-fixture.invalid/'),
        historyUrl: WebUri('https://browser-fixture.invalid/'),
      );
      await ready.future.timeout(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      // The host's initial .invalid navigation can fail before loadData replaces
      // it. Popup handling must add no errors to that fixture setup baseline.
      final errorsBeforePopups = List<String>.of(errors);
      expect(walletRequests, ['connect']);
      final walletRequestBaseline = List<String>.of(walletRequests);

      await _tapWebElement(tester, controller, 'script-popup');
      await _waitForPopupCount(tester, controller, popups, 1);
      expect(popups.single, Uri.parse('https://button-popup.invalid/path'));

      await _tapWebElement(tester, controller, 'blank-link');
      await _waitForPopupCount(tester, controller, popups, 2);
      expect(popups.last, Uri.parse('https://anchor-popup.invalid/path'));

      await _tapWebElement(tester, controller, 'child');
      await tester.pump(const Duration(seconds: 1));
      expect(popups, hasLength(2), reason: 'Subframe popups must be rejected.');

      await controller.evaluateJavascript(
        source: "window.open('https://untrusted-popup.invalid/path','_blank')",
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        popups,
        hasLength(2),
        reason: 'A script-only popup has no trusted main-frame activation.',
      );
      expect(
        (await controller.getUrl())?.toString(),
        'https://browser-fixture.invalid/',
        reason: 'Rejected popups must never replace the current document.',
      );
      expect(
        walletRequests,
        walletRequestBaseline,
        reason: 'Capture views must not add wallet requests.',
      );
      expect(errors, errorsBeforePopups);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    // Flutter test pointer events do not cross into Android's native WebView.
    // The opt-in host driver consumes the emitted coordinates with `adb input`.
    skip: Platform.isAndroid && !_useAndroidNativePopupInput,
  );
}

Future<void> _waitForPopupCount(
  WidgetTester tester,
  InAppWebViewController controller,
  List<Uri> popups,
  int count,
) async {
  for (var attempt = 0; attempt < 100 && popups.length < count; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (popups.length == count) return;
  final state = await controller.evaluateJavascript(
    source:
        '''JSON.stringify({trustedClicks:window.fixtureTrustedClicks,openResult:window.fixtureOpenResult || null,userActive:navigator.userActivation?.isActive || false,url:location.href})''',
  );
  fail('Expected $count popups, received $popups; fixture state: $state');
}

Future<Offset> _elementCenter(
  WidgetTester tester,
  InAppWebViewController controller,
  String id,
) async {
  final raw = await controller.evaluateJavascript(
    source:
        '''JSON.stringify((() => { const r = document.getElementById(${jsonEncode(id)}).getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height}; })())''',
  );
  final rect = (jsonDecode(raw as String) as Map).cast<String, num>();
  final webViewOrigin = tester.getTopLeft(find.byType(InAppWebView));
  return webViewOrigin +
      Offset(rect['x']! + rect['width']! / 2, rect['y']! + rect['height']! / 2);
}

Future<void> _tapWebElement(
  WidgetTester tester,
  InAppWebViewController controller,
  String id,
) async {
  final center = await _elementCenter(tester, controller, id);
  if (!Platform.isAndroid) {
    await tester.tapAt(center);
    return;
  }
  final pixelRatio = tester.view.devicePixelRatio;
  debugPrint(
    'BROWSER_NATIVE_TAP ${(center.dx * pixelRatio).round()} '
    '${(center.dy * pixelRatio).round()}',
  );
}
