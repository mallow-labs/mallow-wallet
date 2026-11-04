import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/browser/screens/browser_screen.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_bar.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class _Session extends Mock implements SessionManager {}

class _Repository extends Mock implements WalletRepository {}

class _Preferences extends Mock implements PreferencesService {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Remote extends Mock implements RemoteConfigService {}

class _Lock extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

class _WebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _WebView(params);
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

void main() {
  final url = Uri.parse('https://example.org/artwork/one?edition=2#details');
  late _Lock lock;
  late _Storage storage;
  late ValueNotifier<RemoteConfig> config;
  late InAppWebViewPlatform? oldPlatform;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    oldPlatform = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = _WebViewPlatform();
    final session = _Session();
    when(() => session.mode).thenReturn(LoginMode.account);
    when(() => session.isProfileMode).thenReturn(false);
    when(() => session.activeAccount).thenReturn(null);
    when(() => session.sessionWallets).thenReturn([]);
    final repository = _Repository();
    when(() => repository.getActiveWallet()).thenAnswer((_) async => null);
    config = ValueNotifier(RemoteConfig.permissive);
    final remote = _Remote();
    when(() => remote.config).thenReturn(config);
    storage = _Storage();
    when(() => storage.loadBrowserMetadata()).thenAnswer((_) async => null);
    when(() => storage.storeBrowserMetadata(any())).thenAnswer((_) async {});
    sl.registerSingleton<SessionManager>(session);
    sl.registerSingleton<WalletRepository>(repository);
    sl.registerSingleton<RemoteConfigService>(remote);
    sl.registerSingleton<SecureWalletStorage>(storage);
    lock = _Lock();
    whenListen(
      lock,
      const Stream<AppLockState>.empty(),
      initialState: const AppLockState.unlocked(),
    );
  });
  tearDown(() async {
    await sl.reset();
    await lock.close();
    config.dispose();
    if (oldPlatform != null) InAppWebViewPlatform.instance = oldPlatform;
  });

  void cleanup(WidgetTester tester) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final reset = BrowserSession.resetForAppWipe();
      await tester.pump();
      await reset;
    });
  }

  Future<void> mount(WidgetTester tester) async {
    cleanup(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: BlocProvider<AppLockBloc>.value(
          value: lock,
          child: BrowserScreen(initialUrl: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final (chain, expectedUrl) in [
    ('solana:mainnet', 'https://orbmarkets.io/tx/receipt'),
    ('solana:devnet', 'https://orbmarkets.io/tx/receipt?cluster=devnet'),
    ('eip155:1', 'https://eth.blockscout.com/tx/receipt'),
  ]) {
    testWidgets('View opens the preferred $chain explorer in the system '
        'browser without changing tabs', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = _Preferences();
      when(() => preferences.explorer).thenReturn('orb');
      when(() => preferences.ethExplorer).thenReturn('blockscout');
      sl.registerSingleton<PreferencesService>(preferences);
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final launched = <Map<Object?, Object?>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') {
          launched.add(call.arguments as Map<Object?, Object?>);
          return true;
        }
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      final tracker = BrowserTransactionTracker.instance;
      tracker.clear();
      await mount(tester);
      final session = BrowserSession.instance;
      final tabId = session.activeId;
      final count = session.tabs.length;
      tracker.start(
        signature: 'receipt',
        chain: chain,
        lookup: (_, _) async => null,
      );
      await tester.pump();
      await tester.pump(MallowTheme.sheetDuration);
      await tester.tap(find.bySemanticsLabel('View transaction'));
      await tester.pump();
      expect(launched, hasLength(1));
      expect(launched.single['url'], expectedUrl);
      expect(launched.single['useSafariVC'], isTrue);
      expect(session.activeId, tabId);
      expect(session.tabs, hasLength(count));
      expect(session.pendingUrl(tabId!), url);
      tracker.clear();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('awaits restoration then opens the shared URL as a new tab', (
    tester,
  ) async {
    final restored = Completer<String?>();
    when(
      () => storage.loadBrowserMetadata(),
    ).thenAnswer((_) => restored.future);
    await mount(tester);
    expect(find.byType(BrowserWebViewHost), findsNothing);
    restored.complete(null);
    await tester.pumpAndSettle();
    expect(BrowserSession.instance.tabs, hasLength(1));
    expect(BrowserSession.instance.activeTab?.url, isNull);
    expect(
      BrowserSession.instance.pendingUrl(BrowserSession.instance.activeId!),
      url,
    );
    expect(
      tester.widget<BrowserWebViewHost>(find.byType(BrowserWebViewHost)).url,
      url,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a pending navigation keeps the visible and saved site identity',
    (tester) async {
      await mount(tester);
      final host = tester.widget<BrowserWebViewHost>(
        find.byType(BrowserWebViewHost),
      );
      host.onNavigationStarted(1);
      host.onNavigation(1, url);
      await tester.pump();
      expect(
        tester.widget<BrowserAddressBar>(find.byType(BrowserAddressBar)).host,
        url.host,
      );

      final destination = Uri.parse('https://other.example/wait');
      host.onNavigationStarted(2);
      await tester.pump();
      expect(
        tester.widget<BrowserAddressBar>(find.byType(BrowserAddressBar)).host,
        url.host,
      );
      expect(BrowserSession.instance.activeTab?.url, url);
      host.onNavigationStarted(3);
      host.onNavigation(2, destination);
      await tester.pump();
      expect(
        tester.widget<BrowserAddressBar>(find.byType(BrowserAddressBar)).host,
        url.host,
      );
      expect(BrowserSession.instance.activeTab?.url, url);

      host.onNavigation(3, destination);
      await tester.pump();
      expect(
        tester.widget<BrowserAddressBar>(find.byType(BrowserAddressBar)).host,
        destination.host,
      );
      expect(BrowserSession.instance.activeTab?.url, destination);
      final spa = destination.replace(path: '/account');
      host.onNavigation(3, spa);
      await tester.pump();
      expect(BrowserSession.instance.activeTab?.url, spa);
    },
  );

  testWidgets('a return visit shows the remembered name and icon on commit', (
    tester,
  ) async {
    await mount(tester);
    final host = tester.widget<BrowserWebViewHost>(
      find.byType(BrowserWebViewHost),
    );
    final icon = Uri.parse('https://example.org/apple-touch-icon.png');
    host.onNavigationStarted(1);
    host.onNavigation(1, url);
    host.onTitle('Example Gallery');
    host.onFavicon!(icon);
    await tester.pump();

    host.onNavigationStarted(2);
    host.onNavigation(2, Uri.parse('https://other.example'));
    await tester.pump();
    expect(BrowserSession.instance.activeTab?.title, 'other.example');
    expect(
      tester.widget<BrowserAddressBar>(find.byType(BrowserAddressBar)).iconUrl,
      isNull,
    );

    // Before the page reports its title or icon.
    host.onNavigationStarted(3);
    host.onNavigation(3, Uri.parse('https://example.org/'));
    await tester.pump();
    expect(BrowserSession.instance.activeTab?.title, 'Example Gallery');
    expect(
      tester.widget<BrowserAddressBar>(find.byType(BrowserAddressBar)).iconUrl,
      icon,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a share received while locked never creates a WebView until unlock',
    (tester) async {
      final states = StreamController<AppLockState>();
      whenListen(
        lock,
        states.stream,
        initialState: const AppLockState.uninitialized(),
      );
      await mount(tester);
      expect(BrowserSession.instance.activeTab?.url, isNull);
      expect(
        BrowserSession.instance.pendingUrl(BrowserSession.instance.activeId!),
        url,
      );
      expect(find.byType(BrowserWebViewHost), findsNothing);
      states.add(const AppLockState.unlocked());
      await tester.pumpAndSettle();
      expect(find.byType(BrowserWebViewHost), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await states.close();
    },
  );

  testWidgets(
    'a full tab list is preserved and reports why the share did not open',
    (tester) async {
      final session = BrowserSession.instance;
      await session.load();
      for (var i = 0; i < 20; i++) {
        session.open(Uri.https('existing.example', '/$i'));
      }
      await mount(tester);
      expect(session.tabs, hasLength(20));
      expect(session.tabs.any((t) => t.url == url), isFalse);
      expect(
        find.text('Close a tab before opening another (20 maximum).'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'disposing the receiving screen while loading does not open a tab',
    (tester) async {
      final restored = Completer<String?>();
      when(
        () => storage.loadBrowserMetadata(),
      ).thenAnswer((_) => restored.future);
      await mount(tester);
      await tester.pumpWidget(const SizedBox());
      restored.complete(null);
      await tester.pumpAndSettle();
      expect(BrowserSession.instance.tabs, isEmpty);
    },
  );
  testWidgets('disabled browser rejects the share without opening a tab', (
    tester,
  ) async {
    config.value = const RemoteConfig(browserEnabled: false);
    cleanup(tester);
    final router = GoRouter(
      initialLocation: '/browser/open',
      routes: [
        GoRoute(
          path: '/browser',
          builder: (_, _) => const Text('browser disabled'),
          routes: [
            GoRoute(
              path: 'open',
              builder: (_, _) => BrowserScreen(initialUrl: url),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      BlocProvider<AppLockBloc>.value(
        value: lock,
        child: MaterialApp.router(
          theme: MallowTheme.lightTheme,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(BrowserSession.instance.tabs, isEmpty);
    expect(find.byType(BrowserWebViewHost), findsNothing);
    expect(find.text('browser disabled'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });
}
