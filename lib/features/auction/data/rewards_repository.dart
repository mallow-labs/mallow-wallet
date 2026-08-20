import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

/// Persists off-chain rewards/physical metadata for a listing. The returned
/// id is concatenated into the listing transaction's memo as `rewards:<id>`
/// so the indexer can join the on-chain listing back to the description.
@lazySingleton
class RewardsRepository {
  RewardsRepository(this._api);

  final MallowApiClient _api;

  Future<String> postRewardsDescription(
    RewardsDescriptionPayload payload,
  ) async {
    final raw = await _api.postRewardsDescription(
      PostRewardsDescriptionRequest(rewardsDescription: payload),
    );
    final result = raw is Map ? raw['result'] : null;
    if (result is! String || result.isEmpty) {
      throw StateError('rewardsDescription endpoint returned no id');
    }
    return result;
  }
}
