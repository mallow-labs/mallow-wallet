import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/cast/models/cast_display_type.dart';
import 'package:mallow_wallet/features/cast/models/cast_overlay_config.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';
import 'package:mallow_wallet/features/cast/widgets/cast_animated_artwork.dart';
import 'package:mallow_wallet/features/cast/widgets/cast_receiver_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// Tile mode advances by animating a four-slide row and settling back to
/// three. Every slide the viewer can already see must survive that as the
/// *same* element showing the *same* bytes — rebuilding one, or dropping its
/// full-resolution layer, reads on a TV as the artwork blinking mid-slide.
void main() {
  CastQueueItem item(String mint) => CastQueueItem(
    mintAccount: mint,
    title: 'Title $mint',
    imageUrl: 'https://example.test/$mint.png',
  );

  CastOverlayConfig overlayFor(String prev, String next) => CastOverlayConfig(
    showQr: false,
    showCaption: false,
    displayType: CastDisplayType.tile,
    prevImageUrl: item(prev).imageUrl,
    nextImageUrl: item(next).imageUrl,
  );

  Future<void> pumpSlide(
    WidgetTester tester,
    String curr, {
    required String prev,
    required String next,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: CastReceiverView(
          item: item(curr),
          overlay: overlayFor(prev, next),
        ),
      ),
    );
  }

  /// The rendered slide for [mint], by the raw URL it was handed.
  CastProgressiveArtwork? slideFor(WidgetTester tester, String mint) {
    final url = 'https://example.test/$mint.png';
    for (final w in tester.widgetList<CastProgressiveArtwork>(
      find.byType(CastProgressiveArtwork),
    )) {
      if (w.imageUrl == url) return w;
    }
    return null;
  }

  testWidgets('the outgoing slide keeps its full-resolution layer', (
    tester,
  ) async {
    await pumpSlide(tester, 'B', prev: 'A', next: 'C');
    await tester.pump();
    expect(slideFor(tester, 'B')?.fullUrl, isNotNull, reason: 'centred slide');
    expect(slideFor(tester, 'A')?.fullUrl, isNull, reason: 'peeks stay poster');

    // Advance B → C. B is now the left peek, mid-animation.
    await pumpSlide(tester, 'C', prev: 'B', next: 'D');
    await tester.pump();

    // B's original is downloaded and decoded. Recomputing `fullUrl` from
    // `isCurrent` would drop it on this exact frame, swapping a full-res
    // image for its poster in place just as the row starts to move.
    expect(slideFor(tester, 'B')?.fullUrl, isNotNull);
    expect(slideFor(tester, 'C')?.fullUrl, isNotNull);
    // D has never been centred, so it stays on the poster.
    expect(slideFor(tester, 'D')?.fullUrl, isNull);
  });

  testWidgets('a wrapping 3-item queue does not collide slide keys', (
    tester,
  ) async {
    // Three items on repeat-all is the *smallest* queue tile mode renders at
    // all (`CastOverlayConfigFromQueue.from` degrades below that), and both
    // peeks wrap — so a forward advance lays the row out as [A, B, C, A].
    // Keying slides on the URL alone puts two children under one ValueKey,
    // which is a hard assertion failure, not a cosmetic one.
    await pumpSlide(tester, 'B', prev: 'A', next: 'C');
    await tester.pump();
    await pumpSlide(tester, 'C', prev: 'B', next: 'A');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('two editions sharing one image do not collide slide keys', (
    tester,
  ) async {
    // Distinct mints, same artwork image — an edition pair sitting next to
    // each other in the queue. Same collision, no wrap needed.
    await pumpSlide(tester, 'A', prev: 'A', next: 'B');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('slides that stay on screen are never rebuilt', (tester) async {
    await pumpSlide(tester, 'B', prev: 'A', next: 'C');
    await tester.pump();
    final before = {
      for (final mint in ['A', 'B', 'C'])
        mint: tester
            .element(
              find.byWidgetPredicate(
                (w) =>
                    w is CastProgressiveArtwork &&
                    w.imageUrl == 'https://example.test/$mint.png',
              ),
            )
            .hashCode,
    };

    await pumpSlide(tester, 'C', prev: 'B', next: 'D');
    await tester.pump();
    // Cross the 600ms transform, then one more frame for the settle that
    // shrinks the row back to three slides. Not pumpAndSettle: the loading
    // shimmer repeats forever while no image can load under a test binding.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    for (final mint in ['B', 'C']) {
      final element = tester.element(
        find.byWidgetPredicate(
          (w) =>
              w is CastProgressiveArtwork &&
              w.imageUrl == 'https://example.test/$mint.png',
        ),
      );
      // A new element means a new ExtendedImage, a re-run load and a fresh
      // fade — the flicker the per-slide ValueKey exists to prevent.
      expect(element.hashCode, before[mint], reason: 'slide $mint reused');
    }
  });
}
