import 'dart:async';
import 'dart:convert';

import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../../shared/utils/chain.dart';
import '../analytics/analytics_events.dart';
import '../analytics/transaction_ledger.dart';
import '../config/remote_config.dart';
import '../crypto/solana_v1_transaction.dart';
import '../crypto/wallet_manager.dart';
import '../network/solana_rpc_service.dart';
import '../observability/app_logger.dart';
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
///    If signing takes longer than [slowSigningThreshold], a Keystone
///    signature is checked against on-chain blockhash validity before send.
///    An expired signature is discarded with [SignedTooLateException]; an
///    RPC failure leaves broadcast and confirmation to determine the outcome.
///  * **Has pre-attached signatures** (any byte in any signature is
///    non-zero): the server (or another party) has already signed over
///    the original message bytes. Replacing the blockhash would
///    invalidate that signature, so we sign as-is. The *caller* is
///    responsible for re-fetching the tx from the backend if the
///    user-confirm gap is long enough to risk staleness — see
///    `market_bloc._onConfirmAndSign` and `raffle_bloc._onConfirmAndSign`
///    for the staleness check / rebuild wiring.
///    Without [discardSignatureIf], slow Keystone signing checks the original
///    blockhash's validity and discards an expired signature unsent. Some
///    builders have side effects, so callers must surface the expiry rather
///    than automatically rebuild or sign those same bytes again.
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
  bool Function()? discardSignatureIf,
  Duration slowSigningThreshold = const Duration(seconds: 10),
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
    final wire = base64Decode(unsignedTxBase64);
    if (SolanaV1Transaction.isV1Wire(wire)) {
      return await _signSendConfirmV1(
        SolanaV1Transaction.fromBytes(wire),
        walletManager: walletManager,
        rpcService: rpcService,
        flow: flow,
        additionalSigners: additionalSigners,
        onSigned: onSigned,
      );
    }
    final unsigned = await _refreshBlockhashIfSafe(
      SignedTx.fromBytes(wire),
      rpcService,
    );
    final clientRefreshed = !hasPreAttachedSignature(unsigned);
    final signingWatch = Stopwatch()..start();
    final signed = await walletManager.signCompiledTx(
      unsignedTx: unsigned,
      additionalSigners: additionalSigners,
    );
    signingWatch.stop();
    // A slow signer — a Keystone's QR round trip — can outlast a tx that only
    // its builder can freshen. Throwing here, before anything is sent, lets
    // the caller rebuild and ask for a new signature before risking broadcast
    // with an expired blockhash.
    //
    // Keystone alone uses this conservative window and explains the retry
    // in its next prompt. Other signers keep broadcasting: crossing the
    // tracker's window does not mean the blockhash has expired on-chain.
    if ((discardSignatureIf?.call() ?? false) &&
        await walletManager.activeSignerIsKeystone()) {
      throw SignedTooLateException();
    }
    // Refreshing before signing resets the clock, but a QR round trip can
    // still use up the new blockhash's lifetime. Only slow Keystone signing
    // needs this extra RPC; fast signing keeps the usual send/confirm path.
    // Untracked co-signatures keep their original blockhash, but still need
    // this check: a builder with side effects cannot safely be replayed and
    // the executor must surface expiry rather than retry the same bytes.
    if (signingWatch.elapsed > slowSigningThreshold &&
        (clientRefreshed || discardSignatureIf == null) &&
        await walletManager.activeSignerIsKeystone()) {
      var blockhashStillValid = true;
      try {
        blockhashStillValid = await rpcService.isBlockhashStillValid(
          signed.compiledMessage.recentBlockhash,
        );
      } catch (_) {
        // A failed probe is not proof of expiry. Confirmation still decides
        // the outcome after broadcast, so a network blip must not discard it.
        AppLogger.debug(
          'TransactionSigning',
          'Post-sign blockhash validity check failed; proceeding to broadcast',
        );
      }
      if (!blockhashStillValid) throw SignedTooLateException();
    }
    onSigned?.call();
    final signature = await rpcService.sendTransaction(signed);
    return await _confirmAndRecord(
      signature,
      awaitConfirmation: () =>
          rpcService.awaitConfirmationOrThrow(signature, rebroadcast: signed),
      walletManager: walletManager,
      flow: flow,
    );
  } finally {
    await ledgerSub?.cancel();
  }
}

