import 'package:flutter/widgets.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/network/evm_transfer_core.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart' show Chain;
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../send/models/eth_gas.dart';
import '../../send/widgets/cancel_transaction_sheet.dart';
import '../../send/widgets/edit_gas_fee_sheet.dart';
import '../utils/pending_tx_fee.dart';

/// The two user-facing actions on a pending EVM transaction, shared by the
/// pending cell and the pending-transaction detail sheet.
///
/// Both prompt first and act second: the fee is a real cost the user is about
/// to pay a second time on a transaction they already paid for, so nothing is
/// re-broadcast without an explicit confirmation.
///
/// **Neither adds a step-up auth prompt, deliberately.** A replacement changes
/// only the fee: the recipient, the amount and the calldata are replayed
/// verbatim from an entry the user already reviewed, gated and authorised once.
/// Re-prompting for biometrics to raise a gas cap would train users to approve
/// prompts they can't distinguish, and the *destination* of the funds cannot
/// change here. What they do carry is the remote kill switch — these paths sign
/// and broadcast, and `signAndBroadcastEvmTransfer` (unlike the Solana
/// executor) does not route through `TransactionAuthGate`, so without the guard
/// below there is no layer at all between an operator's kill and a broadcast.

/// The kill-switch cell a replacement for [entry] belongs to.
///
/// A cancel is literally a 0-ETH self-send, so it answers to `native-send`
/// whatever the original was. A speed-up replays the original payload, so it
/// answers to the original's cell — killing ERC-20 sends must not also freeze
/// a stuck ETH transfer, and vice versa.
///
/// Killing `ethereum:native-send` therefore also stops cancels. That is
/// deliberate and matches the kill-switch escape-hatch rule:
/// a cancel *is* a native send, and an operator who has killed native sends
/// because broadcasting them is broken has not left a working cancel path to
/// preserve.
FlowKey pendingTxReplacementFlowKey(
  PendingEvmTx entry, {
  required bool asCancel,
}) {
  if (asCancel) return const FlowKey(Chain.ethereum, AppFlow.nativeSend);
  return switch (entry.kind) {
    PendingEvmTxKind.nftTransfer => const FlowKey(
      Chain.ethereum,
      AppFlow.nftTransfer,
    ),
    // A `send` with calldata is an ERC-20 transfer; without it, native ETH.
    PendingEvmTxKind.send when entry.data.isNotEmpty => const FlowKey(
      Chain.ethereum,
      AppFlow.tokenSend,
    ),
    // `swap`, `other` and `external` have no cell of their own on EVM. They
    // fall to `native-send` rather than going ungated — an unmatched kind must
    // never be the one path an operator cannot stop.
    _ => const FlowKey(Chain.ethereum, AppFlow.nativeSend),
  };
}

/// Re-price a stuck transaction: open the Edit Gas Fee sheet retitled "Speed Up
/// Transaction", floored so every tier it offers clears the node's 10% bump,
/// and re-broadcast [entry] at the fee the user picks.
///
/// The node can still answer "replacement transaction underpriced" — the floor
/// is computed from the candidates *we* know about, and another client may have
/// bid the same nonce higher. That is not a dead end: the sheet reopens with
/// the floor raised 25%, so the user can walk the bid up instead of being told
/// to give up.
Future<void> promptSpeedUp(BuildContext context, PendingEvmTx entry) async {
  // A speed-up that is really a cancel (an entry already being cancelled, or
  // an external nonce with no payload to replay) reads the cancel cell — the
  // same `asCancel` the tracker itself derives, so the gate and the broadcast
  // can never disagree about which cell they are.
  final flow = pendingTxReplacementFlowKey(
    entry,
    asCancel: entry.isCancelling || entry.isExternal,
  );
  if (await guardFlowDisabled(context, flow)) return;
  if (!context.mounted) return;
  final tracker = sl<PendingEvmTxTracker>();
  final preparation = _prepareSpeedUp(entry, tracker);
  final initialSelection = await showEditGasFeeSheetLoading(
    context,
    preparation: preparation,
    onPreparationError: (error) {
      if (context.mounted) {
        _showFailure(
          context,
          error,
          fallback: "Couldn't load network fees. Please try again.",
        );
      }
    },
  );
  if (initialSelection == null || !context.mounted) return;
  // The preparation has completed before the real sheet is interactive, so
  // this await does not add another user-visible delay. Keep the resolved
  // market around for the underpriced-replacement retry path below.
  final prepared = await preparation;
  var selection = initialSelection;
  var floor = prepared.replacementFloor;

  while (true) {
    if (!context.mounted) return;
    try {
      final result = await tracker.speedUp(entry, selection);
      if (context.mounted) _showOutcome(context, result, 'Speed up submitted');
      return;
    } on Object catch (e) {
      if (classifyEvmBroadcastError(e) !=
          EvmBroadcastError.replacementUnderpriced) {
        if (context.mounted) {
          _showFailure(
            context,
            e,
            fallback: "Couldn't speed up the transaction",
          );
        }
        return;
      }
      floor = escalateCaps((
        maxFeePerGas: selection.maxFeePerGas,
        maxPriorityFeePerGas: selection.maxPriorityFeePerGas,
      ));
      if (!context.mounted) return;
      final nextSelection = await showEditGasFeeSheet(
        context,
        market: prepared.market,
        selection: EthGasSelection.fromTier(
          prepared.market.market,
          gasLimit: prepared.defaultGasLimit,
        ),
        estimatedGasUsed: prepared.estimatedGasUsed,
        defaultGasLimit: prepared.defaultGasLimit,
        ethPriceUsd: prepared.ethPriceUsd,
        title: prepared.title,
        replacementFloor: floor,
      );
      if (nextSelection == null) return;
      selection = nextSelection;
    }
  }
}

