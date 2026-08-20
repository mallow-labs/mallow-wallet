import 'package:freezed_annotation/freezed_annotation.dart';

import '../generated/openapi.enums.swagger.dart' as gen;
import 'artwork.dart' show NftAttribute;

part 'create_asset.freezed.dart';
part 'create_asset.g.dart';

/// On-chain token standard for a digital asset — the canonical enum used
/// across the wallet (mint payloads, DAS parsing, permission rules).
///
/// Wire values mirror `TokenStandard` from the server's shared Solana types
/// (`tokenStandard`).
enum TokenStandard {
  @JsonValue('nft')
  nft,
  @JsonValue('core')
  core,
  @JsonValue('core-collection')
  coreCollection,
  @JsonValue('pnft')
  pnft,
  @JsonValue('cnft')
  cnft,
  @JsonValue('objkt')
  objkt,
  @JsonValue('native')
  native,
  @JsonValue('erc20')
  erc20,
  @JsonValue('erc721')
  erc721,
  @JsonValue('erc1155')
  erc1155,
}

/// Map a Helius DAS `getAsset` `interface` string onto a [TokenStandard].
/// Compressed assets are surfaced as [TokenStandard.cnft] regardless of
/// interface (matches the parsing in `on_chain_asset.dart`).
extension TokenStandardDas on TokenStandard {
  static TokenStandard fromDasInterface(String? dasInterface, {bool isCompressed = false}) {
    if (isCompressed) return TokenStandard.cnft;
    return switch (dasInterface) {
      'MplCoreAsset' => TokenStandard.core,
      'MplCoreCollection' => TokenStandard.coreCollection,
      'ProgrammableNFT' => TokenStandard.pnft,
      _ => TokenStandard.nft,
    };
  }

  /// Wire value sent over the API — kept in sync with the `@JsonValue`
  /// annotations on the enum, so hand-built query strings (e.g. the
  /// collection-picker filter) stay typed.
  String get wireValue => switch (this) {
    TokenStandard.nft => 'nft',
    TokenStandard.core => 'core',
    TokenStandard.coreCollection => 'core-collection',
    TokenStandard.pnft => 'pnft',
    TokenStandard.cnft => 'cnft',
    TokenStandard.objkt => 'objkt',
    TokenStandard.native => 'native',
    TokenStandard.erc20 => 'erc20',
    TokenStandard.erc721 => 'erc721',
    TokenStandard.erc1155 => 'erc1155',
  };

  /// The matching value of the OpenAPI-generated [gen.TokenStandard] enum,
  /// resolved by shared wire value. Used to feed the generated v2 tx-builder
  /// request models (`BurnTxRequest`, `TransferTxRequest`, …) which type
  /// `tokenStandard` as the generated enum rather than a raw string.
  gen.TokenStandard get apiValue => gen.TokenStandard.values.firstWhere(
    (e) => e.value == wireValue,
    orElse: () => throw ArgumentError(
      'No generated TokenStandard for wire value "$wireValue" — the OpenAPI '
      'enum is out of sync with the local TokenStandard; re-run codegen.',
    ),
  );
}

/// What kind of thing is being minted.
///
/// Wire values mirror `CreateType` from the server's shared types
/// (`nftMetadata`).
enum MintCreateType {
  @JsonValue('1/1')
  oneOfOne,
  @JsonValue('editions')
  editions,
  @JsonValue('collection')
  collection,
  @JsonValue('jellybean')
  jellybean,
  @JsonValue('airdrop')
  airdrop,
}

/// A single creator receiving a share of royalties.
@freezed
sealed class MintCreator with _$MintCreator {
  const factory MintCreator({
    required String address,
    required int share,
    @Default(false) bool verified,
  }) = _MintCreator;

  factory MintCreator.fromJson(Map<String, dynamic> json) => _$MintCreatorFromJson(json);
}

/// Optional extended metadata written into the NFT's IPFS JSON.
@freezed
sealed class MintExtendedMetadata with _$MintExtendedMetadata {
  const factory MintExtendedMetadata({
    @Default('') String description,
    @Default(<NftAttribute>[]) List<NftAttribute> attributes,
    String? image,
    String? banner,
    String? video,
    String? processVideo,
    @Default(<String>[]) List<String> tags,
    @Default(false) bool nsfw,
    @Default(<String>[]) List<String> categories,
  }) = _MintExtendedMetadata;

