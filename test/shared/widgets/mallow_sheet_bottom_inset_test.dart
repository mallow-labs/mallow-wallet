import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

/// Renders [sheetBottomInset] under a synthetic MediaQuery and reports it.
Future<double> _inset(
  WidgetTester tester, {
  required double keyboard,
  required double safeArea,
  required bool includeKeyboard,
}) async {
  late double result;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        viewInsets: EdgeInsets.only(bottom: keyboard),
        // The keyboard zeroes `padding.bottom` but never `viewPadding.bottom`.
        viewPadding: EdgeInsets.only(bottom: safeArea),
        padding: EdgeInsets.only(bottom: keyboard > 0 ? 0 : safeArea),
      ),
      child: Builder(
        builder: (context) {
          result = sheetBottomInset(context, includeKeyboard: includeKeyboard);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return result;
}

void main() {
  const gap = MallowTheme.spacing20;
  const homeIndicator = 34.0;
  const keyboardHeight = 300.0;

  group('sheetBottomInset', () {
    testWidgets('clears the home indicator when no keyboard is open', (
      tester,
    ) async {
      expect(
        await _inset(
          tester,
          keyboard: 0,
          safeArea: homeIndicator,
          includeKeyboard: false,
        ),
        homeIndicator + gap,
      );
    });

    testWidgets(
      'drops the safe area once the caller-side keyboard lift covers it',
      (tester) async {
        // The `includeKeyboard: false` callers (bid/offer/listing sheets, the
        // swap and staking forms) wrap their content in a
        // `Padding(bottom: viewInsets.bottom)`. That lift already clears the
        // home indicator, so adding it again floats the CTA a home-indicator's
        // height above the keyboard.
        expect(
          await _inset(
            tester,
            keyboard: keyboardHeight,
            safeArea: homeIndicator,
            includeKeyboard: false,
          ),
          gap,
        );
      },
    );

    testWidgets('keeps the uncovered remainder of a partial lift', (
      tester,
    ) async {
      // A keyboard shorter than the safe area (accessory bars, floating
      // keyboards) only covers part of it — the rest is still owed.
      expect(
        await _inset(
          tester,
          keyboard: 10,
          safeArea: homeIndicator,
          includeKeyboard: false,
        ),
        homeIndicator - 10 + gap,
      );
    });

    testWidgets('includeKeyboard callers still clear the whole keyboard', (
      tester,
    ) async {
      expect(
        await _inset(
          tester,
          keyboard: keyboardHeight,
          safeArea: homeIndicator,
          includeKeyboard: true,
        ),
        keyboardHeight + gap,
      );
    });
  });
}
