import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/widgets/sliver_overscroll_anchored.dart';

void main() {
  const headerKey = Key('header');
  const bodyKey = Key('body');

  Widget build(ScrollController controller) => MaterialApp(
    home: CustomScrollView(
      controller: controller,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: const [
        SliverOverscrollAnchored(child: SizedBox(key: headerKey, height: 50)),
        SliverToBoxAdapter(child: SizedBox(key: bodyKey, height: 2000)),
      ],
    ),
  );

  testWidgets('holds still while pulled past the top', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(build(controller));

    controller.jumpTo(-80);
    await tester.pump();

    expect(tester.getTopLeft(find.byKey(headerKey)).dy, 0);
    // The content below still follows the pull.
    expect(tester.getTopLeft(find.byKey(bodyKey)).dy, 130);
  });

  testWidgets('scrolls away normally', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(build(controller));

    controller.jumpTo(30);
    await tester.pump();

    expect(tester.getTopLeft(find.byKey(headerKey)).dy, -30);
    expect(tester.getTopLeft(find.byKey(bodyKey)).dy, 20);
  });

  testWidgets('taps land on the anchored position during a pull', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          controller: controller,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            SliverOverscrollAnchored(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(height: 50),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 2000)),
          ],
        ),
      ),
    );

    controller.jumpTo(-80);
    await tester.pump();
    await tester.tapAt(const Offset(100, 25));
    expect(taps, 1);
  });
}
