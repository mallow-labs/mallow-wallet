import 'package:freezed_annotation/freezed_annotation.dart';

import 'user.dart';

part 'bulk_user_lookup.freezed.dart';
part 'bulk_user_lookup.g.dart';

/// Request body for POST /v1/user/bulk.
///
/// Public endpoint — no auth required.
@freezed
abstract class BulkUserLookupRequest with _$BulkUserLookupRequest {
  const factory BulkUserLookupRequest({required List<String> addresses}) = _BulkUserLookupRequest;

  factory BulkUserLookupRequest.fromJson(Map<String, dynamic> json) =>
      _$BulkUserLookupRequestFromJson(json);
}

/// A user profile with the set of wallet addresses linked to it.
@freezed
abstract class BulkUserEntry with _$BulkUserEntry {
  const factory BulkUserEntry({
    required UserPreview user,
    @Default([]) List<String> linkedAddresses,
  }) = _BulkUserEntry;

  factory BulkUserEntry.fromJson(Map<String, dynamic> json) => _$BulkUserEntryFromJson(json);
}

/// Lookup result: matched users and unmatched addresses.
@freezed
abstract class BulkLookupResult with _$BulkLookupResult {
  const factory BulkLookupResult({
    @Default([]) List<BulkUserEntry> users,
    @Default([]) List<String> unlinkedAddresses,
  }) = _BulkLookupResult;

  factory BulkLookupResult.fromJson(Map<String, dynamic> json) => _$BulkLookupResultFromJson(json);
}

/// Response from POST /v1/user/bulk.
@freezed
abstract class BulkUserLookupResponse with _$BulkUserLookupResponse {
  const factory BulkUserLookupResponse({required BulkLookupResult result}) =
      _BulkUserLookupResponse;

  factory BulkUserLookupResponse.fromJson(Map<String, dynamic> json) =>
      _$BulkUserLookupResponseFromJson(json);
}

/// Request body for POST /v0/wallet/approveLinkRequestV2.
///
/// Links [address] (a new wallet) into the caller's profile.
/// Requires dual JWT cookies: wallet-sig-{address} + wallet-sig-{existingAddr}.
@freezed
abstract class ApproveLinkRequestV2Body with _$ApproveLinkRequestV2Body {
  const factory ApproveLinkRequestV2Body({required String address}) = _ApproveLinkRequestV2Body;

  factory ApproveLinkRequestV2Body.fromJson(Map<String, dynamic> json) =>
      _$ApproveLinkRequestV2BodyFromJson(json);
}

/// Request body for POST /v0/wallet/removeAddress.
///
/// Removes [address] from the caller's profile.
/// Requires a valid isSignedLogin cookie.
@freezed
abstract class RemoveAddressBody with _$RemoveAddressBody {
  const factory RemoveAddressBody({required String address}) = _RemoveAddressBody;

  factory RemoveAddressBody.fromJson(Map<String, dynamic> json) =>
      _$RemoveAddressBodyFromJson(json);
}
