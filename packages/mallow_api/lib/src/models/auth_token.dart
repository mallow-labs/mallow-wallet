import 'package:freezed_annotation/freezed_annotation.dart';

part 'auth_token.freezed.dart';
part 'auth_token.g.dart';

/// Request body for POST /v0/authToken
@freezed
abstract class AuthTokenRequest with _$AuthTokenRequest {
  const factory AuthTokenRequest({required String address}) = _AuthTokenRequest;

  factory AuthTokenRequest.fromJson(Map<String, dynamic> json) => _$AuthTokenRequestFromJson(json);
}

/// Request body for POST /v0/authToken/verify
@freezed
abstract class AuthTokenVerifyRequest with _$AuthTokenVerifyRequest {
  const factory AuthTokenVerifyRequest({
    required String address,
    required String message,
    required String signature,
  }) = _AuthTokenVerifyRequest;

  factory AuthTokenVerifyRequest.fromJson(Map<String, dynamic> json) =>
      _$AuthTokenVerifyRequestFromJson(json);
}

/// Response body from POST /v0/authToken/verify
@freezed
abstract class AuthTokenVerifyResult with _$AuthTokenVerifyResult {
  const factory AuthTokenVerifyResult({String? expiresAt}) = _AuthTokenVerifyResult;

  factory AuthTokenVerifyResult.fromJson(Map<String, dynamic> json) =>
      _$AuthTokenVerifyResultFromJson(json);
}
