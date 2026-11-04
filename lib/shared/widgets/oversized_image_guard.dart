import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Pixel budget for an image the engine has to decode at full size.
///
/// A decode cap (`memCacheWidth`, [ResizeImage]) only shrinks the *result*.
/// The engine can decode a JPEG straight to a fraction of its size, but PNG,
/// GIF and WebP are decoded at full resolution first and scaled afterwards. A
/// 13500×16244 PNG therefore needs ~877 MB of RGBA however small its tile, and
/// iOS kills the app for it. The image CDN never serves anything near this
/// size; such files only arrive when it hands back the raw original (it
/// redirects there when it cannot resize one) or through the direct-gateway
/// fallback. 50 Mpx is ~200 MB decoded: room for any real artwork, and well
/// short of the originals that have killed the app.
const int kMaxFullDecodePixels = 50 * 1000 * 1000;

/// Bytes needed to read the dimensions of every format [imageHeaderSize]
/// knows. A stream shorter than this is passed through unchecked.
const int _headerBytes = 30;

/// Thrown into an image download that would decode past
/// [kMaxFullDecodePixels]. The image widget treats it like any failed load.
class OversizedImageException implements Exception {
  const OversizedImageException(this.url, this.width, this.height);

  final String url;
  final int width;
  final int height;

  @override
  String toString() =>
      'OversizedImageException: ${width}x$height exceeds the '
      '$kMaxFullDecodePixels-pixel decode budget ($url)';
}

/// [FileService] that aborts a download as soon as its header shows an image
/// [kMaxFullDecodePixels] would refuse, before the bytes reach the disk cache
/// or the decoder. Every other response passes through untouched.
class OversizedImageGuardFileService extends FileService {
  OversizedImageGuardFileService(this._inner);

  final FileService _inner;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async => _GuardedResponse(await _inner.get(url, headers: headers), url);
}

class _GuardedResponse implements FileServiceResponse {
  _GuardedResponse(this._inner, this._url);

  final FileServiceResponse _inner;
  final String _url;

  @override
  Stream<List<int>> get content => guardImageStream(_inner.content, url: _url);

  @override
  int? get contentLength => _inner.contentLength;

  @override
  int get statusCode => _inner.statusCode;

  @override
  DateTime get validTill => _inner.validTill;

  @override
  String? get eTag => _inner.eTag;

  @override
  String get fileExtension => _inner.fileExtension;
}

/// Re-emits [source], unless its header names a full-decode format larger than
/// [maxPixels]: then it throws [OversizedImageException] and cancels [source],
/// so the rest of the file is never downloaded.
@visibleForTesting
Stream<List<int>> guardImageStream(
  Stream<List<int>> source, {
  required String url,
  int maxPixels = kMaxFullDecodePixels,
}) async* {
  final head = BytesBuilder(copy: false);
  var checked = false;
  await for (final chunk in source) {
    if (checked) {
      yield chunk;
      continue;
    }
    head.add(chunk);
    if (head.length < _headerBytes) continue;
    checked = true;
    final bytes = head.takeBytes();
    final size = imageHeaderSize(bytes);
    if (size != null && size.width * size.height > maxPixels) {
      throw OversizedImageException(url, size.width, size.height);
    }
    yield bytes;
  }
  if (head.isNotEmpty) yield head.takeBytes();
}

/// Width and height from the header of a PNG, GIF or WebP, or `null` for any
/// other format (JPEG included: it decodes scaled, so its size is no threat)
/// or a header too short to read.
@visibleForTesting
({int width, int height})? imageHeaderSize(Uint8List b) {
  bool ascii(int at, String s) {
    if (b.length < at + s.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (b[at + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  int be32(int at) =>
      (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
  int le16(int at) => b[at] | (b[at + 1] << 8);
  int le24(int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16);

  // PNG: 8-byte signature, then the IHDR chunk's big-endian width and height.
  if (b.length >= 24 && b[0] == 0x89 && ascii(1, 'PNG') && ascii(12, 'IHDR')) {
    return (width: be32(16), height: be32(20));
  }
  // GIF: the logical screen size, little-endian, right after the signature.
  if (b.length >= 10 && ascii(0, 'GIF8')) {
    return (width: le16(6), height: le16(8));
  }
  if (ascii(0, 'RIFF') && ascii(8, 'WEBP')) {
    // Lossy: 14-bit sizes after the frame tag and start code.
    if (ascii(12, 'VP8 ') && b.length >= 30) {
      return (width: le16(26) & 0x3fff, height: le16(28) & 0x3fff);
    }
    // Lossless: two 14-bit fields, each stored minus one, after the 0x2f
    // signature byte.
    if (ascii(12, 'VP8L') && b.length >= 25) {
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return (width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1);
    }
    // Extended: 24-bit canvas sizes, each stored minus one.
    if (ascii(12, 'VP8X') && b.length >= 30) {
      return (width: le24(24) + 1, height: le24(27) + 1);
    }
  }
  return null;
}