  factory MintExtendedMetadata.fromJson(Map<String, dynamic> json) =>
      _$MintExtendedMetadataFromJson(json);
}

/// Top-level `nftMetadata` payload. Built from the form state and mapped
/// onto the v2 mint/edit request bodies (`MintNftV2Request` /
/// `EditNftV2Request`), and serialized into the IPFS metadata JSON.
@freezed
sealed class MintNftMetadata with _$MintNftMetadata {
  const factory MintNftMetadata({
    required String name,
    @Default(0) int sellerFeeBasisPoints,
    @Default(<MintCreator>[]) List<MintCreator> creators,
    required MintExtendedMetadata extendedMetadata,
    int? maxSupply,
  }) = _MintNftMetadata;

  factory MintNftMetadata.fromJson(Map<String, dynamic> json) => _$MintNftMetadataFromJson(json);
}

/// Reference to the parent collection of a new mint.
@freezed
sealed class MintCollectionRef with _$MintCollectionRef {
  const factory MintCollectionRef({required String mintAccount, TokenStandard? tokenStandard}) =
      _MintCollectionRef;

  factory MintCollectionRef.fromJson(Map<String, dynamic> json) =>
      _$MintCollectionRefFromJson(json);
}

/// Request body for `POST /v1/create/finalize?type=nft`.
@freezed
sealed class FinalizeMintRequest with _$FinalizeMintRequest {
  const factory FinalizeMintRequest({required String mintAccount, required List<String> txIds}) =
      _FinalizeMintRequest;

  factory FinalizeMintRequest.fromJson(Map<String, dynamic> json) =>
      _$FinalizeMintRequestFromJson(json);
}

/// Request body for `POST /v1/ipfsPin`.
@freezed
sealed class IpfsPinRequest with _$IpfsPinRequest {
  const factory IpfsPinRequest({required String hash}) = _IpfsPinRequest;

  factory IpfsPinRequest.fromJson(Map<String, dynamic> json) => _$IpfsPinRequestFromJson(json);
}

/// Per-operation protocol fees returned by `GET /v0/txFees`. All values
/// are SOL (not lamports). Mirrors `TxFees` from
/// the server's shared fee types.
@freezed
sealed class TxFees with _$TxFees {
  const factory TxFees({
    @Default(0.0) double mint,
    @Default(0.0) double edit,
    @Default(0.0) double externalMarketBuy,
    @Default(0.0) double airdrop,
    @Default(0.0) double jellybeanPrint,
    @Default(0) int candyMachineBps,
  }) = _TxFees;

  factory TxFees.fromJson(Map<String, dynamic> json) => _$TxFeesFromJson(json);
}

/// On-chain royalty config carried on `CollectionPreviewNft.royalties`.
/// Mirrors the server's `NftRoyalties` — `feeBPS` is seller-fee
/// basis points (1000 = 10%) and `shares` is the creator-split list.
@freezed
sealed class CollectionRoyalties with _$CollectionRoyalties {
  const factory CollectionRoyalties({
    @Default(0) int feeBPS,
    @Default(<MintCreator>[]) List<MintCreator> shares,
  }) = _CollectionRoyalties;

  factory CollectionRoyalties.fromJson(Map<String, dynamic> json) =>
      _$CollectionRoyaltiesFromJson(json);
}

/// Nested `nft` block on `CollectionPreviewRender`. Only collections
/// that have been created on-chain have this populated.
@freezed
sealed class CollectionPreviewNft with _$CollectionPreviewNft {
  const factory CollectionPreviewNft({
    required String mintAccount,
    String? imageUrl,
    @Default(<NftAttribute>[]) List<NftAttribute> attributes,
    CollectionRoyalties? royalties,
  }) = _CollectionPreviewNft;

  factory CollectionPreviewNft.fromJson(Map<String, dynamic> json) =>
      _$CollectionPreviewNftFromJson(json);
}

/// Lightweight render of a collection returned by
/// `/v0/collections/byCreator/{pubkey}` — the collection picker uses this.
/// Mirrors the server's `CollectionPreviewRender`.
@freezed
sealed class CollectionPreviewRender with _$CollectionPreviewRender {
  const factory CollectionPreviewRender({
    required String slug,
    required String name,
    String? imageUrl,
    @Default(<String>[]) List<String> tags,
    CollectionPreviewNft? nft,
  }) = _CollectionPreviewRender;

  factory CollectionPreviewRender.fromJson(Map<String, dynamic> json) =>
      _$CollectionPreviewRenderFromJson(json);
}
