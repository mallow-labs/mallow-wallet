/// Off-chain token-metadata JSON builder.
///
/// Direct port of the webapp's `tokenMetadata` builder (spec-locked by its
/// own tests) plus the mime → category table from its file-type helper.
///
/// This shape is not cosmetic: the indexer derives **every** render from
/// `properties.category` + `properties.files`
/// (`assetHelper` `mediaType` / `videoUrl` /
/// `htmlUrl` / `modelUrl` / `pdfUrl`), and both mallow gateways are
/// extensionless so its extension fallback never fires. Emitting
/// `category: 'image'` with no `files` array makes a video index as a still
/// and loses a `.glb` / `.html` artwork entirely — and the JSON is pinned
/// before the tx is built, so it is immutable in practice.
library;

/// One entry of `properties.files` — mirrors `MetadataFile` in
/// the server's shared Solana types.
class MintMetadataFile {
  const MintMetadataFile({required this.uri, required this.type});

  /// Public gateway URL of the uploaded file.
  final String uri;

  /// Mime type (`image/png`, `video/mp4`, `model/gltf-binary`, …).
  final String type;

  bool get isImage => type.toLowerCase().startsWith('image/');

  Map<String, dynamic> toJson() => {'uri': uri, 'type': type};
}

/// The webapp's `FileCategory`, from its file-type helper. The wire value
/// is what lands in `properties.category`; note `model` serializes as `vr`.
enum MintFileCategory {
  image('image'),
  video('video'),
  model('vr'),
  html('html'),
  audio('audio'),
  document('document');

  const MintFileCategory(this.wireValue);
  final String wireValue;
}

/// `FILE_CATEGORY_BY_MIME_TYPE` — the whitelisted mime types, verbatim from
/// `fileType`. Anything outside the table falls back to a type-prefix
/// match (see [mintFileCategoryForMimeType]).
const _categoryByMimeType = <String, MintFileCategory>{
  // WHITELISTED_IMAGE_TYPES
  'image/png': MintFileCategory.image,
  'image/gif': MintFileCategory.image,
  'image/jpeg': MintFileCategory.image,
  'image/jpg': MintFileCategory.image,
  'image/webp': MintFileCategory.image,
  'image/avif': MintFileCategory.image,
  'image/bmp': MintFileCategory.image,
  'image/apng': MintFileCategory.image,
  'image/svg': MintFileCategory.image,
  'image/vnd.mozilla.apng': MintFileCategory.image,
  'image/svg+xml': MintFileCategory.image,
  // WHITELISTED_VIDEO_TYPES
  'video/mp4': MintFileCategory.video,
  'video/webm': MintFileCategory.video,
  'video/quicktime': MintFileCategory.video,
  // WHITELISTED_MODEL_TYPES
  'model/gltf-binary': MintFileCategory.model,
  'model/glb': MintFileCategory.model,
  // WHITELISTED_HTML_TYPES
  'text/html': MintFileCategory.html,
  // WHITELISTED_DOCUMENT_TYPES
  'application/pdf': MintFileCategory.document,
  // WHITELISTED_AUDIO_TYPES
  'audio/mp3': MintFileCategory.audio,
  'audio/wav': MintFileCategory.audio,
  'audio/ogg': MintFileCategory.audio,
  'audio/m4a': MintFileCategory.audio,
  'audio/mpeg': MintFileCategory.audio,
  'audio/mp4': MintFileCategory.audio,
};

/// Category for [mimeType], or null when it can't be classified.
///
/// The webapp indexes straight into `FILE_CATEGORY_BY_MIME_TYPE` and yields
/// `undefined` for anything unlisted. We keep the same table but add a
/// type-prefix fallback (`image/*`, `video/*`, `audio/*`, `model/*`), which
/// only fires where the webapp would have emitted no category at all — so it
/// is never a divergence in a case the webapp handles.
MintFileCategory? mintFileCategoryForMimeType(String mimeType) {
  final mt = mimeType.toLowerCase().trim();
  final exact = _categoryByMimeType[mt];
  if (exact != null) return exact;
  if (mt.startsWith('image/')) return MintFileCategory.image;
  if (mt.startsWith('video/')) return MintFileCategory.video;
  if (mt.startsWith('audio/')) return MintFileCategory.audio;
  if (mt.startsWith('model/')) return MintFileCategory.model;
  return null;
}

/// Build the metadata JSON pinned to IPFS and referenced by the on-chain
/// `uri`. Mirrors `getTokenMetadata` key for key.
///
/// [assets] is ordered and **the first entry is the primary asset** — it
/// drives `properties.category` and, when it isn't an image, `animation_url`
/// (plus `video` for the video category). `image` is always the first
/// *image* in the list, i.e. the thumbnail for a video / html / glb mint.
///
/// Divergence from the webapp, deliberately: `getTokenMetadata` throws on an
/// empty [assets] list or a list with no image. Here the same JSON builder
/// also runs while an edit is still prefilling and while the confirm sheet
/// simulates the tx cost, where a partially-hydrated form must not blow up
/// the bloc — so those cases degrade to a null `image` / absent `category`
/// instead of throwing. The mint pipeline's own `mainAsset` guard is what
/// stops an assetless mint.
Map<String, dynamic> buildTokenMetadataJson({
  required List<MintMetadataFile> assets,
  required String name,
  required String description,
  required List<Map<String, dynamic>> attributes,
  required List<String> tags,
  bool nsfw = false,
  String? externalUrl,
  String? banner,
  String? processVideoUri,
}) {
  final primary = assets.isEmpty ? null : assets.first;
  final category = primary == null
      ? null
      : mintFileCategoryForMimeType(primary.type);
  String? image;
  for (final asset in assets) {
    if (asset.isImage) {
      image = asset.uri;
      break;
    }
  }

  return {
    'name': name,
    'description': description,
    'image': image,
    'attributes': attributes,
    'tags': tags,
    'properties': {
      if (category != null) 'category': category.wireValue,
      'files': assets.map((a) => a.toJson()).toList(),
    },
    // Non-image primaries carry the playable/renderable URL in
    // `animation_url`; video additionally duplicates it into `video`
    // (`tokenMetadata`).
    if (primary != null && category != MintFileCategory.image)
      'animation_url': primary.uri,
    if (primary != null && category == MintFileCategory.video)
      'video': primary.uri,
    'external_url': ?externalUrl,
    'banner': ?banner,
    'processVideo': ?processVideoUri,
    if (nsfw) 'nsfw': true,
  };
}
