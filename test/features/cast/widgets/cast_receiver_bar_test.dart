import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/cast/models/cast_display_type.dart';
import 'package:mallow_wallet/features/cast/models/cast_overlay_config.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';
import 'package:mallow_wallet/features/cast/widgets/cast_receiver_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// The receiver's bottom bar is a fixed height on purpose — it renders on
/// everything from a macOS preview window to a 4K TV. That makes it the one
/// surface in the app that cannot also grow with the phone's accessibility
/// text scale, and at 110px there is no headroom left to absorb it.
void main() {
  const item = CastQueueItem(
    mintAccount: 'A',
    title: 'A long artwork title that needs two full lines to render',
    imageUrl: 'https://example.test/A.png',
    artistName: 'An Artist With A Long Name',
  );

  const overlay = CastOverlayConfig(
    qrUrl: 'https://example.test/a',
    title: 'A long artwork title that needs two full lines to render',
    subtitle: 'An Artist With A Long Name',
    displayType: CastDisplayType.fitToScreen,
  );

  Future<void> pumpBar(WidgetTester tester, double scale) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const CastReceiverView(item: item, overlay: overlay),
        ),
      ),
    );
    await tester.pump();
  }

  // 1.3 is the ceiling both hosts clamp to (`app.dart`, `cast_receiver_app
  // .dart`). Unclamped locally, a two-line caption overflows the bar by 16px
  // and paints the debug stripes across a TV.
  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('the bar does not overflow at text scale $scale', (
      tester,
    ) async {
      await pumpBar(tester, scale);
      expect(tester.takeException(), isNull);
    });
  }
}
