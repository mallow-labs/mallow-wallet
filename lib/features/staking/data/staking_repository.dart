import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

/// Data source for the staking feature. Wraps the `GET /v1/staking` endpoint
/// (global + per-user staking data). On-chain reads (stake-account
/// enumeration) and transaction building live in `StakingTxBuilder`.
@lazySingleton
class StakingRepository {
  StakingRepository(this._api);

  final MallowApiClient _api;

  /// Fetch the combined staking payload. Mirrors the webapp's
  /// `apiGET("/v1/staking")`.
  Future<StakingDataResponse> getStakingData() async {
    final response = await _api.getStaking();
    return response.result;
  }

  /// Build the season-rewards claim transaction for [amount] raw SMORES units
  /// (base64, unsigned v0). Mirrors the webapp's
  /// `apiPOST("/v1/staking/getClaimTx")`.
  ///
  /// The rewards are ZK-compressed, and composing a decompress needs a validity
  /// proof and token-pool accounts from a Photon indexer — so unlike every
  /// other staking transaction this one is built server-side, not here.
  Future<String> getClaimTx({required int amount}) async {
    final response = await _api.getStakingClaimTx(
      StakingGetClaimTxRequest(amount: amount),
    );
    return response.result.tx;
  }
}
