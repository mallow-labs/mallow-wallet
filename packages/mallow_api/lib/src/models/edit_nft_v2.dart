import 'package:freezed_annotation/freezed_annotation.dart';

import 'create_asset.dart' show TokenStandard;

part 'edit_nft_v2.freezed.dart';
part 'edit_nft_v2.g.dart';

/// Wire format for the Rust v2 tx routes (`POST /v2/tx/nft/{mint,edit}`).
///
/// These mirror the backend's own request structs. It uses
/// `#[serde(rename_all = "camelCase")]` on every request struct, so the
/// wire interface is camelCase — identical to the keys the webapp sends
/// (`shadowCompare`). json_serializable's
/// default key is the Dart field name (already camelCase), so no `@JsonKey`
/// renaming is needed.
///
/// `nftMetadata.extendedMetadata` is persisted verbatim onto the backend's
/// `NftUpload` record (it is not used for on-chain ix building); the v1
/// finalize handler reads fields like `nsfw` off it, so it must be sent to
/// keep the upload at parity with the legacy v1 mint/edit path.
///
/// v2 routes return the payload directly (`{ tx: ... }`) — no `ApiResponse`
/// envelope.

/// Single creator entry. The on-chain `verified` flag is resolved by the
/// backend rather than supplied by the client — it was dropped from
/// `EditNftCreator` in the contract, so the wire body carries only the
/// address and the royalty share.
@freezed
sealed class EditNftV2Creator with _$EditNftV2Creator {
  const factory EditNftV2Creator({required String address, required int share}) = _EditNftV2Creator;

  factory EditNftV2Creator.fromJson(Map<String, dynamic> json) => _$EditNftV2CreatorFromJson(json);
}

/// One trait entry on [EditNftV2ExtendedMetadata]. Distinct from the
/// IPFS-facing `NftAttribute` (which serializes `trait_type`): the v2
/// backend's `EditNftAttribute` uses the camelCase `traitType` key.
@freezed
sealed class EditNftV2Attribute with _$EditNftV2Attribute {
  const factory EditNftV2Attribute({String? traitType, String? value}) = _EditNftV2Attribute;

  factory EditNftV2Attribute.fromJson(Map<String, dynamic> json) =>
      _$EditNftV2AttributeFromJson(json);
}

/// Extended metadata persisted to the backend's `NftUpload` record. Mirrors
/// its `EditNftExtendedMetadata` — consumed by the v1 finalize
/// path (e.g. the `nsfw` flag), not by the on-chain ix builder. `processVideo`
/// is intentionally absent (it lives only in the IPFS JSON).
@freezed
sealed class EditNftV2ExtendedMetadata with _$EditNftV2ExtendedMetadata {
  const factory EditNftV2ExtendedMetadata({
    String? description,
    @Default(<EditNftV2Attribute>[]) List<EditNftV2Attribute> attributes,
    String? image,
    String? banner,
    String? video,
    @Default(<String>[]) List<String> tags,
    bool? nsfw,
  }) = _EditNftV2ExtendedMetadata;

  factory EditNftV2ExtendedMetadata.fromJson(Map<String, dynamic> json) =>
      _$EditNftV2ExtendedMetadataFromJson(json);
}

/// User-supplied metadata payload shared by the v2 mint and edit routes
/// (the backend's `EditNftMetadata`). The on-chain fields (name, royalties,
/// creators) drive the instruction; `extendedMetadata` is stored on the
/// upload record for the finalize path.
@freezed
sealed class EditNftV2Metadata with _$EditNftV2Metadata {
  const factory EditNftV2Metadata({
    required String name,
    @Default(0) int sellerFeeBasisPoints,
    @Default(<EditNftV2Creator>[]) List<EditNftV2Creator> creators,
    EditNftV2ExtendedMetadata? extendedMetadata,
  }) = _EditNftV2Metadata;

  factory EditNftV2Metadata.fromJson(Map<String, dynamic> json) =>
      _$EditNftV2MetadataFromJson(json);
}

/// Reference to a collection to assign/keep an asset in. Used by both the
/// mint body (parent collection) and edit body (collection swap).
@freezed
sealed class EditNftV2CollectionRef with _$EditNftV2CollectionRef {
  const factory EditNftV2CollectionRef({
    required String asset,
    required TokenStandard tokenStandard,
  }) = _EditNftV2CollectionRef;

  factory EditNftV2CollectionRef.fromJson(Map<String, dynamic> json) =>
      _$EditNftV2CollectionRefFromJson(json);
}

