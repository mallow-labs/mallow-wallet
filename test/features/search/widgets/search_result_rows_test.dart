import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mallow_wallet/features/search/models/search_models.dart';
import 'package:mallow_wallet/features/search/widgets/search_artwork_item.dart';
import 'package:mallow_wallet/features/search/widgets/search_curation_item.dart';
import 'package:mallow_wallet/features/search/widgets/search_token_item.dart';
import 'package:mallow_wallet/features/search/widgets/search_user_item.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// Names in search results are attacker-controlled: anyone can mint a token or
/// an artwork whose name is a page of newline-separated text. Each row must
/// stay one row tall whatever the name holds, or a single result takes over
/// the sheet.
void main() {
  final hostileName = List.generate(40, (i) => 'Line $i').join('\n');

  setUp(() {
    final originalFonts = GoogleFonts.config.allowRuntimeFetching;
    GoogleFonts.config.allowRuntimeFetching = false;
    addTearDown(() => GoogleFonts.config.allowRuntimeFetching = originalFonts);
  });

  Future<double> rowHeight(WidgetTester tester, Widget row) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const key = Key('row');
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: KeyedSubtree(key: key, child: row),
          ),
        ),
      ),
    );
    return tester.getSize(find.byKey(key)).height;
  }

  final rows = <String, Widget>{
    'token': SearchTokenItem(
      token: SearchTokenResult(
        mintAddress: 'So11111111111111111111111111111111111111113',
        name: hostileName,
        symbol: 'COFFEE',
        usdPrice: 0.0000033,
      ),
    ),
    'artwork': SearchArtworkItem(
      artwork: SearchArtworkResult(
        title: hostileName,
        mintAccount: 'mint',
        artistUsername: 'artist',
      ),
    ),
    'collection': SearchCollectionItem(
      collection: SearchCollectionResult(
        name: hostileName,
        curatorUsername: 'curator',
      ),
    ),
    'curation': SearchCurationItem(
      curation: SearchCurationResult(
        id: 'c',
        name: hostileName,
        ownerUsername: 'owner',
      ),
    ),
    'user': SearchUserItem(
      user: SearchUserResult(
        username: hostileName,
        avatarUrl: 'https://example.com/a.png',
      ),
    ),
  };

  for (final MapEntry(key: label, value: row) in rows.entries) {
    testWidgets('$label row stays one row tall for a multi-line name', (
      tester,
    ) async {
      final height = await rowHeight(tester, row);
      // The 48px thumbnail sets the row height; one name line plus the
      // subtitle fits inside it. Forty lines of name would be ~800px.
      expect(height, lessThanOrEqualTo(64));
      expect(tester.takeException(), isNull);
    });
  }
}
