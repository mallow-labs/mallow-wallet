import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';

/// Quality passed to the JPEG encoder. Close enough to what `image_picker`
/// already does to HEIC on iOS that the two import paths produce comparable
/// files, without the ~3x size of a lossless re-encode.
const _jpegQuality = 95;

/// Large enough to exceed any camera sensor. The plugin's scale factor is
/// `max(1, min(width / minWidth, height / minHeight))`, so a minimum that is
/// never reached pins the factor at 1 and disables downscaling — we are
/// converting a container, not compressing artwork.
const _noDownscale = 100000;

/// Transcodes HEIC/HEIF [bytes] to JPEG, returning null when the platform
/// cannot decode them.
///
/// Only reachable for stills the system pickers hand back with a `.heic` /
/// `.heif` name. On iOS that is the Files browser alone: the photo picker
/// already re-encodes HEIC to JPEG itself (`image_picker_ios` sniffs the
/// first byte, misses the HEIF magic, and falls through to its JPEG
/// default). Android converts nothing, so both of its sources land here.
///
/// Returns null rather than throwing when the decode fails — most
/// importantly on Android below API 28, where `BitmapFactory` has no HEIF
/// support at all. The caller surfaces that as an ordinary unsupported-file
/// rejection.
Future<Uint8List?> transcodeHeicToJpeg(Uint8List bytes) async {
  try {
    final jpeg = await FlutterImageCompress.compressWithList(
      bytes,
      minWidth: _noDownscale,
      minHeight: _noDownscale,
      // Both currently match the plugin's defaults, hence the lint. Stated
      // anyway: the output format and quality are the contract this
      // function's name and its callers depend on, not a detail to inherit
      // from whatever a future version of the package defaults to.
      // ignore: avoid_redundant_argument_values
      quality: _jpegQuality,
      // ignore: avoid_redundant_argument_values
      format: CompressFormat.jpeg,
    );
    return jpeg.isEmpty ? null : jpeg;
  } catch (_) {
    return null;
  }
}
