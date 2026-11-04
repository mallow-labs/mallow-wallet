import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/screens/browser_start_screen.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/bottom_nav_bar.dart';

void main() {
  testWidgets('four destinations and action fit 320dp with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final handle = tester.ensureSemantics();
    MallowNavTab? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            bottomNavigationBar: MallowBottomNavBar(
              currentTab: MallowNavTab.home,
              onTabSelected: (tab) => selected = tab,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.bySemanticsLabel('Browser'));
    expect(selected, MallowNavTab.browser);
    expect(find.bySemanticsLabel('Home'), findsOneWidget);
    expect(find.bySemanticsLabel('Portfolio'), findsOneWidget);
    expect(find.bySemanticsLabel('Tokens'), findsOneWidget);
    handle.dispose();
  });
  testWidgets('start page wraps catalog and searches at 320dp large text', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession(
      BrowserRepository(
        SecureWalletStorage(const FlutterSecureStorage(), MnemonicVault()),
      ),
    );
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.darkTheme,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: BrowserStartScreen(
              session: session,
              onOpen: (uri) => opened = uri,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The catalog sits below the bookmarks section, so at this size it
    // starts below the fold; scroll it in as a user would.
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('mallow.art'),
      200,
      scrollable: scrollable,
    );
    await tester.scrollUntilVisible(
      find.text('Jupiter'),
      200,
      scrollable: scrollable,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('mallow.art'), findsOneWidget);
    expect(find.text('Jupiter'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(TextField),
      -200,
      scrollable: scrollable,
    );
    await tester.enterText(find.byType(TextField), 'art on Solana');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    expect(opened?.host, 'duckduckgo.com');
    expect(tester.takeException(), isNull);
  });

  testWidgets('bookmark menu uses the distinct new-tab callback', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession(
      BrowserRepository(
        SecureWalletStorage(const FlutterSecureStorage(), MnemonicVault()),
      ),
    );
    await session.load();
    final bookmark = BrowserBookmark(
      url: Uri.parse('https://bookmarked.example/path'),
      title: 'Saved site',
    );
    session.bookmark(bookmark);
    Uri? opened;
    Uri? openedInNewTab;

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: BrowserStartScreen(
            inBrowser: true,
            session: session,
            onOpen: (uri) => opened = uri,
            onOpenNewTab: (uri) => openedInNewTab = uri,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.longPress(find.text(bookmark.title));
    await tester.pumpAndSettle();
    // Sheets ignore taps briefly after their entrance settles.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Open in new tab'));
    await tester.pumpAndSettle();

    expect(opened, isNull);
    expect(openedInNewTab, bookmark.url);
  });

  testWidgets('browser kill switch removes browser destination', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          bottomNavigationBar: MallowBottomNavBar(
            currentTab: MallowNavTab.home,
            showBrowser: false,
            onTabSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Browser'), findsNothing);
    handle.dispose();
  });
}
