import 'package:freezed_annotation/freezed_annotation.dart';

part 'api_response.freezed.dart';
part 'api_response.g.dart';

/// Generic API response wrapper used by mallow API endpoints.
///
/// The mallow API returns responses in the format:
/// ```json
/// {
///   "result": <T>,
///   "err": null | { "message": "..." }
/// }
/// ```
@Freezed(genericArgumentFactories: true)
sealed class ApiResponse<T> with _$ApiResponse<T> {
  const factory ApiResponse({required T result, ApiError? err}) = _ApiResponse<T>;

  factory ApiResponse.fromJson(Map<String, dynamic> json, T Function(Object?) fromJsonT) =>
      _$ApiResponseFromJson(json, fromJsonT);
}

/// API error object returned when an error occurs.
@freezed
sealed class ApiError with _$ApiError {
  const factory ApiError({required String message, String? code}) = _ApiError;

  factory ApiError.fromJson(Map<String, dynamic> json) => _$ApiErrorFromJson(json);
}
