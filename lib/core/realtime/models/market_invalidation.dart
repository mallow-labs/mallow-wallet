import 'package:freezed_annotation/freezed_annotation.dart';

part 'market_invalidation.freezed.dart';
part 'market_invalidation.g.dart';

/// Per-mint marketplace invalidation pushed by the backend over the
/// `/v2/ws/invalidations` WebSocket. Schema mirrors the chain listener's
/// `publish_invalidations` payload and the backend's own `InvalidationEvent`.
@freezed
sealed class MarketInvalidation with _$MarketInvalidation {
  const factory MarketInvalidation({
    required String mint,
    required String signature,
    required int slot,
    @Default(<String>[]) List<String> programs,
  }) = _MarketInvalidation;

  factory MarketInvalidation.fromJson(Map<String, dynamic> json) =>
      _$MarketInvalidationFromJson(json);
}
