import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/screens/browser_settings_screen.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/services/browser_data_clearer.dart';
import 'package:mallow_wallet/features/browser/services/browser_services.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/dapp_permission_service.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_settings_rows.dart';
import 'package:mallow_wallet/features/settings/widgets/settings_menu_item.dart';
import 'package:mallow_wallet/shared/widgets/tappable.dart';
import 'package:mocktail/mocktail.dart';

class _MockBrowserDataClearer extends Mock implements BrowserDataClearer {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    BrowserTransactionTracker.instance.clear();
  });

  testWidgets('failed clear stays visible and can be retried', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final clearer = _MockBrowserDataClearer();
    var attempts = 0;
    when(
      () =>
          clearer.clearBrowsingData(keepBookmarks: any(named: 'keepBookmarks')),
    ).thenAnswer((_) async {
      attempts++;
      return attempts == 1
          ? const [BrowserDataClearFailure('session', 'StateError')]
          : const [];
    });
    await tester.pumpWidget(
      MaterialApp(home: BrowserSettingsScreen(dataClearer: clearer)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear browsing data'));
    await tester.pumpAndSettle();
    // Sheets ignore taps for a moment after they settle.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Clear data'));
    await tester.pumpAndSettle();

    expect(
      find.text('Some browsing data could not be cleared. Please try again.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Clear browsing data'));
    await tester.pumpAndSettle();
    // Sheets ignore taps for a moment after they settle.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Clear data'));
    await tester.pumpAndSettle();

    expect(
      find.text('Some browsing data could not be cleared. Please try again.'),
      findsNothing,
    );
    expect(attempts, 2);
  });

  testWidgets('clear sheet passes the keep-bookmarks choice', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final clearer = _MockBrowserDataClearer();
    when(
      () =>
          clearer.clearBrowsingData(keepBookmarks: any(named: 'keepBookmarks')),
    ).thenAnswer((_) async => const []);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserSettingsScreen(
          dataClearer: clearer,
          permissions: DappPermissionService(
            read: () async => null,
            write: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear browsing data'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    verifyNever(
      () =>
          clearer.clearBrowsingData(keepBookmarks: any(named: 'keepBookmarks')),
    );

    await tester.tap(find.text('Clear browsing data'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('keep-bookmarks')));
    await tester.pump();
    await tester.tap(find.text('Clear data'));
    await tester.pumpAndSettle();
    verify(() => clearer.clearBrowsingData(keepBookmarks: false)).called(1);
  });

  testWidgets('disconnect asks first, then revokes that grant', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var stored =
        '[{"origin":"https://jup.ag","address":"$_address","createdAt":"2026-01-01T00:00:00Z"}]';
    final permissions = DappPermissionService(
      read: () async => stored,
      write: (value) async => stored = value,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserSettingsScreen(
          dataClearer: _MockBrowserDataClearer(),
          permissions: permissions,
          accounts: () async => const [
            Account(
              id: 'a',
              name: 'Main',
              wallets: [
                WalletInfo(
                  id: 'w',
                  address: _address,
                  name: 'Wallet 2',
                  walletType: WalletType.hd,
                  chain: 'solana',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The hub counts the connected sites and opens them on their own screen.
    expect(_badgeOf('Connected sites'), findsOneWidget);
    await tester.tap(find.text('Connected sites'));
    await tester.pumpAndSettle();
    expect(find.text('jup.ag'), findsOneWidget);
    // The Account's name, never the wallet's own label.
    expect(find.textContaining('Main'), findsOneWidget);
    expect(find.textContaining('Wallet 2'), findsNothing);

    await tester.tap(_disconnectButton);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await permissions.list(), hasLength(1));

    await tester.tap(_disconnectButton);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(await permissions.list(), isEmpty);
    expect(find.text('No connected sites'), findsOneWidget);

    // The header's title is its back control.
    await tester.tap(find.text('Connected sites'));
    await tester.pumpAndSettle();
    expect(find.text('Browser settings'), findsOneWidget);
    expect(_badgeOf('Connected sites'), findsNothing);
  });

  testWidgets('recent transactions open on their own screen', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserSettingsScreen(
          dataClearer: _MockBrowserDataClearer(),
          permissions: DappPermissionService(
            read: () async => null,
            write: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No recent browser transactions'), findsNothing);

    await tester.tap(find.text('Recent transactions'));
    await tester.pumpAndSettle();
    expect(find.text('No recent browser transactions'), findsOneWidget);
  });

  testWidgets('the search engine can be switched to Google and back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(
      () => browserSearchEngine.value = BrowserSearchEngine.duckDuckGo,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserSettingsScreen(
          dataClearer: _MockBrowserDataClearer(),
          permissions: DappPermissionService(
            read: () async => null,
            write: (_) async {},
          ),
          accounts: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('DuckDuckGo'), findsOneWidget);
    await tester.tap(find.text('Search engine'));
    await tester.pumpAndSettle();
    // Sheets ignore taps for a moment after they settle.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    expect(browserSearchEngine.value, BrowserSearchEngine.google);
    expect(find.text('Google'), findsOneWidget);
    expect(
      browserInputUri(
        'solana art',
        engine: browserSearchEngine.value,
      ).toString(),
      'https://www.google.com/search?q=solana+art',
    );
  });
}

final _disconnectButton = find.descendant(
  of: find.byType(ConnectedSiteRow),
  matching: find.byType(Tappable),
);

Finder _badgeOf(String label) => find.descendant(
  of: find.ancestor(
    of: find.text(label),
    matching: find.byType(BrowserSettingsRow),
  ),
  matching: find.byType(SettingsBadgePill),
);

const _address = '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU';
