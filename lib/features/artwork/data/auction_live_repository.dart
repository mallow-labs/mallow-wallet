import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

/// Wraps `GET /v2/auctions/:mint` — live `MallowAuction` PDA snapshot.
/// Polled by the auction sheets while the auction is active so the
/// countdown / "Highest bid by …" line stays in sync with chain state
/// without waiting for an indexer cycle.
@lazySingleton
class AuctionLiveRepository {
  AuctionLiveRepository(this._apiV2);

  final api.MallowApiV2Client _apiV2;

  /// Returns null when the auction account doesn't exist (already settled
  /// + closed, or never created).
  ///
  /// The backend responds with the `{ viewSlot, auction }` envelope (absent =
  /// `auction: null`); legacy backends return the bare `AuctionLiveState`
  /// fields or a 404. Both shapes are handled — the snapshot's fields are all
  /// merged monotonically by the caller, so the view slot itself is not
  /// (yet) surfaced.
  Future<api.AuctionLiveState?> getState(String mint) async {
    if (mint.isEmpty) return null;
    try {
      final response = await _apiV2.getAuctionState(mint);
      final raw = response.result?.data;
      if (raw == null) return null;
      if (raw.containsKey('auction')) {
        final auction = raw['auction'];
        if (auction == null) return null;
        return api.AuctionLiveState.fromJson(auction as Map<String, dynamic>);
      }
      // Legacy backend: the bare snapshot fields.
      return api.AuctionLiveState.fromJson(raw);
    } on DioException catch (e) {
      // Transport / HTTP failure (incl. 404 "no auction account") — the
      // expected "absent or temporarily unreachable" path. Degrade to null.
      debugPrint('[AuctionLiveRepository] getState($mint) request failed: $e');
      return null;
    } catch (e, s) {
      // A non-Dio error is a deserialization / contract mismatch, NOT an
      // absent account. Surface it loudly so the snapshot backstop silently
      // degrading to the laggy indexer is visible rather than masked as null.
      debugPrint(
        '[AuctionLiveRepository] getState($mint) DECODE error '
        '(contract drift?): $e\n$s',
      );
      return null;
    }
  }
}
