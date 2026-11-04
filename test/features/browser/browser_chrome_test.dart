import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/browser_visibility.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_field.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_bottom_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_lock_cover.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_page_menu.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_status_toast.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_tab_switcher.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_wallet_picker.dart';
import 'package:mallow_wallet/features/wallets/services/wallet_drawer_bloc.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

const _wallet = WalletInfo(
  id: 'w1',
  address: '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJos9fQa',
  name: 'Wallet 1',
  walletType: WalletType.hd,
  chain: 'solana',
);
const _viewOnly = WalletInfo(
  id: 'w2',
  address: '9bQmZr4uH1xYk2PqE7sT3vN8cW5dF6gA1jL0oM2nB4Kt',
  name: 'Watcher',
  walletType: WalletType.viewOnly,
  chain: 'solana',
);

Widget _app(
  Widget child, {
  Size? size,
  double textScale = 1,
  bool dark = false,
}) => MaterialApp(
  theme: dark ? MallowTheme.darkTheme : MallowTheme.lightTheme,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(size: size, textScaler: TextScaler.linear(textScale)),
      child: child,
    ),
  ),
);

void _viewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Calls {
  final log = <String>[];
  VoidCallback call(String name) =>
      () => log.add(name);
}

BrowserBottomBar _bar(
  _Calls calls, {
  BrowserWalletPillState state = BrowserWalletPillState.connected,
  WalletInfo? wallet = _wallet,
  bool canBack = true,
  bool canForward = false,
}) => BrowserBottomBar(
  host: 'jup.ag',
  canBack: canBack,
  canForward: canForward,
  tabCount: 3,
  wallet: wallet,
  walletState: state,
  onMinimise: calls.call('minimise'),
  onBack: calls.call('back'),
  onForward: calls.call('forward'),
  onTabs: calls.call('tabs'),
  onMenu: calls.call('menu'),
  onWallet: calls.call('wallet'),
);

BrowserAddressBar _address(
  _Calls calls, {
  bool compact = false,
  bool loading = false,
  bool blank = false,
}) => BrowserAddressBar(
  compact: compact,
  host: blank ? null : 'jup.ag',
  blank: blank,
  loading: loading,
  onAddress: calls.call('address'),
  onTabs: calls.call('tabs'),
  onReloadOrStop: calls.call('reload'),
  onExpand: calls.call('expand'),
);

/// Both bars, where the browser screen puts them.
Scaffold _chrome(_Calls calls, {BrowserAddressBar? address}) => Scaffold(
  body: Align(
    alignment: Alignment.topCenter,
    child: address ?? _address(calls),
  ),
  bottomNavigationBar: _bar(calls),
);

Future<BrowserSession> _session() async {
  FlutterSecureStorage.setMockInitialValues({});
  final session = BrowserSession(
    BrowserRepository(
      SecureWalletStorage(const FlutterSecureStorage(), MnemonicVault()),
    ),
  );
  await session.load();
  return session;
}

