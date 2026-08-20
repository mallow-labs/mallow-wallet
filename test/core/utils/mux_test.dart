import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/utils/mux.dart';

void main() {
  const id = 'abc123XYZ';

  group('Mux.streamUrl', () {
    test('returns HLS manifest URL for a playback id', () {
      expect(Mux.streamUrl(id), 'https://stream.mux.com/$id.m3u8');
    });
  });

  group('Mux.posterUrl', () {
    test('returns thumbnail URL for a playback id', () {
      expect(Mux.posterUrl(id), 'https://image.mux.com/$id/thumbnail.jpg');
    });
  });

  group('Mux.previewId', () {
    test('returns clipPlaybackId when both are present', () {
      expect(Mux.previewId('full', 'clip'), 'clip');
    });

    test('falls back to playbackId when clipPlaybackId is null', () {
      expect(Mux.previewId('full', null), 'full');
    });

    test('falls back to playbackId when clipPlaybackId is empty string', () {
      expect(Mux.previewId('full', ''), 'full');
    });

    test('falls back to playbackId when clipPlaybackId is whitespace', () {
      expect(Mux.previewId('full', '   '), 'full');
    });

    test('returns null when both are null', () {
      expect(Mux.previewId(null, null), isNull);
    });

    test('returns null when playbackId is empty and clip is null', () {
      expect(Mux.previewId('', null), isNull);
    });

    test('returns null when both are empty', () {
      expect(Mux.previewId('', ''), isNull);
    });
  });
}
