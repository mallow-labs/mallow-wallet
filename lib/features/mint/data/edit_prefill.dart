import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../core/network/das_api_service.dart';
import '../../artwork/data/artwork_repository.dart';
import '../../artwork/services/artwork_bloc.dart';

/// Snapshot of an asset's current metadata, ready to seed the mint form
/// for an edit. Mirrors the webapp's `onEditAssetFetched` in
/// `CreateContext`:
///
/// - On-chain DAS data is the source of truth for `name`, royalties,
///   `tokenStandard`, supply, and the existing `uri`.
/// - The off-chain JSON at `uri` is fetched best-effort (5s timeout) for
///   the richer fields (description, attributes, image, video, tags).
/// - When the IPFS fetch fails we fall back to the API artwork render —
///   the user can still edit, just from server-cached values rather than
///   the canonical JSON.
class EditNftPrefill {
  const EditNftPrefill({
    required this.mintAccount,
    required this.tokenStandard,
    required this.name,
    required this.description,
    required this.attributes,
    required this.tags,
    required this.nsfw,
    required this.sellerFeeBasisPoints,
    required this.creators,
    required this.isMasterEdition,
    required this.isCollection,
    required this.maxSupply,
    required this.currentSupply,
    required this.isMutable,
    this.updateAuthority,
    this.existingImageUrl,
    this.existingThumbnailUrl,
    this.existingProcessVideoUrl,
    this.existingBannerUrl,
    this.existingUri,
    this.collection,
    this.collectionName,
    this.isMainAssetVideo = false,
    this.existingFileTypesByUri = const <String, String>{},
  });

  final String mintAccount;
  final TokenStandard tokenStandard;

  // Form fields
  final String name;
  final String description;
  final List<NftAttribute> attributes;
  final List<String> tags;
  final bool nsfw;
  final int sellerFeeBasisPoints;

  /// Creators with original on-chain `verified` preserved (NFT/pNFT only;
  /// Core derives verified from the update authority, so it's always
  /// safe to recompute server-side).
  final List<MintCreator> creators;

  /// True for Core master editions — `tokenStandard == coreCollection &&
  /// hasMasterEditionPlugin`. When true, the edition supply step should
  /// be visible and editable (subject to mutability).
  final bool isMasterEdition;

  /// True for plain Core collections — `tokenStandard == coreCollection`
  /// without the master-edition plugin. Mutually exclusive with
  /// [isMasterEdition]. Used to drive the collection variant of the
  /// upload/details steps in edit mode.
  final bool isCollection;

  /// Max supply at the time of fetch. `null` for open editions, `0` for
  /// 1/1, positive integer for limited editions.
  final int? maxSupply;

  /// Current minted count (for master editions). Used to disallow
  /// reducing supply below what's already been printed.
  final int currentSupply;

  final bool isMutable;

  /// On-chain update authority of the asset — the wallet the edit tx must be
  /// signed by. Used to auto-switch the active signer to the holding session
  /// wallet before building/signing the edit (mirrors transfer/burn/list).
  final String? updateAuthority;

  // Existing IPFS URLs — reused as-is when the user doesn't pick a new
  // asset (skipping the IPFS upload step entirely).
  final String? existingImageUrl;
  final String? existingThumbnailUrl;
  final String? existingProcessVideoUrl;

  /// Collection banner URL pulled from the off-chain JSON `banner`
  /// field. Only meaningful when [isCollection] is true.
  final String? existingBannerUrl;

  /// Existing metadata URI from on-chain — reused when no field changed
  /// (skips re-uploading metadata JSON to IPFS).
  final String? existingUri;

  /// Parent collection reference, if any.
  final MintCollectionRef? collection;

  /// Display name of [collection], when the artwork render could supply
  /// one. Seeds the details-step picker pill so an untouched edit reads as
  /// "still in `<collection>`" rather than "no collection".
  final String? collectionName;

  /// True when the main asset URL points at a playable video. Derived
  /// from the off-chain JSON's `properties.category == 'video'` flag,
  /// falling back to a file-extension check on the URL. Drives the
  /// edit upload step to use the video preview path in the dropzone
  /// (Image.network can't decode mp4/webm).
  final bool isMainAssetVideo;

  /// Mime type per existing asset URL. Sourced from the off-chain JSON's own
  /// `properties.files` (authoritative when the artwork was minted from the
  /// webapp) plus the indexer's `mimeType` for the main asset. An edit that
  /// doesn't re-pick a file needs these to rebuild `properties.files` and
  /// `properties.category` faithfully — without them a video artwork loses
  /// its `animation_url` and re-indexes as a still image.
  final Map<String, String> existingFileTypesByUri;
}

/// Loads the on-chain + API + IPFS data needed to pre-fill an edit-NFT
/// form. Best-effort throughout: any single source can fail and the
/// helper still returns whatever is recoverable.
@lazySingleton
class EditNftPrefillService {
  EditNftPrefillService(this._dasApi, this._artworkRepo)
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

  final DasApiService _dasApi;
  final ArtworkRepository _artworkRepo;
  final Dio _dio;

