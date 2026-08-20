import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_owner_sheet.dart';

// The owner sheet is the only in-app way to move an artwork you hold out of
// your wallet, and the only way to list it. Those two affordances have
// different preconditions — a flagged artwork can't be listed but must still be
// sendable, and a frozen one can't be sent but may still be listable-looking —
// so the sheet must render them independently. Collapsing them onto one flag is
// what stranded flagged artworks in the app and gave the app's most
// prominent Send button the weakest predicate on the screen.

ArtworkDetails _artwork() => const ArtworkDetails(
  mintAccount: 'mint1',
  title: 'T',
  imageUrl: '',
  description: null,
  artistName: 'A',
  artistAddress: 'artist1',
);

Future<void> _pump(
  WidgetTester tester, {
  required bool canList,
  required bool canSend,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: ArtworkOwnerSheet(
        artwork: _artwork(),
        canList: canList,
        canSend: canSend,
        onList: () {},
        onSend: () {},
        onAcceptOffer: (_) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('renders both CTAs when the owner may list and send', (
    tester,
  ) async {
    await _pump(tester, canList: true, canSend: true);
    expect(find.text('Send artwork'), findsOneWidget);
    expect(find.text('List artwork'), findsOneWidget);
  });

  testWidgets('a listing-blocked artwork can still be sent', (tester) async {
    // The flagged / sold-out-master case: the webapp gates only "List for
    // sale" (`ActionBox`) and leaves Transfer
    // available (`:200-217`).
    await _pump(tester, canList: false, canSend: true);
    expect(find.text('Send artwork'), findsOneWidget);
    expect(find.text('List artwork'), findsNothing);
  });

  testWidgets('an untransferable artwork still offers listing', (tester) async {
    await _pump(tester, canList: true, canSend: false);
    expect(find.text('Send artwork'), findsNothing);
    expect(find.text('List artwork'), findsOneWidget);
  });
}