/// Tri-state for the edit body's `collection` field. The backend types it as a
/// double option — `Option<Option<EditNftCollectionRef>>` on
/// `EditNftTxRequest`. The edit route branches on all three, and they are NOT
/// interchangeable:
///
/// * field absent (`None`) — leave group/collection membership untouched.
/// * field explicit `null` (`Some(None)`) — detach: remove a Master Edition
///   from its mpl-core group (`build_remove_collections_from_group_ix`). A ME's
///   link to its parent is a Group, not the asset's update authority, so
///   omitting the field is a silent no-op rather than a detach.
/// * field object (`Some(Some(_))`) — assign/keep the given collection.
///
/// json_serializable's null-aware map entry (`'collection': ?instance.collection`)
/// can only express "absent" or "a value", so the detach case is carried by
/// [EditNftV2CollectionUpdate.detach], whose [toJson] returns `null`. Request
/// bodies are handed to Dio as the map `toJson()` produces and encoded with
/// `jsonEncode`, which calls `toJson()` on nested objects — the same mechanism
/// the sibling `nftMetadata`/`collection` entries already rely on — so a `null`
/// return lands on the wire as a literal `"collection": null`. That is exactly
/// what the webapp sends (`v2TxBody`).
class EditNftV2CollectionUpdate {
  /// Assign (or keep) [ref] as the asset's collection.
  const EditNftV2CollectionUpdate.assign(EditNftV2CollectionRef this.ref);

  /// Explicit `collection: null` — detach a Master Edition from its group.
  const EditNftV2CollectionUpdate.detach() : ref = null;

  /// An object on the wire is always an assign; an explicit `null` never
  /// reaches here (json_serializable maps it back to an absent field).
  factory EditNftV2CollectionUpdate.fromJson(Map<String, dynamic> json) =>
      EditNftV2CollectionUpdate.assign(EditNftV2CollectionRef.fromJson(json));

  /// The target collection, or `null` for the detach case.
  final EditNftV2CollectionRef? ref;

  bool get isDetach => ref == null;

  /// `null` for detach so the encoder writes a literal JSON `null`.
  Map<String, dynamic>? toJson() => ref?.toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is EditNftV2CollectionUpdate && other.ref == ref);

  @override
  int get hashCode => ref.hashCode;

  @override
  String toString() => 'EditNftV2CollectionUpdate(${ref ?? 'detach'})';
}

/// How the fee is paid. Wire values are PascalCase to match the backend's
/// `PaymentMethod` enum (`#[serde(rename_all = "PascalCase")]`). The wallet
/// only sends `Solana`; `Cream`/`Reward` are kept for wire parity.
enum EditNftV2PaymentMethod {
  @JsonValue('Solana')
  solana,
  @JsonValue('Cream')
  cream,
  @JsonValue('Reward')
  reward,
}

/// Which higher-level edit flow the backend runs. Mirrors its `EditTarget`
/// (`#[serde(rename_all = "snake_case")]`): `asset` (default,
/// 1/1 + master-edition edits) vs `parent_collection`.
enum EditNftV2EditTarget {
  @JsonValue('asset')
  asset,
  @JsonValue('parent_collection')
  parentCollection,
}

/// Body for `POST /v2/tx/nft/edit`.
@freezed
sealed class EditNftV2Request with _$EditNftV2Request {
  const factory EditNftV2Request({
    /// The authority/signer — the wallet that will sign and send the tx.
    required String authority,
    required String asset,
    required String uri,
    required EditNftV2Metadata nftMetadata,
    required TokenStandard tokenStandard,

    /// `null` for assets, positive integer for Core-Collection master
    /// editions. Open-edition is also `null`.
    @JsonKey(includeIfNull: false) int? maxSupply,

    /// Tri-state — see [EditNftV2CollectionUpdate]. `null` here means the
    /// field is omitted ("leave membership untouched"), which is NOT the
    /// same as [EditNftV2CollectionUpdate.detach].
    @JsonKey(includeIfNull: false) EditNftV2CollectionUpdate? collection,

    /// Higher-level edit type carried through to the upload record. v2
    /// accepts `"editNft"` (asset) and `"editCollection"` (parent).
    @Default('editNft') String createType,
    @Default(EditNftV2PaymentMethod.solana) EditNftV2PaymentMethod paymentMethod,

    /// Empty for now; non-empty triggers AppData writes the v2 handler
    /// rejects until the unlockable-content port lands.
    @Default(<int>[]) List<int> unlockableContentIds,
    @JsonKey(includeIfNull: false) int? targetPriorityFeeLamports,
    @Default(EditNftV2EditTarget.asset) EditNftV2EditTarget editTarget,

    /// Master Edition re-parent: the Core Collection to move this Master
    /// Edition under. The backend emits `RemoveCollectionsFromGroup(old)` +
    /// `AddCollectionsToGroup(new)` / `CreateGroupV1` for it.
    /// CoreCollection-only, and mutually exclusive with a detaching
    /// [collection].
    @JsonKey(includeIfNull: false) String? newParentCollection,

    /// Pubkey of a fresh client-generated keypair backing the destination
    /// `GroupV1` when [newParentCollection] has no group yet — the backend
    /// 400s without it in that case. The client signs the returned tx with
    /// the keypair iff it ends up a required signer.
    @JsonKey(includeIfNull: false) String? newGroupSigner,

    /// Estimate-only: build + price the tx (including any would-be subsidy)
    /// WITHOUT reserving the group-rent subsidy slot, persisting an
    /// `NftUpload` record, or auth-signing it — the edit route skips all
    /// three side effects under this flag. Must be `true` for the cost
    /// preview and `false` for the tx the user actually signs.
    @Default(false) bool dryRun,
  }) = _EditNftV2Request;

  factory EditNftV2Request.fromJson(Map<String, dynamic> json) => _$EditNftV2RequestFromJson(json);
}
