import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/widgets/portfolio_action_buttons.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

// The portfolio's Swap / Send / Receive / Stake row. In a build that hides
// swap (the iOS App Store build, Guideline 3.1.5(ii)) the Swap button is not
// rendered at all — a greyed one would invite a tap with nothing to explain.
// The other three are wallet functions and never move.

class _MockSessionManager extends Mock implements SessionManager {}

void main() {
  setUp(() {
    final session = _MockSessionManager();
    // No signable wallet on any chain: Swap and Stake render disabled, which
    // is orthogonal to whether Swap is rendered at all — the point here.
    when(() => session.sessionWalletForChain(any())).thenReturn(null);
    when(() => session.sessionWalletsForChain(any())).thenReturn(const []);
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    sl.registerFactory<SessionManager>(() => session);
  });

  tearDown(() {
    debugShowSwapOverride = null;
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
  });

  setUpAll(() => registerFallbackValue(Chain.solana));

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: const Scaffold(body: PortfolioActionButtonsRow()),
    ),
  );

  testWidgets('shows all four actions when swap is shown', (tester) async {
    debugShowSwapOverride = true;
    await pump(tester);
    for (final label in const ['Swap', 'Send', 'Receive', 'Stake']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('drops Swap — and only Swap — when swap is hidden', (
    tester,
  ) async {
    debugShowSwapOverride = false;
    await pump(tester);
    expect(find.text('Swap'), findsNothing);
    // Stake stays: native staking is not a swap, and its sheet is still the
    // way to reach the unstake and claim escape hatches.
    for (final label in const ['Send', 'Receive', 'Stake']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('spaces the three remaining actions in equal slots', (
    tester,
  ) async {
    debugShowSwapOverride = false;
    await pump(tester);
    final send = tester.getCenter(find.text('Send')).dx;
    final receive = tester.getCenter(find.text('Receive')).dx;
    final stake = tester.getCenter(find.text('Stake')).dx;
    final width = tester.getSize(find.byType(PortfolioActionButtonsRow)).width;
    // Receive sits dead centre and the outer two are the same distance from
    // it, rather than pinned to the row's edges.
    expect(receive, moreOrLessEquals(width / 2));
    expect(receive - send, moreOrLessEquals(stake - receive));
    final slot = (width - 2 * MallowTheme.spacing20) / 3;
    expect(receive - send, moreOrLessEquals(slot));
  });
}