/// The v1 arm of [signSendConfirm], after its auth gate.
///
/// The same steps as the v0 path, on wire bytes: refresh the blockhash when
/// nobody has signed yet, sign, send, confirm. Only a key the app holds signs
/// v1 ([WalletManager.activeSignerCanSignV1]), so the Keystone staleness
/// checks never apply and Ledger has no device prompt to report.
Future<String> _signSendConfirmV1(
  SolanaV1Transaction unsigned, {
  required WalletManager walletManager,
  required SolanaRpcService rpcService,
  required FlowKey flow,
  required List<Ed25519HDKeyPair> additionalSigners,
  required void Function()? onSigned,
}) async {
  final fresh = unsigned.hasPreAttachedSignature
      ? unsigned
      : unsigned.withRecentBlockhash(await rpcService.getLatestBlockhash());
  final signed = await walletManager.signV1Tx(
    unsignedTx: fresh,
    additionalSigners: additionalSigners,
  );
  onSigned?.call();
  final signature = await rpcService.sendWireTransaction(signed);
  return _confirmAndRecord(
    signature,
    awaitConfirmation: () =>
        rpcService.awaitWireConfirmationOrThrow(signature, rebroadcast: signed),
    walletManager: walletManager,
    flow: flow,
  );
}

/// Wait for [signature] to confirm and record it in the transaction ledger.
///
/// Every flow on the executor reaches the ledger through here. The signer is
/// the active wallet — the pipeline sheet holds the screen until this
/// returns, so it cannot change between signing and the read.
Future<String> _confirmAndRecord(
  String signature, {
  required Future<void> Function() awaitConfirmation,
  required WalletManager walletManager,
  required FlowKey flow,
}) async {
  void record(TxConfirmation confirmation) => recordSubmittedTransaction(
    chain: Chain.solana,
    flow: flow.flow,
    signature: signature,
    walletAddress: walletManager.getAddress,
    confirmation: confirmation,
  );
  // Throws unless the tx confirmed. The previous poller returned a `bool`
  // that was discarded here, so every flow reported success at the 30 s
  // timeout while the tx was still in the mempool.
  try {
    await awaitConfirmation();
  } on SolanaTransactionFailedException {
    // Executed and failed: not recorded as usage.
    rethrow;
  } catch (_) {
    // Unconfirmed, or the wait itself broke: sent, and possibly landing.
    record(TxConfirmation.pending);
    rethrow;
  }
  record(TxConfirmation.confirmed);
  return signature;
}

/// A Keystone signature came back after the tx it signed had gone stale and
/// was thrown away before broadcast. Nothing was sent; the caller refreshes
/// or rebuilds and signs again. See [signSendConfirm].
class SignedTooLateException implements Exception {
  SignedTooLateException([
    this.message = 'That took too long, so the transaction expired. Try again.',
  ]);

  final String message;

  @override
  String toString() => message;
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

/// Solana's Address Lookup Table program.
const String addressLookupTableProgramId =
    'AddressLookupTab1e1111111111111111111111111';

/// bincode variant index (u32, little-endian) of the ALT program's
/// `CreateLookupTable` instruction. `ExtendLookupTable` is variant 2 and
/// carries no time-bound state, so the discriminator — not merely the program
/// id — is what this matches on.
const List<int> _createLookupTableDiscriminator = <int>[0, 0, 0, 0];

/// `true` when [tx] carries a `CreateLookupTable` instruction.
///
/// ### Why this is not the same question as "is it co-signed?"
///
/// [_refreshBlockhashIfSafe] can rewrite the blockhash of any tx nobody has
/// pre-signed, which is why non-co-signed flows with a fast signer normally
/// need no staleness rebuild: the blockhash is the only clock on them, and
/// the refresh resets it. A slow Keystone signer can outlast even that fresh
/// blockhash, so [signSendConfirm] checks its validity before broadcast and
/// asks for another signature if it expired.
///
/// `create_lookup_table` breaks that assumption. It bakes a `recent_slot` into
/// its instruction data, and the runtime validates that slot against
/// `SlotHashes` — the last 512 slots, roughly 3.4 minutes. A blockhash refresh
/// leaves those bytes untouched, so a confirmation sheet left open past the
/// slot window sends a transaction that looks perfectly fresh and fails
/// on-chain for a reason nothing on screen explains. Since a LUT `setupTx`
/// leads the batch, that failure lands on the *first* transaction of a cNFT
/// buy / list / cancel / settle.
///
/// The principle: a blockhash refresh is not a substitute for a rebuild when
/// the transaction carries other time-bound state. Such a tx must go back to
/// the builder, exactly like a co-signed one — see `TransactionExecutor.execute`.
///
/// Program ids are always static account keys (they can never be loaded from
/// an address lookup table), so reading them off `accountKeys` is complete for
/// both legacy and v0 messages.
bool createsLookupTable(SignedTx tx) {
  final message = tx.compiledMessage;
  final keys = message.accountKeys;
  for (final ix in message.instructions) {
    if (ix.programIdIndex < 0 || ix.programIdIndex >= keys.length) continue;
    if (keys[ix.programIdIndex].toBase58() != addressLookupTableProgramId) {
      continue;
    }
    final data = ix.data;
    if (data.length < _createLookupTableDiscriminator.length) continue;
    final head = data.take(_createLookupTableDiscriminator.length).toList();
    var matches = true;
    for (var i = 0; i < head.length; i++) {
      if (head[i] != _createLookupTableDiscriminator[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
