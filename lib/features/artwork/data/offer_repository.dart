import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

/// Reads marketplace offers via `POST /v1/offers`. Used by the dispatcher to
/// detect `userOwnOffer` — i.e. whether the connected wallet already has a
/// live offer on the artwork — and by the artwork page's Offers section /
/// accept-offer sheet for the full active-offer list.
@lazySingleton
class OfferRepository {
  OfferRepository(this._api);

  final api.MallowApiClient _api;

  /// Active offers on [mintAccount], one page at a time. Mirrors the
  /// webapp's artwork-page offers query (`filter: {nftMint, activeOnly}`).
  /// [sort] defaults to latest-first for list rows; pass
  /// [api.OfferSort.highestOffer] when only the top offer matters
  /// (accept-offer sheet).
  Future<api.OffersPage> getOffers({
    required String mintAccount,
    int page = 0,
    int? pageSize,
    api.OfferSort sort = api.OfferSort.latest,
  }) {
    return _api.getOffers(
      api.GetOffersRequest(
        page: page,
        pageSize: pageSize,
        sort: sort,
        filter: api.OfferFilter(nftMint: mintAccount, activeOnly: true),
      ),
    );
  }

  /// The single highest active offer on [mintAccount], or null when none
  /// exist (or the read fails — callers treat that as "nothing to accept").
  Future<api.OfferRender?> getHighestOffer({
    required String mintAccount,
  }) async {
    try {
      final pageResult = await getOffers(
        mintAccount: mintAccount,
        pageSize: 1,
        sort: api.OfferSort.highestOffer,
      );
      return pageResult.result.isEmpty ? null : pageResult.result.first;
    } catch (e) {
      debugPrint('[OfferRepository] getHighestOffer failed: $e');
      return null;
    }
  }

  /// Returns the connected wallet's active offer on [mintAccount], or null
  /// when none exists. Membership in [buyerAddresses] is the
  /// authoritative ownership check — pass every linked wallet so a user
  /// connected via any address sees their offer.
  Future<api.OfferRender?> getUserActiveOffer({
    required String mintAccount,
    required Iterable<String> buyerAddresses,
  }) async {
    final addresses = buyerAddresses.where((a) => a.isNotEmpty).toSet();
    if (addresses.isEmpty || mintAccount.isEmpty) return null;
    // The endpoint filters by a single buyer address per call. For users
    // with multiple linked wallets we run the queries in parallel and pick
    // the first hit — typically only one wallet has an offer at a time.
    try {
      final results = await Future.wait(
        addresses.map(
          (buyer) => _api.getOffers(
            api.GetOffersRequest(
              filter: api.OfferFilter(
                buyer: buyer,
                nftMint: mintAccount,
                activeOnly: true,
              ),
            ),
          ),
        ),
      );
      for (final page in results) {
        if (page.result.isNotEmpty) return page.result.first;
      }
      return null;
    } catch (e) {
      debugPrint('[OfferRepository] getUserActiveOffer failed: $e');
      return null;
    }
  }
}