  /// Build the prefill snapshot. Throws only when the on-chain DAS fetch
  /// itself fails — that's the one source we cannot work around.
  Future<EditNftPrefill> load(String mintAccount) async {
    final asset = await _dasApi.getAsset(mintAccount);

    // API artwork render is best-effort; if it fails we'll fall back to
    // on-chain data only.
    ArtworkDetails? artwork;
    try {
      artwork = await _artworkRepo.getArtworkDetail(mintAccount);
    } catch (_) {
      artwork = null;
    }

    // Off-chain JSON is best-effort with a hard 5s timeout. Mirrors the
    // webapp's `Promise.race` against a 5s reject.
    Map<String, dynamic>? json;
    if (asset.uri != null && asset.uri!.isNotEmpty) {
      json = await _fetchJsonOrNull(asset.uri!);
    }

    final isMasterEdition =
        asset.tokenStandard == TokenStandard.coreCollection &&
        asset.hasMasterEditionPlugin;
    final isCollection =
        asset.tokenStandard == TokenStandard.coreCollection &&
        !asset.hasMasterEditionPlugin;

    // Name: prefer on-chain (matches webapp); fall back to API if
    // somehow missing.
    final name = (asset.name?.trim().isNotEmpty == true)
        ? asset.name!
        : (artwork?.title ?? '');

    // Description / tags / NSFW: JSON wins, then API render, then empty.
    final description =
        (json?['description'] as String?) ?? artwork?.description ?? '';
    final tags = _parseTags(json) ?? artwork?.tags ?? const <String>[];
    final nsfw = json?['nsfw'] == true || tags.contains('nsfw');

    // Attributes: JSON wins (canonical trait_type/value pairs); fall
    // back to API render's parsed attributes.
    final attributes =
        _parseAttributes(json) ??
        artwork?.attributes
            .map(
              (ArtworkAttribute a) =>
                  NftAttribute(traitType: a.traitType, value: a.value),
            )
            .toList() ??
        const <NftAttribute>[];

    // Image / thumbnail / process video. JSON's `image` + `animation_url`
    // (when present) follow the webapp's split where the animation is
    // the main asset and `image` becomes the thumbnail. Falls back to
    // the API render's imageUrl.
    final animationUrl = json?['animation_url'] as String?;
    final imageInJson = json?['image'] as String?;
    String? mainAssetUrl;
    String? thumbnailUrl;
    if (animationUrl != null && animationUrl.isNotEmpty) {
      mainAssetUrl = animationUrl;
      if (imageInJson != null && imageInJson != animationUrl) {
        thumbnailUrl = imageInJson;
      }
    } else {
      mainAssetUrl = imageInJson ?? artwork?.imageUrl;
    }
    final processVideoUrl = json?['processVideo'] as String?;
    final bannerUrl = json?['banner'] as String?;

    final propsCategory =
        ((json?['properties'] as Map<String, dynamic>?)?['category'] as String?)
            ?.toLowerCase();
    final isMainAssetVideo =
        mainAssetUrl != null &&
        (propsCategory == 'video' || _hasVideoExtension(mainAssetUrl));

    // uri → mime for every file the existing JSON declares, so an edit that
    // doesn't re-pick can rebuild `properties.files` with the real types.
    // The indexer's own `mimeType` backfills the main asset for JSONs written
    // before `properties.files` was emitted (every mobile-minted artwork).
    final fileTypes = _parseFileTypes(json);
    final indexedMime = artwork?.mimeType;
    if (mainAssetUrl != null &&
        indexedMime != null &&
        indexedMime.isNotEmpty &&
        !fileTypes.containsKey(mainAssetUrl)) {
      fileTypes[mainAssetUrl] = indexedMime;
    }

    // Royalties: prefer DAS for token-metadata so we capture each
    // creator's original `verified` flag (the chain enforces it). For
    // Core / CoreCollection, the mpl-core royalties plugin is the
    // on-chain source of truth (webapp `getRoyalties` parity). The API
    // render is the last resort — critically, it does NOT work for
    // collection mints: they aren't in the artwork index, so the lookup
    // 404s and would seed an empty creator list that the chain rejects
    // at edit time (royalty shares must sum to 100 → mpl-core 0x1C
    // "Invalid setting for plugin").
    final isTokenMetadata =
        asset.tokenStandard == TokenStandard.nft ||
        asset.tokenStandard == TokenStandard.pnft ||
        asset.tokenStandard == TokenStandard.cnft;

    int sellerFeeBps;
    List<MintCreator> creators;
    if (isTokenMetadata && asset.tokenMetadataCreators.isNotEmpty) {
      sellerFeeBps = asset.sellerFeeBasisPoints ?? 0;
      creators = asset.tokenMetadataCreators
          .map(
            (c) => MintCreator(
              address: c.address,
              share: c.share,
              verified: c.verified,
            ),
          )
          .toList(growable: false);
    } else if (asset.royaltiesPluginCreators.isNotEmpty) {
      sellerFeeBps = asset.royaltiesPluginBasisPoints ?? 0;
      creators = asset.royaltiesPluginCreators
          .map((c) => MintCreator(address: c.address, share: c.share))
          .toList(growable: false);
    } else {
      final pct = double.tryParse(artwork?.royaltyPercent ?? '') ?? 0;
      sellerFeeBps = (pct * 100).round();
      creators =
          artwork?.royaltySplits
              .map(
                (ArtworkRoyaltySplit r) =>
                    MintCreator(address: r.address, share: r.sharePercent),
              )
              .toList(growable: false) ??
          const <MintCreator>[];
    }

    // Supply for master editions: prefer on-chain `masterEditionMaxSupply`
    // (null = open). Current supply is `currentSize` (numMinted equivalent).
    final maxSupply = isMasterEdition
        ? asset.masterEditionMaxSupply
        : (artwork?.maxSupply ?? 0);
    final currentSupply = isMasterEdition ? (asset.currentSize ?? 0) : 0;

    // Parent collection. A plain Core asset carries it in DAS `grouping`
    // (`group_key == "collection"`). A group-attached Master Edition does
    // NOT: its link to the parent is an mpl-core Group, which DAS never
    // surfaces as a grouping entry — so fall back to the indexer's
    // group-resolved key, which the artwork render exposes as
    // `collection.slug` (the indexer picks `resolved_collection_key` for
    // master editions). Webapp parity: `useCreateMetadata`.
    // Missing this makes an untouched master-edition edit read as "no
    // collection", so a user who then re-picks the same parent pays for a
    // pointless group migration.
    final parentMint = (asset.collectionKey?.isNotEmpty ?? false)
        ? asset.collectionKey
        : (isMasterEdition ? artwork?.collectionMint : null);
    final collection = (parentMint != null && parentMint.isNotEmpty)
        ? MintCollectionRef(
            mintAccount: parentMint,
            tokenStandard: TokenStandard.coreCollection,
          )
        : null;
    // Only trust the render's name when it describes the same collection we
    // resolved on-chain.
    final collectionName =
        (collection != null &&
            artwork?.collectionMint == collection.mintAccount)
        ? artwork?.collectionName
        : null;

    return EditNftPrefill(
      mintAccount: mintAccount,
      tokenStandard: asset.tokenStandard,
      name: name,
      description: description,
      attributes: attributes,
      tags: tags,
      nsfw: nsfw,
      sellerFeeBasisPoints: sellerFeeBps,
      creators: creators,
      isMasterEdition: isMasterEdition,
      isCollection: isCollection,
      maxSupply: maxSupply,
      currentSupply: currentSupply,
      isMutable: asset.isMutable,
      updateAuthority: asset.updateAuthority,
      existingImageUrl: mainAssetUrl,
      existingThumbnailUrl: thumbnailUrl,
      existingProcessVideoUrl: processVideoUrl,
      existingBannerUrl: bannerUrl,
      existingUri: asset.uri,
      collection: collection,
      collectionName: collectionName,
      isMainAssetVideo: isMainAssetVideo,
      existingFileTypesByUri: fileTypes,
    );
  }

