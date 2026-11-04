import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';
import 'package:mallow_wallet/shared/widgets/pinned_top_bar.dart';

Finder _icon(String asset) => find.byWidgetPredicate(
  (w) => w is MallowSvgIcon && w.assetPath == 'assets/icons/$asset.svg',
);

Future<void> _pump(WidgetTester tester, PinnedTopBar bar) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Align(alignment: Alignment.topCenter, child: bar),
    ),
  ),
);

void main() {
  testWidgets('back and kebab fire their callbacks', (tester) async {
    var backs = 0;
    var menus = 0;
    await _pump(
      tester,
      PinnedTopBar(
        title: '@artist',
        onBack: () => backs++,
        onMenuTap: () => menus++,
      ),
    );

    expect(find.text('@artist'), findsOneWidget);
    await tester.tap(_icon('arrow_left'));
    await tester.tap(_icon('dots_vertical'));
    expect(backs, 1);
    expect(menus, 1);
  });

  testWidgets('without onMenuTap the kebab is omitted and the title stays '
      'centred', (tester) async {
    await _pump(tester, PinnedTopBar(title: 'Title', onBack: () {}));

    expect(_icon('dots_vertical'), findsNothing);
    final bar = tester.getRect(find.byType(PinnedTopBar));
    final title = tester.getRect(find.text('Title'));
    expect(title.center.dx, closeTo(bar.center.dx, 0.5));
  });

  testWidgets('height is the row plus the top inset', (tester) async {
    await _pump(tester, PinnedTopBar(onBack: () {}, topInset: 44));

    expect(
      tester.getSize(find.byType(PinnedTopBar)).height,
      PinnedTopBar.rowHeight + 44,
    );
  });
}
