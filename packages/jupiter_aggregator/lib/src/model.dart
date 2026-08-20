// ignore_for_file: invalid_annotation_target, freezed compatibility

import 'package:freezed_annotation/freezed_annotation.dart';

part 'model.freezed.dart';
part 'model.g.dart';

/// Query parameters for `GET /ultra/v1/order`.
///
/// `slippageBps` / `priorityFeeLamports` are optional overrides — when
/// omitted Jupiter picks both automatically (real-time slippage estimation
/// and network-condition-based priority fees).
///
/// `referralAccount` + `referralFee` (bps, 50–255) route an integrator fee
/// to the referral program account; both must be set together.
@freezed
abstract class UltraOrderRequestDto with _$UltraOrderRequestDto {
  const factory UltraOrderRequestDto({
    required String inputMint,
    required String outputMint,
    required int amount,
    String? taker,
    int? slippageBps,
    int? priorityFeeLamports,
    String? referralAccount,
    int? referralFee,
  }) = _UltraOrderRequestDto;

  factory UltraOrderRequestDto.fromJson(Map<String, dynamic> json) =>
      _$UltraOrderRequestDtoFromJson(json);
}

/// Response of `GET /ultra/v1/order` — a quote plus (when `taker` was sent)
/// an unsigned base64 transaction to sign and submit via `POST /execute`.
@freezed
abstract class UltraOrderResponseDto with _$UltraOrderResponseDto {
  const factory UltraOrderResponseDto({
    required String inputMint,
    required String outputMint,
    required String inAmount,
    required String outAmount,
    required String otherAmountThreshold,
    required String requestId,

    /// Unsigned base64 transaction. Null when no `taker` was provided;
    /// empty string when a `taker` was provided but the transaction could
    /// not be built (see [errorMessage], e.g. insufficient funds).
    String? transaction,
    String? swapMode,
    int? slippageBps,
    String? priceImpactPct,
    num? priceImpact,
    num? feeBps,
    String? feeMint,
    num? signatureFeeLamports,
    num? prioritizationFeeLamports,
    num? rentFeeLamports,
    bool? gasless,
    String? router,
    num? inUsdValue,
    num? outUsdValue,
    String? expireAt,
    num? errorCode,
    String? errorMessage,
    String? error,
  }) = _UltraOrderResponseDto;

  factory UltraOrderResponseDto.fromJson(Map<String, dynamic> json) =>
      _$UltraOrderResponseDtoFromJson(json);
}

/// Body of `POST /ultra/v1/execute`.
@freezed
abstract class UltraExecuteRequestDto with _$UltraExecuteRequestDto {
  const factory UltraExecuteRequestDto({
    required String signedTransaction,
    required String requestId,
  }) = _UltraExecuteRequestDto;

  factory UltraExecuteRequestDto.fromJson(Map<String, dynamic> json) =>
      _$UltraExecuteRequestDtoFromJson(json);
}

/// Response of `POST /ultra/v1/execute`. Jupiter broadcasts and confirms the
/// transaction itself — `status` is `Success` or `Failed`.
@freezed
abstract class UltraExecuteResponseDto with _$UltraExecuteResponseDto {
  const factory UltraExecuteResponseDto({
    String? status,
    String? signature,

    /// Slot the swap landed in. The live API returns this as a JSON string
    /// (e.g. "292739551"), not a number.
    String? slot,
    num? code,
    String? error,
    String? totalInputAmount,
    String? totalOutputAmount,
  }) = _UltraExecuteResponseDto;

  factory UltraExecuteResponseDto.fromJson(Map<String, dynamic> json) =>
      _$UltraExecuteResponseDtoFromJson(json);

  const UltraExecuteResponseDto._();

  bool get isSuccess => status == 'Success';
}

@freezed
abstract class PriceRequestDto with _$PriceRequestDto {
  const factory PriceRequestDto({@JsonKey(toJson: _listToString) required List<String> ids}) =
      _PriceRequestDto;

  factory PriceRequestDto.fromJson(Map<String, dynamic> json) => _$PriceRequestDtoFromJson(json);
}

/// One entry of a Price v3 body, keyed in the response by its mint.
///
/// `usdPrice` is a JSON **number** — v2's `price` was a string, and v2 is gone.
@freezed
abstract class PriceDto with _$PriceDto {
  const factory PriceDto({required double? usdPrice}) = _PriceDto;

  factory PriceDto.fromJson(Map<String, dynamic> json) => _$PriceDtoFromJson(json);
}

String _listToString(List<String> list) => list.join(',');
