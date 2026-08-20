import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/widgets/portfolio_value_section.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// The portfolio total is the single number a user checks most often, and it
/// is assembled from two separately styled spans (dollars + cents). Splitting
/// the value before rounding let the two disagree: `9.999` truncated to an
/// integer part of 9 while the remainder rounded to 100 cents, and `padLeft(2)`
/// happily emitted "100" — so a $10.00 portfolio read "$9.100". These pin that
/// the carry propagates.
Future<String> _renderedTotal(WidgetTester tester, double value) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(body: PortfolioValueSection(totalUsd: value)),
    ),
  );
  final text = tester.widget<Text>(find.byType(Text).first);
  final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
  return spans.map((s) => s.text).join();
}

void main() {
  testWidgets('a value that rounds up to the next dollar carries', (
    tester,
  ) async {
    expect(await _renderedTotal(tester, 9.999), r'$10.00');
  });

  testWidgets('cents never render as a three-digit "100"', (tester) async {
    for (final value in [0.999, 9.999, 1234.999]) {
      final rendered = await _renderedTotal(tester, value);
      expect(
        rendered,
        isNot(endsWith('.100')),
        reason: '$value must not render a 100-cent remainder',
      );
    }
  });

  testWidgets('thousands stay grouped after the carry', (tester) async {
    // The carry must not bypass the separator pass: 999,999.999 rolls the
    // integer part over to 1,000,000.
    expect(await _renderedTotal(tester, 999999.999), r'$1,000,000.00');
  });

  testWidgets('an ordinary value is unchanged', (tester) async {
    expect(await _renderedTotal(tester, 1234.56), r'$1,234.56');
  });
}
