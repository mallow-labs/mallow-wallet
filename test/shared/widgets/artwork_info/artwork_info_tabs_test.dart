import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/artwork_info/artwork_info_tabs.dart';
import 'package:mallow_wallet/shared/widgets/artwork_info/artwork_info_view_data.dart';
import 'package:mallow_wallet/shared/widgets/tappable.dart';

void main() {
  testWidgets('Details displays the distinct compressed v2 label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const Scaffold(
          body: ArtworkInfoTabs(
            data: ArtworkInfoViewData(tokenStandard: 'cnft-v2'),
          ),
        ),
      ),
    );
    expect(find.text('Metaplex Compressed V2'), findsOneWidget);
  });

  const data = ArtworkInfoViewData(
    categories: ['Digital Art'],
    tags: ['sunset'],
  );

  Future<void> pump(
    WidgetTester tester, {
    ValueChanged<String>? onCategoryTap,
    ValueChanged<String>? onTagTap,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: ArtworkInfoTabs(
          data: data,
          onCategoryTap: onCategoryTap,
          onTagTap: onTagTap,
        ),
      ),
    ),
  );

  testWidgets('a category chip reports its display name', (tester) async {
    final tapped = <String>[];
    await pump(tester, onCategoryTap: tapped.add, onTagTap: (_) {});

    await tester.tap(find.text('Categories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Digital Art'));
    expect(tapped, ['Digital Art']);
  });

  testWidgets('a tag chip reports the raw tag, without the hash', (
    tester,
  ) async {
    final tapped = <String>[];
    await pump(tester, onCategoryTap: (_) {}, onTagTap: tapped.add);

    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#sunset'));
    expect(tapped, ['sunset']);
  });

  // The mint review step previews an artwork that doesn't exist yet, so its
  // chips must not read as buttons.
  testWidgets('chips are inert without callbacks', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Categories'));
    await tester.pumpAndSettle();

    expect(find.text('Digital Art'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Digital Art'),
        matching: find.byType(Tappable),
      ),
      findsNothing,
    );
  });
}
