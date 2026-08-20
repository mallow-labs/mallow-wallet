import 'package:injectable/injectable.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';

import '../../../core/config/environment.dart';
import '../swap_constants.dart';

@lazySingleton
class SwapRepository {
  SwapRepository(this._jupiterClient);

  final JupiterAggregatorClient _jupiterClient;

  /// Fetch an order (quote + unsigned tx) from the Jupiter Ultra API.
  ///
  /// [slippageBps] / [priorityFeeLamports] are the user's saved settings;
  /// `null` lets Jupiter auto-pick. mallow's 0.5% integrator fee is attached
  /// whenever a referral account is configured.
  Future<UltraOrderResponseDto> getOrder({
    required String inputMint,
    required String outputMint,
    required int amount,
    required String taker,
    int? slippageBps,
    int? priorityFeeLamports,
  }) {
    final referralAccount = Config.jupiterReferralAccount;
    return _jupiterClient.getOrder(
      UltraOrderRequestDto(
        inputMint: inputMint,
        outputMint: outputMint,
        amount: amount,
        taker: taker,
        slippageBps: slippageBps,
        priorityFeeLamports: priorityFeeLamports,
        referralAccount: referralAccount.isEmpty ? null : referralAccount,
        referralFee: referralAccount.isEmpty
            ? null
            : SwapConstants.referralFeeBps,
      ),
    );
  }

  /// Submit the signed order transaction — Jupiter broadcasts and confirms.
  Future<UltraExecuteResponseDto> executeOrder({
    required String signedTransaction,
    required String requestId,
  }) {
    return _jupiterClient.executeOrder(
      UltraExecuteRequestDto(
        signedTransaction: signedTransaction,
        requestId: requestId,
      ),
    );
  }
}
