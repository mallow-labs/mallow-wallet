import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/services/fee_config.dart';

/// Reads + tx-builders for the rafffle program. Mirrors the webapp's
/// raffle hooks.
///
/// Every tx-builder goes to the v2 Rust routes (`POST /v2/tx/raffles/*`). The
/// nodejs `/v1/raffle/*` routes these used to fall back to on a `400` are being
/// deleted backend-side, so a `400` is now the final answer — surface it rather
/// than retrying somewhere that no longer exists.
@lazySingleton
class RaffleRepository {
  RaffleRepository(this._apiV2, this._feeConfig);

  final api.MallowApiV2Client _apiV2;
  final FeeConfig _feeConfig;

  /// Live raffle PDA snapshot — authoritative draw / claim state.
  /// `GET /v2/raffles/:raffle_key`; null when the raffle account is gone
  /// (cancelled or fully settled).
  ///
  /// The backend responds with the `{ viewSlot, raffle }` envelope (absent =
  /// `raffle: null`); legacy backends return the bare `RaffleLiveState`
  /// fields or null. Both shapes are handled.
  Future<api.RaffleLiveState?> getState(String raffleKey) async {
    if (raffleKey.isEmpty) return null;
    try {
      final response = await _apiV2.getRaffleState(raffleKey);
      final raw = response.result?.data;
      if (raw == null) return null;
      if (raw.containsKey('raffle')) {
        final raffle = raw['raffle'];
        if (raffle == null) return null;
        return api.RaffleLiveState.fromJson(raffle as Map<String, dynamic>);
      }
      // Legacy backend: the bare snapshot fields.
      return api.RaffleLiveState.fromJson(raw);
    } catch (e) {
      debugPrint('[RaffleRepository] getState: $e');
      return null;
    }
  }

  /// Build an unsigned `buyTickets` transaction.
  Future<String> getBuyTicketsTx({
    required String buyer,
    required String raffleKey,
    required int ticketCount,
    int? targetPriorityFeeLamports,
  }) async {
    final response = await _apiV2.buyRaffleTicketsTx(
      api.BuyTicketsTxRequest(
        buyer: buyer,
        raffleKey: raffleKey,
        ticketCount: ticketCount,
        targetPriorityFeeLamports:
            targetPriorityFeeLamports ?? _feeConfig.priorityFeeLamports,
      ),
    );
    return response.result.tx;
  }

  /// Build an unsigned `cancelRaffle` transaction.
  Future<String> getCancelRaffleTx({
    required String creator,
    required String raffleKey,
    int? targetPriorityFeeLamports,
  }) async {
    final response = await _apiV2.cancelRaffleTx(
      api.CancelRaffleTxRequest(
        creator: creator,
        raffleKey: raffleKey,
        targetPriorityFeeLamports:
            targetPriorityFeeLamports ?? _feeConfig.priorityFeeLamports,
      ),
    );
    return response.result.tx;
  }

  /// Build an unsigned `claimPrize` transaction. Used by both winners and
  /// creators reclaiming after no-winner draws — backend distinguishes
  /// via `raffle.winner`.
  Future<String> getClaimNftTx({
    required String caller,
    required String raffleKey,
    int? targetPriorityFeeLamports,
  }) async {
    final response = await _apiV2.claimRafflePrizeTx(
      api.ClaimRafflePrizeTxRequest(
        authority: caller,
        raffleKey: raffleKey,
        targetPriorityFeeLamports:
            targetPriorityFeeLamports ?? _feeConfig.priorityFeeLamports,
      ),
    );
    return response.result.tx;
  }

  /// Build an unsigned `collectProceedsV2` transaction.
  Future<String> getClaimProceedsTx({
    required String creator,
    required String raffleKey,
    int? targetPriorityFeeLamports,
  }) async {
    final response = await _apiV2.claimRaffleProceedsTx(
      api.ClaimRaffleProceedsTxRequest(
        creator: creator,
        raffleKey: raffleKey,
        targetPriorityFeeLamports:
            targetPriorityFeeLamports ?? _feeConfig.priorityFeeLamports,
      ),
    );
    return response.result.tx;
  }
}