void main() {
  group('bottom bar', () {
    testWidgets('controls are labelled 44 dp targets that fire callbacks', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final calls = _Calls();
      await tester.pumpWidget(_app(_chrome(calls)));
      await tester.pumpAndSettle();
      for (final (label, call) in [
        ('Minimise browser', 'minimise'),
        ('Back', 'back'),
        ('3 open tabs', 'tabs'),
        ('Page menu', 'menu'),
        ('Reload', 'reload'),
        ('Show tabs', 'tabs'),
        ('Edit address, jup.ag', 'address'),
        ('Wallet 7xKX…9fQa, connected to jup.ag. Choose wallet', 'wallet'),
      ]) {
        final finder = find.bySemanticsLabel(label);
        expect(finder, findsOneWidget, reason: label);
        final size = tester.getSize(finder);
        expect(size.height, greaterThanOrEqualTo(44), reason: label);
        await tester.tap(finder);
        expect(calls.log.last, call, reason: label);
      }
      // Forward is disabled: tapping it does nothing.
      final before = calls.log.length;
      await tester.tap(find.bySemanticsLabel('Forward'));
      expect(calls.log.length, before);
      handle.dispose();
    });

    testWidgets('loading swaps reload for stop', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(Scaffold(body: _address(_Calls(), loading: true))),
      );
      expect(find.bySemanticsLabel('Stop loading'), findsOneWidget);
      expect(find.bySemanticsLabel('Reload'), findsNothing);
      handle.dispose();
    });

    testWidgets('wallet pill shows the address and connection, never a label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final (state, wallet, label, text) in [
        (
          BrowserWalletPillState.disconnected,
          _wallet,
          'Wallet 7xKX…9fQa, not connected to jup.ag. Choose wallet',
          'Disconnected',
        ),
        (BrowserWalletPillState.none, null, 'Select a wallet', 'Select'),
        (
          BrowserWalletPillState.connected,
          _viewOnly,
          'Wallet 9bQm…B4Kt, connected to jup.ag. Choose wallet',
          'Connected',
        ),
      ]) {
        await tester.pumpWidget(
          _app(
            Scaffold(
              bottomNavigationBar: _bar(_Calls(), state: state, wallet: wallet),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel(label), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        // A wallet's stored name is an internal label.
        expect(find.text('Wallet 1'), findsNothing);
        expect(find.text('Watcher'), findsNothing);
        // There is no generic Connect button.
        expect(find.text('Connect'), findsNothing);
      }
      handle.dispose();
    });

    testWidgets('the address scales down rather than wrapping', (tester) async {
      // The narrowest width and largest text that still show the address.
      _viewSize(tester, const Size(390, 640));
      await tester.pumpWidget(
        _app(_chrome(_Calls()), size: const Size(390, 640), textScale: 1.3),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final address = tester.renderObject<RenderParagraph>(
        find.text('7xKX…9fQa'),
      );
      expect(address.didExceedMaxLines, isFalse);
      expect(address.size.height, lessThan(24));
    });

    testWidgets('the pills hug their content and centre as a group', (
      tester,
    ) async {
      _viewSize(tester, const Size(430, 800));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(_chrome(_Calls()), size: const Size(430, 800)),
      );
      await tester.pumpAndSettle();
      final controls = tester.getRect(
        find
            .ancestor(
              of: find.bySemanticsLabel('Minimise browser'),
              matching: find.byType(Container),
            )
            .last,
      );
      final wallet = tester.getRect(
        find.bySemanticsLabel(
          'Wallet 7xKX…9fQa, connected to jup.ag. Choose wallet',
        ),
      );
      final address = tester.getRect(find.text('7xKX…9fQa'));
      // Tight: avatar padding, avatar, gap, text, right padding.
      expect(wallet.right - address.right, closeTo(12, 0.5));
      // Centred: equal space either side of the group.
      expect(controls.left, closeTo(430 - wallet.right, 0.5));
      handle.dispose();
    });

    testWidgets('fits 320 dp at 2x text in light and dark', (tester) async {
      _viewSize(tester, const Size(320, 640));
      final handle = tester.ensureSemantics();
      for (final dark in [false, true]) {
        final calls = _Calls();
        await tester.pumpWidget(
          _app(
            _chrome(calls),
            size: const Size(320, 640),
            textScale: 2,
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // The text drops; the pill keeps its meaning for screen readers.
        expect(find.text('7xKX…9fQa'), findsNothing);
        await tester.tap(
          find.bySemanticsLabel(
            'Wallet 7xKX…9fQa, connected to jup.ag. Choose wallet',
          ),
        );
        expect(calls.log, ['wallet']);
      }
      handle.dispose();
    });

    testWidgets('compact address bar keeps the controls and drops reload', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final calls = _Calls();
      await tester.pumpWidget(
        _app(_chrome(calls, address: _address(calls, compact: true))),
      );
      await tester.pumpAndSettle();
      expect(find.text('jup.ag'), findsOneWidget);
      expect(find.bySemanticsLabel('Page menu'), findsOneWidget);
      expect(find.bySemanticsLabel('Reload'), findsNothing);
      expect(find.bySemanticsLabel('Show tabs'), findsNothing);
      await tester.tap(find.bySemanticsLabel('jup.ag. Show toolbar'));
      expect(calls.log, ['expand']);
      handle.dispose();
    });

    testWidgets('start page shows search, not a host or reload', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(Scaffold(body: _address(_Calls(), blank: true))),
      );
      expect(find.text('Search or enter address'), findsOneWidget);
      expect(find.bySemanticsLabel('Reload'), findsNothing);
      handle.dispose();
    });
  });

  group('bar collapse', () {
    test('acts on direction changes past the slop, debounced', () {
      var now = DateTime(2026);
      final collapse = BrowserBarCollapse(clock: () => now);
      expect(collapse.scrolled(0), isFalse);
      // Small moves and moves near the top never collapse.
      expect(collapse.scrolled(20), isFalse);
      expect(collapse.scrolled(60), isFalse);
      expect(collapse.compact, isFalse);
      expect(collapse.scrolled(200), isTrue);
      expect(collapse.compact, isTrue);
      // Still going down: no change, however far.
      expect(collapse.scrolled(900), isFalse);
      // A wobble up inside the slop is ignored.
      expect(collapse.scrolled(890), isFalse);
      // A real turn upward within the debounce window is held back...
      now = now.add(const Duration(milliseconds: 100));
      expect(collapse.scrolled(800), isFalse);
      expect(collapse.compact, isTrue);
      // ...and taken once the window has passed.
      now = now.add(const Duration(milliseconds: 400));
      expect(collapse.scrolled(770), isTrue);
      expect(collapse.compact, isFalse);
    });

    test('the top of the page and a tap always expand', () {
      var now = DateTime(2026);
      final collapse = BrowserBarCollapse(clock: () => now);
      collapse
        ..scrolled(0)
        ..scrolled(300);
      expect(collapse.compact, isTrue);
      expect(collapse.scrolled(0), isTrue, reason: 'no debounce at the top');
      now = now.add(const Duration(seconds: 1));
      collapse.scrolled(400);
      expect(collapse.compact, isTrue);
      expect(collapse.set(false, force: true), isTrue);
      collapse.reset();
      expect(collapse.compact, isFalse);
      expect(collapse.scrolled(500), isFalse, reason: 'fresh anchor');
    });
  });

  group('page menu', () {
    Future<BrowserMenuAction?> open(
      WidgetTester tester,
      Widget menu, {
      String? tap,
      Size? size,
      double textScale = 1,
    }) async {
      BrowserMenuAction? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showMallowSheet<BrowserMenuAction>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => menu,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          size: size,
          textScale: textScale,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      if (tap != null) {
        await tester.tap(
          tap.startsWith('text:')
              ? find.text(tap.substring(5))
              : find.bySemanticsLabel(tap),
        );
        await tester.pumpAndSettle();
      }
      return result;
    }

    testWidgets('every action pops its value', (tester) async {
      final handle = tester.ensureSemantics();
      for (final (label, action) in [
        ('Bookmark this page', BrowserMenuAction.bookmark),
        ('Share', BrowserMenuAction.share),
        ('Reload', BrowserMenuAction.reload),
        ('New tab', BrowserMenuAction.newTab),
        // Shared SheetMenuRows are found by their text.
        ('text:Copy link', BrowserMenuAction.copyLink),
        ('text:Scan QR code on page', BrowserMenuAction.scanPageCode),
        ('text:Browser settings', BrowserMenuAction.settings),
        ('text:Close tab', BrowserMenuAction.close),
        ('Disconnect', BrowserMenuAction.disconnect),
      ]) {
        final result = await open(
          tester,
          BrowserPageMenu(
            url: Uri.parse('https://jup.ag/swap'),
            title: 'Swap',
            bookmarked: false,
            loading: false,
            wallet: _wallet,
            connected: true,
            canScanCode: true,
          ),
          tap: label,
        );
        expect(result, action, reason: label);
      }
      handle.dispose();
    });

    testWidgets('the page scan is offered only with WalletConnect', (
      tester,
    ) async {
      for (final available in [false, true]) {
        await open(
          tester,
          BrowserPageMenu(
            url: Uri.parse('https://mallow.art/'),
            title: 'mallow',
            bookmarked: false,
            loading: false,
            wallet: _wallet,
            connected: false,
            canScanCode: available,
          ),
        );
        expect(
          find.text('Scan QR code on page'),
          available ? findsOneWidget : findsNothing,
        );
        Navigator.of(tester.element(find.text('Copy link'))).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('connection card labels Solana and Ethereum-only connections', (
      tester,
    ) async {
      const ethereum = WalletInfo(
        id: 'eth1',
        address: '0x123456789012345678901234567890123456cdef',
        name: 'Ethereum 1',
        walletType: WalletType.hd,
        chain: 'ethereum',
      );
      for (final (wallet, address, chain) in [
        (_wallet, '7xKX…9fQa', 'Solana'),
        (ethereum, '0x12…cdef', 'Ethereum'),
      ]) {
        await open(
          tester,
          BrowserPageMenu(
            url: Uri.parse('https://dapp.example/'),
            title: 'Dapp',
            bookmarked: false,
            loading: false,
            wallet: wallet,
            connected: true,
          ),
        );
        expect(find.text('Connected as $address'), findsOneWidget);
        expect(find.text('$address · $chain'), findsOneWidget);
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('committed host leads a page title that claims another', (
      tester,
    ) async {
      await open(
        tester,
        BrowserPageMenu(
          url: Uri.parse('https://evil.example/x'),
          title: 'jup.ag',
          bookmarked: true,
          loading: true,
          wallet: _wallet,
          connected: false,
        ),
      );
      // Host first, then the page's claim; the URL line leads with it too.
      expect(find.text('evil.example'), findsNWidgets(2));
      expect(find.text('/x'), findsOneWidget);
      expect(find.text(' · jup.ag'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      // Not connected: no card, but a way to switch wallet.
      expect(find.text('Disconnect'), findsNothing);
      expect(find.text('Switch wallet'), findsOneWidget);
    });

    testWidgets('start page disables page actions', (tester) async {
      final handle = tester.ensureSemantics();
      final result = await open(
        tester,
        const BrowserPageMenu(
          url: null,
          title: '',
          bookmarked: false,
          loading: false,
          wallet: _wallet,
          connected: false,
        ),
        tap: 'Share',
      );
      expect(result, isNull);
      expect(find.text('Share'), findsOneWidget, reason: 'still open');
      handle.dispose();
    });

    testWidgets('fits 320 dp at 2x text', (tester) async {
      _viewSize(tester, const Size(320, 640));
      await open(
        tester,
        BrowserPageMenu(
          url: Uri.parse('https://app.kamino.finance/lending'),
          title: 'Kamino Lend',
          bookmarked: false,
          loading: false,
          wallet: _wallet,
          connected: true,
        ),
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('wallet picker', () {
    Future<Object?> open(WidgetTester tester, Widget sheet, String tap) async {
      Object? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showMallowSheet<Object>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => sheet,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.bySemanticsLabel(tap));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('lists accounts and profiles with every address', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      const second = WalletInfo(
        id: 'w3',
        address: 'Bq2zKx7Lm4Np9Qr2St5Uv8Wx1Yz3Ab6Cd9Ef2Gh5eYa7K',
        name: 'Imported key',
        walletType: WalletType.hd,
        chain: 'solana',
        accountId: 'a1',
      );
      const eth = WalletInfo(
        id: 'w4',
        address: '0x1111111111111111111111111111111111111111',
        name: 'Ethereum 1',
        walletType: WalletType.hd,
        chain: 'ethereum',
        accountId: 'a1',
      );
      const account = Account(
        id: 'a1',
        name: 'Main',
        wallets: [_wallet, second, eth],
      );
      const profile = ProfileGroup(
        wallets: [_viewOnly],
        isAnon: false,
        userId: 'u1',
        username: 'maren.studio',
      );
      const state = WalletDrawerState.loaded(
        profileGroups: [profile],
        anonGroup: ProfileGroup(wallets: [], isAnon: true),
        activeWalletId: 'w1',
        accounts: [account],
      );
      final picked = await open(
        tester,
        const BrowserWalletPicker(
          state: state,
          selected: _wallet,
          host: 'jup.ag',
          siteConnected: true,
        ),
        'Main, Solana Bq2zK…eYa7K',
      );
      expect(picked, isA<BrowserWalletPicked>());
      picked as BrowserWalletPicked;
      expect(picked.wallet, second);
      expect(picked.account, account);
      expect(picked.profile, isNull);

      expect(
        await open(
          tester,
          const BrowserWalletPicker(
            state: state,
            selected: _wallet,
            host: 'jup.ag',
            siteConnected: true,
          ),
          'Disconnect jup.ag',
        ),
        isA<BrowserWalletDisconnect>(),
      );
      handle.dispose();
    });

    const second = WalletInfo(
      id: 'w3',
      address: 'Bq2zKx7Lm4Np9Qr2St5Uv8Wx1Yz3Ab6Cd9Ef2Gh5eYa7K',
      name: 'Imported key',
      walletType: WalletType.hd,
      chain: 'solana',
      accountId: 'a1',
    );
    const loaded = WalletDrawerState.loaded(
      profileGroups: [
        ProfileGroup(
          wallets: [
            WalletInfo(
              id: 'w2',
              address: '9bQmZr4uH1xYk2PqE7sT3vN8cW5dF6gA1jL0oM2nB4Kt',
              name: 'Watcher',
              walletType: WalletType.viewOnly,
              chain: 'solana',
              balanceUsd: 95.1,
            ),
          ],
          isAnon: false,
          userId: 'u1',
          username: 'maren.studio',
        ),
      ],
      anonGroup: ProfileGroup(
        wallets: [
          WalletInfo(
            id: 'w1',
            address: '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJos9fQa',
            name: 'Wallet 1',
            walletType: WalletType.hd,
            chain: 'solana',
            balanceUsd: 1284.1,
          ),
          WalletInfo(
            id: 'w3',
            address: 'Bq2zKx7Lm4Np9Qr2St5Uv8Wx1Yz3Ab6Cd9Ef2Gh5eYa7K',
            name: 'Imported key',
            walletType: WalletType.hd,
            chain: 'solana',
            balanceUsd: 42.7,
          ),
        ],
        isAnon: true,
      ),
      activeWalletId: 'w1',
      accounts: [
        Account(id: 'a1', name: 'Main', wallets: [_wallet, second]),
      ],
    );

    Future<void> pumpPicker(
      WidgetTester tester,
      WalletDrawerState state, {
      BrowserWalletPickerShape shape = const BrowserWalletPickerShape(),
    }) async {
      _viewSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: BrowserWalletPicker(
                state: state,
                shape: shape,
                selected: _wallet,
                activeAccountId: 'a1',
                host: 'jup.ag',
                siteConnected: true,
              ),
            ),
          ),
          size: const Size(390, 844),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('shows names, addresses and their own values only', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpPicker(tester, loaded);
      await tester.pumpAndSettle();
      expect(find.text('Choose wallet'), findsOneWidget);
      expect(
        find.textContaining('Switching also changes'),
        findsNothing,
        reason: 'no sublabel',
      );
      expect(find.text('Main'), findsOneWidget);
      expect(find.text('7xKXt…s9fQa'), findsOneWidget);
      expect(find.text(r'$1,284.10'), findsOneWidget);
      expect(find.text(r'$42.70'), findsOneWidget);
      // No Account total.
      expect(find.text(r'$1,326.80'), findsNothing);
      // Every value sits at the row's right edge, whatever precedes it (the
      // selected row also carries the Connected mark).
      for (final value in [r'$1,284.10', r'$42.70']) {
        expect(
          tester.getRect(find.text(value)).right,
          closeTo(390 - 8 - 12, 0.5),
          reason: value,
        );
      }
      expect(
        find.bySemanticsLabel(
          'Main, Solana 7xKXt…s9fQa, connected to this site, selected',
        ),
        findsOneWidget,
      );
      // Only the wallet the site sees says Connected, even when the site
      // once connected others.
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Wallet 1'), findsNothing);

      await tester.tap(find.text('Profiles'));
      await tester.pumpAndSettle();
      expect(find.text('maren.studio'), findsOneWidget);
      // Only the group in use marks its wallet selected.
      expect(find.bySemanticsLabel(RegExp('selected')), findsNothing);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('9bQmZ…nB4Kt'), findsOneWidget);
      expect(find.text('Watcher'), findsNothing);
      handle.dispose();
    });

    testWidgets('lists Ethereum addresses after Solana, highlights only the '
        'pill wallet, and picks either', (tester) async {
      final handle = tester.ensureSemantics();
      const eth = WalletInfo(
        id: 'w4',
        address: '0x1111111111111111111111111111111111111111',
        name: 'Ethereum 1',
        walletType: WalletType.hd,
        chain: 'ethereum',
        accountId: 'a1',
      );
      const eth2 = WalletInfo(
        id: 'w5',
        address: '0x2222222222222222222222222222222222222222',
        name: 'Ethereum 2',
        walletType: WalletType.importedKey,
        chain: 'ethereum',
        accountId: 'a1',
      );
      // Listed out of chain order: the picker still puts Solana first.
      const account = Account(
        id: 'a1',
        name: 'Main',
        wallets: [eth, _wallet, eth2, second],
      );
      const state = WalletDrawerState.loaded(
        profileGroups: [],
        anonGroup: ProfileGroup(wallets: [], isAnon: true),
        activeWalletId: 'w1',
        accounts: [account],
      );
      BrowserWalletPicker picker({Chain? only}) => BrowserWalletPicker(
        state: state,
        selected: _wallet,
        selectedEthereum: eth,
        activeAccountId: 'a1',
        host: 'app.uniswap.org',
        ethereumConnected: true,
        onlyChain: only,
      );
      _viewSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: picker()),
          ),
          size: const Size(390, 844),
        ),
      );
      await tester.pumpAndSettle();
      final rows = [
        for (final address in [
          '7xKXt…s9fQa',
          'Bq2zK…eYa7K',
          '0x111…11111',
          '0x222…22222',
        ])
          tester.getTopLeft(find.text(address)).dy,
      ];
      expect(rows, orderedEquals([...rows]..sort()));
      expect(
        find.bySemanticsLabel('Main, Solana 7xKXt…s9fQa, selected'),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel(
          'Main, Ethereum 0x111…11111, connected to this site, selected',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r', selected$')), findsOneWidget);
      expect(find.text('Connected as 0x11…1111'), findsOneWidget);

      final picked = await open(tester, picker(), 'Main, Ethereum 0x222…22222');
      expect(picked, isA<BrowserWalletPicked>());
      expect((picked! as BrowserWalletPicked).wallet, eth2);

      // A request names its chain; the Switch picker lists only that chain.
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: picker(only: Chain.ethereum),
            ),
          ),
          size: const Size(390, 844),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('7xKXt…s9fQa'), findsNothing);
      expect(find.text('0x222…22222'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('is full screen: switching tabs keeps its height', (
      tester,
    ) async {
      await pumpPicker(tester, loaded);
      await tester.pumpAndSettle();
      final sheet = find.byType(BrowserWalletPicker);
      final accounts = tester.getSize(sheet);
      await tester.tap(find.text('Profiles'));
      await tester.pumpAndSettle();
      expect(tester.getSize(sheet), accounts);
      expect(accounts.height, greaterThan(844 * 0.85));
    });

    testWidgets('loading shows a shimmer per known group and address', (
      tester,
    ) async {
      await pumpPicker(
        tester,
        const WalletDrawerState.loading(),
        shape: const BrowserWalletPickerShape(accounts: [2, 1], profiles: [3]),
      );
      // Two groups (avatar + name) plus three addresses (address + value).
      expect(find.byType(ShimmerBox), findsNWidgets(2 * 2 + 3 * 2));
      await tester.tap(find.text('Profiles'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ShimmerBox), findsNWidgets(1 * 2 + 3 * 2));
    });
  });

  group('tab switcher', () {
    testWidgets('is a popup over the page, never a covering page route', (
      tester,
    ) async {
      final session = await _session();
      session.open(Uri.parse('https://jup.ag'));
      final navigator = GlobalKey<NavigatorState>();
      final page = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: MallowTheme.lightTheme,
          navigatorKey: navigator,
          navigatorObservers: [browserPageRouteObserver],
          home: Scaffold(key: page),
        ),
      );
      final events = _RouteEvents();
      browserPageRouteObserver.subscribe(
        events,
        ModalRoute.of(page.currentContext!)! as PageRoute<dynamic>,
      );
      final route = browserTabSwitcherRoute(
        session: session,
        connectedTabs: const {},
        onClose: (_) {},
      );
      expect(route, isA<PopupRoute<String>>());
      unawaited(navigator.currentState!.push(route));
      await tester.pumpAndSettle();
      expect(events.covered, 0);
      browserPageRouteObserver.unsubscribe(events);
    });

    testWidgets('selects, closes and opens tabs', (tester) async {
      _viewSize(tester, const Size(390, 844));
      final handle = tester.ensureSemantics();
      final session = await _session();
      session.open(Uri.parse('https://jup.ag/swap'));
      final jup = session.activeId!;
      session.update(jup, title: 'Swap');
      session.open(Uri.parse('https://mallow.art'));
      final mallow = session.activeId!;
      final closed = <String>[];
      String? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    result = await Navigator.of(context).push(
                      browserTabSwitcherRoute(
                        session: session,
                        connectedTabs: {jup},
                        onClose: closed.add,
                      ),
                    ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('2 tabs'), findsOneWidget);
      // The site and its close button head each card.
      expect(
        tester.getCenter(find.bySemanticsLabel('Close jup.ag, Swap')).dy,
        lessThan(
          tester.getCenter(find.bySemanticsLabel('Show jup.ag, Swap')).dy,
        ),
      );
      // Only the connected tab's tile carries the dot.
      expect(find.byKey(const Key('site-tile-connected')), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Close jup.ag, Swap'));
      expect(closed, [jup]);
      await tester.tap(find.bySemanticsLabel('Show jup.ag, Swap'));
      await tester.pumpAndSettle();
      expect(result, jup);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tab-switcher-new-tab')));
      await tester.pumpAndSettle();
      expect(result, browserNewTab);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tab-switcher-done')));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(session.activeId, mallow, reason: 'the switcher never selects');
      handle.dispose();
    });

    testWidgets('shows only in-memory thumbnails, and not once cleared', (
      tester,
    ) async {
      final session = await _session();
      session.open(Uri.parse('https://jup.ag'));
      final id = session.activeId!;
      // A 1x1 transparent PNG.
      session.setThumbnail(
        id,
        Uint8List.fromList(const [
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, //
          0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
          0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
          0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63,
          0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
          0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
          0x82,
        ]),
      );
      await tester.pumpWidget(
        _app(
          BrowserTabSwitcher(
            session: session,
            connectedTabs: const {},
            onClose: (_) {},
          ),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      session.clearThumbnails();
      await tester.pump();
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('fits 320 dp at 2x text', (tester) async {
      _viewSize(tester, const Size(320, 640));
      final session = await _session();
      session.open(Uri.parse('https://jup.ag'));
      session.update(session.activeId!, title: 'A long page title');
      session.open(null);
      await tester.pumpWidget(
        _app(
          BrowserTabSwitcher(
            session: session,
            connectedTabs: const {},
            onClose: (_) {},
          ),
          size: const Size(320, 640),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('status toast', () {
    for (final confirmed in [false, true]) {
      testWidgets('Close dismisses a ${confirmed ? 'confirmed' : 'pending'} '
          'transaction and keeps it hidden', (tester) async {
        _viewSize(tester, const Size(320, 640));
        final tracker = BrowserTransactionTracker(
          interval: const Duration(milliseconds: 10),
        );
        addTearDown(tracker.dispose);
        final calls = _Calls();
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: BrowserTransactionToast(
                  tracker: tracker,
                  onView: (_) => calls.log.add('view'),
                  child: _address(calls, compact: true),
                ),
              ),
            ),
            textScale: 2,
          ),
        );
        final lookup = Completer<Object?>();
        void confirm() => lookup.complete({
          'value': [
            {'confirmationStatus': 'confirmed', 'err': null, 'slot': 1},
          ],
        });
        tracker.start(
          signature: 'sig-dismiss',
          chain: 'solana:mainnet',
          lookup: (_, _) => lookup.future,
        );
        await tester.pump();
        await tester.pump(MallowTheme.sheetDuration);
        if (confirmed) {
          confirm();
          await tester.pump();
        }
        await tester.tap(find.bySemanticsLabel('Close transaction status'));
        await tester.pumpAndSettle();
        expect(find.byType(BrowserStatusToast), findsNothing);
        expect(calls.log, isEmpty);
        await tester.tap(find.bySemanticsLabel('jup.ag. Show toolbar'));
        expect(calls.log, ['expand']);

        if (!confirmed) confirm();
        await tester.pump();
        await tester.pump(const Duration(seconds: 6));
        expect(find.byType(BrowserStatusToast), findsNothing);
        expect(
          tracker.records.single.status,
          BrowserTransactionStatus.confirmed,
        );

        tracker.start(
          signature: 'sig-next',
          chain: 'solana:mainnet',
          lookup: (_, _) async => null,
        );
        await tester.pump();
        await tester.pump(MallowTheme.sheetDuration);
        expect(find.byType(BrowserStatusToast), findsOneWidget);
        expect(tester.takeException(), isNull);
        tracker.clear();
        await tester.pumpAndSettle();
      });
    }

    for (final compact in [false, true]) {
      testWidgets(
        'replaces the ${compact ? 'compact' : 'expanded'} address bar and restores it',
        (tester) async {
          _viewSize(tester, const Size(320, 640));
          final semantics = tester.ensureSemantics();
          final tracker = BrowserTransactionTracker(
            interval: const Duration(milliseconds: 10),
          );
          addTearDown(tracker.dispose);
          final calls = _Calls();
          final viewed = <String>[];
          final addressLabel = compact
              ? 'jup.ag. Show toolbar'
              : 'Edit address, jup.ag';
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: Align(
                  alignment: Alignment.topCenter,
                  child: MediaQuery(
                    data: const MediaQueryData(
                      size: Size(320, 640),
                      padding: EdgeInsets.only(top: 24),
                      textScaler: TextScaler.linear(2),
                    ),
                    child: BrowserTransactionToast(
                      tracker: tracker,
                      onView: (record) => viewed.add(record.signature),
                      child: _address(calls, compact: compact),
                    ),
                  ),
                ),
                bottomNavigationBar: _bar(calls),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final addressBarState = tester.element(
            find.byType(BrowserAddressBar),
          );
          expect(find.semantics.byLabel(addressLabel), findsOneWidget);

          final lookup = Completer<Object?>();
          tracker.start(
            signature: 'sig-top',
            chain: 'solana:mainnet',
            lookup: (_, _) => lookup.future,
          );
          await tester.pump();
          await tester.pump(MallowTheme.sheetDuration);
          expect(find.semantics.byLabel(addressLabel), findsNothing);
          final pill = tester.getRect(find.byType(BrowserStatusToast));
          expect(pill.top, 30);
          expect(pill.bottom, lessThan(150));
          expect(find.bySemanticsLabel('Minimise browser'), findsOneWidget);
          await tester.tap(find.bySemanticsLabel('View transaction'));
          expect(viewed, ['sig-top']);
          expect(calls.log, isEmpty);
          expect(tester.takeException(), isNull);

          lookup.complete({
            'value': [
              {'confirmationStatus': 'confirmed', 'err': null, 'slot': 1},
            ],
          });
          await tester.pump();
          expect(find.text('Transaction confirmed'), findsOneWidget);
          await tester.pump(const Duration(seconds: 6));
          await tester.pumpAndSettle();
          expect(find.byType(BrowserStatusToast), findsNothing);
          expect(find.semantics.byLabel(addressLabel), findsOneWidget);
          expect(
            tester.element(find.byType(BrowserAddressBar)),
            same(addressBarState),
          );
          await tester.tap(find.bySemanticsLabel(addressLabel));
          expect(calls.log, [compact ? 'expand' : 'address']);
          semantics.dispose();
        },
      );
    }

    testWidgets('uses only fades when reduced motion is enabled', (
      tester,
    ) async {
      _viewSize(tester, const Size(390, 640));
      final tracker = BrowserTransactionTracker();
      addTearDown(tracker.dispose);
      await tester.pumpWidget(
        _app(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 640),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: BrowserTransactionToast(
                  tracker: tracker,
                  onView: (_) {},
                  child: _address(_Calls(), compact: true),
                ),
              ),
            ),
          ),
        ),
      );
      tracker.start(
        signature: 'sig-reduced',
        chain: 'solana:mainnet',
        lookup: (_, _) async => null,
      );
      await tester.pump();
      await tester.pump(MallowTheme.sheetDuration ~/ 2);
      expect(
        tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset,
        Offset.zero,
      );
      for (final slide in tester.widgetList<SlideTransition>(
        find.descendant(
          of: find.byType(BrowserTransactionToast),
          matching: find.byType(SlideTransition),
        ),
      )) {
        expect(slide.position.value, Offset.zero);
      }
      expect(tester.takeException(), isNull);
      tracker.clear();
      await tester.pumpAndSettle();
    });

    testWidgets('follows a new transaction and then steps aside', (
      tester,
    ) async {
      final tracker = BrowserTransactionTracker(
        interval: const Duration(milliseconds: 10),
      );
      addTearDown(tracker.dispose);
      final viewed = <String>[];
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: BrowserTransactionToast(
                tracker: tracker,
                onView: (record) => viewed.add(record.signature),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(BrowserStatusToast), findsNothing);
      final lookup = Completer<Object?>();
      tracker.start(
        signature: 'sig1',
        chain: 'solana:mainnet',
        lookup: (_, _) => lookup.future,
      );
      await tester.pump();
      await tester.pump(MallowTheme.sheetDuration);
      expect(find.text('Transaction sent · Confirming'), findsOneWidget);
      await tester.tap(find.text('View'));
      expect(viewed, ['sig1']);

      await tester.pump(const Duration(milliseconds: 20));
      lookup.complete({
        'value': [
          {'confirmationStatus': 'confirmed', 'err': null, 'slot': 1},
        ],
      });
      await tester.pump();
      await tester.pump(MallowTheme.sheetDuration);
      expect(find.text('Transaction confirmed'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserStatusToast), findsNothing);
    });

    testWidgets('an outcome it never saw pending is not announced', (
      tester,
    ) async {
      final tracker = BrowserTransactionTracker();
      addTearDown(tracker.dispose);
      tracker.start(
        signature: 'old',
        chain: 'solana:mainnet',
        lookup: (_, _) async => null,
      );
      tracker.markRejected('solana:mainnet', 'old');
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: BrowserTransactionToast(tracker: tracker, onView: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BrowserStatusToast), findsNothing);
    });
  });

  group('address field', () {
    testWidgets(
      'selects the URL, rejects unsafe input and opens a parsed URL',
      (tester) async {
        _viewSize(tester, const Size(320, 640));
        Uri? result;
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: BrowserAddressField(
                  initial: 'https://jup.ag/',
                  onOpen: (uri) => result = uri,
                ),
              ),
            ),
            textScale: 1.5,
          ),
        );
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byKey(const Key('browser-address-field')),
          matching: find.byType(TextField),
        );
        expect(tester.testTextInput.isVisible, isTrue);
        expect(
          tester.widget<TextField>(field).controller!.selection,
          const TextSelection(baseOffset: 0, extentOffset: 15),
        );
        await tester.enterText(field, 'http://insecure.example');
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(
          find.text('Only HTTPS websites without credentials are supported'),
          findsOneWidget,
        );
        expect(result, isNull);
        await tester.enterText(field, 'example.com');
        await tester.pump();
        expect(
          find.text('Only HTTPS websites without credentials are supported'),
          findsNothing,
        );
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(result, Uri.parse('https://example.com'));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('clear removes the URL and validation error, keeping focus', (
      tester,
    ) async {
      _viewSize(tester, const Size(320, 640));
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: BrowserAddressField(
              initial: 'https://example.com/',
              onOpen: (_) {},
            ),
          ),
          dark: true,
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      await tester.enterText(field, 'http://example.com');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      final semantics = tester.ensureSemantics();
      try {
        await tester.tap(find.bySemanticsLabel('Clear'));
        await tester.pump();
      } finally {
        semantics.dispose();
      }
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(
        find.text('Only HTTPS websites without credentials are supported'),
        findsNothing,
      );
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('lock cover shows the mark and nothing of the page', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const BrowserLockCover()));
    expect(find.bySemanticsLabel('Website hidden'), findsOneWidget);
    expect(find.byType(Icon), findsNothing);
    handle.dispose();
  });
}

class _RouteEvents with RouteAware {
  int covered = 0;
  @override
  void didPushNext() => covered++;
}
