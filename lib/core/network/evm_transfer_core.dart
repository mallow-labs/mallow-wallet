import 'dart:typed_data';

// web3dart 3.x re-homed EthereumAddress/EtherAmount in package:wallet; it
// imports them but does not re-export, so they need a direct import here.
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/web3dart.dart';

import '../crypto/wallet_manager.dart';
import '../services/pending_evm_tx_tracker.dart';
import 'ethereum_rpc_service.dart';

const _zeroEvmAddress = '0x0000000000000000000000000000000000000000';

/// Shared money-movement core for the EVM transfer services
/// (`EthereumTransferService` for native/ERC-20 sends,
/// `EvmArtworkTransferService` for ERC-721/1155 artwork transfers). Both run the
/// same security-critical pipeline — a state-change simulation gate and an
/// on-device sign-and-broadcast — so the pieces that must stay byte-for-byte in
/// lock-step live here, once. The genuinely per-flow parts (calldata encoding,
/// the artwork auth-gate and recipient-contract probe) stay in the services.

/// Decode a `0x`-prefixed (or bare) hex string to bytes. An empty / `0x` value
/// yields an empty list; an odd-length string is left-padded with a nibble.
Uint8List evmHexToBytes(String hex) {
  final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (clean.isEmpty) return Uint8List(0);
  final normalized = clean.length.isOdd ? '0$clean' : clean;
  final out = Uint8List(normalized.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Encode bytes as a `0x`-prefixed lowercase hex string. Empty/absent calldata
/// encodes as the empty string (not `0x`), so a round-trip through
/// [evmHexToBytes] reproduces "no calldata".
String evmBytesToHex(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return '';
  return '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Decode a `0x`-prefixed (or bare) hex string to a [BigInt]. An empty / `0x`
/// value is zero.
BigInt evmHexToBigInt(String hex) {
  final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (clean.isEmpty) return BigInt.zero;
  return BigInt.parse(clean, radix: 16);
}

/// Assert the simulated state change is exactly the intended asset leaving
/// [source] — no approval grants, no other outflow, no revert. This is the
/// fail-closed
/// heart of the safety gate: every early exit is a *throw*, and reaching the end
/// with nothing matched is also a throw.
///
/// The two per-flow decisions are injected:
///  * [isIntendedAsset] — whether an outflow is *the* asset the user chose (a
///    token contract / native match for a send, a contract + tokenId match for
///    an NFT).
///  * [assertAmount] — asserts the moved amount/quantity matches what was
///    requested; it throws an [EvmTransferBlockedException] on a mismatch, or
///    does nothing when the flow has no per-change amount check.
///
/// [noMovementMessage] is the block message when the simulation shows nothing
/// leaving the wallet.
void assertEvmSimulation(
  EvmSimulationResult sim, {
  required String source,
  required bool Function(EvmAssetChange change) isIntendedAsset,
  required void Function(EvmAssetChange change) assertAmount,
  required String noMovementMessage,
}) {
  if (sim.error != null) {
    throw EvmTransferBlockedException(
      'This transfer would fail on-chain: ${sim.error}',
    );
  }
  final owner = source.toLowerCase();
  var matched = 0;
  for (final change in sim.changes) {
    // Only changes *from* the wallet can move or grant rights over its assets;
    // an approve/outflow whose `from` isn't the owner (e.g. a recipient
    // contract's internal approve) can never touch the owner's assets.
    if (change.from != owner) continue;
    // ERC-721 transfers clear the token's approval by writing the zero
    // address. Alchemy reports that state change as APPROVE, but it is a
    // revocation rather than a new spender gaining control. Only a non-zero
    // approval target is an approval grant; a missing target remains blocked.
    if (change.isApprove && change.to?.toLowerCase() != _zeroEvmAddress) {
      throw const EvmTransferBlockedException(
        'This transfer would grant an approval over your assets.',
      );
    }
    if (!isIntendedAsset(change)) {
      throw const EvmTransferBlockedException(
        'This transfer would move an unexpected asset from your wallet.',
      );
    }
    assertAmount(change);
    matched++;
  }
  if (matched == 0) {
    throw EvmTransferBlockedException(noMovementMessage);
  }
}

/// The gas limit to sign for a validated transfer: the user's [overrideGasLimit]
/// when set, but never below [preparedGasLimit] — the padded estimate the
/// simulation gate already validated. A persisted or hand-edited limit lower than
/// the estimate would broadcast an out-of-gas transaction that mines a revert
/// with the fee still charged and the asset unmoved. Unused gas is refunded, so
/// keeping the estimate's headroom never overcharges; flooring here is free
/// defense-in-depth behind the resolve-layer fix (which stops a stale limit from
/// another transaction being applied in the first place).
int effectiveSignedGasLimit({
  required int? overrideGasLimit,
  required int preparedGasLimit,
}) => (overrideGasLimit == null || overrideGasLimit < preparedGasLimit)
    ? preparedGasLimit
    : overrideGasLimit;

/// Fill nonce + fees, sign a validated EVM transfer on-device, broadcast it, and
/// best-effort wait for inclusion. Returns the transaction hash. [onBroadcasting]
/// fires once the tx is signed and about to be broadcast (drives the
/// signing → broadcasting UI transition); [onBroadcastRegistered] fires only
/// after the node has accepted the raw transaction *and* the broadcast has been
/// handed to `PendingEvmTxTracker`. That later signal is what makes leaving the
/// flow early safe: until it fires, `sendRawTransaction` can still throw and the
/// only place that failure can be shown is the flow the user would be leaving.
///
/// [onBroadcastRegistered] also carries the [PendingTxResolutionClaim] this call
/// took out on the slot (when it waits for inclusion): while the claim is held
/// the tracker stays quiet about the outcome, because this flow is going to show
/// it. A UI that lets the user leave early must call
/// [PendingTxResolutionClaim.release] when they do, or the outcome is reported
/// nowhere.
///
/// The nonce is always re-read so back-to-back sends don't sign an expired one.
/// When [refreshFees] is true (no user fee override), the review-time values
/// could be stale by broadcast, so both are reconciled against fresh chain state
/// immediately before signing:
///  * the EIP-1559 caps are re-fetched — a base-fee spike would otherwise leave
///    the signed [maxFeePerGas] under-priced and the tx stuck, and
///  * the pre-sign `estimateGas` (which also throws if the transfer would now
///    revert) is *used*: if the recipient's storage state changed since review
///    (e.g. a token slot went zero→nonzero) the transfer now burns more gas than
///    the prepared pad, so the signed limit is raised to the larger of the
///    prepared limit and the freshly padded estimate ([gasHeadroomNum] /
///    [gasHeadroomDen], defaulting to the shared 20%). Signing the stale lower
///    limit would mine an out-of-gas revert with the fee still charged; unused
///    gas is refunded, so the higher cap never overcharges.
///
/// [nonceOverride] makes this a **replacement** (speed-up / cancel) for an
/// existing pending transaction: the pending-nonce read is skipped entirely so
/// the replacement lands on the caller's slot, and the fee refresh is skipped
/// even when [refreshFees] is true — re-fetching the market could sign *below*
/// the 110% bump the node demands over the transaction being replaced.
///
/// The broadcast is registered with `PendingEvmTxTracker` ([trackKind] /
/// [trackAs] describe it for display; [trackRole] says whether it opens a nonce
/// slot or joins one). Registration is fire-and-forget: the transaction is
/// already on the wire by then, so a tracker or database failure must never
/// turn a successful send into an error.
///
/// [awaitInclusion] is false for replacements, whose caller (the tracker) owns
/// confirmation through its own watcher and must not block a UI action for the
/// 60 s inclusion wait.
///
/// When [refreshFees] is false the caller's [maxFeePerGas] /
/// [maxPriorityFeePerGas] / [gasLimit] (the user's chosen fee) are signed
/// verbatim.
///
/// For a **native ETH send** ([data] null) the balance is re-read and the send
/// fails closed *before signing* when `value + signedGasLimit × maxFeePerGas`
/// exceeds it: the node reserves that worst-case budget at inclusion, so a Max
/// send whose gas limit or fee cap rose since it was computed (a contract
/// recipient's heavier gas, or a cap bumped by the refresh/an override) would
/// otherwise be rejected "insufficient funds for gas * price + value" only
/// *after* biometric auth. Throwing here surfaces a re-quote message instead.
Future<String> signAndBroadcastEvmTransfer({
  required EthereumRpcService rpc,
  required WalletManager walletManager,
  required String walletId,
  required String source,
  required EthereumAddress to,
  required BigInt value,
  required Uint8List? data,
  required int gasLimit,
  required BigInt maxFeePerGas,
  required BigInt maxPriorityFeePerGas,
  required bool refreshFees,
  int gasHeadroomNum = 12,
  int gasHeadroomDen = 10,
  void Function()? onBroadcasting,
  void Function(PendingTxResolutionClaim? claim)? onBroadcastRegistered,
  int? nonceOverride,
  PendingEvmTxKind trackKind = PendingEvmTxKind.other,
  PendingTxMetadata? trackAs,
  PendingTxCandidateRole trackRole = PendingTxCandidateRole.original,
  bool awaitInclusion = true,
}) async {
  final isReplacement = nonceOverride != null;
  var signMaxFeePerGas = maxFeePerGas;
  var signMaxPriorityFeePerGas = maxPriorityFeePerGas;
  var signGasLimit = gasLimit;
  // A native ETH send has no calldata; an ERC-20 / artwork transfer always does.
  final isNativeSend = data == null;
  if (refreshFees && !isReplacement) {
    // Re-fetch the fee market and re-run estimateGas immediately before signing,
    // so a stale review estimate can never broadcast against an under-priced fee
    // or a transfer that would now revert.
    final results = await Future.wait<Object>([
      rpc.getFeeData(),
      rpc.estimateGas(
        from: source,
        to: to.with0x,
        valueWei: value == BigInt.zero ? null : value,
        data: data,
      ),
    ]);
    final fee = results[0] as EthFeeData;
    final freshEstimate = results[1] as BigInt;
    signMaxFeePerGas = fee.maxFeePerGas;
    signMaxPriorityFeePerGas = fee.maxPriorityFeePerGas;
    // Reconcile the gas limit against the fresh estimate — a heavier transfer
    // now needs more gas than the prepared pad. Keep the larger of the two.
    final freshPadded =
        (freshEstimate *
                BigInt.from(gasHeadroomNum) ~/
                BigInt.from(gasHeadroomDen))
            .toInt();
    if (freshPadded > signGasLimit) signGasLimit = freshPadded;
  }

  final nonce = nonceOverride ?? await rpc.getNonce(source);

  if (isNativeSend) {
    // Fail closed before signing when the worst-case budget the node reserves
    // (value + gasLimit × maxFeePerGas) exceeds the fresh balance.
    final balance = await rpc.getBalance(source);
    final budget = value + BigInt.from(signGasLimit) * signMaxFeePerGas;
    if (budget > balance) {
      throw const EvmTransferBlockedException(
        'The amount plus the network fee now exceeds your balance. Go back and '
        're-enter the amount to get a fresh quote.',
      );
    }
  }

  final transaction = Transaction(
    to: to,
    value: EtherAmount.inWei(value),
    data: data,
    maxGas: signGasLimit,
    maxFeePerGas: EtherAmount.inWei(signMaxFeePerGas),
    maxPriorityFeePerGas: EtherAmount.inWei(signMaxPriorityFeePerGas),
    nonce: nonce,
  );
  final signed = await walletManager.signEthereumTransaction(
    walletId,
    transaction,
    chainId: rpc.chainId,
  );
  onBroadcasting?.call();
  final hash = await rpc.sendRawTransaction(signed);
  // Persist the broadcast so the nonce stays actionable (speed up / cancel)
  // across restarts. Fire-and-forget by contract — see the doc comment.
  notifyPendingEvmBroadcast(
    PendingEvmBroadcast(
      walletAddress: source,
      nonce: nonce,
      chainId: rpc.chainId,
      kind: trackKind,
      role: trackRole,
      toAddress: to.with0x,
      valueWei: value,
      data: evmBytesToHex(data),
      gasLimit: signGasLimit,
      maxFeePerGas: signMaxFeePerGas,
      maxPriorityFeePerGas: signMaxPriorityFeePerGas,
      hash: hash,
      metadata: trackAs,
    ),
  );
  // Claim the resolution notice in the same synchronous turn as the registration
  // above, so no watcher pass can resolve — and announce — this slot in between.
  // Only a flow that waits out inclusion itself claims: a replacement's caller
  // (the tracker) has no success screen of its own, so the toast is its report.
  final claim = awaitInclusion
      ? claimPendingEvmResolution(source, nonce)
      : null;
  // The nonce is now tracked, so nothing after this point can strand the user:
  // any remaining failure (an inclusion-wait timeout) leaves a Pending entry
  // that owns the transaction. Only here may a UI offer an early exit — and a UI
  // that does must hand [claim] back when the user takes it (see `SendBloc`).
  onBroadcastRegistered?.call(claim);
  if (!awaitInclusion) return hash;
  // Best-effort inclusion wait — mirrors the Solana/Tezos confirmation loop.
  // The tx is already broadcast; a timeout does not undo it.
  try {
    await rpc.waitForConfirmation(hash);
  } on EvmInclusionTimeoutException {
    // The wait ran out with the transaction still in the mempool. Nothing was
    // learned, so the tracker — which still holds the row — owns reporting it;
    // marking it reported here would suppress the eventual confirmed/reverted
    // toast for good. Not an error to the caller either: the tx is broadcast,
    // so the hash comes back exactly as it does on inclusion.
    claim?.release();
    return hash;
  } on Object {
    // Nothing was learned about the outcome, so the tracker owns reporting it.
    claim?.release();
    rethrow;
  }
  // The caller is about to show its own success step for this transaction, so
  // the tracker's toast would repeat it. Also retires the row now rather than
  // leaving it in Pending until the next poll.
  await claim?.reported();
  return hash;
}

/// Infra failure while preparing/executing an EVM transfer (no wallet, backend
/// error, RPC failure). Distinct from [EvmTransferBlockedException], which is a
/// deliberate safety-gate rejection.
class EvmTransferException implements Exception {
  const EvmTransferException(this.message);
  final String message;
  @override
  String toString() => 'EVM transfer error: $message';
}

/// The safety gate refused the transfer — the calldata or the simulated state
/// change did not match a clean, single-asset transfer. [message] is
/// user-facing (surfaced verbatim via `toString`).
class EvmTransferBlockedException implements Exception {
  const EvmTransferBlockedException(this.message);
  final String message;
  @override
  String toString() => message;
}
