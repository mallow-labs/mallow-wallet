import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

/// Reads the aggregated active offers + auction bids the session is involved
/// in via `POST /v2/offers/inbox` — both received (on the viewer's art) and
/// placed (by the viewer), across every wallet in [owners]. Backs the Offers
/// screen.
@lazySingleton
class OffersInboxRepository {
  OffersInboxRepository(this._apiV2);

  final api.MallowApiV2Client _apiV2;

  /// One page of the merged, recency-sorted feed. [owners] is every session
  /// wallet address. [sort] defaults to latest-first.
  Future<api.OffersInboxPage> getInbox({
    required Iterable<String> owners,
    api.OffersInboxSort sort = api.OffersInboxSort.latest,
    int page = 0,
    int pageSize = 30,
  }) async {
    final response = await _apiV2.getOffersInbox(
      api.GetOffersInboxRequest(
        owners: owners.where((a) => a.isNotEmpty).toSet().toList(),
        sort: sort,
        page: page,
        pageSize: pageSize,
      ),
    );
    return response.result;
  }
}
