import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

/// Wraps the auction-related backend endpoints used by the listing flow.
///
/// The webapp builds these transactions client-side with its own SDK; the
/// Flutter wallet defers tx-building to the backend (mirroring the
/// existing buy/bid flows in [MarketBloc]) and only signs and broadcasts.
@lazySingleton
class AuctionRepository {
  AuctionRepository(this._apiV2);

  final MallowApiV2Client _apiV2;

  /// Build an unsigned `createAuction` transaction via the v2
  /// `POST /v2/tx/auctions/create` route. Returns the base64-encoded
  /// serialized message ready for the wallet to sign.
  Future<String> getCreateAuctionTx(CreateAuctionTxRequest args) async {
    final response = await _apiV2.createAuctionTx(args);
    return response.result.tx;
  }
}
