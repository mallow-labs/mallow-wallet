import 'package:freezed_annotation/freezed_annotation.dart';

// Full import (no `show`) so freezed's generated `$…CopyWith` helpers for the
// shared `EditNftV2Metadata` / `EditNftV2CollectionRef` fields are in scope.
import 'edit_nft_v2.dart';

part 'mint_nft_v2.freezed.dart';
part 'mint_nft_v2.g.dart';

/// Wire format for `POST /v2/tx/nft/mint` — mirrors the backend's
/// `MintNftTxRequest` and the body the webapp builds in
/// `buildMintShadowBody`.
///
/// The backend models the kind-specific fields as an externally-tagged enum
/// flattened into the request (`#[serde(flatten)] kind` with `tag = "kind"`).
/// On the wire that is a flat object: a `kind` discriminator string plus the
/// optional kind fields (`collection`, `maxSupply`, `groupSigner`) at the top
/// level. We model it flat with nullable fields and `includeIfNull: false`,
/// setting only the fields valid for each kind:
///
///  - `core_asset` (1/1): optional `collection`.
///  - `core_master_edition_collection` (editions): optional `maxSupply`,
///    optional `collection`, and `groupSigner` (only when a parent
///    collection is present and may need a lazily-created group).
///  - `core_collection` (parent collection): no extra fields.

/// `kind` discriminator values for [MintNftV2Request].
class MintNftV2Kind {
  const MintNftV2Kind._();

  static const coreAsset = 'core_asset';
  static const coreMasterEditionCollection = 'core_master_edition_collection';
  static const coreCollection = 'core_collection';
}

@freezed
sealed class MintNftV2Request with _$MintNftV2Request {
  const factory MintNftV2Request({
    /// The authority/signer — the wallet that will sign and send the tx.
    required String authority,

    /// Address the new asset will occupy. The tx is built for this exact
    /// address and must also be signed by it.
    required String asset,
    required String uri,
    required EditNftV2Metadata nftMetadata,

    /// Discriminator — one of [MintNftV2Kind].
    required String kind,

    /// Parent collection. Set for `core_asset` and
    /// `core_master_edition_collection` when minting into a collection.
    @JsonKey(includeIfNull: false) EditNftV2CollectionRef? collection,

    /// `core_master_edition_collection` only: `null` → open edition,
    /// positive integer → limited.
    @JsonKey(includeIfNull: false) int? maxSupply,

    /// `core_master_edition_collection` under a parent only: pubkey of a
    /// fresh keypair backing a lazily-created `GroupV1`. The client signs
    /// the returned tx with this keypair iff it ends up a required signer.
    @JsonKey(includeIfNull: false) String? groupSigner,

    /// Free-form upload-record tag (`"1/1"`, `"editions"`, `"collection"`).
    required String createType,
    @Default(EditNftV2PaymentMethod.solana) EditNftV2PaymentMethod paymentMethod,
    @Default(<int>[]) List<int> unlockableContentIds,
    @JsonKey(includeIfNull: false) int? targetPriorityFeeLamports,

    /// Estimate-only: build + price the tx (including any would-be subsidy)
    /// WITHOUT reserving the group-rent subsidy slot, persisting an
    /// `NftUpload` record, or auth-signing it — the mint route skips all
    /// three side effects under this flag. Must be `true` for the cost
    /// preview and `false` for
    /// the tx the user actually signs — a non-dry preview burns the
    /// subsidy slot, so the real mint that follows is charged user-pays.
    @Default(false) bool dryRun,
  }) = _MintNftV2Request;

  factory MintNftV2Request.fromJson(Map<String, dynamic> json) => _$MintNftV2RequestFromJson(json);
}
