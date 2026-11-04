import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/widgets/dapp_connect_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';

DappConnectionRequest _request({bool canSign = true, bool? canSignMessages}) =>
    DappConnectionRequest(
      context: DappFrameContext(
        tabId: 'tab',
        generation: 1,
        origin: Uri.parse('https://jup.ag'),
        isMainFrame: true,
        isActive: true,
      ),
      wallet: DappWallet(
        id: 'w',
        address: '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU',
        canSign: canSign,
        canSignMessages: canSignMessages,
      ),
      cancelled: Completer<void>().future,
      ensureActive: () {},
    );

void main() {
  Future<Future<bool?>> open(
    WidgetTester tester, [
    DappConnectionRequest? request,
    VoidCallback? onSwitch,
  ]) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (context) {
            host = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final route = dappConnectRoute(
      context: host,
      request: request ?? _request(),
      onSwitch: onSwitch,
    );
    expect(route, isA<PopupRoute<bool>>());
    final result = Navigator.of(host).push(route);
    await tester.pumpAndSettle();
    // Sheets swallow taps until a short settle timer after the entrance.
    await tester.pump(const Duration(milliseconds: 200));
    return result;
  }

  for (final (key, expected) in [
    ('approve-connect', true),
    ('reject-connect', false),
  ]) {
    testWidgets('$key pops $expected and shows the native origin', (
      tester,
    ) async {
      final result = await open(tester);
      expect(find.text('https://jup.ag'), findsOneWidget);
      expect(find.text('Connect to jup.ag?'), findsOneWidget);
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(await result, expected);
    });
  }

  testWidgets('Switch offers another wallet and names none by its label', (
    tester,
  ) async {
    var switched = 0;
    final result = await open(tester, null, () => switched++);
    // Outside a session there is no Account or Profile name: the short
    // address stands in, never a wallet label or a generic placeholder.
    expect(find.text('7xKX…gAsU'), findsOneWidget);
    expect(find.text('Solana wallet'), findsNothing);
    await tester.tap(find.byKey(const Key('connect-switch-wallet')));
    await tester.pumpAndSettle();
    expect(switched, 1);
    // Switching is the caller's to resolve; the sheet stays up.
    expect(find.text('Connect to jup.ag?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reject-connect')));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('without a switch handler there is no Switch', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('connect-switch-wallet')), findsNothing);
  });

  testWidgets('dismissing the sheet pops null', (tester) async {
    final result = await open(tester);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  for (final (label, request, expected, absent) in [
    (
      'full signing',
      _request(),
      'Request transactions and signatures',
      "Can't request signatures",
    ),
    (
      'transactions only',
      _request(canSignMessages: false),
      'Request transactions',
      'Request transactions and signatures',
    ),
    (
      'view-only',
      _request(canSign: false),
      "Can't request signatures",
      'Request transactions',
    ),
  ]) {
    testWidgets('$label wallets list what the site can do', (tester) async {
      await open(tester, request);
      expect(find.text('See your address and balances'), findsOneWidget);
      expect(find.text(expected), findsOneWidget);
      expect(find.text(absent), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('fits 320 dp at 2x text', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final result = await open(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('approve-connect')));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('a late tap never pops a newer route above the sheet', (
    tester,
  ) async {
    final result = await open(tester);
    var settled = false;
    unawaited(result.then((_) => settled = true));
    final button = tester.widget<MallowButton>(
      find.byKey(const Key('approve-connect')),
    );
    unawaited(
      Navigator.of(tester.element(find.byType(Scaffold).first)).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('newer route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    button.onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('newer route'), findsOneWidget);
    expect(settled, isFalse);
  });
}
