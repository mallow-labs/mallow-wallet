import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/action_menu.dart';

// The (+) menu is the global entry to Mint, Sell and Swap. In a store build
// that hides NFT commerce (the iOS App Store build, Guideline 3.1.1) the first
// two rows must be absent — not disabled, not "coming soon" — and in one that
// hides swap (Guideline 3.1.5(ii)) so must the third. The two flags are
// independent: Transfer, Send and Receive are wallet functions and survive
// both.

Future<void> _pump(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    theme: MallowTheme.lightTheme,
    // The card is a fixed 178px wide and the test font renders every glyph
    // as a full em square, so at 1.0 the longest row overflows by a few px.
    // Scale the text down: the assertions are about which rows exist.
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(0.6)),
      child: child!,
    ),
    home: Scaffold(
      body: ActionMenuCard(
        onReceive: () {},
        onSigningNavigate: (_, _, _) {},
        onSwap: () {},
        onSend: () {},
      ),
    ),
  ),
);

void main() {
  tearDown(() {
    debugShowNftCommerceOverride = null;
    debugShowSwapOverride = null;
  });

  testWidgets('shows every row when commerce and swap are shown', (
    tester,
  ) async {
    debugShowNftCommerceOverride = true;
    debugShowSwapOverride = true;
    await _pump(tester);
    for (final label in const [
      'Mint',
      'Transfer',
      'Sell',
      'Send',
      'Receive',
      'Swap',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets(
    'drops Mint and Sell — and only those — when commerce is hidden',
    (tester) async {
      debugShowNftCommerceOverride = false;
      await _pump(tester);
      expect(find.text('Mint'), findsNothing);
      expect(find.text('Sell'), findsNothing);
      for (final label in const ['Transfer', 'Send', 'Receive', 'Swap']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // The group keeps its heading with the one row that remains.
      expect(find.text('Art'), findsOneWidget);
      expect(find.text('Tokens'), findsOneWidget);
    },
  );

  testWidgets('drops Swap — and only Swap — when swap is hidden', (
    tester,
  ) async {
    // Commerce left shown on purpose: the two flags answer different
    // guidelines and one must not drag the other's rows with it.
    debugShowNftCommerceOverride = true;
    debugShowSwapOverride = false;
    await _pump(tester);
    expect(find.text('Swap'), findsNothing);
    for (final label in const ['Mint', 'Transfer', 'Sell', 'Send', 'Receive']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Tokens'), findsOneWidget);
  });

  testWidgets('the App Store build shows neither', (tester) async {
    // Both defines the iOS release lane passes, together.
    debugShowNftCommerceOverride = false;
    debugShowSwapOverride = false;
    await _pump(tester);
    for (final gone in const ['Mint', 'Sell', 'Swap']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    for (final kept in const ['Transfer', 'Send', 'Receive']) {
      expect(find.text(kept), findsOneWidget, reason: kept);
    }
  });
}
