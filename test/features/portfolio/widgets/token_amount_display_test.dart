import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/widgets/token_list_item.dart';
import 'package:mallow_wallet/features/portfolio/widgets/token_position_card.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

void main() {
  const token = TokenBalance(
    mint: 'TokenMint',
    symbol: 'TEST',
    name: 'Test Token',
    decimals: 6,
    rawBalance: 1230000,
    uiBalance: 1.2300,
  );

  Widget host(Widget child) => MaterialApp(
    theme: MallowTheme.lightTheme,
    home: Scaffold(body: child),
  );

  testWidgets('portfolio token row strips insignificant balance zeros', (
    tester,
  ) async {
    await tester.pumpWidget(host(const TokenListItem(token: token)));

    expect(find.text('1.23 TEST'), findsOneWidget);
    expect(find.text('1.23000 TEST'), findsNothing);
  });

  testWidgets('position card strips insignificant balance zeros', (
    tester,
  ) async {
    await tester.pumpWidget(host(const TokenPositionCard(token: token)));

    expect(find.text('1.23 TEST'), findsOneWidget);
    expect(find.text('1.2300 TEST'), findsNothing);
  });

  testWidgets('portfolio token row keeps grouping while trimming decimals', (
    tester,
  ) async {
    const grouped = TokenBalance(
      mint: 'TokenMint',
      symbol: 'TEST',
      name: 'Test Token',
      decimals: 6,
      rawBalance: 1234500000,
      uiBalance: 1234.5,
    );

    await tester.pumpWidget(host(const TokenListItem(token: grouped)));

    expect(find.text('1,234.5 TEST'), findsOneWidget);
  });
}
