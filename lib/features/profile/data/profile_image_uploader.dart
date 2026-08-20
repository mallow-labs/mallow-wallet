import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mime/mime.dart';

/// Longest edge kept when re-encoding, mirroring the reference web client's
/// `resizeProfileImage`. The largest rendition mallow ever serves is well
/// under this, while a picture straight off a phone camera is several times it.
const _maxDimension = 1200;

/// Quality for the re-encode, matching the reference web client's 0.8.
const _reencodeQuality = 80;

/// Re-encoding flattens animation to a single frame and rasterizes vectors, so
/// these upload untouched. Going direct to S3 makes that cost the API nothing —
/// only the user's own upload time.
const _unresizableTypes = <String>{
  'image/gif',
  'image/apng',
  'image/vnd.mozilla.apng',
  'image/svg+xml',
};

/// `MAX_PROFILE_FILE_SIZE_MB` from the server's shared types. This is a
/// condition of the presigned policy, so S3 itself rejects a larger body — with
/// an XML error the user can't read. Checked here to fail with a sentence
/// instead.
const _maxUploadMb = 20;

/// Uploads a profile picture / banner straight to S3 with a presigned POST and
/// returns the `path` to pass to `POST /v1/user/updateProfile`.
///
/// The upload deliberately bypasses the API: posting the file to the backend
/// meant it was received in full, spooled to disk, then re-uploaded to the same
/// bucket with the response blocked on both legs, which routinely pushed
/// `updateProfile` past 30s on a multi-MB picture. Going direct removes the
/// second leg. Mirrors `uploadProfileImage` in the reference web client.
///
/// Nothing here is trusted server-side: the key, the content type and the size
/// ceiling are all baked into the signature, so a tampered-with form is
/// rejected by S3, and `updateProfile` re-derives the stored URL from the
/// caller's own signed prefix rather than from the path we hand back.
@lazySingleton
class ProfileImageUploader {
  ProfileImageUploader(this._api)
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(minutes: 2),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );

  /// The S3 leg has no seam otherwise — injectable would hand us the app's
  /// authenticated Dio, which is exactly what must not reach a non-mallow host.
  @visibleForTesting
  ProfileImageUploader.withDio(this._api, this._dio);

  final api.MallowApiClient _api;

  /// S3 is not a mallow host — this Dio deliberately carries none of the app's
  /// auth interceptors, and no headers beyond what the multipart body needs.
  final Dio _dio;

  /// Presign, upload, and return the storage path for the picked image.
  ///
  /// Throws [ProfileImageUploadException] when the file is unusable or the S3
  /// leg fails; a rejected presign (bad mime type, locked gif pfp) surfaces as
  /// the backend's own `DioException` so the existing error mapping applies.
  Future<String> upload({
    required Uint8List bytes,
    required String fileName,
    required api.CreateProfileUploadRequestType type,
  }) async {
    final image = await _prepare(bytes, fileName);

    if (image.bytes.length > _maxUploadMb * 1024 * 1024) {
      throw const ProfileImageUploadException(
        'Image is too large. Please pick one under ${_maxUploadMb}MB.',
      );
    }

    final presigned = (await _api.createProfileUpload(
      api.CreateProfileUploadRequest(type: type, mimeType: image.mimeType),
    )).result;

    final form = FormData();
    // Every signed field is an exact-match condition of the policy, so they go
    // up verbatim — and S3 ignores everything after the file part, so the file
    // goes last. Dio finalizes `fields` ahead of `files`, which is that order.
    presigned.fields.forEach(
      (key, value) => form.fields.add(MapEntry(key, '$value')),
    );
    form.files.add(
      MapEntry(
        'file',
        MultipartFile.fromBytes(
          image.bytes,
          filename: image.fileName,
          contentType: DioMediaType.parse(image.mimeType),
        ),
      ),
    );

    try {
      // A successful presigned POST is a bodyless 204, and a rejected one is
      // an XML fault — neither is JSON, so don't ask Dio to parse it.
      await _dio.post<void>(
        presigned.url,
        data: form,
        options: Options(responseType: ResponseType.plain),
      );
    } on DioException catch (e) {
      throw ProfileImageUploadException(
        'Could not upload the image. Please try again. '
        '(${e.response?.statusCode ?? e.message})',
      );
    }

    return presigned.path;
  }

  /// Downscale [bytes] where that helps, and resolve the mime type the presign
  /// has to be signed for — it is an exact-match condition, so it must describe
  /// what actually gets uploaded, not what was picked.
  Future<({Uint8List bytes, String fileName, String mimeType})> _prepare(
    Uint8List bytes,
    String fileName,
  ) async {
    final sourceType = lookupMimeType(
      fileName,
      headerBytes: bytes.take(64).toList(),
    );

    if (sourceType != null && _unresizableTypes.contains(sourceType)) {
      return (bytes: bytes, fileName: fileName, mimeType: sourceType);
    }

    final resized = await _downscale(bytes);
    // An already-optimized source can beat the re-encode, small PNGs
    // especially.
    if (resized != null && resized.length < bytes.length) {
      return (
        bytes: resized,
        fileName: '${fileName.replaceAll(RegExp(r'\.[^.]+$'), '')}.webp',
        mimeType: 'image/webp',
      );
    }

    // The source uploads as-is from here, so its own type is what the presign
    // gets signed for — and the backend rejects anything outside its image
    // whitelist. A type neither the magic number nor the extension resolved
    // would presign as `application/octet-stream` and come back as a raw 400
    // scraped for its `message`, so fail with a sentence instead. Only the
    // re-encode declining leaves this reachable: an unrecognized source that
    // does decode comes back above as `image/webp`.
    if (sourceType == null || !sourceType.startsWith('image/')) {
      throw const ProfileImageUploadException(
        'That file is not a recognized image. '
        'Please pick a PNG, JPEG, GIF, or WebP.',
      );
    }

    return (bytes: bytes, fileName: fileName, mimeType: sourceType);
  }

  /// Re-encode [bytes] to a WebP no larger than [_maxDimension] on its longest
  /// edge, or null when that isn't possible or isn't worth doing.
  ///
  /// WebP (not JPEG) because a profile picture is routinely a PNG with
  /// transparency, which JPEG would flatten onto black.
  Future<Uint8List?> _downscale(Uint8List bytes) async {
    try {
      final (width, height) = await _intrinsicSize(bytes);
      final longest = math.max(width, height);
      if (longest <= _maxDimension) return null;

      final scale = longest / _maxDimension;
      final resized = await FlutterImageCompress.compressWithList(
        bytes,
        // The plugin scales by `max(1, min(w / minWidth, h / minHeight))`, so
        // handing it the already-scaled dimensions makes that exactly `scale`
        // and lands the LONG edge on _maxDimension. Passing _maxDimension for
        // both would bound the short edge instead, which leaves a wide banner
        // — the one case that needs this most — untouched.
        minWidth: (width / scale).round(),
        minHeight: (height / scale).round(),
        quality: _reencodeQuality,
        format: CompressFormat.webp,
      );
      return resized.isEmpty ? null : resized;
    } catch (e) {
      // Unreadable header, or a device whose encoder can't produce WebP. The
      // original still uploads; the server-side whitelist stays the authority
      // on whether it's acceptable.
      debugPrint('[ProfileImageUploader] Resize skipped: $e');
      return null;
    }
  }

  /// Pixel dimensions of an encoded image, read from its header — no full
  /// decode, so a 4000px source doesn't cost ~64MB of RGBA to measure.
  Future<(int, int)> _intrinsicSize(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final ui.ImageDescriptor descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } finally {
      buffer.dispose();
    }
    try {
      return (descriptor.width, descriptor.height);
    } finally {
      descriptor.dispose();
    }
  }
}

/// A profile image could not be prepared or uploaded. Carries a message meant
/// for the user — `EditProfileScreen` shows it verbatim.
class ProfileImageUploadException implements Exception {
  const ProfileImageUploadException(this.message);

  final String message;

  @override
  String toString() => 'ProfileImageUploadException: $message';
}
