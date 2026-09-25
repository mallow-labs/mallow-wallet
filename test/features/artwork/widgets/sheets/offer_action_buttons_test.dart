import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/offer_action_buttons.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';

// On a store build that hides NFT commerce "Cancel offer" is the block's only
// CTA — the siblings that carry the in-flight spinner elsewhere (Buy,
// make/update offer) are not rendered — so it has to show the spinner itself.
// Without it a cancel tx just greys the button out and the user sees no sign
// the action is running.

void main() {
  tearDown(() => debugShowNftCommerceOverride = null);

  Future<void> pump(
    WidgetTester tester, {
    required bool userOwnOffer,
    bool isLoading = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OfferActionButtons(
          userOwnOffer: userOwnOffer,
          isLoading: isLoading,
          onMakeOffer: () {},
          onCancelOffer: () {},
        ),
      ),
    ),
  );

  testWidgets('commerce hidden: an in-flight cancel shows the spinner', (
    tester,
  ) async {
    debugShowNftCommerceOverride = false;
    await pump(tester, userOwnOffer: true, isLoading: true);

    final cancel = find.widgetWithText(MallowButton, 'Cancel offer');
    expect(cancel, findsOneWidget);
    expect(tester.widget<MallowButton>(cancel).isLoading, isTrue);
    expect(
      find.descendant(of: cancel, matching: find.byType(MallowLoader)),
      findsOneWidget,
    );
  });

  testWidgets('commerce hidden: no offer of your own renders nothing', (
    tester,
  ) async {
    debugShowNftCommerceOverride = false;
    await pump(tester, userOwnOffer: false);

    expect(find.byType(MallowButton), findsNothing);
    expect(find.text('Make offer'), findsNothing);
  });
}