/// Replace a stuck transaction with a 0-ETH self-send at the same nonce, after
/// confirming the replacement's fee on the Cancel Transaction sheet.
Future<void> promptCancel(BuildContext context, PendingEvmTx entry) async {
  if (await guardFlowDisabled(
    context,
    pendingTxReplacementFlowKey(entry, asCancel: true),
  )) {
    return;
  }
  if (!context.mounted) return;
  final tracker = sl<PendingEvmTxTracker>();
  final rpc = sl<EthereumRpcService>();
  final preparation = _prepareCancel(entry, rpc);
  final confirmed = await showCancelTransactionSheetLoading(
    context,
    walletAddress: entry.walletAddress,
    preparation: preparation,
    onPreparationError: (error) {
      if (context.mounted) {
        _showFailure(
          context,
          error,
          fallback: "Couldn't load network fees. Please try again.",
        );
      }
    },
    // Nothing to out-bid means the blind-cancel ladder decides the final fee.
    feeMayIncrease: entry.isExternal && entry.candidates.isEmpty,
  );
  if (confirmed != true) return;
  // The preparation has completed before Confirm can be tapped, so this await
  // is already resolved and gives us the exact caps the sheet displayed.
  final prepared = await preparation;

  try {
    final result = await tracker.cancel(entry, prepared.caps);
    if (context.mounted) {
      _showOutcome(context, result, 'Cancellation submitted');
    }
  } on Object catch (e) {
    if (context.mounted) {
      _showFailure(context, e, fallback: "Couldn't cancel the transaction");
    }
  }
}

Future<EditGasFeeSheetData> _prepareSpeedUp(
  PendingEvmTx entry,
  PendingEvmTxTracker tracker,
) async {
  final marketFuture = EthGasMarket.fetch(sl<EthereumRpcService>());
  final priceFuture = pendingTxEthPriceUsd(entry.walletAddress);
  final market = await marketFuture;
  final priceUsd = await priceFuture;
  final gasLimit = replacementGasLimitFor(entry);

  // Non-null keeps the sheet in replacement mode (gas-limit control hidden,
  // nothing persisted as the user's default fee) even for an entry with no
  // candidate to out-bid, where a zero floor leaves the tiers untouched.
  final floor =
      tracker.replacementFloorOf(entry) ??
      (maxFeePerGas: BigInt.zero, maxPriorityFeePerGas: BigInt.zero);

  return EditGasFeeSheetData(
    market: market,
    selection: EthGasSelection.fromTier(market.market, gasLimit: gasLimit),
    estimatedGasUsed: BigInt.from(gasLimit),
    defaultGasLimit: gasLimit,
    ethPriceUsd: priceUsd,
    title: 'Speed Up Transaction',
    replacementFloor: floor,
  );
}

Future<CancelTransactionSheetData> _prepareCancel(
  PendingEvmTx entry,
  EthereumRpcService rpc,
) async {
  final marketFuture = EthGasMarket.fetch(rpc);
  final balanceFuture = rpc.getBalance(entry.walletAddress);
  final priceFuture = pendingTxEthPriceUsd(entry.walletAddress);
  final market = await marketFuture;
  final balanceWei = await balanceFuture;
  final priceUsd = await priceFuture;

  // Quoted once, gated once, signed once: the caps the sheet prices and checks
  // the balance against are the caps the tracker signs, so a base fee that
  // climbs while the user reads the sheet can't turn an affordable cancel into
  // an insufficient-funds failure.
  final caps = cancelCapsFor(entry, market);
  return CancelTransactionSheetData(
    maxFeePerGas: caps.maxFeePerGas,
    balanceWei: balanceWei,
    ethPriceUsd: priceUsd,
    caps: caps,
  );
}

/// Report what the replacement actually did.
///
/// [submitted] is only shown when something reached the wire: a `nonce too low`
/// rejection means the slot resolved while the user was deciding and nothing was
/// broadcast, so claiming a submission would have the user believe they are
/// paying a second fee for a transaction that does not exist.
void _showOutcome(
  BuildContext context,
  PendingTxReplacementResult result,
  String submitted,
) => AppSnackBar.show(context, switch (result) {
  PendingTxReplacementResult.broadcast => submitted,
  PendingTxReplacementResult.alreadyResolved => 'Transaction already confirmed',
});

/// Surface [error] unless the user simply backed out of the signing prompt —
/// a cancelled biometric is not a failure to report.
///
/// Only our own typed messages are shown; anything else (raw node/transport
/// text) collapses to [fallback].
void _showFailure(
  BuildContext context,
  Object error, {
  required String fallback,
}) {
  if (AppFailure.from(error).isCancelled || !context.mounted) return;
  AppSnackBar.show(context, switch (error) {
    EvmTransferBlockedException(:final message) => message,
    EvmTransferException(:final message) => message,
    _ => fallback,
  }, type: AppSnackBarType.error);
}
