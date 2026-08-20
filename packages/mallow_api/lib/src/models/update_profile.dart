/// Request bodies for the profile-editing endpoints.
///
/// These mirror the contracts the backend implements:
/// - `POST /v1/otp` (send an email OTP)
/// - `POST /v1/otp/verify` (confirm an email OTP)
///
/// The `POST /v1/user/updateProfile` envelope is built as a raw JSON map in
/// the repository (so optional/null fields can be controlled precisely), so it
/// has no model here — see `MallowApiClient.updateProfile`.
library;

/// Action discriminator for [CreateOtpRequest].
///
/// Wire values mirror `OtpAction` from the server's shared types.
abstract class OtpActions {
  /// Verify and attach an email address to the logged-in account.
  static const verifyEmail = 'verifyEmail';
}

/// Body for `POST /v1/otp` — requests an OTP be emailed to [email].
class CreateOtpRequest {
  const CreateOtpRequest({required this.email, this.action = OtpActions.verifyEmail});

  final String email;
  final String action;

  Map<String, dynamic> toJson() => {'email': email, 'action': action};
}

/// Body for `POST /v1/otp/verify` — confirms the [code] from the OTP email.
class VerifyOtpRequest {
  const VerifyOtpRequest({required this.code});

  final String code;

  Map<String, dynamic> toJson() => {'code': code};
}
