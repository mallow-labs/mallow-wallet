import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/widgets/text_span_tap_targets.dart';

void main() {
  const style = TextStyle(fontSize: 14);

  late TapGestureRecognizer recognizerOne;
  late TapGestureRecognizer recognizerTwo;
  late int tapsOne;
  late int tapsTwo;

  setUp(() {
    tapsOne = 0;
    tapsTwo = 0;
    recognizerOne = TapGestureRecognizer()..onTap = () => tapsOne++;
    recognizerTwo = TapGestureRecognizer()..onTap = () => tapsTwo++;
  });

  tearDown(() {
    recognizerOne.dispose();
    recognizerTwo.dispose();
  });

  // Mirrors the mint tags list: label + two recognizer spans + separator.
  TextSpan tagsSpan() => TextSpan(
    style: style,
    children: [
      const TextSpan(text: 'Added: '),
      TextSpan(text: '#one', recognizer: recognizerOne),
      const TextSpan(text: ', '),
      TextSpan(text: '#two', recognizer: recognizerTwo),
    ],
  );

  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(MaterialApp(home: Center(child: child)));
  }

  Rect spanRect(WidgetTester tester, int start, int end) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText),
    );
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    final local = boxes.single.toRect();
    return local.shift(paragraph.localToGlobal(Offset.zero));
  }

  testWidgets('renders at the exact size of the bare Text.rich', (
    tester,
  ) async {
    await pump(tester, Text.rich(tagsSpan()));
    final bareSize = tester.getSize(find.byType(RichText));

    await pump(tester, TextSpanTapTargets(span: tagsSpan()));
    expect(tester.getSize(find.byType(RichText)), bareSize);
  });

  testWidgets('on-glyph tap fires the span recognizer exactly once', (
    tester,
  ) async {
    await pump(tester, TextSpanTapTargets(span: tagsSpan()));

    // 'Added: ' is 7 chars, '#one' spans offsets 7..11.
    await tester.tapAt(spanRect(tester, 7, 11).center);
    expect(tapsOne, 1);
    expect(tapsTwo, 0);
  });

  testWidgets('tap below a span (outside its glyphs) fires that span', (
    tester,
  ) async {
    await pump(tester, TextSpanTapTargets(span: tagsSpan()));

    final one = spanRect(tester, 7, 11);
    await tester.tapAt(one.center + Offset(0, one.height / 2 + 8));
    expect(tapsOne, 1);
    expect(tapsTwo, 0);
  });

  testWidgets('tap on the separator resolves to the nearest span', (
    tester,
  ) async {
    await pump(tester, TextSpanTapTargets(span: tagsSpan()));

    // '#two' spans offsets 13..17; tap just left of its glyphs, in the
    // separator gap, where '#two' is clearly the nearest target.
    final two = spanRect(tester, 13, 17);
    await tester.tapAt(Offset(two.left - 2, two.center.dy));
    expect(tapsOne, 0);
    expect(tapsTwo, 1);
  });

  testWidgets('tap far outside every expanded target fires nothing', (
    tester,
  ) async {
    await pump(tester, TextSpanTapTargets(span: tagsSpan()));

    final one = spanRect(tester, 7, 11);
    await tester.tapAt(one.center + const Offset(0, 40));
    expect(tapsOne, 0);
    expect(tapsTwo, 0);
  });

  testWidgets('non-recognizer text outside any expanded target is inert', (
    tester,
  ) async {
    // A lone label with no recognizers anywhere: taps must be no-ops.
    await pump(
      tester,
      const TextSpanTapTargets(
        span: TextSpan(text: 'Added: ', style: style),
      ),
    );
    await tester.tapAt(tester.getCenter(find.byType(RichText)));
    expect(tapsOne, 0);
    expect(tapsTwo, 0);
  });
}
