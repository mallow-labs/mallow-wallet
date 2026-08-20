import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/cast/widgets/cast_animated_artwork.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// A video-only (or animation-only) NFT carries no still image, so `imageUrl`
/// reaches [CastProgressiveArtwork] empty — the repositories default it to
/// `item.imageUrl ?? ''` and nothing filters it out of the cast queue. Short-
/// circuiting to the shimmer on an empty poster stranded the receiver on it
/// forever: the player initialised from `animationUrl` and was then never
/// shown. These tests pin that the poster is only one of the layers worth
/// rendering, and that the shimmer survives for the case where it is the only
/// honest answer.
void main() {
  Future<void> pumpArtwork(WidgetTester tester, Widget artwork) {
    return tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(body: artwork),
      ),
    );
  }

  testWidgets('empty poster still renders the video player upgrade', (
    tester,
  ) async {
    await pumpArtwork(
      tester,
      const CastProgressiveArtwork(
        imageUrl: '',
        fit: BoxFit.cover,
        upgrade: Text('player'),
      ),
    );
    await tester.pump();

    // The upgrade is what the viewer came for; the shimmer stays underneath
    // only as the base layer, never as the whole screen.
    expect(find.text('player'), findsOneWidget);
  });

  testWidgets('empty poster with nothing to upgrade to keeps the shimmer', (
    tester,
  ) async {
    await pumpArtwork(
      tester,
      const CastProgressiveArtwork(imageUrl: '', fit: BoxFit.cover),
    );
    await tester.pump();

    expect(find.byType(CastShimmerSurface), findsOneWidget);
  });
}
