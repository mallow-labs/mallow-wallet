import 'package:freezed_annotation/freezed_annotation.dart';

import 'profile.dart';

part 'explore.freezed.dart';
part 'explore.g.dart';

/// Request body for POST /v1/explore.
@freezed
sealed class ExploreRequest with _$ExploreRequest {
  const factory ExploreRequest({
    @Default(0) int page,
    @Default(40) int pageSize,
    @Default(ExploreSort.trending) ExploreSort sort,
    ExploreFilter? filter,
  }) = _ExploreRequest;

  factory ExploreRequest.fromJson(Map<String, dynamic> json) => _$ExploreRequestFromJson(json);
}

/// Response from POST /v1/explore.
///
/// Items in [result] are raw maps — parse into domain models in the
/// repository layer (same pattern as ProfileResponse).
@JsonSerializable()
class ExploreResponse {
  const ExploreResponse({this.result = const []});

  final List<Map<String, dynamic>> result;

  factory ExploreResponse.fromJson(Map<String, dynamic> json) => _$ExploreResponseFromJson(json);

  Map<String, dynamic> toJson() => _$ExploreResponseToJson(this);
}

/// Request body for POST /v1/gumball/explore.
@freezed
sealed class GumballExploreRequest with _$GumballExploreRequest {
  const factory GumballExploreRequest({@Default(0) int page, @Default('live') String mode}) =
      _GumballExploreRequest;

  factory GumballExploreRequest.fromJson(Map<String, dynamic> json) =>
      _$GumballExploreRequestFromJson(json);
}

/// Request body for POST /v1/jellybean/explore.
@freezed
sealed class JellybeanExploreRequest with _$JellybeanExploreRequest {
  const factory JellybeanExploreRequest({@Default(0) int page, @Default('live') String mode}) =
      _JellybeanExploreRequest;

  factory JellybeanExploreRequest.fromJson(Map<String, dynamic> json) =>
      _$JellybeanExploreRequestFromJson(json);
}

/// Response from GET /exhibitions/:slug.
@JsonSerializable()
class ExhibitionDetailResponse {
  const ExhibitionDetailResponse({required this.result});

  final ExhibitionDetailResult result;

  factory ExhibitionDetailResponse.fromJson(Map<String, dynamic> json) =>
      _$ExhibitionDetailResponseFromJson(json);

  Map<String, dynamic> toJson() => _$ExhibitionDetailResponseToJson(this);
}

/// The `result` object inside an [ExhibitionDetailResponse].
@JsonSerializable()
class ExhibitionDetailResult {
  const ExhibitionDetailResult({this.artworks = const []});

  /// Raw NFT maps — parse with [NftPreview.fromJson] in the repository layer.
  final List<Map<String, dynamic>> artworks;

  factory ExhibitionDetailResult.fromJson(Map<String, dynamic> json) =>
      _$ExhibitionDetailResultFromJson(json);

  Map<String, dynamic> toJson() => _$ExhibitionDetailResultToJson(this);
}

/// Request body for POST /exhibitions/explore.
@freezed
sealed class ExhibitionsExploreRequest with _$ExhibitionsExploreRequest {
  const factory ExhibitionsExploreRequest({
    @Default(0) int page,
    @Default(ExploreSort.trending) ExploreSort sort,
  }) = _ExhibitionsExploreRequest;

  factory ExhibitionsExploreRequest.fromJson(Map<String, dynamic> json) =>
      _$ExhibitionsExploreRequestFromJson(json);
}
