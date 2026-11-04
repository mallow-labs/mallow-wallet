import 'dart:convert';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/screens/browser_screen.dart';
import 'package:mallow_wallet/features/browser/services/browser_services.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_bottom_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class _Session extends Mock implements SessionManager {}

class _Repository extends Mock implements WalletRepository {}

class _Storage extends Mock implements SecureWalletStorage {}

class _WalletManager extends Mock implements WalletManager {}

class _Remote extends Mock implements RemoteConfigService {}

class _Controller extends Mock implements InAppWebViewController {}

class _HttpOverrides extends HttpOverrides {}

class _Lock extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

// Replace the platform view while retaining the screen's real lifecycle and
// native request coordinator.
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
  const wallet = WalletInfo(
    id: 'wallet',
    address: '11111111111111111111111111111111',
    name: 'Test',
    walletType: WalletType.hd,
    chain: 'solana',
  );
  const ethereumWallet = WalletInfo(
    id: 'ethereum',
    address: '0x1111111111111111111111111111111111111111',
    name: 'Ethereum',
    walletType: WalletType.hd,
    chain: 'ethereum',
  );
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final origin = Uri.parse('https://example.org');
  late _Controller controller;
  late _Lock lock;
  late ValueNotifier<RemoteConfig> config;
  late InAppWebViewPlatform? previousPlatform;
  late List<String> scripts;
  late _Session session;
  late _Repository repository;
  late Map<String, String> secureValues;
  late int grantReads;

  setUp(() async {
    Config.debugOverrides['API_BASE_URL'] = 'https://example.org';
    Config.debugOverrides['API_V2_BASE_URL'] = 'https://example.org/v2';
    secureValues = {};
    grantReads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final arguments = call.arguments as Map;
          final key = arguments['key'] as String;
          switch (call.method) {
            case 'read':
              if (key == 'browser.dapp_grants.v1') grantReads++;
              return secureValues[key];
            case 'write':
              secureValues[key] = arguments['value'] as String;
              return null;
            default:
              throw UnimplementedError(call.method);
          }
        });
    previousPlatform = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = _WebViewPlatform();
    session = _Session();
    when(() => session.mode).thenReturn(LoginMode.account);
    when(() => session.isProfileMode).thenReturn(false);
    when(() => session.activeAccount).thenReturn(null);
    when(() => session.sessionWallets).thenReturn([wallet, ethereumWallet]);
    repository = _Repository();
    when(() => repository.getActiveWallet()).thenAnswer((_) async => wallet);
    config = ValueNotifier(RemoteConfig.permissive);
    final remote = _Remote();
    when(() => remote.config).thenReturn(config);
    sl.registerSingleton<SessionManager>(session);
    sl.registerSingleton<WalletRepository>(repository);
    sl.registerSingleton<WalletManager>(_WalletManager());
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
    await BrowserSession.instance.load();
    BrowserSession.instance.open(origin);
    await browserPermissions.grant(origin.origin, wallet.address);
    await browserPermissions.grant(origin.origin, ethereumWallet.address);
  });
  tearDown(() async {
    Config.debugOverrides.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
    await sl.reset();
    await lock.close();
    config.dispose();
    if (previousPlatform != null) {
      InAppWebViewPlatform.instance = previousPlatform;
    }
  });

  Future<BrowserWebViewHost> mount(WidgetTester tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final reset = BrowserSession.resetForAppWipe();
      await tester.pump();
      await reset;
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: BlocProvider<AppLockBloc>.value(
          value: lock,
          child: const BrowserScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final host = tester.widget<BrowserWebViewHost>(
      find.byType(BrowserWebViewHost),
    );
    // Flush the platform-channel reads started by navigation before counting
    // the request's own secure-store access.
    await tester.runAsync(() async {
      host.onController(controller);
      host.onNavigationStarted(1);
      host.onNavigation(1, origin);
      await browserPermissions.list();
      await browserPermissions.list();
    });
    await tester.pumpAndSettle();
    grantReads = 0;
    return tester.widget<BrowserWebViewHost>(find.byType(BrowserWebViewHost));
  }

  DappFrameContext frame() => DappFrameContext(
    tabId: BrowserSession.instance.activeId!,
    generation: 1,
    origin: origin,
    isMainFrame: true,
    isActive: true,
  );

  testWidgets('page reads do not read grants or rebuild the browser', (
    tester,
  ) async {
    final host = await mount(tester);
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        Config.debugOverrides['ETH_RPC_URL'] =
            'http://127.0.0.1:${server.port}';
        final subscription = server.listen((request) async {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': '0x10'}),
          );
          await request.response.close();
        });
        try {
          for (var i = 0; i < 50; i++) {
            final result = await host.onRequest({
              'id': 'read-$i',
              'namespace': 'eip155',
              'method': 'read',
              'params': {'method': 'eth_blockNumber', 'params': <Object?>[]},
            }, frame());
            expect(result, {'result': '0x10'});
          }
        } finally {
          await subscription.cancel();
          await server.close(force: true);
        }
      }, _HttpOverrides()),
    );
    expect(grantReads, 0);
    await tester.pump();
    expect(
      tester.widget<BrowserWebViewHost>(find.byType(BrowserWebViewHost)),
      same(host),
    );
  });

  testWidgets(
    'silent Ethereum polls only read their grant and do not rebuild',
    (tester) async {
      final host = await mount(tester);
      await tester.runAsync(() async {
        for (var i = 0; i < 50; i++) {
          final result = await host.onRequest({
            'id': 'accounts-$i',
            'namespace': 'eip155',
            'method': 'connect',
            'params': {'silent': true},
          }, frame());
          expect((result['result'] as Map)['accounts'], [
            ethereumWallet.address,
          ]);
        }
      });
      expect(grantReads, 50);
      await tester.pump();
      expect(
        tester.widget<BrowserWebViewHost>(find.byType(BrowserWebViewHost)),
        same(host),
      );
    },
  );

  testWidgets(
    'interactive connect still refreshes both connection indicators',
    (tester) async {
      final host = await mount(tester);
      final result = await tester.runAsync(
        () => host.onRequest({
          'id': 'connect',
          'namespace': 'eip155',
          'method': 'connect',
          'params': <String, Object?>{},
        }, frame()),
      );
      expect((result!['result'] as Map)['accounts'], [ethereumWallet.address]);
      expect(grantReads, 3);
      await tester.pump();
      expect(
        tester.widget<BrowserWebViewHost>(find.byType(BrowserWebViewHost)),
        isNot(same(host)),
      );
    },
  );

  testWidgets('disconnect refreshes the indicator after revoking both grants', (
    tester,
  ) async {
    final host = await mount(tester);
    await tester.runAsync(() async {
      for (final namespace in [null, 'eip155']) {
        await host.onRequest({
          'id': 'disconnect-$namespace',
          if (namespace != null) 'namespace': namespace,
          'method': 'disconnect',
        }, frame());
      }
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BrowserBottomBar>(find.byType(BrowserBottomBar))
          .walletState,
      BrowserWalletPillState.disconnected,
    );
    expect(await tester.runAsync(browserPermissions.list), isEmpty);
  });

  testWidgets('signing methods retain the connection refresh on errors', (
    tester,
  ) async {
    final host = await mount(tester);
    final result = await tester.runAsync(
      () => host.onRequest({
        'id': 'sign',
        'method': 'signMessage',
        'params': <String, Object?>{},
      }, frame()),
    );
    expect((result!['error'] as Map)['code'], -32602);
    expect(grantReads, 3);
    await tester.pump();
    expect(
      tester.widget<BrowserWebViewHost>(find.byType(BrowserWebViewHost)),
      isNot(same(host)),
    );
  });
}
