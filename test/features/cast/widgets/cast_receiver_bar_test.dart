import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:mallow_wallet/features/cast/models/cast_display_type.dart';
import 'package:mallow_wallet/features/cast/models/cast_overlay_config.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';
import 'package:mallow_wallet/features/cast/widgets/cast_receiver_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// The receiver's bottom bar scales with the screen, never with the phone's
/// accessibility text scale: it is a fixed proportion of the stage, and at
/// its reference size of 110px there is no headroom left to absorb a larger
/// type size.
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

  Future<void> pumpBar(
    WidgetTester tester,
    double scale, {
    Size surface = const Size(800, 600),
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: MediaQuery(
          data: MediaQueryData(
            size: surface,
            textScaler: TextScaler.linear(scale),
          ),
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

  Size qrSize(WidgetTester tester) => tester.getSize(
    find
        .ancestor(
          of: find.byType(PrettyQrView),
          matching: find.byType(SizedBox),
        )
        .first,
  );

  testWidgets('the bar keeps its reference size on a 720p-or-smaller stage', (
    tester,
  ) async {
    await pumpBar(tester, 1, surface: const Size(1280, 720));
    expect(qrSize(tester), const Size(84, 84));
  });

  // A monitor reporting 1440 logical pixels of height used to get the same
  // 110px bar as a 720p TV — a sliver, with a QR too small to scan.
  testWidgets('the bar and QR scale with a taller stage', (tester) async {
    await pumpBar(tester, 1, surface: const Size(2560, 1440));
    expect(qrSize(tester), const Size(168, 168));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a scaled bar does not overflow at text scale 1.3', (
    tester,
  ) async {
    await pumpBar(tester, 1.3, surface: const Size(3840, 2160));
    expect(tester.takeException(), isNull);
  });
}
