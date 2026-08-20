import 'package:dio/dio.dart';

/// The HTTP status the v2 (Rust) tx-builders return when a sub-path is still
/// deferred to the nodejs v1 routes. Callers retry the equivalent v1 builder on
/// exactly this signal.
const int kV2DeferralStatus = 400;

/// `error.message` substrings that mark a [kV2DeferralStatus] as a *deferral*
/// rather than a real rejection.
///
/// The status alone is not enough to act on: the v2 builders answer 400 for
/// ordinary failures too — "Raffle sold out", "Raffle has ended", "quantity
/// must be >= 1", "Listing not found" — and retrying v1 on those replaces the
/// real reason with whatever the stale v1 builder says instead. Only two
/// sub-paths are actually deferred today:
///
/// - **Holder-gated and pNFT-prize raffles.** The v2 raffle builder rejects
///   all three (holder-only ticket buys, pNFT cancel, pNFT claim-prize) with
///   "… not yet supported in v2 — use v1".
/// - **Off-chain-Merkle-gated editions.** Both builders answer "User is not
///   whitelisted", but v2 gates on the request's `buyer` while v1 gates on the
///   session address, so v1 can still serve a buy v2 refuses.
const _deferralMarkers = <String>[
  'not yet supported in v2',
  'User is not whitelisted',
];

extension V2DeferralFallback on DioException {
  /// True when this error is the v2→v1 deferral signal (and not some other
  /// failure that should propagate). Keeps the policy in one place so a backend
  /// change (e.g. 400 → 422) updates every fallback site at once.
  bool get isV2DeferralFallback {
    if (response?.statusCode != kV2DeferralStatus) return false;
    final message = _v2ErrorMessage(response?.data);
    return message != null && _deferralMarkers.any(message.contains);
  }
}

/// The message out of `{ "error": { "message": "…" } }` — the envelope every v2
/// route renders, from the backend's shared error type. Null when the body
/// isn't that shape, which is itself a reason not to fall back: a 400 from a
/// proxy or a malformed request never came from a deferral branch.
String? _v2ErrorMessage(dynamic data) {
  if (data is! Map) return null;
  final error = data['error'];
  if (error is! Map) return null;
  final message = error['message'];
  return message is String ? message : null;
}
