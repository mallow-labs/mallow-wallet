import 'package:collection/collection.dart';

import '../../../core/services/pending_evm_tx.dart';
import '../../../core/utils/token_amount.dart';
import '../../../di.dart';
import '../../../shared/utils/price_format.dart' show stripTrailingZeros;
import '../../portfolio/data/ethereum_token_service.dart';

/// What a pending EVM slot costs, for the surfaces that have to say so: the
/// detail sheet's "Max fee" row and the Speed up / Cancel prompts' fee quotes.
///
/// One home because the two got it different ways and drifted: the price lookup
/// and — the part with teeth — the gas limit a fee is multiplied by. A cancel is
/// a 21 000-gas self-send, so pricing one at the original payload's limit
/// overstates the fee several times over.

/// USD price of ETH for the fee rows, or null when it can't be resolved — every
/// caller renders without the "~$…" line rather than blocking on a price.
///
/// Read from the wallet's own balance rows ([EthereumTokenService]);
/// `TokenPriceService` is keyed by Solana mints and cannot resolve the native
/// coin.
Future<double?> pendingTxEthPriceUsd(String walletAddress) async {
  try {
    final tokens = await sl<EthereumTokenService>().getTokenBalances(
      walletAddress,
    );
    return tokens.firstWhereOrNull((t) => t.isNative)?.pricePerToken;
  } on Object catch (_) {
    return null;
  }
}

/// The gas limit a *replacement* for [entry] will burn, which is what the Speed
/// Up sheet must quote against.
///
/// An entry that is already cancelling speeds up its **cancel** (the tracker
/// keeps it a cancel), and an external entry can only be cancelled, so both cost
/// [kCancelGasLimit] rather than the stored payload's limit.
int replacementGasLimitFor(PendingEvmTx entry) =>
    entry.isCancelling || entry.isExternal ? kCancelGasLimit : entry.gasLimit;

/// What [entry] is currently bidding: the highest-fee candidate's max fee over
/// *that candidate's own* gas limit — the ceiling this transaction can cost.
/// `—` when there is no candidate (a derived external entry).
///
/// The limit is per candidate, not per row: a cancel candidate is a 0-ETH
/// self-send burning [kCancelGasLimit], even on a row whose original was a 90k
/// ERC-20 transfer.
String pendingTxMaxFeeLabel(PendingEvmTx entry, double? ethPriceUsd) {
  final candidate = entry.highestFeeCandidate;
  if (candidate == null) return '—';
  final gasLimit = candidate.isCancel ? kCancelGasLimit : entry.gasLimit;
  final wei = candidate.maxFeePerGas * BigInt.from(gasLimit);
  final eth = stripTrailingZeros(TokenAmount.formatTokenAmount(wei, 18));
  if (ethPriceUsd == null) return '$eth ETH';
  final usd = wei / BigInt.from(10).pow(18) * ethPriceUsd;
  return '$eth ETH (~\$${usd.toStringAsFixed(2)})';
}
