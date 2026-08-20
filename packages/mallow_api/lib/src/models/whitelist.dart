import 'package:freezed_annotation/freezed_annotation.dart';

part 'whitelist.freezed.dart';
part 'whitelist.g.dart';

/// Request body for `POST /v0/whitelist/checkEligibility`.
///
/// Server returns the subset of [merkleRoots] that [address] is eligible
/// for. An empty result set means the wallet is excluded from every phase
/// in the input list.
@freezed
sealed class WhitelistEligibilityRequest with _$WhitelistEligibilityRequest {
  const factory WhitelistEligibilityRequest({
    required List<String> merkleRoots,
    required String address,
  }) = _WhitelistEligibilityRequest;

  factory WhitelistEligibilityRequest.fromJson(Map<String, dynamic> json) =>
      _$WhitelistEligibilityRequestFromJson(json);
}

/// Request body for `POST /v0/getHolderOnlyMint` — the *token-gate* half of a
/// whitelist phase (the other half being the wallet Merkle allowlist above).
///
/// The server merges `WhitelistConfig.collectionsOrCreators` for
/// [listingAddress] and walks the caller's DAS-owned assets for one whose
/// verified creator or collection grouping intersects that set
/// (`holderOnlyMintHelper`).
///
/// [listingAddress] is the **listing PDA** (`["listing", mint]`), not the
/// mint — see the webapp's `fetchHolderOnlyNftMint(listingWithKey.publicKey)`
/// (`useBuyNow`). The route also accepts a `raffleAccount` instead,
/// which mobile does not use yet; the backend 400s when both are absent.
@freezed
sealed class HolderOnlyMintRequest with _$HolderOnlyMintRequest {
  const factory HolderOnlyMintRequest({required String address, required String listingAddress}) =
      _HolderOnlyMintRequest;

  factory HolderOnlyMintRequest.fromJson(Map<String, dynamic> json) =>
      _$HolderOnlyMintRequestFromJson(json);
}

/// Response body for `POST /v0/getHolderOnlyMint`.
///
/// [result] is the base58 mint of a qualifying NFT the wallet holds, or
/// **null** — which the backend returns for BOTH "this wallet holds nothing
/// that qualifies" and "this listing defines no holder gate"
/// (`creatorsOrCollections.size === 0`). The two are indistinguishable on the
/// wire and the webapp does not distinguish them either: `holderOnlyNftMint
/// != null` is the whole test (`useWhitelistConfig`).
///
/// Modelled as its own type rather than `ApiResponse<String?>` because the
/// generic wrapper declares `required T result` and cannot express a null
/// payload.
@freezed
sealed class HolderOnlyMintResponse with _$HolderOnlyMintResponse {
  const factory HolderOnlyMintResponse({String? result}) = _HolderOnlyMintResponse;

  factory HolderOnlyMintResponse.fromJson(Map<String, dynamic> json) =>
      _$HolderOnlyMintResponseFromJson(json);
}
