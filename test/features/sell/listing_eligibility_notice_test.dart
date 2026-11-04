import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/sell/services/trade_eligibility.dart';
import 'package:mallow_wallet/features/sell/widgets/listing_eligibility_notice.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';

void main() {
  testWidgets(
    'pending verification shows a loader and completed refusal offers retry',
    (tester) async {
      var retries = 0;
      Future<void> pump(String? message, bool checking) => tester.pumpWidget(
        MaterialApp(
          theme: MallowTheme.lightTheme,
          home: Scaffold(
            body: ListingEligibilityNotice(
              message: message,
              isChecking: checking,
              onRetry: () => retries++,
            ),
          ),
        ),
      );
      await pump(verifyingArtworkEligibility, true);
      await tester.pump();
      expect(find.byType(MallowLoader), findsOneWidget);
      expect(find.text(verifyingArtworkEligibility), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      await pump(TradeEligibility.unverified.message, false);
      expect(find.byType(MallowLoader), findsNothing);
      expect(find.textContaining('try again'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retries, 1);
      await pump(null, false);
      expect(find.text('Try again'), findsNothing);
    },
  );
}
