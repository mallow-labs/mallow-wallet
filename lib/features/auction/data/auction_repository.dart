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
  /// `POST /v2/tx/auctions/create` route. The payload is wrapped in the
  /// `{ result }` envelope: [UnsignedTxWithSetupResponse.tx] is always the
  /// listing transaction, and a compressed NFT whose eventual settle would not
  /// fit the 1232-byte packet raw *also* carries
  /// [UnsignedTxWithSetupResponse.setupTx] — the address-lookup-table
  /// transaction `tx` is compiled against.
  ///
  /// The envelope is returned whole (rather than just `tx`) because the caller
  /// must sign and confirm `setupTx` FIRST: dropping it broadcasts a
  /// transaction naming a lookup table that does not exist yet, which fails
  /// on-chain. Mirrors [FixedPriceRepository.getCreateBuyNowTx].
  Future<ApiResponse<UnsignedTxWithSetupResponse>> getCreateAuctionTx(
    CreateAuctionTxRequest args,
  ) async {
    return _apiV2.createAuctionTx(args);
  }
}
