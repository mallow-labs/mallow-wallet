// Hand-rolled because the vendored spec models TokenPricesResult as
// `additionalProperties: {type: string}`. swagger_dart_code_generator emits
// an empty class for that shape — the price map is silently dropped on
// fromJson. Drop the hand-rolled model once the generator emits that map.

/// Response wrapper for `GET /v0/getTokenPrices`.
///
/// The backend returns a bare `{ <mint>: <priceString> }` map (string-encoded
/// to avoid losing precision on tiny token prices). We hand-roll the
/// deserializer because retrofit's `Map<String, String>.fromJson` codegen
/// doesn't compile, and parse the strings to `double` here so consumers
/// don't have to repeat the conversion.
class TokenPricesResponse {
  const TokenPricesResponse({required this.usdByMint});

  /// Mint address → USD price.
  final Map<String, double> usdByMint;

  factory TokenPricesResponse.fromJson(Map<String, dynamic> json) {
    return TokenPricesResponse(
      usdByMint: {
        for (final entry in json.entries)
          if (entry.value is String)
            entry.key: double.tryParse(entry.value as String) ?? 0
          else if (entry.value is num)
            entry.key: (entry.value as num).toDouble(),
      },
    );
  }
}
