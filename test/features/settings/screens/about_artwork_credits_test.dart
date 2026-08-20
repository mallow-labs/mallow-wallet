import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/onboarding/widgets/artwork_ring_3d.dart';
import 'package:mallow_wallet/features/settings/screens/about_screen.dart';

/// The copyright in the nine onboarding carousel works stays with the artists;
/// the About screen credit is what makes showing them honest. The credit list
/// is derived from [kDefaultCarouselArtworks] rather than hand-copied, so these
/// tests fail the moment the two can name different artists again — which is
/// the only reason the derivation exists.
void main() {
  final names = kDefaultCarouselArtworks.map((a) => a.artist).toList();

  Future<TextSpan> pumpCredit(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
    await tester.pump();

    final finder = find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          w.text.toPlainText().startsWith('Onboarding artwork by '),
    );
    expect(finder, findsOneWidget);
    return tester.widget<RichText>(finder).text as TextSpan;
  }

  testWidgets('credits every carousel artist, in carousel order', (
    tester,
  ) async {
    final span = await pumpCredit(tester);

    expect(
      span.toPlainText(),
      'Onboarding artwork by ${names.take(names.length - 1).join(', ')} '
      'and ${names.last}',
    );
  });

  // A name rendered as plain text is an uncredited link target: the artist is
  // named but the reader cannot reach the profile that identifies them.
  testWidgets('every credited name links to that artist', (tester) async {
    final span = await pumpCredit(tester);

    final linked = <String?>[];
    span.visitChildren((child) {
      if (child is TextSpan && child.recognizer != null) linked.add(child.text);
      return true;
    });
    expect(linked, names);
  });
}
