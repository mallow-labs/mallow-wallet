import 'package:freezed_annotation/freezed_annotation.dart';

import 'create_asset.dart';
import 'user.dart';

part 'collection.freezed.dart';
part 'collection.g.dart';

/// Full collection detail returned by `GET /v0/collections/fullByMint/{mint}`.
/// Mirrors webapp `CollectionFullRender` from
/// `collection`.
@freezed
sealed class CollectionFullRender with _$CollectionFullRender {
  const factory CollectionFullRender({
    required String slug,
    required String name,
    String? description,
    String? imageUrl,
    String? bannerUrl,
    String? creatorAddress,
    @Default(<String>[]) List<String> tags,
    CollectionDetailNft? nft,
    UserPreview? creator,
    @Default(0) int itemCount,
    @Default(0) double usdVolume,
    double? floor,
    @Default(0) int collectorCount,
    @Default(false) bool isCreatorHidden,
    @Default(false) bool isOwnerHidden,
  }) = _CollectionFullRender;

  factory CollectionFullRender.fromJson(Map<String, dynamic> json) =>
      _$CollectionFullRenderFromJson(json);
}

/// On-chain metadata block on a [CollectionFullRender]. Picks out the fields
/// the detail page renders (token standard, royalties, mint, image).
@freezed
sealed class CollectionDetailNft with _$CollectionDetailNft {
  const factory CollectionDetailNft({
    required String mintAccount,
    String? imageUrl,
    TokenStandard? tokenStandard,
    CollectionRoyalties? royalties,

    /// Off-chain JSON metadata URL for the collection NFT (arweave / IPFS
    /// gateway / s3 / shdw-drive / custom). The backend casts the full
    /// Mongo asset doc onto the wire even though `CollectionPreviewRender`
    /// only Picks a subset, so this is present in practice.
    String? metadataUrl,
  }) = _CollectionDetailNft;

  factory CollectionDetailNft.fromJson(Map<String, dynamic> json) =>
      _$CollectionDetailNftFromJson(json);
}
