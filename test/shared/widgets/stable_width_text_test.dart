import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/widgets/stable_width_text.dart';

void main() {
  Future<Size> sizeOf(WidgetTester tester, String text) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: StableWidthText(
            text,
            reserve: const ['Follow', 'Following'],
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ),
    );
    return tester.getSize(find.byType(StableWidthText));
  }

  testWidgets('every state lays out at the widest label width', (tester) async {
    final follow = await sizeOf(tester, 'Follow');
    final following = await sizeOf(tester, 'Following');
    expect(follow.width, following.width);
  });
}
