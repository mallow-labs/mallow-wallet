import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

/// Wraps marketplace read endpoints — listing PDA, edition purchase stats — on the v2 Rust backend. The webapp performs
/// these reads via its own Anchor client; the Flutter wallet routes
/// through the backend instead.
@lazySingleton
class MarketListingRepository {
  MarketListingRepository(this._apiV2);

  final api.MallowApiV2Client _apiV2;

  /// Live edition purchase + allowlist state for [buyer] on the
  /// master-edition [mint]. Drives the `ArtworkBuyEditionSheet`
  /// "Wallet limit reached" / "Not allowlisted" disable. The backend
  /// fetches the listing + `BuyEditionHistory` PDA from the mint.
  Future<api.EditionPurchaseStats?> getEditionPurchaseStats({
    required String mint,
    required String buyer,
  }) async {
    if (mint.isEmpty || buyer.isEmpty) return null;
    try {
      final response = await _apiV2.getEditionPurchaseStats(mint, buyer);
      return response.result;
    } catch (e) {
      debugPrint('[MarketListingRepository] getEditionPurchaseStats: $e');
      return null;
    }
  }

  /// DAS-derived edition state for [mint] — `isPrintableMasterEdition` +
  /// live supply info. Returns null when the asset isn't found. Drives
  /// the dispatcher's `BuyEditionSheet` vs `BuySheet` routing and the
  /// progress bar on `ArtworkBuyEditionSheet`.
  Future<api.EditionLiveState?> getEditionState(String mint) async {
    if (mint.isEmpty) return null;
    try {
      final response = await _apiV2.getEditionState(mint);
      return response.result;
    } catch (e) {
      debugPrint('[MarketListingRepository] getEditionState: $e');
      return null;
    }
  }
}
