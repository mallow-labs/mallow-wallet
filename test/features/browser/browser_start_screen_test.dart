import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/screens/browser_start_screen.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/dapp_permission_service.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_site_tile.dart';
import 'package:mallow_wallet/features/browser/widgets/start_bookmark_grid.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_pill_field.dart';

const _address = '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU';
const _wallet = WalletInfo(
  id: 'w2',
  address: _address,
  name: 'Wallet 2',
  walletType: WalletType.hd,
  chain: 'solana',
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

DappPermissionService _grants(String origins) =>
    DappPermissionService(read: () async => origins, write: (_) async {});

final _bookmark = BrowserBookmark(
  url: Uri.parse('https://bookmarked.example/path'),
  title: 'Saved site',
);

class _FakeWalletRepository extends Fake implements WalletRepository {
  _FakeWalletRepository(this.wallets);

  List<WalletInfo> wallets;
  bool readFails = false;

  @override
  final walletsRevision = ValueNotifier(0);

  @override
  Future<List<WalletInfo>> getAllWallets() async {
    if (readFails) throw StateError('Wallets unavailable');
    return wallets;
  }
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(body: screen),
    ),
  );
  await tester.pumpAndSettle();
}

/// Sheets ignore taps for a moment after they settle.
Future<void> _settleSheet(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  for (final inBrowser in [false, true]) {
    for (final chains in [
      <String>[],
      ['ethereum'],
      ['tezos'],
      ['ethereum', 'tezos'],
    ]) {
      testWidgets(
        'popular catalogs match device wallets $chains (inBrowser: $inBrowser)',
        (tester) async {
          final session = (await tester.runAsync(_session))!;
          final repository = _FakeWalletRepository([
            for (final chain in chains)
              _wallet.copyWith(id: chain, chain: chain),
          ]);
          addTearDown(repository.walletsRevision.dispose);
          await _pump(
            tester,
            BrowserStartScreen(
              session: session,
              inBrowser: inBrowser,
              walletRepository: repository,
              onOpen: (_) {},
            ),
          );

          final solana = find.text('Popular on Solana');
          expect(solana, findsOneWidget);
          expect(find.text('Jupiter'), findsOneWidget);
          for (final (chain, title, site) in [
            ('ethereum', 'Popular on Ethereum', 'OpenSea'),
            ('tezos', 'Popular on Tezos', 'objkt'),
          ]) {
            final visible = chains.contains(chain);
            expect(find.text(title), visible ? findsOneWidget : findsNothing);
            expect(find.text(site), visible ? findsOneWidget : findsNothing);
            if (visible) {
              expect(
                tester.getTopLeft(solana).dy,
                lessThan(tester.getTopLeft(find.text(title)).dy),
              );
            }
          }
        },
      );
    }
  }

  testWidgets('popular catalogs update when device wallets change', (
    tester,
  ) async {
    final session = (await tester.runAsync(_session))!;
    final repository = _FakeWalletRepository([]);
    addTearDown(repository.walletsRevision.dispose);
    await _pump(
      tester,
      BrowserStartScreen(
        session: session,
        inBrowser: true,
        walletRepository: repository,
        onOpen: (_) {},
      ),
    );

    repository.wallets = [_wallet.copyWith(chain: 'ethereum')];
    repository.walletsRevision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Popular on Ethereum'), findsOneWidget);
    expect(find.text('Popular on Tezos'), findsNothing);

    repository.wallets = [_wallet.copyWith(chain: 'tezos')];
    repository.walletsRevision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Popular on Ethereum'), findsNothing);
    expect(find.text('Popular on Tezos'), findsOneWidget);

    repository.wallets = [];
    repository.walletsRevision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Popular on Ethereum'), findsNothing);
    expect(find.text('Popular on Tezos'), findsNothing);
    expect(find.text('Popular on Solana'), findsOneWidget);
  });

  testWidgets('a wallet read failure hides optional catalogs', (tester) async {
    final session = (await tester.runAsync(_session))!;
    final repository = _FakeWalletRepository([
      _wallet.copyWith(chain: 'ethereum'),
    ]);
    addTearDown(repository.walletsRevision.dispose);
    await _pump(
      tester,
      BrowserStartScreen(
        session: session,
        walletRepository: repository,
        onOpen: (_) {},
      ),
    );
    expect(find.text('Popular on Ethereum'), findsOneWidget);

    repository.readFails = true;
    repository.walletsRevision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Popular on Ethereum'), findsNothing);
    expect(find.text('Popular on Tezos'), findsNothing);
    expect(find.text('Popular on Solana'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continue card shows the active tab and its connection', (
    tester,
  ) async {
    final session = (await tester.runAsync(_session))!;
    session.open(Uri.parse('https://mallow.art/'));
    session.open(Uri.parse('https://jup.ag/swap'));
    session.update(session.activeId!, title: 'Swap');
    await _pump(
      tester,
      BrowserStartScreen(
        session: session,
        activeWallet: () async => _wallet,
        permissions: _grants(
          '[{"origin":"https://jup.ag","address":"$_address",'
          '"createdAt":"2026-01-01T00:00:00Z"}]',
        ),
      ),
    );
    expect(find.text('Continue browsing'), findsOneWidget);
    expect(find.text('2 tabs'), findsOneWidget);
    // Named by its owner, or its short address outside a session; never by
    // the wallet's stored label.
    expect(find.text('Connected with 7xKX…gAsU'), findsOneWidget);
    expect(find.text('Connected with Wallet 2'), findsNothing);

    session.select(session.tabs.first.id);
    await tester.pumpAndSettle();
    expect(find.text('Connected with 7xKX…gAsU'), findsNothing);
  });

  testWidgets('the tab count opens the tab switcher over the start page', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final session = (await tester.runAsync(_session))!;
    session.open(Uri.parse('https://mallow.art/'));
    session.open(Uri.parse('https://jup.ag/swap'));
    final jup = session.activeId!;
    await _pump(
      tester,
      BrowserStartScreen(
        session: session,
        activeWallet: () async => _wallet,
        permissions: _grants(
          '[{"origin":"https://jup.ag","address":"$_address",'
          '"createdAt":"2026-01-01T00:00:00Z"}]',
        ),
      ),
    );
    // The count is its own button, not part of the card's label.
    expect(find.bySemanticsLabel('2 open tabs'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'Continue browsing.*tabs')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('start-continue-tabs')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tab-switcher-done')), findsOneWidget);
    expect(find.byKey(const Key('site-tile-connected')), findsOneWidget);
    expect(session.activeId, jup);

    // Done comes back to the start page without entering the browser.
    await tester.tap(find.byKey(const Key('tab-switcher-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tab-switcher-done')), findsNothing);
    expect(find.text('Continue browsing'), findsOneWidget);

    // Closing the last tab leaves the switcher for the empty start page.
    await tester.tap(find.byKey(const Key('start-continue-tabs')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Close jup.ag'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tab-switcher-done')), findsOneWidget);
    // The top-anchored Undo snack bar covers the card heads until it ends.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Close mallow.art'));
    await tester.pumpAndSettle();
    expect(session.tabs, isEmpty);
    expect(find.byKey(const Key('tab-switcher-done')), findsNothing);
    expect(find.text('Continue browsing'), findsNothing);
    // Let the Undo snack bar time out.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    handle.dispose();
  });

  testWidgets('a new tab inside the browser has no continue card', (
    tester,
  ) async {
    final session = (await tester.runAsync(_session))!;
    session.open(Uri.parse('https://jup.ag/'));
    await _pump(
      tester,
      BrowserStartScreen(session: session, inBrowser: true, onOpen: (_) {}),
    );
    expect(find.text('Continue browsing'), findsNothing);
    // The search field is the tab's address bar, with the gear inside it.
    expect(find.text('Where to next?'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(MallowPillField),
        matching: find.byTooltip('Browser settings'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the browser tab keeps its title row and gear', (tester) async {
    final session = (await tester.runAsync(_session))!;
    await _pump(tester, BrowserStartScreen(session: session, onOpen: (_) {}));
    expect(find.text('Where to next?'), findsOneWidget);
    expect(find.byTooltip('Browser settings'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MallowPillField),
        matching: find.byTooltip('Browser settings'),
      ),
      findsNothing,
    );
  });

  testWidgets('bookmark menu opens a new tab through its own callback', (
    tester,
  ) async {
    final session = (await tester.runAsync(_session))!;
    session.bookmark(_bookmark);
    Uri? opened;
    Uri? openedInNewTab;
    await _pump(
      tester,
      BrowserStartScreen(
        inBrowser: true,
        session: session,
        onOpen: (uri) => opened = uri,
        onOpenNewTab: (uri) => openedInNewTab = uri,
      ),
    );
    await tester.longPress(find.text(_bookmark.title));
    await _settleSheet(tester);
    await tester.tap(find.text('Open in new tab'));
    await tester.pumpAndSettle();
    expect(opened, isNull);
    expect(openedInNewTab, _bookmark.url);
  });

  testWidgets('bookmarks match Popular tiles and tap opens the saved page', (
    tester,
  ) async {
    final session = (await tester.runAsync(_session))!;
    session.bookmark(_bookmark);
    Uri? opened;
    await _pump(
      tester,
      BrowserStartScreen(
        session: session,
        inBrowser: true,
        onOpen: (uri) => opened = uri,
      ),
    );
    final grid = find.byType(StartBookmarkGrid);
    final tile = tester.widget<BrowserSiteTile>(
      find.descendant(of: grid, matching: find.byType(BrowserSiteTile)),
    );
    expect(tile.size, 60);
    expect(tile.host, _bookmark.url.host);
    expect(find.byTooltip('Bookmark actions'), findsNothing);
    await tester.tap(find.text(_bookmark.title));
    await tester.pumpAndSettle();
    expect(opened, _bookmark.url);
  });

  testWidgets(
    'long press enters reorder mode, drag moves across rows, Done restores taps',
    (tester) async {
      final session = (await tester.runAsync(_session))!;
      final bookmarks = [
        _bookmark,
        for (var i = 1; i <= 5; i++)
          BrowserBookmark(
            url: Uri.parse('https://saved$i.example'),
            title: 'Saved $i',
          ),
      ];
      for (final bookmark in bookmarks) {
        session.bookmark(bookmark);
      }
      Uri? opened;
      await _pump(
        tester,
        BrowserStartScreen(
          session: session,
          inBrowser: true,
          onOpen: (uri) => opened = uri,
        ),
      );
      await tester.longPress(find.text(_bookmark.title));
      await _settleSheet(tester);
      expect(find.text('Open in new tab'), findsOneWidget);
      expect(find.text('Edit bookmark'), findsOneWidget);
      expect(find.text('Remove bookmark'), findsOneWidget);
      await tester.tap(find.text('Reorder bookmarks'));
      await tester.pumpAndSettle();
      expect(find.text('Drag bookmarks to reorder'), findsOneWidget);
      await tester.tap(find.text(_bookmark.title));
      await tester.pumpAndSettle();
      expect(opened, isNull);

      final first = find.byKey(ValueKey(_bookmark.url));
      final last = find.byKey(ValueKey(bookmarks.last.url));
      await tester.drag(
        first,
        tester.getCenter(last) - tester.getCenter(first),
      );
      await tester.pumpAndSettle();
      expect(session.bookmarks.map((b) => b.url), [
        ...bookmarks.skip(1).map((b) => b.url),
        _bookmark.url,
      ]);

      // A cancelled drop outside the grid does not change the saved order.
      final beforeCancel = session.bookmarks.map((b) => b.url).toList();
      await tester.drag(first, const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect(session.bookmarks.map((b) => b.url), beforeCancel);

      final newFirst = find.byKey(ValueKey(bookmarks[1].url));
      await tester.drag(
        first,
        tester.getCenter(newFirst) - tester.getCenter(first),
      );
      await tester.pumpAndSettle();
      expect(session.bookmarks.map((b) => b.url), bookmarks.map((b) => b.url));

      await tester.tap(find.byKey(const Key('bookmark-reorder-done')));
      await tester.pumpAndSettle();
      expect(find.text('Drag bookmarks to reorder'), findsNothing);
      expect(find.byType(Draggable<Uri>), findsNothing);
      await tester.tap(find.text(_bookmark.title));
      await tester.pumpAndSettle();
      expect(opened, _bookmark.url);
    },
  );

  testWidgets('bookmark edit validates, keeps the icon only on the same host', (
    tester,
  ) async {
    final session = (await tester.runAsync(_session))!;
    session.bookmark(
      BrowserBookmark(
        url: _bookmark.url,
        title: _bookmark.title,
        iconUrl: Uri.parse('https://bookmarked.example/icon.png'),
      ),
    );
    await _pump(
      tester,
      BrowserStartScreen(session: session, inBrowser: true, onOpen: (_) {}),
    );
    await tester.longPress(find.text(_bookmark.title));
    await _settleSheet(tester);
    await tester.tap(find.text('Edit bookmark'));
    await _settleSheet(tester);

    final url = find.descendant(
      of: find.byKey(const Key('bookmark-url')),
      matching: find.byType(TextField),
    );
    await tester.enterText(url, 'http://insecure.example');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(
      find.text('Enter an HTTPS address without credentials'),
      findsOneWidget,
    );

    await tester.enterText(url, 'https://bookmarked.example/other');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('bookmark-name')),
        matching: find.byType(TextField),
      ),
      'Renamed',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = session.bookmarks.single;
    expect(saved.title, 'Renamed');
    expect(saved.url, Uri.parse('https://bookmarked.example/other'));
    expect(saved.iconUrl, isNotNull);
    expect(find.text('Renamed'), findsOneWidget);
  });

  testWidgets('bookmark can be removed', (tester) async {
    final session = (await tester.runAsync(_session))!;
    session.bookmark(_bookmark);
    await _pump(
      tester,
      BrowserStartScreen(session: session, inBrowser: true, onOpen: (_) {}),
    );
    await tester.longPress(find.text(_bookmark.title));
    await _settleSheet(tester);
    await tester.tap(find.text('Remove bookmark'));
    await tester.pumpAndSettle();
    expect(session.bookmarks, isEmpty);
    expect(find.text('Bookmarks'), findsNothing);
  });

  testWidgets('no bookmarks hides the bookmarks section', (tester) async {
    final session = (await tester.runAsync(_session))!;
    await _pump(
      tester,
      BrowserStartScreen(session: session, inBrowser: true, onOpen: (_) {}),
    );
    expect(find.text('Bookmarks'), findsNothing);
    expect(find.text('Popular on Solana'), findsOneWidget);
  });

  testWidgets('invalid input shows an inline error that clears on typing', (
    tester,
  ) async {
    final session = (await tester.runAsync(_session))!;
    await _pump(
      tester,
      BrowserStartScreen(session: session, inBrowser: true, onOpen: (_) {}),
    );
    await tester.enterText(find.byType(TextField), 'http://example.com');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(
      find.text('Only HTTPS websites without credentials are supported'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'example.com');
    await tester.pump();
    expect(
      find.text('Only HTTPS websites without credentials are supported'),
      findsNothing,
    );
  });
}
