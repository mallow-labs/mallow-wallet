import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/features/cast/models/cast_display_type.dart';
import 'package:mallow_wallet/features/cast/models/cast_media_type.dart';
import 'package:mallow_wallet/features/cast/models/cast_overlay_config.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';

CastQueueItem _item(String mint, {String? artist}) => CastQueueItem(
  mintAccount: mint,
  title: 'Title $mint',
  imageUrl: 'https://example.test/$mint.png',
  artistName: artist,
);

void main() {
  // These suites assert URL *shapes*, which only exist once the build declares
  // the hosts that produce them. Placeholder hosts on purpose: the rule under
  // test is the transform, never one deployment's domain.
  setUp(() {
    Config.debugOverrides.addAll({
      'IMAGE_CDN_BASE_URL': 'https://images.example.com',
    });
  });

  tearDown(Config.debugOverrides.clear);

  group('CastOverlayConfigFromQueue.from', () {
    test('mirrors session toggles and item metadata', () {
      final queue = CastQueue(
        items: [_item('A'), _item('B'), _item('C'), _item('D')],
        currentIndex: 1, // playing B; prev=A, next=C
      );
      final cfg = CastOverlayConfigFromQueue.from(queue, queue.currentItem!);
      expect(cfg.showQr, isTrue);
      expect(cfg.showCaption, isTrue);
      expect(cfg.qrUrl, 'https://mallow.art/artwork/B');
      expect(cfg.title, 'Title B');
      expect(cfg.prevImageUrl, 'https://example.test/A.png');
      expect(cfg.nextImageUrl, 'https://example.test/C.png');
    });

    test('qrUrl is null when showQr is off', () {
      // Receiver shouldn't render a stale QR after the user disables it.
      final queue = CastQueue(items: [_item('A')], showQr: false);
      final cfg = CastOverlayConfigFromQueue.from(queue, queue.currentItem!);
      expect(cfg.qrUrl, isNull);
    });

    test('subtitle falls back to null when item has no artistName', () {
      final queue = CastQueue(items: [_item('A')]);
      final cfg = CastOverlayConfigFromQueue.from(queue, queue.currentItem!);
      expect(cfg.subtitle, isNull);
    });

    test('tile mode collapses to fitToScreen when queue has <3 items', () {
      // Carousel reads as broken without prev+next peeks, so a 1- or 2-item
      // queue should not actually render tile on the receiver. The user's
      // preference is preserved on the queue itself.
      final two = CastQueue(
        items: [_item('A'), _item('B')],
        displayType: CastDisplayType.tile,
      );
      final cfg = CastOverlayConfigFromQueue.from(two, two.currentItem!);
      expect(cfg.displayType, CastDisplayType.fitToScreen);
      expect(two.displayType, CastDisplayType.tile);
    });

    test('tile mode passes through when queue has ≥3 items', () {
      final three = CastQueue(
        items: [_item('A'), _item('B'), _item('C')],
        displayType: CastDisplayType.tile,
      );
      final cfg = CastOverlayConfigFromQueue.from(three, three.currentItem!);
      expect(cfg.displayType, CastDisplayType.tile);
    });

    test('non-tile display types pass through regardless of length', () {
      final solo = CastQueue(
        items: [_item('A')],
        displayType: CastDisplayType.fitToScreen,
      );
      final cfg = CastOverlayConfigFromQueue.from(solo, solo.currentItem!);
      expect(cfg.displayType, CastDisplayType.fitToScreen);
    });

    test('peek slots wrap with repeat-all at the edges', () {
      final atEnd = CastQueue(
        items: [_item('A'), _item('B'), _item('C')],
        currentIndex: 2,
      );
      final cfg = CastOverlayConfigFromQueue.from(atEnd, atEnd.currentItem!);
      expect(cfg.nextImageUrl, 'https://example.test/A.png');
      expect(cfg.prevImageUrl, 'https://example.test/B.png');
    });

    test('peek slots are null at the edges with repeat-off', () {
      final atStart = CastQueue(
        items: [_item('A'), _item('B')],
        repeatMode: CastRepeatMode.off,
      );
      final cfg = CastOverlayConfigFromQueue.from(
        atStart,
        atStart.currentItem!,
      );
      expect(cfg.prevImageUrl, isNull);
      expect(cfg.nextImageUrl, 'https://example.test/B.png');
    });
  });

  group('CastOverlayConfig JSON', () {
    test('roundtrips through fromJson/toJson', () {
      const original = CastOverlayConfig(
        showQr: false,
        title: 'T',
        subtitle: 'S',
        displayType: CastDisplayType.fitToScreen,
        prevImageUrl: 'p',
        nextImageUrl: 'n',
      );
      final round = CastOverlayConfig.fromJson(original.toJson());
      expect(round, original);
    });
  });

  group('forHtmlReceiver', () {
    // The Chromecast receiver is a browser: it sets these peek URLs straight
    // onto `<img src>` and can neither fetch an ipfs:// URI nor build a CDN
    // bucket itself. The Flutter receivers keep the raw form and resolve at
    // render time, so this transform is the wire boundary between the two.
    const ipfsSource = 'ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG';

    test('resolves both peek URLs to fetchable posters', () {
      const raw = CastOverlayConfig(
        prevImageUrl: ipfsSource,
        nextImageUrl: 'https://x.test/next.png',
      );
      final wire = raw.forHtmlReceiver;
      expect(wire.prevImageUrl, startsWith('https://images.example.com/'));
      expect(wire.nextImageUrl, startsWith('https://images.example.com/'));
    });

    test('agrees with posterUrl, so tile direction detection still works', () {
      // `renderTile` matches the incoming item's imageUrl (also a poster, set
      // by ChromecastCastService.sendMedia) against the previous triple's
      // prev/next. Any disagreement between the two makes every advance look
      // like a non-adjacent jump and the carousel snaps instead of animating.
      const raw = CastOverlayConfig(nextImageUrl: 'https://x.test/next.png');
      expect(
        raw.forHtmlReceiver.nextImageUrl,
        ArtworkMediaResolver.posterUrl('https://x.test/next.png'),
      );
    });

    test('leaves absent peeks absent at the ends of an unwrapped queue', () {
      // Null = no neighbour at all; empty = a neighbour with no artwork URL.
      // Both must survive untouched, since `posterUrl('')` is `''` and a
      // fabricated CDN URL for either would render a broken peek slot.
      const raw = CastOverlayConfig(nextImageUrl: '');
      final wire = raw.forHtmlReceiver;
      expect(wire.prevImageUrl, isNull);
      expect(wire.nextImageUrl, '');
    });

    test('leaves the rest of the overlay untouched', () {
      const raw = CastOverlayConfig(
        showQr: false,
        title: 'T',
        subtitle: 'S',
        qrUrl: 'https://mallow.art/artwork/A',
        displayType: CastDisplayType.tile,
      );
      expect(raw.forHtmlReceiver, raw);
    });
  });
}
