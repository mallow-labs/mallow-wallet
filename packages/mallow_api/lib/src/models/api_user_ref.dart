import 'package:freezed_annotation/freezed_annotation.dart';

part 'api_user_ref.freezed.dart';
part 'api_user_ref.g.dart';

/// Structured reference to a mallow user as returned by the API on fields
/// like `creator` and `owner`. The shape is preserved as-is — callers pick
/// the field they need (`username` for a handle, `address` for a profile
/// route, `displayName` for a label) instead of receiving a collapsed
/// display string that can't be reliably round-tripped.
@freezed
sealed class ApiUserRef with _$ApiUserRef {
  const ApiUserRef._();

  const factory ApiUserRef({
    String? address,
    String? username,
    String? displayName,
    @JsonKey(name: 'imageUrl') String? avatarUrl,
    bool? isTwitterVerified,

    /// Moderation flag on the referenced user. Shipped by the API's user
    /// renderer (`userRenderer`) and read by
    /// the listing-eligibility gate: a flagged creator blocks listing of
    /// their artwork even when everything else checks out.
    bool? isFlagged,
    @Default([]) List<String> addresses,
    String? primaryAddress,
    @Default([]) List<String> roles,
  }) = _ApiUserRef;

  /// Best single on-chain address: prefer the explicit [address] field,
  /// then [primaryAddress], then the first entry in [addresses]. Returns
  /// null when none of the address-shaped fields are populated.
  String? get effectiveAddress {
    final a = address;
    if (a != null && a.isNotEmpty) return a;
    final p = primaryAddress;
    if (p != null && p.isNotEmpty) return p;
    if (addresses.isNotEmpty) return addresses.first;
    return null;
  }

  factory ApiUserRef.fromJson(Map<String, dynamic> json) => _$ApiUserRefFromJson(json);
}

/// Deserializer for `creator` / `owner` fields that the API may return as
/// either a bare address string (legacy form) or a structured user object.
ApiUserRef? apiUserRefFromAny(Object? value) {
  if (value == null) return null;
  if (value is String) {
    if (value.isEmpty) return null;
    return ApiUserRef(address: value);
  }
  if (value is Map<String, dynamic>) return ApiUserRef.fromJson(value);
  return null;
}

Object? apiUserRefToAny(ApiUserRef? value) => value?.toJson();
