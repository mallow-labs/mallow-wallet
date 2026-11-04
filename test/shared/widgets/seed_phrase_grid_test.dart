import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/seed_phrase_grid.dart';

/// The editable grid is where a user types a recovery phrase by hand. Every
/// cell has to keep the words away from the keyboard: suggestions and
/// autocorrect hand them to the input method's learning, and autofill offers
/// them to a password manager.
void main() {
  testWidgets('every editable cell keeps the words out of the keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeedPhraseGrid(words: List.filled(12, ''), editable: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields, hasLength(12));
    for (final field in fields) {
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.smartDashesType, SmartDashesType.disabled);
      expect(field.smartQuotesType, SmartQuotesType.disabled);
      expect(field.autofillHints, isNull);
    }
  });
}
