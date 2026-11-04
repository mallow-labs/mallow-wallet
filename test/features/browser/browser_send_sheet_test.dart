import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/signing_copy.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_send_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';
import 'package:mallow_wallet/shared/widgets/striped_activity_panel.dart';

void main() {
  late ValueNotifier<BrowserSendStep> step;
  late int closed;

  /// Opens the browser signing sheet.
  ///
  /// Fixtures are built here rather than in `setUp`, inside the test's fake
  /// async zone: a completer made outside it never resolves under `pump`.
  Future<void> open(WidgetTester tester) async {
    step = ValueNotifier<BrowserSendStep>(const BrowserSendReview());
    closed = 0;
    addTearDown(step.dispose);
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
    final navigator = Navigator.of(host);
    late final ModalBottomSheetRoute<void> route;
    route = mallowSheetRoute<void>(
      context: host,
      isScrollControlled: true,
      builder: (_) => BrowserSendSheet(
        step: step,
        onClose: () {
          closed++;
          if (route.isActive) navigator.removeRoute(route);
        },
        review: const SizedBox(height: 400, child: Text('review body')),
      ),
    );
    unawaited(navigator.push(route));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(MallowTheme.sheetDuration);
    await tester.pump(MallowTheme.sheetDuration);
  }

  testWidgets('approval morphs the review into the striped signing state', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('review body'), findsOneWidget);

    step.value = const BrowserSendSigning(WalletType.hd);
    await settle(tester);
    expect(find.text('review body'), findsNothing);
    expect(find.byType(StripedActivityPanel), findsOneWidget);
    expect(find.text(kLocalSigningLabel), findsOneWidget);
    expect(find.text(kLocalSigningSublabel), findsOneWidget);
  });

  testWidgets('a Ledger signer is asked to approve on the device', (
    tester,
  ) async {
    await open(tester);
    step.value = const BrowserSendSigning(WalletType.ledger);
    await settle(tester);
    expect(find.text(kExternalSigningLabel), findsOneWidget);
    expect(find.text(kLedgerSigningSublabel), findsOneWidget);
  });

  testWidgets('a failure before broadcast says nothing was sent', (
    tester,
  ) async {
    await open(tester);
    step.value = const BrowserSendFailed('Review expired.');
    await settle(tester);
    expect(find.text('Transaction not sent'), findsOneWidget);
    expect(find.text('Review expired.'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(closed, 1);
  });
}
