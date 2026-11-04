import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/browser/screens/browser_screen.dart';
import 'package:mallow_wallet/features/browser/services/browser_services.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_bottom_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_lock_cover.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_wallet_picker.dart';
import 'package:mallow_wallet/features/wallets/services/wallet_drawer_bloc.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class _Session extends Mock implements SessionManager {}

class _Repository extends Mock implements WalletRepository {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Remote extends Mock implements RemoteConfigService {}

class _Drawer extends MockBloc<WalletDrawerEvent, WalletDrawerState>
    implements WalletDrawerBloc {}

class _Controller extends Mock implements InAppWebViewController {}

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
  const ethereumWallet = WalletInfo(
    id: 'ethereum-wallet',
    address: '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826',
    name: 'Ethereum',
    walletType: WalletType.hd,
    chain: 'ethereum',
  );
  const tezosWallet = WalletInfo(
    id: 'tezos-wallet',
    address: 'tz1-test-address',
    name: 'Tezos',
    walletType: WalletType.hd,
    chain: 'tezos',
  );
  const multiChainAccount = Account(
    id: 'multi',
    name: 'Multichain',
    wallets: [wallet, ethereumWallet, tezosWallet],
  );
  final origin = Uri.parse('https://example.org');
  late _Controller controller;
  late _Lock lock;
  late ValueNotifier<RemoteConfig> config;
  late InAppWebViewPlatform? previousPlatform;
  late List<String> scripts;
  late _Session session;
  late _Repository repository;
  VoidCallback? sessionListener;
  Completer<void>? pageDisconnected;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    previousPlatform = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = _WebViewPlatform();
    session = _Session();
    sessionListener = null;
    when(() => session.addListener(any())).thenAnswer((invocation) {
      sessionListener = invocation.positionalArguments.first as VoidCallback;
    });
    when(() => session.mode).thenReturn(LoginMode.account);
    when(() => session.isProfileMode).thenReturn(false);
    when(() => session.activeAccount).thenReturn(null);
    when(() => session.sessionWallets).thenReturn([wallet]);
    repository = _Repository();
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
    pageDisconnected = null;
    when(
      () => controller.evaluateJavascript(source: any(named: 'source')),
    ).thenAnswer((invocation) async {
      final source = invocation.namedArguments[#source] as String;
      scripts.add(source);
      if (source.contains('__mallowDisconnect') &&
          pageDisconnected?.isCompleted == false) {
        pageDisconnected!.complete();
      }
      return null;
    });
    when(() => controller.canGoBack()).thenAnswer((_) async => false);
    when(() => controller.canGoForward()).thenAnswer((_) async => false);
    await BrowserSession.instance.load();
    BrowserSession.instance.open(origin);
    await browserPermissions.grant(origin.origin, wallet.address);
  });
  tearDown(() async {
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
    host.onController(controller);
    return host;
  }

  for (final (url, expected) in [
    ('https://jup.ag', wallet),
    ('https://app.uniswap.org', ethereumWallet),
    ('https://objkt.com', tezosWallet),
  ]) {
    testWidgets('navigation to $url selects its chain in the current account', (
      tester,
    ) async {
      when(() => session.activeAccount).thenReturn(multiChainAccount);
      when(() => session.sessionWallets).thenReturn(multiChainAccount.wallets);
      when(
        () => repository.getAccountViews(),
      ).thenAnswer((_) async => [multiChainAccount]);
      final host = await mount(tester);
      final policy = await _lastParams!.shouldOverrideUrlLoading!(
        controller,
        NavigationAction(
          request: URLRequest(url: WebUri(url)),
          isForMainFrame: true,
        ),
      );
      expect(policy, NavigationActionPolicy.ALLOW);
      host.onNavigationStarted(1);
      host.onNavigation(1, Uri.parse(url));
      await tester.pumpAndSettle();
      final pill = tester.widget<BrowserBottomBar>(
        find.byType(BrowserBottomBar),
      );
      expect(pill.wallet?.id, expected.id);
      expect(pill.walletState, BrowserWalletPillState.disconnected);
      verifyNever(
        () => session.switchToAccount(
          any(),
          preferredWalletId: any(named: 'preferredWalletId'),
        ),
      );
      expect(
        await tester.runAsync(
          () => browserPermissions.isGranted(
            Uri.parse(url).origin,
            expected.address,
          ),
        ),
        isFalse,
      );
    });
  }

  testWidgets('missing chain switches accounts and retains the open tabs', (
    tester,
  ) async {
    const current = Account(id: 'current', name: 'Solana', wallets: [wallet]);
    const other = Account(id: 'other', name: 'Tezos', wallets: [tezosWallet]);
    when(() => session.activeAccount).thenReturn(current);
    when(
      () => repository.getAccountViews(),
    ).thenAnswer((_) async => [current, other]);
    when(
      () => session.switchToAccount('other', preferredWalletId: null),
    ).thenAnswer((_) async {
      when(() => session.activeAccount).thenReturn(other);
      when(() => session.sessionWallets).thenReturn(other.wallets);
      when(
        () => repository.getActiveWallet(),
      ).thenAnswer((_) async => tezosWallet);
      sessionListener!();
    });
    final host = await mount(tester);
    final tabIds = BrowserSession.instance.tabs.map((tab) => tab.id).toList();
    await host.beforeNavigation!(Uri.parse('https://objkt.com'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<BrowserBottomBar>(find.byType(BrowserBottomBar)).wallet?.id,
      tezosWallet.id,
    );
    expect(BrowserSession.instance.tabs.map((tab) => tab.id), tabIds);
    verify(
      () => session.switchToAccount('other', preferredWalletId: null),
    ).called(1);
  });

  testWidgets(
    'unknown sites retain the chosen chain and do not switch accounts',
    (tester) async {
      when(() => session.activeAccount).thenReturn(multiChainAccount);
      when(() => session.sessionWallets).thenReturn(multiChainAccount.wallets);
      when(
        () => repository.getAccountViews(),
      ).thenAnswer((_) async => [multiChainAccount]);
      final host = await mount(tester);
      await host.beforeNavigation!(Uri.parse('https://objkt.com'));
      await host.beforeNavigation!(Uri.parse('https://example.net'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BrowserBottomBar>(find.byType(BrowserBottomBar))
            .wallet
            ?.id,
        tezosWallet.id,
      );
      verify(() => repository.getAccountViews()).called(1);
    },
  );

  testWidgets('a newer navigation supersedes a slow chain selection', (
    tester,
  ) async {
    when(() => session.activeAccount).thenReturn(multiChainAccount);
    when(() => session.sessionWallets).thenReturn(multiChainAccount.wallets);
    final accounts = Completer<List<Account>>();
    when(() => repository.getAccountViews()).thenAnswer((_) => accounts.future);
    await mount(tester);
    Future<NavigationActionPolicy?> navigate(String url) async =>
        _lastParams!.shouldOverrideUrlLoading!(
          controller,
          NavigationAction(
            request: URLRequest(url: WebUri(url)),
            isForMainFrame: true,
          ),
        );
    final older = navigate('https://app.uniswap.org');
    await tester.pump();
    final newer = navigate('https://objkt.com');
    accounts.complete([multiChainAccount]);
    expect(await older, NavigationActionPolicy.CANCEL);
    expect(await newer, NavigationActionPolicy.ALLOW);
    await tester.pumpAndSettle();
    expect(
      tester.widget<BrowserBottomBar>(find.byType(BrowserBottomBar)).wallet?.id,
      tezosWallet.id,
    );
  });

  testWidgets(
    'an explicit pick replaces the pill and survives same-site navigation',
    (tester) async {
      when(() => session.activeAccount).thenReturn(multiChainAccount);
      when(() => session.sessionWallets).thenReturn(multiChainAccount.wallets);
      when(
        () => repository.getAccountViews(),
      ).thenAnswer((_) async => [multiChainAccount]);
      final drawer = _Drawer();
      addTearDown(drawer.close);
      whenListen(
        drawer,
        const Stream<WalletDrawerState>.empty(),
        initialState: const WalletDrawerState.loaded(
          accounts: [multiChainAccount],
          profileGroups: [],
          anonGroup: ProfileGroup(wallets: [], isAnon: true),
          activeWalletId: 'wallet',
        ),
      );
      sl.registerSingleton<WalletDrawerBloc>(drawer);
      final host = await mount(tester);
      final url = Uri.parse('https://objkt.com');
      await host.beforeNavigation!(url);
      await tester.pumpAndSettle();
      tester.widget<BrowserBottomBar>(find.byType(BrowserBottomBar)).onWallet();
      await tester.pumpAndSettle();
      final picker = tester.widget<BrowserWalletPicker>(
        find.byType(BrowserWalletPicker),
      );
      expect(picker.displayWallet?.id, tezosWallet.id);
      Navigator.of(tester.element(find.byType(BrowserWalletPicker))).pop(
        const BrowserWalletPicked(ethereumWallet, account: multiChainAccount),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BrowserBottomBar>(find.byType(BrowserBottomBar))
            .wallet
            ?.id,
        ethereumWallet.id,
      );
      await host.beforeNavigation!(url.replace(path: '/explore'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BrowserBottomBar>(find.byType(BrowserBottomBar))
            .wallet
            ?.id,
        ethereumWallet.id,
      );
    },
  );

  testWidgets('a grant on another chain does not mark the pill connected', (
    tester,
  ) async {
    when(() => session.activeAccount).thenReturn(multiChainAccount);
    when(() => session.sessionWallets).thenReturn(multiChainAccount.wallets);
    when(
      () => repository.getAccountViews(),
    ).thenAnswer((_) async => [multiChainAccount]);
    final url = Uri.parse('https://objkt.com');
    await tester.runAsync(
      () => browserPermissions.grant(url.origin, wallet.address),
    );
    final host = await mount(tester);
    await host.beforeNavigation!(url);
    host.onNavigationStarted(1);
    host.onNavigation(1, url);
    await tester.pumpAndSettle();
    final pill = tester.widget<BrowserBottomBar>(find.byType(BrowserBottomBar));
    expect(pill.wallet?.id, tezosWallet.id);
    expect(pill.walletState, BrowserWalletPillState.disconnected);
  });

  testWidgets(
    'a committed redirect selects its wallet before the bridge is ready',
    (tester) async {
      when(() => session.activeAccount).thenReturn(multiChainAccount);
      when(() => session.sessionWallets).thenReturn(multiChainAccount.wallets);
      final accounts = Completer<List<Account>>();
      when(
        () => repository.getAccountViews(),
      ).thenAnswer((_) => accounts.future);
      final url = WebUri('https://objkt.com');
      when(() => controller.getUrl()).thenAnswer((_) async => url);
      await mount(tester);
      _lastParams!.onLoadStart!(controller, url);
      _lastParams!.onPageCommitVisible!(controller, url);
      await tester.pump();
      expect(
        scripts.where((s) => s.contains('mallow:document-ready')),
        isEmpty,
      );
      accounts.complete([multiChainAccount]);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BrowserBottomBar>(find.byType(BrowserBottomBar))
            .wallet
            ?.id,
        tezosWallet.id,
      );
      expect(
        scripts.where((s) => s.contains('mallow:document-ready')),
        hasLength(1),
      );
    },
  );

  testWidgets('new document navigation does not cancel its startup connect', (
    tester,
  ) async {
    final host = await mount(tester);
    host.onNavigation(1, origin);
    await tester.pump();
    expect(scripts, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'browser overlay cancels work while retaining the connection; revocation disconnects',
    (tester) async {
      final host = await mount(tester);
      host.onNavigation(1, origin);
      await tester.pump();
      scripts.clear();
      tester
          .widget<BrowserAddressBar>(find.byType(BrowserAddressBar))
          .onAddress();
      await tester.pumpAndSettle();
      expect(
        scripts,
        contains(
          'window.__mallowDisconnect && window.__mallowDisconnect({preserveConnection: true});',
        ),
      );
      scripts.clear();
      await tester.runAsync(
        () => browserPermissions.revoke(origin.origin, wallet.address),
      );
      await tester.pump();
      expect(
        scripts,
        contains(
          'window.__mallowDisconnect && window.__mallowDisconnect({preserveConnection: false, preserveNamespaces: []});',
        ),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final revokeSolana in [true, false]) {
    testWidgets(
      'revoking ${revokeSolana ? 'Solana' : 'Ethereum'} preserves the other provider',
      (tester) async {
        when(() => session.sessionWallets).thenReturn([wallet, ethereumWallet]);
        await tester.runAsync(
          () => browserPermissions.grant(origin.origin, ethereumWallet.address),
        );
        final host = await mount(tester);
        host.onNavigationStarted(1);
        host.onNavigation(1, origin);
        await tester.pumpAndSettle();
        scripts.clear();

        pageDisconnected = Completer<void>();
        await tester.runAsync(
          () => browserPermissions.revoke(
            origin.origin,
            revokeSolana ? wallet.address : ethereumWallet.address,
          ),
        );
        // Drain both the widget and storage queues before checking the page.
        for (
          var frame = 0;
          frame < 20 && !pageDisconnected!.isCompleted;
          frame++
        ) {
          await tester.pump();
          await tester.runAsync(() async {});
        }
        await tester.pumpAndSettle();
        expect(pageDisconnected!.isCompleted, isTrue);

        final remaining = revokeSolana ? 'eip155' : 'solana';
        expect(scripts.where((script) => script.contains('__mallowDisconnect')), [
          'window.__mallowDisconnect && window.__mallowDisconnect({preserveConnection: false, preserveNamespaces: ["$remaining"]});',
        ]);
      },
    );
  }

  testWidgets(
    'a session notification that keeps the wallet cancels nothing; a new wallet does',
    (tester) async {
      final host = await mount(tester);
      host.onNavigation(1, origin);
      await tester.pump();
      scripts.clear();
      // A re-login finishing after a switch notifies again with the same
      // wallet: a connection sheet opened in between must survive it.
      sessionListener!();
      await tester.pumpAndSettle();
      expect(scripts.where((s) => s.contains('__mallowDisconnect')), isEmpty);

      const other = WalletInfo(
        id: 'other',
        address: '22222222222222222222222222222222',
        name: 'Other',
        walletType: WalletType.hd,
        chain: 'solana',
      );
      when(() => session.sessionWallets).thenReturn([wallet, other]);
      when(() => repository.getActiveWallet()).thenAnswer((_) async => other);
      sessionListener!();
      await tester.pumpAndSettle();
      expect(
        scripts,
        contains(
          'window.__mallowDisconnect && window.__mallowDisconnect({preserveConnection: false});',
        ),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the theme background covers the WebView until a page commits', (
    tester,
  ) async {
    when(
      () => controller.getUrl(),
    ).thenAnswer((_) async => WebUri(origin.toString()));
    await mount(tester);
    double cover() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byType(BrowserWebViewHost),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(cover(), 1, reason: 'no page has drawn yet');
    _lastParams!.onPageCommitVisible!(controller, WebUri(origin.toString()));
    await tester.pumpAndSettle();
    expect(cover(), 0);
    await tester.pumpWidget(const SizedBox());
  });

  group('a kept page', () {
    late StreamController<AppLockState> lockStates;

    setUp(() {
      lockStates = StreamController<AppLockState>.broadcast();
      whenListen(
        lock,
        lockStates.stream,
        initialState: const AppLockState.unlocked(),
      );
      when(() => controller.pause()).thenAnswer((_) async {});
      when(() => controller.resume()).thenAnswer((_) async {});
    });
    tearDown(() => lockStates.close());

    Key? hostKey(WidgetTester tester) =>
        tester.widget<BrowserWebViewHost>(find.byType(BrowserWebViewHost)).key;

    Future<void> lifecycle(
      WidgetTester tester,
      List<AppLifecycleState> states,
    ) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
    }

    testWidgets('survives backgrounding, covered while away', (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final host = await mount(tester);
      host.onNavigation(1, origin);
      await tester.pump();
      final key = hostKey(tester);
      scripts.clear();

      await lifecycle(tester, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      expect(find.byType(BrowserLockCover), findsOneWidget);
      expect(hostKey(tester), key);
      expect(host.canPrompt!(), isFalse);
      // Away cancels the page's work but keeps its accounts.
      expect(
        scripts,
        contains(
          'window.__mallowDisconnect && window.__mallowDisconnect({preserveConnection: true});',
        ),
      );
      verify(() => controller.pause()).called(1);

      await lifecycle(tester, const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(find.byType(BrowserLockCover), findsNothing);
      expect(hostKey(tester), key);
      expect(host.canPrompt!(), isTrue);
      verify(() => controller.resume()).called(1);
    });

    testWidgets('survives the app lock, covered until unlocked', (
      tester,
    ) async {
      final host = await mount(tester);
      final key = hostKey(tester);

      lockStates.add(const AppLockState.locked());
      await tester.pumpAndSettle();
      expect(find.byType(BrowserLockCover), findsOneWidget);
      expect(hostKey(tester), key);
      expect(host.canPrompt!(), isFalse);

      lockStates.add(const AppLockState.unlocked());
      await tester.pumpAndSettle();
      expect(find.byType(BrowserLockCover), findsNothing);
      expect(hostKey(tester), key);
      expect(host.canPrompt!(), isTrue);
    });

    testWidgets('picks no wallet while locked, and catches up on unlock', (
      tester,
    ) async {
      when(() => session.activeAccount).thenReturn(multiChainAccount);
      when(() => session.sessionWallets).thenReturn(multiChainAccount.wallets);
      when(
        () => repository.getAccountViews(),
      ).thenAnswer((_) async => [multiChainAccount]);
      final host = await mount(tester);
      final objkt = Uri.parse('https://objkt.com');

      lockStates.add(const AppLockState.locked());
      await tester.pumpAndSettle();
      await host.beforeNavigation!(objkt);
      host.onNavigationStarted(1);
      host.onNavigation(1, objkt);
      await tester.pumpAndSettle();
      verifyNever(() => repository.getAccountViews());

      lockStates.add(const AppLockState.unlocked());
      // The selection reads grants from storage: drain both queues.
      String? pill() => tester
          .widget<BrowserBottomBar>(find.byType(BrowserBottomBar))
          .wallet
          ?.id;
      for (var frame = 0; frame < 20 && pill() != tezosWallet.id; frame++) {
        await tester.pump();
        await tester.runAsync(() async {});
      }
      expect(
        tester
            .widget<BrowserBottomBar>(find.byType(BrowserBottomBar))
            .wallet
            ?.id,
        tezosWallet.id,
      );
    });

    testWidgets('is rebuilt once the OS ends its process', (tester) async {
      final host = await mount(tester);
      final key = hostKey(tester);
      host.onProcessGone!();
      await tester.pump();
      expect(hostKey(tester), isNot(key));
    });
  });
}
