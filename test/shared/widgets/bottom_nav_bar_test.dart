import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/bottom_nav_bar.dart';

void main() {
  testWidgets('every tab builds and taps when hosted above the Navigator', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final selected = <MallowNavTab>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const SizedBox.shrink(),
        // Mirrors app.dart: the bar is a router-level overlay placed in the
        // MaterialApp builder, so it has no Overlay (and no Scaffold) above
        // it. A tab built from a widget that needs either paints the red
        // error box instead of the icon.
        builder: (context, child) => Stack(
          children: [
            child!,
            Align(
              alignment: Alignment.bottomCenter,
              child: MallowBottomNavBar(
                currentTab: MallowNavTab.home,
                onTabSelected: selected.add,
              ),
            ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);

    for (final (label, tab) in [
      ('Browser', MallowNavTab.browser),
      ('Portfolio', MallowNavTab.portfolio),
      ('Tokens', MallowNavTab.tokens),
      ('Home', MallowNavTab.home),
    ]) {
      await tester.tap(find.bySemanticsLabel(label));
      await tester.pump();
      expect(selected.last, tab, reason: label);
    }
    handle.dispose();
  });

  testWidgets('showBrowser: false hides the browser tab', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: MallowBottomNavBar(
          currentTab: MallowNavTab.home,
          showBrowser: false,
          onTabSelected: (_) {},
        ),
      ),
    );
    expect(find.bySemanticsLabel('Browser'), findsNothing);
    expect(find.bySemanticsLabel('Home'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the browser tab uses the compass icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: MallowBottomNavBar(
          currentTab: MallowNavTab.home,
          onTabSelected: (_) {},
        ),
      ),
    );
    final assets = tester
        .widgetList<SvgPicture>(find.byType(SvgPicture))
        .map((svg) => svg.bytesLoader)
        .whereType<SvgAssetLoader>()
        .map((loader) => loader.assetName);
    expect(assets, contains('assets/icons/compass.svg'));
    expect(assets, isNot(contains('assets/icons/public.svg')));
  });
}
