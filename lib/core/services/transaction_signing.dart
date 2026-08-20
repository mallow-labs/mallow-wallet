import 'dart:async';
import 'dart:convert';

import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../config/remote_config.dart';
import '../crypto/wallet_manager.dart';
import '../network/solana_rpc_service.dart';
import '../security/transaction_auth_gate.dart';
import 'ledger_service.dart';

/// Sign [unsignedTxBase64] with the active wallet, broadcast it, and wait for
/// confirmation. Returns the signature on success; throws on signing,
/// broadcast, or confirmation failure.
///
/// ### Confirmation is not optional
///
/// The returned signature means the transaction **executed successfully** at
/// `confirmed` commitment. The confirmation wait re-broadcasts until the
/// blockhash expires and throws
/// [SolanaTransactionFailedException] / [SolanaTransactionUnconfirmedException]
/// otherwise — see [SolanaRpcService.awaitConfirmationOrThrow]. Callers must
/// therefore treat a successful return as the *only* success signal; the
/// unconfirmed exception is indeterminate and its message (which is
/// user-facing) must reach the user verbatim rather than be replaced with a
/// "failed, try again" of the caller's own.
///
/// Used by every flow that signs a server-built compiled transaction
/// (mint, fixed-price listing, auction listing, market actions, swap,
/// raffle). Flows that need to surface distinct UI between the sign and
/// broadcast phases — e.g. an "Approve in your wallet" → "Confirming on
/// Solana" transition — pass [onSigned], which fires synchronously
/// between `signCompiledTx` and `sendTransaction`.
///
/// When [ledgerService] and [onLedgerSigning] are provided, the callback
/// fires for every emission of [LedgerService.signingState] while the
/// signing call is in flight. Hosts use this to flip their pipeline
/// label to "Approve on your Ledger device" / etc. without having to
/// branch on wallet type. The subscription is scoped to this call and
/// always cancels.
///
/// ### Blockhash freshness
///
/// Solana blockhashes expire after ~150 slots (~60s). Flows where the
/// user sits on a confirmation sheet for tens of seconds between fetch
/// and sign routinely tripped "Blockhash not found" on the broadcast.
/// To avoid that, this helper inspects the decoded tx and branches:
///
///  * **No pre-attached signatures** (`signatures[]` is all zero
///    placeholders): the tx is unsigned by anyone. We fetch a fresh
///    blockhash from [rpcService] and rewrite `recentBlockhash` on the
///    compiled message before signing. The wallet then signs over the
///    updated bytes, so the new blockhash is covered. ALTs and
///    instructions are preserved verbatim.
///  * **Has pre-attached signatures** (any byte in any signature is
///    non-zero): the server (or another party) has already signed over
///    the original message bytes. Replacing the blockhash would
///    invalidate that signature, so we sign as-is. The *caller* is
///    responsible for re-fetching the tx from the backend if the
///    user-confirm gap is long enough to risk staleness — see
///    `market_bloc._onConfirmAndSign` and `raffle_bloc._onConfirmAndSign`
///    for the staleness check / rebuild wiring.
Future<String> signSendConfirm(
  String unsignedTxBase64, {
  required WalletManager walletManager,
  required SolanaRpcService rpcService,
  required TransactionAuthGate authGate,
  required double? usdValue,
  required FlowKey flow,
  List<Ed25519HDKeyPair> additionalSigners = const [],
  void Function()? onSigned,
  LedgerService? ledgerService,
  void Function(LedgerSigningState)? onLedgerSigning,
}) async {
  // Step-up auth gate + remote kill-switch backstop. Runs before
  // any signing work so a cancelled prompt leaves the wallet completely
  // untouched. `usdValue` is the net USD outflow for this tx — pass `null` to
  // force a prompt when the value can't be computed (fail-closed). `flow` is
  // the `(chain, flow)` cell the kill switch is keyed on.
  final outcome = await authGate.authorize(usdValue: usdValue, flow: flow);
  final disabledMessage = outcome.disabledMessage;
  if (disabledMessage != null) {
    // A killed cell is NOT a user cancel — throwing the cancel type here made
    // silent-cancel surfaces swallow the operator's message.
    throw TransactionFlowDisabledException(disabledMessage);
  }
  if (outcome != TransactionAuthOutcome.allowed) {
    throw TransactionAuthCancelledException(outcome);
  }

  StreamSubscription<LedgerSigningState>? ledgerSub;
  if (ledgerService != null && onLedgerSigning != null) {
    ledgerSub = ledgerService.signingState.listen(onLedgerSigning);
  }
  try {
    final unsigned = await _refreshBlockhashIfSafe(
      SignedTx.fromBytes(base64Decode(unsignedTxBase64)),
      rpcService,
    );
    final signed = await walletManager.signCompiledTx(
      unsignedTx: unsigned,
      additionalSigners: additionalSigners,
    );
    onSigned?.call();
    final signature = await rpcService.sendTransaction(signed);
    // Throws unless the tx confirmed. The previous poller returned a `bool`
    // that was discarded here, so every flow reported success at the 30 s
    // timeout while the tx was still in the mempool.
    await rpcService.awaitConfirmationOrThrow(signature, rebroadcast: signed);
    return signature;
  } finally {
    await ledgerSub?.cancel();
  }
}

/// `true` when any signature slot already carries non-zero bytes — i.e.
/// someone (typically the backend) has pre-signed this tx. Unsigned
/// placeholders are 64 zero bytes per slot.
bool hasPreAttachedSignature(SignedTx tx) =>
    tx.signatures.any((s) => s.bytes.any((b) => b != 0));

/// Returns a copy of [tx] with [tx.compiledMessage.recentBlockhash] set
/// to a freshly fetched value when it's safe to do so (no pre-attached
/// signatures). Otherwise returns [tx] unchanged so the existing
/// server-side signature stays valid over the original bytes.
Future<SignedTx> _refreshBlockhashIfSafe(
  SignedTx tx,
  SolanaRpcService rpcService,
) async {
  if (hasPreAttachedSignature(tx)) return tx;
  final fresh = await rpcService.getLatestBlockhash();
  return SignedTx(
    signatures: tx.signatures,
    compiledMessage: tx.compiledMessage.copyWith(recentBlockhash: fresh),
  );
}
