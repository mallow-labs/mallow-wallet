import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'picked_mint_asset.freezed.dart';

/// A file the user has picked from their device for the mint flow.
///
/// Holds a byte source in memory until it's uploaded to IPFS. The
/// [ipfsHash] / [ipfsUrl] fields are populated after upload so the
/// metadata-JSON builder can reference the pinned CID without
/// re-uploading on retries.
@freezed
sealed class PickedMintAsset with _$PickedMintAsset {
  const factory PickedMintAsset({
    required String fileName,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
    String? ipfsHash,
    String? ipfsUrl,
  }) = _PickedMintAsset;

  const PickedMintAsset._();

  /// True when the main artwork's mime requires a separate thumbnail
  /// (video/html/glb/pdf) — matches the webapp upload validation.
  bool get needsThumbnail {
    final mt = mimeType.toLowerCase();
    if (mt.startsWith('video/')) return true;
    if (mt == 'application/pdf') return true;
    if (mt == 'text/html' || mt == 'application/x-html') return true;
    if (mt == 'model/gltf-binary' || fileName.toLowerCase().endsWith('.glb')) {
      return true;
    }
    return false;
  }

  bool get isImage => mimeType.toLowerCase().startsWith('image/');
  bool get isVideo => mimeType.toLowerCase().startsWith('video/');

  /// SVG is an image everywhere downstream (`FileCategory.image`, no
  /// thumbnail required) but needs `flutter_svg` rather than a raster
  /// decoder to preview locally.
  bool get isSvg {
    final mt = mimeType.toLowerCase();
    return mt == 'image/svg+xml' || mt == 'image/svg';
  }
}
