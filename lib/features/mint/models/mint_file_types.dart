/// What each mint upload slot accepts.
///
/// Port of the webapp's `fileType` whitelists and
/// the `useAssetDropzone` flags each dropzone passes in
/// `CreateContext`. It belongs next to
/// [MintFileCategory] rather than in the widget: the two are two halves of
/// one port, and a format allowed here but unclassified there mints an
/// artwork with no `properties.category` — which the indexer cannot recover
/// from, since the metadata JSON is pinned before the tx is built.
library;

import 'package:mime/mime.dart';

import '../../../shared/utils/heic_import.dart';

/// Extensions the `mime` package's table has no entry for. `apng` is the
/// only whitelisted format it misses, and the miss is not cosmetic: an
/// unmapped extension becomes `application/octet-stream`, which
/// [mintFileCategoryForMimeType] cannot classify, which pins a metadata JSON
/// with no `properties.category`. The webapp never needed this map — the
/// browser hands it `file.type` directly.
const _extraMimeTypes = <String, String>{'apng': 'image/apng'};

/// Mime type for an uploaded file, falling back to `application/octet-stream`
/// exactly as the caller previously did on its own.
String mintMimeTypeForFileName(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  return _extraMimeTypes[ext] ??
      lookupMimeType(fileName) ??
      'application/octet-stream';
}

/// `WHITELISTED_IMAGE_EXTS`.
const kMintImageExtensions = <String>[
  'png',
  'gif',
  'jpeg',
  'jpg',
  'webp',
  'avif',
  'bmp',
  'apng',
  'svg',
];

/// `WHITELISTED_VIDEO_EXTS`.
const kMintVideoExtensions = <String>['mp4', 'mov', 'webm'];

/// `WHITELISTED_AUDIO_EXTS`.
const kMintAudioExtensions = <String>['mp3', 'wav', 'ogg', 'm4a'];

/// `WHITELISTED_MODEL_EXTS`.
const kMintModelExtensions = <String>['glb'];

/// `WHITELISTED_HTML_EXTS`.
const kMintHtmlExtensions = <String>['html'];

/// `WHITELISTED_DOCUMENT_EXTS`.
const kMintDocumentExtensions = <String>['pdf'];

/// What one upload slot accepts. Keeping the allowlist, the size cap and the
/// caption in one value is what stops the dropzone caption from drifting
/// away from what the picker actually takes — before this existed they had
/// already diverged on the exclusive-content slot.
class MintAcceptRules {
  const MintAcceptRules({
    required this.extensions,
    required this.maxSizeBytes,
    required this.summary,
    this.allowsStills = true,
  });

  /// Extensions this slot keeps, once any import-time conversion has run.
  /// HEIC is deliberately absent — see [pickable].
  final List<String> extensions;

  final int maxSizeBytes;

  /// Human list for the caption and the rejection snackbar, e.g.
  /// `.mp4, .mov or .webm`. Written out rather than derived from
  /// [extensions] because the image set alone is nine of them.
  final String summary;

  /// Whether the slot takes stills, which is what makes HEIC importable and
  /// what decides which system photo picker to open.
  final bool allowsStills;

  /// Extensions the system pickers may hand back. Adds HEIC/HEIF wherever
  /// stills are allowed so camera-roll photos survive the filter long enough
  /// to be transcoded to JPEG on import.
  List<String> get pickable =>
      allowsStills ? <String>[...extensions, ...kHeicExtensions] : extensions;

  /// The dropzone caption, e.g. `100mb max  •  .mp4, .mov or .webm`.
  String get caption => '${maxSizeBytes ~/ (1024 * 1024)}mb max  •  $summary';
}

const _stillSummary = '.jpeg, .png, .gif, .webp, .avif, .bmp, .apng or .svg';

/// Main artwork — stills, video, models, HTML and PDF, but no audio.
const kMintMainAssetRules = MintAcceptRules(
  extensions: <String>[
    ...kMintImageExtensions,
    ...kMintVideoExtensions,
    ...kMintModelExtensions,
    ...kMintHtmlExtensions,
    ...kMintDocumentExtensions,
  ],
  maxSizeBytes: 100 * 1024 * 1024,
  summary: 'an image, .mp4, .mov, .webm, .html, .glb or .pdf',
);

/// Thumbnail — stills only. It stands in for the main asset on cards, so the
/// webapp's thumbnail dropzone passes none of the `allow*` flags.
const kMintThumbnailRules = MintAcceptRules(
  extensions: kMintImageExtensions,
  maxSizeBytes: 100 * 1024 * 1024,
  summary: _stillSummary,
);

/// Process video — every video container we support, nothing else.
const kMintProcessVideoRules = MintAcceptRules(
  extensions: kMintVideoExtensions,
  maxSizeBytes: 100 * 1024 * 1024,
  summary: '.mp4, .mov or .webm',
  allowsStills: false,
);

/// Exclusive/unlockable content — the main-asset set plus audio, at the much
/// larger `MAX_UNLOCKABLE_CONTENT_SIZE_MB` cap.
const kMintUnlockableRules = MintAcceptRules(
  extensions: <String>[
    ...kMintImageExtensions,
    ...kMintVideoExtensions,
    ...kMintAudioExtensions,
    ...kMintModelExtensions,
    ...kMintHtmlExtensions,
    ...kMintDocumentExtensions,
  ],
  maxSizeBytes: 500 * 1024 * 1024,
  summary: 'an image, video, audio, .html, .glb or .pdf',
);

/// Collection image and banner — stills only, at the smaller
/// `MAX_COLLECTION_FILE_SIZE_MB` cap.
const kMintCollectionRules = MintAcceptRules(
  extensions: kMintImageExtensions,
  maxSizeBytes: 30 * 1024 * 1024,
  summary: _stillSummary,
);
