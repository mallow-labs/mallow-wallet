import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/listing_disclosures.dart';

// `ListingDisclosures` is the buyer-facing "Physical available" / "Rewards
// included" accordion on the listed bottom sheets. Its contract — surface a
// disclosure only when the seller supplied that extra, and keep at most one
// open at a time — is what these tests pin. The collapse-on-expand behaviour
// is the part most likely to regress silently if someone swaps the shared
// open-state for per-tile state.

ArtworkDetails _artwork({RewardsDescriptionPayload? rewardsInfo}) =>
    ArtworkDetails(
      mintAccount: 'mint1',
      title: 'T',
      imageUrl: '',
      description: null,
      artistName: 'A',
      artistAddress: 'artist1',
      rewardsInfo: rewardsInfo,
    );

Future<void> _pump(WidgetTester tester, ArtworkDetails artwork) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ListingDisclosures(artwork: artwork)),
    ),
  );
}

void main() {
  testWidgets('renders nothing when the listing has no physical or rewards', (
    tester,
  ) async {
    await _pump(tester, _artwork());

    expect(find.text('Physical available'), findsNothing);
    expect(find.text('Rewards included'), findsNothing);
    // The whole subtree collapses to an empty box.
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('shows only the physical disclosure when only physical is set', (
    tester,
  ) async {
    await _pump(
      tester,
      _artwork(
        rewardsInfo: const RewardsDescriptionPayload(
          includesPhysical: true,
          physicalDetails: PhysicalDetailsPayload(
            description: 'A signed print',
          ),
        ),
      ),
    );

    expect(find.text('Physical available'), findsOneWidget);
    expect(find.text('Rewards included'), findsNothing);
  });

  testWidgets('rewards needs non-empty copy to surface', (tester) async {
    await _pump(
      tester,
      _artwork(
        rewardsInfo: const RewardsDescriptionPayload(rewardsDescription: '   '),
      ),
    );

    expect(find.text('Rewards included'), findsNothing);
  });

  testWidgets('opening one disclosure collapses the other', (tester) async {
    await _pump(
      tester,
      _artwork(
        rewardsInfo: const RewardsDescriptionPayload(
          rewardsDescription: 'Discord role for holders',
          includesPhysical: true,
          physicalDetails: PhysicalDetailsPayload(
            description: 'A signed print',
          ),
        ),
      ),
    );

    // Both disclosures present and collapsed — two "+" glyphs, no "−".
    expect(find.text('Physical available'), findsOneWidget);
    expect(find.text('Rewards included'), findsOneWidget);
    expect(find.text('+'), findsNWidgets(2));
    expect(find.text('−'), findsNothing);

    // Expand physical → exactly one disclosure open.
    await tester.tap(find.text('Physical available'));
    await tester.pumpAndSettle();
    expect(find.text('−'), findsOneWidget);

    // Expand rewards → physical must collapse, so still exactly one open.
    await tester.tap(find.text('Rewards included'));
    await tester.pumpAndSettle();
    expect(find.text('−'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);

    // Tapping the open disclosure again collapses everything.
    await tester.tap(find.text('Rewards included'));
    await tester.pumpAndSettle();
    expect(find.text('−'), findsNothing);
    expect(find.text('+'), findsNWidgets(2));
  });

  // The webapp gates a physical buy behind a shipping form and threads
  // the resulting order id into an `order:<id>` memo. Mobile has no form and
  // sends no `orderId`, and the product decision is to let the purchase
  // proceed anyway — so the ONLY thing standing between the buyer and a
  // physical that can never be shipped is this sentence. If it disappears,
  // the buyer pays for a physical believing the seller has their address.
  testWidgets('warns that no shipping address is sent when the seller asks '
      'for one', (tester) async {
    await _pump(
      tester,
      _artwork(
        rewardsInfo: const RewardsDescriptionPayload(
          includesPhysical: true,
          askForShippingAddress: true,
          physicalDetails: PhysicalDetailsPayload(
            description: 'A signed print',
          ),
        ),
      ),
    );

    await tester.tap(find.text('Physical available'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('cannot collect a shipping address yet'),
      findsOneWidget,
    );
  });

  testWidgets('omits the shipping warning when the seller never asked for an '
      'address', (tester) async {
    await _pump(
      tester,
      _artwork(
        rewardsInfo: const RewardsDescriptionPayload(
          includesPhysical: true,
          physicalDetails: PhysicalDetailsPayload(
            description: 'A signed print',
          ),
        ),
      ),
    );

    await tester.tap(find.text('Physical available'));
    await tester.pumpAndSettle();

    // The standard seller-responsibility disclaimer still renders — only the
    // shipping-address sentence is conditional.
    expect(find.textContaining('responsibility of the seller'), findsOneWidget);
    expect(
      find.textContaining('cannot collect a shipping address yet'),
      findsNothing,
    );
  });
}