  /// `properties.files` → `{uri: type}`. Tolerates the legacy `url` key the
  /// indexer also accepts (`assetHelper` reads `f.uri ?? f.url`).
  Map<String, String> _parseFileTypes(Map<String, dynamic>? json) {
    final out = <String, String>{};
    final props = json?['properties'];
    if (props is! Map) return out;
    final files = props['files'];
    if (files is! List) return out;
    for (final entry in files) {
      if (entry is! Map) continue;
      final uri = entry['uri'] ?? entry['url'];
      final type = entry['type'];
      if (uri is! String || uri.isEmpty) continue;
      if (type is! String || type.isEmpty) continue;
      out[uri] = type;
    }
    return out;
  }

  bool _hasVideoExtension(String url) {
    final lower = url.toLowerCase();
    // Strip query string before checking — IPFS gateways sometimes append one.
    final pathOnly = lower.split('?').first;
    return pathOnly.endsWith('.mp4') ||
        pathOnly.endsWith('.mov') ||
        pathOnly.endsWith('.webm');
  }

  /// Fetch JSON at [uri] with a 5s ceiling. Returns null on any failure.
  Future<Map<String, dynamic>?> _fetchJsonOrNull(String uri) async {
    try {
      final response = await _dio.get<dynamic>(
        uri,
        options: Options(responseType: ResponseType.json),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      return null;
    } catch (e) {
      debugPrint('[EditNftPrefillService] IPFS fetch failed for $uri: $e');
      return null;
    }
  }

  List<String>? _parseTags(Map<String, dynamic>? json) {
    final raw = json?['tags'];
    if (raw is! List) return null;
    return raw.whereType<String>().toList(growable: false);
  }

  List<NftAttribute>? _parseAttributes(Map<String, dynamic>? json) {
    final raw = json?['attributes'];
    if (raw is! List) return null;
    final out = <NftAttribute>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final type = entry['trait_type'] ?? entry['traitType'];
      final value = entry['value'];
      if (type is! String || type.isEmpty) continue;
      out.add(NftAttribute(traitType: type, value: value?.toString() ?? ''));
    }
    return out;
  }
}
