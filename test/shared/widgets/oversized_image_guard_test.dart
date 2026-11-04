import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/widgets/oversized_image_guard.dart';

Uint8List _be32(int v) => Uint8List.fromList([
  v >> 24 & 0xff,
  v >> 16 & 0xff,
  v >> 8 & 0xff,
  v & 0xff,
]);

/// PNG signature + IHDR chunk header for a [w]×[h] image, padded with a body.
Uint8List _png(int w, int h, {int body = 64}) => Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0, 0, 0, 13, ...'IHDR'.codeUnits,
  ..._be32(w), ..._be32(h),
  ...List.filled(body, 7),
]);

Uint8List _gif(int w, int h) => Uint8List.fromList([
  ...'GIF89a'.codeUnits,
  w & 0xff,
  w >> 8,
  h & 0xff,
  h >> 8,
  ...List.filled(40, 0),
]);

/// WebP container with a [chunk] fourcc and the given chunk payload bytes.
Uint8List _webp(String chunk, List<int> payload) => Uint8List.fromList([
  ...'RIFF'.codeUnits,
  0,
  0,
  0,
  0,
  ...'WEBP'.codeUnits,
  ...chunk.codeUnits,
  0,
  0,
  0,
  0,
  ...payload,
  ...List.filled(16, 0),
]);

Uint8List _jpeg() => Uint8List.fromList([
  0xff, 0xd8, 0xff, 0xe0, //
  ...List.filled(60, 1),
]);

/// Splits [bytes] into [size]-byte chunks, so headers straddle chunk edges.
Stream<List<int>> _chunked(Uint8List bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

Future<Uint8List> _collect(Stream<List<int>> s) async {
  final out = BytesBuilder();
  await for (final c in s) {
    out.add(c);
  }
  return out.takeBytes();
}

class _FakeResponse implements FileServiceResponse {
  _FakeResponse(this.content);

  @override
  final Stream<List<int>> content;
  @override
  int? get contentLength => null;
  @override
  int get statusCode => 200;
  @override
  DateTime get validTill => DateTime(2100);
  @override
  String? get eTag => 'etag';
  @override
  String get fileExtension => '.png';
}

class _FakeFileService extends FileService {
  _FakeFileService(this.bytes);

  final Uint8List bytes;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async => _FakeResponse(_chunked(bytes, 5));
}

void main() {
  group('imageHeaderSize', () {
    test('reads PNG, GIF and the three WebP variants', () {
      expect(imageHeaderSize(_png(13500, 16244)), (
        width: 13500,
        height: 16244,
      ));
      expect(imageHeaderSize(_gif(640, 480)), (width: 640, height: 480));

      // Lossy: frame tag (3 bytes), start code, then 14-bit sizes.
      expect(
        imageHeaderSize(
          _webp('VP8 ', [0, 0, 0, 0x9d, 0x01, 0x2a, 0x10, 0x27, 0xe0, 0x2e]),
        ),
        (width: 10000, height: 12000),
      );
      // Lossless: 0x2f, then width-1 and height-1 packed into 14-bit fields.
      const w = 4000, h = 3000;
      const bits = (w - 1) | ((h - 1) << 14);
      expect(
        imageHeaderSize(
          _webp('VP8L', [
            0x2f,
            bits & 0xff,
            bits >> 8 & 0xff,
            bits >> 16 & 0xff,
            bits >> 24 & 0xff,
          ]),
        ),
        (width: w, height: h),
      );
      // Extended: 4 flag bytes, then 24-bit width-1 and height-1.
      expect(
        imageHeaderSize(
          _webp('VP8X', [0, 0, 0, 0, 0x0f, 0x27, 0, 0x1f, 0x4e, 0]),
        ),
        (width: 10000, height: 20000),
      );
    });

    test('ignores JPEG and unknown formats', () {
      expect(imageHeaderSize(_jpeg()), isNull);
      expect(imageHeaderSize(Uint8List.fromList(List.filled(40, 3))), isNull);
    });
  });

  group('guardImageStream', () {
    test('passes an image within budget through byte-for-byte', () async {
      final png = _png(4000, 4000, body: 500);
      expect(await _collect(guardImageStream(_chunked(png, 7), url: 'u')), png);
    });

    test('passes a huge JPEG, which decodes scaled', () async {
      final jpeg = _jpeg();
      expect(
        await _collect(guardImageStream(_chunked(jpeg, 3), url: 'u')),
        jpeg,
      );
    });

    test('passes a stream shorter than any header', () async {
      final tiny = Uint8List.fromList([1, 2, 3]);
      expect(
        await _collect(guardImageStream(Stream.value(tiny), url: 'u')),
        tiny,
      );
    });

    test(
      'refuses an oversized PNG from its header and stops the download',
      () async {
        // The original that killed the app: 13500×16244, ~877 MB decoded.
        final png = _png(13500, 16244, body: 10000);
        var cancelled = false;
        var sent = 0;
        final source = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        addTearDown(source.close);
        source.onListen = () async {
          for (var i = 0; i < png.length && !cancelled; i += 8) {
            sent += 8;
            source.add(png.sublist(i, i + 8));
            await Future<void>.delayed(Duration.zero);
          }
        };

        await expectLater(
          guardImageStream(source.stream, url: 'https://x/run.png').toList(),
          throwsA(
            isA<OversizedImageException>()
                .having((e) => e.width, 'width', 13500)
                .having((e) => e.height, 'height', 16244),
          ),
        );
        expect(cancelled, isTrue);
        expect(sent, lessThan(100));
      },
    );
  });

  test('the file service guards the content and keeps the metadata', () async {
    final service = OversizedImageGuardFileService(
      _FakeFileService(_png(20000, 20000)),
    );
    final response = await service.get('https://x/big.png');
    expect(response.statusCode, 200);
    expect(response.eTag, 'etag');
    expect(response.fileExtension, '.png');
    await expectLater(
      response.content.toList(),
      throwsA(isA<OversizedImageException>()),
    );

    final ok = await OversizedImageGuardFileService(
      _FakeFileService(_png(100, 100)),
    ).get('https://x/small.png');
    expect(await _collect(ok.content), _png(100, 100));
  });
}
