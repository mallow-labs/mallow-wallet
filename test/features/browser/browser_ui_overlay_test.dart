import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/screens/browser_screen.dart';
import 'package:mallow_wallet/features/browser/services/browser_visibility.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/browser_ui_channel.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_field.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_bottom_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_status_toast.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class _Session extends Mock implements SessionManager {}

class _Repository extends Mock implements WalletRepository {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Remote extends Mock implements RemoteConfigService {}

class _Controller extends Mock implements InAppWebViewController {}

class _Lock extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

class _WebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _WebView(params);
}

/// The creation params of the last WebView built, for driving its callbacks.
PlatformInAppWebViewWidgetCreationParams? _lastParams;

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params) : super.implementation() {
    _lastParams = params;
  }
  @override
  Widget build(BuildContext context) => const SizedBox();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();
  @override
  void dispose() {}
}

void main() {
  const wallet = WalletInfo(
    id: 'wallet',
    address: '11111111111111111111111111111111',
    name: 'Test',
    walletType: WalletType.hd,
    chain: 'solana',
  );
  // The web app's own origin is built in; tests run as a production build.
  final firstParty = Uri.parse('https://mallow.art/artwork/1');
  final thirdParty = Uri.parse('https://example.org/');
  late _Controller controller;
  late _Lock lock;
  late ValueNotifier<RemoteConfig> config;
  late InAppWebViewPlatform? previousPlatform;
  late List<String> scripts;

  setUpAll(() {
    registerFallbackValue(URLRequest(url: WebUri('https://mallow.art')));
    registerFallbackValue(
      UserScript(
        source: '',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    );
  });

  setUp(() async {
    Config.debugOverrides['ENV'] = 'production';
    FlutterSecureStorage.setMockInitialValues({});
    previousPlatform = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = _WebViewPlatform();
    final session = _Session();
    when(() => session.mode).thenReturn(LoginMode.account);
    when(() => session.isProfileMode).thenReturn(false);
    when(() => session.activeAccount).thenReturn(null);
    when(() => session.sessionWallets).thenReturn([wallet]);
    final repository = _Repository();
    when(() => repository.getActiveWallet()).thenAnswer((_) async => wallet);
    config = ValueNotifier(RemoteConfig.permissive);
    final remote = _Remote();
    when(() => remote.config).thenReturn(config);
    sl.registerSingleton<SessionManager>(session);
    sl.registerSingleton<WalletRepository>(repository);
    sl.registerSingleton<RemoteConfigService>(remote);
    final storage = _Storage();
    when(() => storage.loadBrowserMetadata()).thenAnswer((_) async => null);
    when(() => storage.storeBrowserMetadata(any())).thenAnswer((_) async {});
    sl.registerSingleton<SecureWalletStorage>(storage);
    lock = _Lock();
    whenListen(
      lock,
      const Stream<AppLockState>.empty(),
      initialState: const AppLockState.unlocked(),
    );
    controller = _Controller();
    scripts = [];
    when(
      () => controller.evaluateJavascript(source: any(named: 'source')),
    ).thenAnswer((invocation) async {
      scripts.add(invocation.namedArguments[#source] as String);
      return null;
    });
    when(() => controller.canGoBack()).thenAnswer((_) async => false);
    when(() => controller.canGoForward()).thenAnswer((_) async => false);
    when(
      () => controller.loadUrl(urlRequest: any(named: 'urlRequest')),
    ).thenAnswer((_) async {});
    await BrowserSession.instance.load();
  });

  tearDown(() async {
    Config.debugOverrides.clear();
    await sl.reset();
    await lock.close();
    config.dispose();
    if (previousPlatform != null) {
      InAppWebViewPlatform.instance = previousPlatform;
    }
  });

  Widget app(ThemeData theme) => MaterialApp(
    theme: theme,
    navigatorObservers: [browserPageRouteObserver],
    home: BlocProvider<AppLockBloc>.value(
      value: lock,
      child: const BrowserScreen(),
    ),
  );

  /// Opens [url] and commits it as the host's current document.
  Future<BrowserWebViewHost> mount(WidgetTester tester, Uri url) async {
    BrowserSession.instance.open(url);
    when(
      () => controller.getUrl(),
    ).thenAnswer((_) async => WebUri(url.toString()));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final reset = BrowserSession.resetForAppWipe();
      await tester.pump();
      await reset;
    });
    await tester.pumpWidget(app(MallowTheme.lightTheme));
    await tester.pumpAndSettle();
    _lastParams!.onWebViewCreated!(controller);
    await tester.pumpAndSettle();
    _lastParams!.onPageCommitVisible!(controller, WebUri(url.toString()));
    await tester.pumpAndSettle();
    return tester.widget<BrowserWebViewHost>(find.byType(BrowserWebViewHost));
  }

  DappFrameContext frame(Uri url, {int generation = 0}) => DappFrameContext(
    tabId: BrowserSession.instance.activeId!,
    generation: generation,
    origin: Uri.parse(url.origin),
    isMainFrame: true,
    isActive: true,
  );

  Future<void> overlay(
    WidgetTester tester,
    BrowserWebViewHost host,
    bool active, {
    Uri? from,
  }) async {
    host.onUiCommand!(
      BrowserUiSetOverlay(active: active),
      frame(from ?? firstParty),
    );
    await tester.pumpAndSettle();
  }

  double webViewBottom(WidgetTester tester) =>
      tester.getRect(find.byType(BrowserWebViewHost)).bottom;

  double scrimOpacity(WidgetTester tester, [Key key = browserChromeScrimKey]) =>
      tester
          .widget<Opacity>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;

  /// Page-facing calls, without the page probes that run on their own timer.
  Iterable<String> pageCalls() =>
      scripts.where((s) => !s.contains('getComputedStyle'));

  bool compact(WidgetTester tester) =>
      tester.widget<BrowserAddressBar>(find.byType(BrowserAddressBar)).compact;

  group('injection', () {
    testWidgets('the grant goes ahead of the provider', (tester) async {
      await mount(tester, firstParty);
      final userScripts = _lastParams!.initialUserScripts!;
      expect(userScripts, hasLength(2));
      final grant = userScripts.first;
      expect(grant.groupName, 'mallow-ui');
      expect(
        grant.source,
        browserUiGrantScript(environment: Environment.production, dark: false),
      );
      expect(grant.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(grant.forMainFrameOnly, isTrue);
      expect(userScripts.last.source, contains('window.__mallowUiGrant'));
    });

    final local = Uri.parse('https://192.168.1.20:5173/artwork/1');

    testWidgets('a development build treats a local web app as first-party', (
      tester,
    ) async {
      Config.debugOverrides['ENV'] = 'development';
      await mount(tester, local);
      expect(
        _lastParams!.initialUserScripts!.first.source,
        browserUiGrantScript(environment: Environment.development, dark: false),
      );
      final ready = scripts.singleWhere(
        (s) => s.contains('__mallowDocumentToken'),
      );
      expect(ready, contains(browserUiThemeScript(dark: false)));
    });

    testWidgets('a production build does not', (tester) async {
      await mount(tester, local);
      final ready = scripts.singleWhere(
        (s) => s.contains('__mallowDocumentToken'),
      );
      expect(ready, isNot(contains('__mallowUiSetTheme')));
    });

    testWidgets('only a first-party document is told the theme', (
      tester,
    ) async {
      await mount(tester, firstParty);
      final ready = scripts.singleWhere(
        (s) => s.contains('__mallowDocumentToken'),
      );
      expect(ready, contains(browserUiThemeScript(dark: false)));
      expect(
        ready.indexOf('__mallowUiSetTheme'),
        lessThan(ready.indexOf('mallow:document-ready')),
      );

      scripts.clear();
      await tester.pumpWidget(app(MallowTheme.darkTheme));
      await tester.pumpAndSettle();
      expect(scripts, contains(browserUiThemeScript(dark: true)));
    });

    testWidgets('later documents in the same WebView start in the theme the '
        'wallet moved to', (tester) async {
      final removed = <String>[];
      final added = <UserScript>[];
      when(
        () => controller.removeUserScriptsByGroupName(
          groupName: any(named: 'groupName'),
        ),
      ).thenAnswer((invocation) async {
        removed.add(invocation.namedArguments[#groupName] as String);
      });
      when(
        () => controller.addUserScript(userScript: any(named: 'userScript')),
      ).thenAnswer((invocation) async {
        added.add(invocation.namedArguments[#userScript] as UserScript);
      });
      await mount(tester, firstParty);
      // The grant already carries the wallet's theme.
      expect(added, isEmpty);

      await tester.pumpWidget(app(MallowTheme.darkTheme));
      await tester.pumpAndSettle();
      expect(removed, [browserUiStartThemeGroup]);
      final script = added.single;
      expect(script.groupName, browserUiStartThemeGroup);
      expect(
        script.source,
        browserUiStartThemeScript(
          environment: Environment.production,
          dark: true,
        ),
      );
      expect(script.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(script.forMainFrameOnly, isTrue);

      // Replaced, never stacked, when the theme moves again.
      await tester.pumpWidget(app(MallowTheme.lightTheme));
      await tester.pumpAndSettle();
      expect(removed, [browserUiStartThemeGroup, browserUiStartThemeGroup]);
      expect(added, hasLength(2));
      expect(
        added.last.source,
        browserUiStartThemeScript(
          environment: Environment.production,
          dark: false,
        ),
      );
    });

    testWidgets('a third-party document never is', (tester) async {
      await mount(tester, thirdParty);
      expect(scripts.where((s) => s.contains('__mallowUiSetTheme')), isEmpty);
      await tester.pumpWidget(app(MallowTheme.darkTheme));
      await tester.pumpAndSettle();
      expect(scripts.where((s) => s.contains('__mallowUiSetTheme')), isEmpty);
    });
  });

  group('inline address editing', () {
    Future<void> editAddress(WidgetTester tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.tap(find.bySemanticsLabel('Edit address, example.org'));
        await tester.pumpAndSettle();
      } finally {
        semantics.dispose();
      }
      clearInteractions(controller);
    }

    testWidgets(
      'opens in the top bar and keeps the webview fixed with keyboard',
      (tester) async {
        await mount(tester, thirdParty);
        final before = tester.getRect(find.byType(BrowserWebViewHost));
        final addressTop = tester.getTopLeft(find.byType(BrowserAddressBar)).dy;
        await editAddress(tester);

        expect(find.byType(BrowserAddressField), findsOneWidget);
        expect(find.byType(BrowserBottomBar), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          tester.getTopLeft(find.byType(BrowserAddressField)).dy,
          addressTop + 6,
        );
        final input = tester.widget<TextField>(find.byType(TextField));
        expect(input.controller!.text, thirdParty.toString());
        expect(
          input.controller!.selection,
          TextSelection(
            baseOffset: 0,
            extentOffset: thirdParty.toString().length,
          ),
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(BrowserWebViewHost)), before);
      },
    );

    testWidgets('Go navigates the current tab and restores the address bar', (
      tester,
    ) async {
      await mount(tester, thirdParty);
      final tabId = BrowserSession.instance.activeId;
      await editAddress(tester);
      await tester.enterText(find.byType(TextField), 'next.example/path');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      final request =
          verify(
                () => controller.loadUrl(
                  urlRequest: captureAny(named: 'urlRequest'),
                ),
              ).captured.single
              as URLRequest;
      expect(request.url.toString(), 'https://next.example/path');
      expect(BrowserSession.instance.activeId, tabId);
      expect(find.byType(BrowserAddressField), findsNothing);
      expect(find.byType(BrowserAddressBar), findsOneWidget);
    });

    for (final back in [false, true]) {
      testWidgets(
        '${back ? 'Back' : 'tapping the page'} cancels address editing',
        (tester) async {
          await mount(tester, thirdParty);
          await editAddress(tester);
          await tester.enterText(find.byType(TextField), 'discard.example');
          if (back) {
            await tester.binding.handlePopRoute();
          } else {
            await tester.tapAt(const Offset(200, 200));
          }
          await tester.pumpAndSettle();
          expect(find.byType(BrowserAddressField), findsNothing);
          expect(find.byType(BrowserAddressBar), findsOneWidget);
          expect(BrowserSession.instance.activeTab!.url, thirdParty);
          verifyNever(
            () => controller.loadUrl(urlRequest: any(named: 'urlRequest')),
          );
        },
      );
    }

    testWidgets('switching tabs cancels the editor without navigating', (
      tester,
    ) async {
      await mount(tester, thirdParty);
      await editAddress(tester);
      BrowserSession.instance.open(firstParty);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserAddressField), findsNothing);
      expect(BrowserSession.instance.activeTab!.url, firstParty);
      verifyNever(
        () => controller.loadUrl(urlRequest: any(named: 'urlRequest')),
      );
    });
  });

  group('overlay', () {
    testWidgets('steps the bar aside, compacts the address bar and dims the '
        'chrome; release restores it', (tester) async {
      final host = await mount(tester, firstParty);
      final height = tester.getSize(find.byType(Scaffold)).height;
      final barTop = tester.getTopLeft(find.byType(BrowserBottomBar)).dy;
      expect(webViewBottom(tester), barTop);
      expect(scrimOpacity(tester), 0);
      expect(compact(tester), isFalse);

      await overlay(tester, host, true);
      expect(webViewBottom(tester), height);
      expect(
        tester.getTopLeft(find.byType(BrowserBottomBar)).dy,
        greaterThanOrEqualTo(height),
      );
      expect(scrimOpacity(tester), 1);
      expect(compact(tester), isTrue);

      await overlay(tester, host, false);
      expect(webViewBottom(tester), barTop);
      expect(tester.getTopLeft(find.byType(BrowserBottomBar)).dy, barTop);
      expect(scrimOpacity(tester), 0);
      expect(compact(tester), isFalse);
    });

    testWidgets('the scrim covers the chrome above the page in the theme '
        'scrim, and a tap only tells the page', (tester) async {
      final host = await mount(tester, firstParty);
      await overlay(tester, host, true);
      final scrim = tester.getRect(find.byKey(browserChromeScrimKey));
      expect(scrim.top, 0);
      expect(scrim.bottom, tester.getRect(find.byType(BrowserWebViewHost)).top);
      final box = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byKey(browserChromeScrimKey),
          matching: find.byType(ColoredBox),
        ),
      );
      final context = tester.element(find.byType(BrowserScreen));
      expect(box.color, context.mallowColors.scrim);

      scripts.clear();
      await tester.tap(find.byKey(browserChromeScrimKey));
      await tester.pumpAndSettle();
      // The only page-facing call (page probes run on their own timer).
      expect(scripts.where((s) => !s.contains('getComputedStyle')), [
        browserUiScrimTapScript,
      ]);
      // Nothing native opened, and the page still holds the chrome.
      expect(find.byType(BrowserAddressField), findsNothing);
      expect(scrimOpacity(tester), 1);
    });

    testWidgets('the released scrim lets taps through to the chrome', (
      tester,
    ) async {
      await mount(tester, firstParty);
      final ignore = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byKey(browserChromeScrimKey),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignore.ignoring, isTrue);
    });

    testWidgets('a third-party page cannot claim the chrome', (tester) async {
      final host = await mount(tester, thirdParty);
      await overlay(tester, host, true, from: thirdParty);
      expect(scrimOpacity(tester), 0);
      expect(compact(tester), isFalse);
    });

    testWidgets('a stale document cannot claim the chrome', (tester) async {
      final host = await mount(tester, firstParty);
      host.onUiCommand!(
        const BrowserUiSetOverlay(active: true),
        frame(firstParty, generation: 7),
      );
      await tester.pumpAndSettle();
      expect(scrimOpacity(tester), 0);
    });

    group('resets', () {
      testWidgets('on a new document', (tester) async {
        final host = await mount(tester, firstParty);
        await overlay(tester, host, true);
        host.onNavigationStarted(1);
        await tester.pumpAndSettle();
        expect(scrimOpacity(tester), 0);
        expect(compact(tester), isFalse);
      });

      testWidgets('on a new WebView', (tester) async {
        final host = await mount(tester, firstParty);
        await overlay(tester, host, true);
        host.onController(controller);
        await tester.pumpAndSettle();
        expect(scrimOpacity(tester), 0);
      });

      testWidgets('on a tab switch', (tester) async {
        final host = await mount(tester, firstParty);
        await overlay(tester, host, true);
        BrowserSession.instance.open(firstParty);
        await tester.pumpAndSettle();
        expect(scrimOpacity(tester), 0);
      });

      testWidgets('when a native overlay opens, and stays off under it', (
        tester,
      ) async {
        final host = await mount(tester, firstParty);
        await overlay(tester, host, true);
        tester
            .widget<BrowserAddressBar>(find.byType(BrowserAddressBar))
            .onAddress();
        await tester.pumpAndSettle();
        expect(scrimOpacity(tester), 0);
        // The page cannot reclaim the chrome from under the wallet's sheet.
        await overlay(tester, host, true);
        expect(scrimOpacity(tester), 0);
      });

      testWidgets('when the WebView is covered by a pushed route', (
        tester,
      ) async {
        final host = await mount(tester, firstParty);
        await overlay(tester, host, true);
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const SizedBox()),
          ),
        );
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pumpAndSettle();
        expect(scrimOpacity(tester), 0);
        expect(compact(tester), isFalse);
      });
    });

    group('system navigation bar', () {
      void navigationBar(WidgetTester tester, double logical) {
        final padding = FakeViewPadding(
          bottom: logical * tester.view.devicePixelRatio,
        );
        tester.view.viewPadding = padding;
        tester.view.padding = padding;
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetPadding);
      }

      testWidgets('Android keeps its strip under the page sheet, dimmed, and '
          'a tap on it goes to the page', (tester) async {
        navigationBar(tester, 48);
        final host = await mount(tester, firstParty);
        final height = tester.getSize(find.byType(Scaffold)).height;
        final barTop = tester.getTopLeft(find.byType(BrowserBottomBar)).dy;
        expect(find.byKey(browserChromeBottomScrimKey), findsNothing);

        await overlay(tester, host, true);
        expect(webViewBottom(tester), height - 48);
        final strip = tester.getRect(find.byKey(browserChromeBottomScrimKey));
        expect(strip.top, height - 48);
        expect(strip.bottom, height);
        expect(scrimOpacity(tester, browserChromeBottomScrimKey), 1);

        scripts.clear();
        await tester.tap(find.byKey(browserChromeBottomScrimKey));
        await tester.pumpAndSettle();
        expect(pageCalls(), [browserUiScrimTapScript]);

        await overlay(tester, host, false);
        expect(webViewBottom(tester), barTop);
        expect(find.byKey(browserChromeBottomScrimKey), findsNothing);
      });

      testWidgets(
        'iOS runs the page to the screen edge, where its own safe area '
        'applies',
        (tester) async {
          navigationBar(tester, 34);
          final host = await mount(tester, firstParty);
          await overlay(tester, host, true);
          expect(
            webViewBottom(tester),
            tester.getSize(find.byType(Scaffold)).height,
          );
          expect(find.byKey(browserChromeBottomScrimKey), findsNothing);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    });

    testWidgets('system back goes to the page sheet instead of navigating', (
      tester,
    ) async {
      when(() => controller.canGoBack()).thenAnswer((_) async => true);
      when(() => controller.goBack()).thenAnswer((_) async {});
      final host = await mount(tester, firstParty);
      await overlay(tester, host, true);
      scripts.clear();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(pageCalls(), [browserUiScrimTapScript]);
      verifyNever(() => controller.goBack());
      expect(scrimOpacity(tester), 1);

      // Once the page lets go, back navigates again.
      await overlay(tester, host, false);
      scripts.clear();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      verify(() => controller.goBack()).called(1);
      expect(pageCalls(), isNot(contains(browserUiScrimTapScript)));
    });

    testWidgets('the transaction toast stays out from under the scrim while '
        'the page holds the chrome, and returns after', (tester) async {
      final tracker = BrowserTransactionTracker.instance;
      addTearDown(tracker.clear);
      final host = await mount(tester, firstParty);
      await overlay(tester, host, true);
      tracker.start(
        signature: 'sig-overlay',
        chain: 'solana:mainnet',
        lookup: (_, _) async => null,
      );
      await tester.pump();
      await tester.pump(MallowTheme.sheetDuration);
      expect(find.byType(BrowserStatusToast), findsNothing);
      // The compact address bar, inside the dimmed band, stands in for it.
      expect(compact(tester), isTrue);
      final band = tester.getRect(find.byKey(browserChromeScrimKey));
      expect(
        tester.getRect(find.byType(BrowserAddressBar)).bottom,
        lessThanOrEqualTo(band.bottom),
      );

      host.onUiCommand!(
        const BrowserUiSetOverlay(active: false),
        frame(firstParty),
      );
      await tester.pump();
      await tester.pump(MallowTheme.sheetDuration);
      expect(find.byType(BrowserStatusToast), findsOneWidget);
      tracker.clear();
      await tester.pump();
      await tester.pump(MallowTheme.sheetDuration);
    });

    testWidgets('jumps instead of animating under reduced motion', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final host = await mount(tester, firstParty);
      host.onUiCommand!(
        const BrowserUiSetOverlay(active: true),
        frame(firstParty),
      );
      await tester.pump();
      expect(scrimOpacity(tester), 1);
      host.onUiCommand!(
        const BrowserUiSetOverlay(active: false),
        frame(firstParty),
      );
      await tester.pump();
      expect(scrimOpacity(tester), 0);
    });
  });
}
