import 'package:freezed_annotation/freezed_annotation.dart';

part 'holders.freezed.dart';
part 'holders.g.dart';

/// One row in the response from `POST /v1/holders/detailed`. Mirrors the
/// shape used by the webapp's Export holders feature in
/// `CollectionOptionsButton`.
@freezed
sealed class HolderEntry with _$HolderEntry {
  const factory HolderEntry({
    required String assetId,
    required String owner,
    @Default(0) int editionNumber,
  }) = _HolderEntry;

  factory HolderEntry.fromJson(Map<String, dynamic> json) => _$HolderEntryFromJson(json);
}

/// Request body for `POST /v1/holders/detailed`.
@freezed
sealed class DetailedHoldersRequest with _$DetailedHoldersRequest {
  const factory DetailedHoldersRequest({required String collectionKey}) = _DetailedHoldersRequest;

  factory DetailedHoldersRequest.fromJson(Map<String, dynamic> json) =>
      _$DetailedHoldersRequestFromJson(json);
}
