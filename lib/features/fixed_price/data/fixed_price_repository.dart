import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

/// Wraps the backend's fixed-price listing builder so the bloc can stay
/// transport-agnostic. Mirrors `AuctionRepository`. The method name predates
/// the v2 migration — the v1 `getCreateBuyNowTx` route no longer exists.
@lazySingleton
class FixedPriceRepository {
  FixedPriceRepository(this._apiV2);

  final MallowApiV2Client _apiV2;

  /// Build an unsigned listing transaction via the v2
  /// `POST /v2/tx/fixed-price/create` route. The payload is wrapped in the
  /// `{ result }` envelope. When the listing needs a lookup table that does
  /// not exist yet, [CreateFixedPriceTxResponse.setupTx] is also populated
  /// and must be signed and confirmed first.
  ///
  /// Non-native currency listings go through this route unchanged — the v2
  /// handler threads `currencyMint` into `listNft` / `listCoreAsset` /
  /// `listEditions` and only falls back to SOL when it is omitted.
  Future<ApiResponse<CreateFixedPriceTxResponse>> getCreateBuyNowTx(
    CreateFixedPriceTxRequest args,
  ) async {
    return _apiV2.createFixedPriceTx(args);
  }
}
