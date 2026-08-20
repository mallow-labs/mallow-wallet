import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/crypto/tezos_forge.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/tezos_rpc_service.dart';
import '../../../shared/utils/tezos_address.dart';

/// The FA token standard a `KT1…` contract implements, which decides the shape
/// of the `transfer` argument the send flow has to build.
enum TezosFaStandard {
  /// FA1.2 (TZIP-7) — `transfer` takes `pair from (pair to value)`. No token
  /// ids: one contract is one token.
  fa12,

  /// FA2 (TZIP-12) — `transfer` takes a batch,
  /// `list (pair from_ (list (pair to_ (pair token_id amount))))`.
  fa2,
}

/// Fee/gas/storage estimate for a Tezos transfer, surfaced to the confirm step
/// (fees in XTZ, gas + storage, and whether a one-time `reveal` is bundled in).
@immutable
class TezosSendEstimate {
  const TezosSendEstimate({
    required this.feeMutez,
    required this.burnMutez,
    required this.gasLimit,
    required this.storageLimit,
    required this.includesReveal,
  });

  /// Baker fee for the group, in mutez (1 XTZ = 1_000_000 mutez). This is only
  /// part of what leaves the account — see [burnMutez] and [totalCostMutez].
  final BigInt feeMutez;

  /// Storage burn for the group, in mutez: the protocol destroys
  /// [TezosRpcService.costPerByteMutez] per byte of storage the operation
  /// writes. Dominated by the 257-byte allocation charged when the destination
  /// is a fresh, never-funded account (0.06425 XTZ) — which is precisely the
  /// case where quoting [feeMutez] alone understates the cost ~160×.
  final BigInt burnMutez;

  /// Total declared gas limit across the group (reveal + transaction).
  final int gasLimit;

  /// Total declared storage limit across the group, in bytes.
  final int storageLimit;

  /// Whether the group prepends a `reveal` (first-ever outgoing op for this
  /// account) — it adds a small extra fee the user should see.
  final bool includesReveal;

  /// Everything the send costs the sender on top of the amount: baker fee plus
  /// storage burn. This — not [feeMutez] — is what the confirm step quotes.
  BigInt get totalCostMutez => feeMutez + burnMutez;

  /// Baker fee expressed in whole XTZ.
  double get feeXtz => feeMutez.toDouble() / 1e6;

  /// Storage burn expressed in whole XTZ.
  double get burnXtz => burnMutez.toDouble() / 1e6;

  /// Fee + burn expressed in whole XTZ.
  double get totalCostXtz => totalCostMutez.toDouble() / 1e6;
}

/// A fully-built, forged-ready operation group plus the display estimate — the
/// output of [TezosTransferService._buildPlan]. The estimate step discards the
/// forge; the send step forges → signs → injects it.
class _TezosOperationPlan {
  const _TezosOperationPlan({
    required this.branch,
    required this.contents,
    required this.estimate,
  });

  final String branch;
  final List<TezosOperationContent> contents;
  final TezosSendEstimate estimate;
}

/// Client-side Tezos transfer orchestrator: the money-movement glue tying the
/// RPC client, the local Micheline forge + ed25519 signer, and [WalletManager]
/// into a single forge → estimate → sign → inject flow, mirroring the app's
/// client-side Solana path.
///
/// Covers **native XTZ** and **FA1.2 / FA2 token** transfers from HD /
/// imported-key `tz1` wallets. Both go through the same plan → forge → sign →
/// inject path; a token transfer differs only in that the transaction's
/// destination is the token `KT1…`, its XTZ amount is zero, and it carries a
/// `transfer` entrypoint call ([fa12TransferParameters] /
/// [fa2TransferParameters]). The fee is paid in XTZ either way.
@lazySingleton
class TezosTransferService {
  TezosTransferService(this._rpc, this._walletManager);

  final TezosRpcService _rpc;
  final WalletManager _walletManager;

  /// Memoised [faStandardOf] answers. A Tezos contract's code — and so its
  /// entrypoint types — is immutable once originated, so an answer can never go
  /// stale within the process.
  final Map<String, TezosFaStandard> _faStandards = {};

  /// Gas/storage headroom the node accepts during `run_operation` so the
  /// simulation is never itself gas-starved. Must stay below the protocol's
  /// per-*block* gas limit: since recent protocols (Seoul/PsUshuai onward)
  /// set `hard_gas_limit_per_block == hard_gas_limit_per_operation`
  /// (1_040_000), a bundled reveal+transaction simulated at the per-operation
  /// max (2 × 1_040_000) is rejected with `gas_exhausted.block`. Capping each
  /// content at 500_000 keeps a reveal+tx pair (1_000_000) under the block
  /// limit while leaving ~200× headroom over real transfer gas (~2_000).
  static const int _simGasCap = 500000;
  static const int _simStorageCap = 60000;

  /// Extra mutez added to the computed minimal fee so a couple bytes of size
  /// drift (fee zarith growing once the real fee is written back) can never dip
  /// the operation below the baker's minimal-fee floor.
  static const int _feeBufferMutez = 100;

  /// Storage headroom, in bytes, added to the simulated storage burn. Absorbs
  /// protocol rounding the same way [TezosRpcService.gasSafetyMargin] does for
  /// gas, so the real operation never runs out of storage quota.
  static const int _storageSafetyMargin = 10;

  /// Native-XTZ Max headroom (mutez) used only when the Max simulation in
  /// [maxNativeSendable] can't run: ~0.1 XTZ, generous next to a real transfer
  /// fee (~0.0004 XTZ) plus a fresh destination's 0.06425 XTZ allocation burn.
  /// A guess this coarse is the fallback, never the offer — it strands ~0.035
  /// XTZ the sender asked to move.
  static const int _fallbackMaxBufferMutez = 100000;

  /// Mutez held back from a Max *on top of* the simulated cost. The offered
  /// amount is larger than the 1-mutez probe the quote was simulated for, so
  /// its zarith serializes a few bytes longer and the fee this operation is
  /// re-planned with at injection is a few mutez higher (the minimal fee is
  /// 1 mutez/byte). Without the cushion the operation would miss by those
  /// bytes and the node would reject the whole thing as `balance_too_low` —
  /// on precisely the send the user asked to empty the account with.
  static const int _maxSendCushionMutez = 100;

  /// Spendable balance of [address] in mutez, for the Max-amount computation.
  Future<BigInt> nativeBalance(String address) => _rpc.getBalance(address);

  /// The native XTZ that can actually leave [source] for [destination] in one
  /// transfer, in mutez — the Max amount.
  ///
  /// This is the balance less what the operation *really* costs: the baker fee,
  /// any one-time `reveal`, and the storage burn (0.06425 XTZ when [destination]
  /// is a fresh, never-funded account, nothing when it already exists), all read
  /// from a `run_operation` simulation of this exact transfer rather than from a
  /// flat headroom number. So Max empties the account instead of stranding a
  /// tenth of an XTZ in it, and it stays correct for the fresh-destination case
  /// a smaller flat number would have broken.
  ///
  /// The probe simulates 1 mutez: gas, storage and the burn do not depend on the
  /// amount, and simulating the full balance would have to guess the cost it is
  /// trying to measure. Falls back to [_fallbackMaxBufferMutez] when the
  /// simulation can't run at all (unreachable node, a destination the node
  /// rejects) — a conservative Max beats no Max.
  Future<BigInt> maxNativeSendable({
    required String walletId,
    required String source,
    required String destination,
  }) async {
    final balance = await _rpc.getBalance(source);
    if (balance <= BigInt.zero) return BigInt.zero;
    BigInt reserve;
    try {
      final estimate = await estimateNativeTransfer(
        walletId: walletId,
        source: source,
        destination: destination,
        amountMutez: BigInt.one,
      );
      reserve = estimate.totalCostMutez + BigInt.from(_maxSendCushionMutez);
    } catch (e) {
      debugPrint('[Tezos] Max simulation failed, using flat headroom: $e');
      reserve = BigInt.from(_fallbackMaxBufferMutez);
    }
    final spendable = balance - reserve;
    return spendable > BigInt.zero ? spendable : BigInt.zero;
  }

  /// Estimate the fee / gas / storage of a native XTZ transfer for the confirm
  /// step. Throws when the node reports the operation would fail (e.g. the
  /// recipient is invalid or the balance can't cover it).
  Future<TezosSendEstimate> estimateNativeTransfer({
    required String walletId,
    required String source,
    required String destination,
    required BigInt amountMutez,
  }) async {
    final plan = await _buildPlan(
      walletId: walletId,
      source: source,
      destination: destination,
      amountMutez: amountMutez,
    );
    return plan.estimate;
  }

  /// Estimate the XTZ fee / gas / storage of moving [amountRaw] atomic units of
  /// the FA token [token] for the confirm step. [amountRaw] is in the token's
  /// own decimals, not mutez — the operation moves zero XTZ; only the fee and
  /// the storage the contract writes are paid in XTZ.
  ///
  /// Throws when the node reports the call would fail — an insufficient token
  /// balance, a missing operator permission, or a contract that does not
  /// implement the standard its entrypoints advertise all surface here rather
  /// than after the user has signed.
  Future<TezosSendEstimate> estimateTokenTransfer({
    required String walletId,
    required String source,
    required String destination,
    required TezosTokenRef token,
    required BigInt amountRaw,
  }) async {
    final plan = await _buildPlan(
      walletId: walletId,
      source: source,
      destination: token.contract,
      amountMutez: BigInt.zero,
      parameters: await _tokenTransferParameters(
        token: token,
        source: source,
        destination: destination,
        amountRaw: amountRaw,
      ),
    );
    return plan.estimate;
  }

  /// Forge → sign → inject a native XTZ transfer, returning the operation hash
  /// once it is *included in a block*. Throws
  /// [TezosOperationUnconfirmedException] when the inclusion poll times out —
  /// indeterminate, not failed, so callers must not offer a blind retry.
  /// [onBroadcasting] fires once the operation is signed and about to be
  /// injected (drives the signing → broadcasting UI transition, matching the
  /// Solana executor's stage callback).
  Future<String> sendNativeTransfer({
    required String walletId,
    required String source,
    required String destination,
    required BigInt amountMutez,
    void Function()? onBroadcasting,
  }) async {
    // Re-plan against a fresh branch/counter so a stale review estimate can
    // never inject against an expired branch.
    final plan = await _buildPlan(
      walletId: walletId,
      source: source,
      destination: destination,
      amountMutez: amountMutez,
    );
    final forgedHex = forgeOperationGroup(plan.branch, plan.contents);
    final signed = await _walletManager.signTezosOperation(walletId, forgedHex);
    onBroadcasting?.call();
    final opHash = await _rpc.injectOperation(signed.signedOperationHex);
    // Returning normally means *included*, never merely injected — mirrors the
    // Solana confirmation loop. Reporting success on a timeout let
    // the caller refresh balances against a transfer still in the mempool,
    // writing the pre-send number straight back into the cache; there is no
    // Tezos equivalent of [PendingEvmTxTracker] to correct it later.
    //
    // The operation is already injected and a timeout does not undo it, so
    // this is indeterminate rather than failed — hence a distinct exception
    // the surface renders without a retry affordance.
    if (!await _rpc.waitForConfirmation(opHash)) {
      throw TezosOperationUnconfirmedException(opHash);
    }
    return opHash;
  }

  /// Forge → sign → inject an FA1.2 / FA2 token transfer, returning the
  /// operation hash once it is *included in a block*. Same contract as
  /// [sendNativeTransfer], including the [TezosOperationUnconfirmedException]
  /// on an inclusion timeout — callers must not offer a blind retry there.
  Future<String> sendTokenTransfer({
    required String walletId,
    required String source,
    required String destination,
    required TezosTokenRef token,
    required BigInt amountRaw,
    void Function()? onBroadcasting,
  }) async {
    // Re-plan (and re-simulate) against a fresh branch/counter, exactly as the
    // native path does — a review estimate is never what gets injected.
    final plan = await _buildPlan(
      walletId: walletId,
      source: source,
      destination: token.contract,
      amountMutez: BigInt.zero,
      parameters: await _tokenTransferParameters(
        token: token,
        source: source,
        destination: destination,
        amountRaw: amountRaw,
      ),
    );
    final forgedHex = forgeOperationGroup(plan.branch, plan.contents);
    final signed = await _walletManager.signTezosOperation(walletId, forgedHex);
    onBroadcasting?.call();
    final opHash = await _rpc.injectOperation(signed.signedOperationHex);
    if (!await _rpc.waitForConfirmation(opHash)) {
      throw TezosOperationUnconfirmedException(opHash);
    }
    return opHash;
  }

  /// The `transfer` entrypoint call for [token], shaped to whichever standard
  /// its contract actually implements ([faStandardOf]).
  Future<TezosTransactionParameters> _tokenTransferParameters({
    required TezosTokenRef token,
    required String source,
    required String destination,
    required BigInt amountRaw,
  }) async {
    final standard = await faStandardOf(token.contract);
    switch (standard) {
      case TezosFaStandard.fa2:
        return fa2TransferParameters(
          from: source,
          to: destination,
          tokenId: token.tokenId,
          amount: amountRaw,
        );
      case TezosFaStandard.fa12:
        // FA1.2 has no token ids, so a non-zero one means the holding and the
        // contract disagree about what this token is. Refuse rather than drop
        // the id and move a *different* token than the one on screen.
        if (token.tokenId != BigInt.zero) {
          throw TezosUnsupportedTokenException(
            token.contract,
            'this contract is FA1.2, which has no token ids, but the holding '
            'carries token id ${token.tokenId}',
          );
        }
        return fa12TransferParameters(
          from: source,
          to: destination,
          amount: amountRaw,
        );
    }
  }

  /// Which FA standard the token contract [contract] implements, read from its
  /// on-chain entrypoint types and memoised.
  ///
  /// The balances wire (`/v2/tezos/balances`, an `EvmHolding` shape) carries no
  /// standard field, and an FA2 token with id 0 is encoded identically to an
  /// FA1.2 one — so the contract itself is the only thing that can answer this.
  /// Throws [TezosUnsupportedTokenException] when it exposes no `transfer`
  /// entrypoint of either shape.
  Future<TezosFaStandard> faStandardOf(String contract) async {
    final cached = _faStandards[contract];
    if (cached != null) return cached;
    final entrypoints = await _rpc.getContractEntrypoints(contract);
    final standard = faStandardFromEntrypoints(entrypoints);
    if (standard == null) {
      throw TezosUnsupportedTokenException(
        contract,
        'it exposes no FA1.2 or FA2 `transfer` entrypoint',
      );
    }
    _faStandards[contract] = standard;
    return standard;
  }

  /// The FA standard implied by a contract's [entrypoints] map
  /// ([TezosRpcService.getContractEntrypoints]), or null when its `transfer` is
  /// missing or neither shape.
  ///
  /// The two standards are told apart by the outermost primitive of the
  /// `transfer` parameter type: FA2 batches, so it is a `list`; FA1.2 moves one
  /// amount, so it is a `pair`. Static + pure so it can be tested against
  /// captured node payloads without a node.
  static TezosFaStandard? faStandardFromEntrypoints(
    Map<String, dynamic> entrypoints,
  ) {
    final transfer = entrypoints['transfer'];
    if (transfer is! Map) return null;
    return switch (transfer['prim']) {
      'list' => TezosFaStandard.fa2,
      'pair' => TezosFaStandard.fa12,
      _ => null,
    };
  }

  /// Build the reveal(?) + transaction group: fetch chain state, simulate for
  /// per-content gas/storage, then set real limits + minimal fee.
  ///
  /// [parameters] is null for a native XTZ transfer and set for an FA token
  /// transfer, where [destination] is the token `KT1…` and [amountMutez] zero.
  Future<_TezosOperationPlan> _buildPlan({
    required String walletId,
    required String source,
    required String destination,
    required BigInt amountMutez,
    TezosTransactionParameters? parameters,
  }) async {
    // These four reads are independent, so fetch them concurrently rather than
    // paying four serial node round-trips (each with its own timeout).
    // [Future.wait] (not record `.wait`) so a failing read surfaces that call's
    // concrete [TezosRpcException] — endpoint + HTTP status — instead of the
    // opaque `ParallelWaitError` that read as "Parallel request error".
    final reads = await Future.wait<Object>([
      _rpc.getBranchHash(),
      _rpc.getChainId(),
      _rpc.nextCounter(source),
      _rpc.isRevealed(source),
    ]);
    final branch = reads[0] as String;
    final chainId = reads[1] as String;
    final counter = reads[2] as int;
    final revealed = reads[3] as bool;

    // Contents at simulation caps + zero fee: the node reports the gas/storage
    // each content actually consumes without a fee or limit starving it.
    var nextCounter = counter;
    final simContents = <TezosOperationContent>[];
    if (!revealed) {
      final edpk = await _walletManager.getTezosPublicKey(walletId);
      simContents.add(
        TezosReveal(
          source: source,
          publicKey: edpk,
          fee: BigInt.zero,
          counter: BigInt.from(nextCounter),
          gasLimit: BigInt.from(_simGasCap),
          storageLimit: BigInt.zero,
        ),
      );
      nextCounter += 1;
    }
    simContents.add(
      TezosTransaction(
        source: source,
        destination: destination,
        amount: amountMutez,
        fee: BigInt.zero,
        counter: BigInt.from(nextCounter),
        gasLimit: BigInt.from(_simGasCap),
        storageLimit: BigInt.from(_simStorageCap),
        parameters: parameters,
      ),
    );

    final response = await _rpc.runOperation(
      branch: branch,
      contents: [for (final c in simContents) c.toJson()],
      chainId: chainId,
    );
    _throwIfFailed(response);
    final perContent = TezosRpcService.perContentEstimates(response);
    if (perContent.length != simContents.length) {
      throw StateError(
        'Tezos simulation returned ${perContent.length} results for '
        '${simContents.length} operations',
      );
    }

    // Rebuild each content with its own consumed gas/storage + safety margins.
    final hasReveal = !revealed;
    final revealIndex = hasReveal ? 0 : -1;
    final txIndex = simContents.length - 1;

    final revealGas = hasReveal
        ? perContent[revealIndex].gas + TezosRpcService.gasSafetyMargin
        : 0;
    final revealStorage = hasReveal ? perContent[revealIndex].storage : 0;
    final txGas = perContent[txIndex].gas + TezosRpcService.gasSafetyMargin;
    final txStorage = perContent[txIndex].storage == 0
        ? 0
        : perContent[txIndex].storage + _storageSafetyMargin;

    final totalGas = revealGas + txGas;
    final totalStorage = revealStorage + txStorage;

    // The burn is charged on storage actually written, not on the declared
    // limit — so price the *simulated* bytes and leave [_storageSafetyMargin]
    // (a cap-only cushion) out of the quote rather than overstating it.
    final burnMutez = TezosRpcService.storageBurnMutez(
      revealStorage + perContent[txIndex].storage,
    );

    List<TezosOperationContent> build(BigInt txFee) {
      var c = counter;
      final out = <TezosOperationContent>[];
      if (hasReveal) {
        out.add(
          TezosReveal(
            source: source,
            publicKey: (simContents[revealIndex] as TezosReveal).publicKey,
            fee: BigInt.zero,
            counter: BigInt.from(c),
            gasLimit: BigInt.from(revealGas),
            storageLimit: BigInt.from(revealStorage),
          ),
        );
        c += 1;
      }
      out.add(
        TezosTransaction(
          source: source,
          destination: destination,
          amount: amountMutez,
          // The whole group's fee rides on the transaction content; the baker
          // charges the aggregate fee against the aggregate minimal, so a zero
          // reveal fee is fine as long as the total clears the floor.
          fee: txFee,
          counter: BigInt.from(c),
          gasLimit: BigInt.from(txGas),
          storageLimit: BigInt.from(txStorage),
          parameters: parameters,
        ),
      );
      return out;
    }

    // Size the operation with a zero fee first, then compute the minimal fee
    // over that size (+64-byte signature) and write it back.
    final sizingHex = forgeOperationGroup(branch, build(BigInt.zero));
    final opSizeBytes = sizingHex.length ~/ 2 + 64;
    final feeMutez =
        TezosRpcService.minimalFeeMutez(
          gasLimit: totalGas,
          operationSizeBytes: opSizeBytes,
        ) +
        _feeBufferMutez;

    return _TezosOperationPlan(
      branch: branch,
      contents: build(BigInt.from(feeMutez)),
      estimate: TezosSendEstimate(
        feeMutez: BigInt.from(feeMutez),
        burnMutez: BigInt.from(burnMutez),
        gasLimit: totalGas,
        storageLimit: totalStorage,
        includesReveal: hasReveal,
      ),
    );
  }

  /// Throw a [TezosSimulationException] when any content (or internal result)
  /// of a `run_operation` response did not apply, surfacing the node errors.
  void _throwIfFailed(Map<String, dynamic> response) {
    final estimate = TezosRpcService.parseEstimate(response);
    if (!estimate.success) {
      throw TezosSimulationException(estimate.errors);
    }
  }
}

/// Thrown when a `KT1…` the balance feed listed as a fungible holding cannot be
/// transferred by this build — it implements neither FA1.2 nor FA2's `transfer`,
/// or it contradicts the token id the holding carries.
///
/// Raised **before** anything is signed. [toString] is the user-facing copy
/// (`AppFailure.from` falls through to it), so it names the contract: the token
/// is still in the wallet and an explorer lookup is the only way to find out
/// what it actually is.
class TezosUnsupportedTokenException implements Exception {
  const TezosUnsupportedTokenException(this.contract, this.reason);

  final String contract;
  final String reason;

  @override
  String toString() =>
      "This token can't be sent from mallow: $reason "
      '($contract).';
}

/// Thrown when a Tezos `run_operation` simulation reports the transfer would
/// fail. Carries the node's raw error objects for diagnostics.
class TezosSimulationException implements Exception {
  const TezosSimulationException(this.errors);

  final List<dynamic> errors;

  @override
  String toString() {
    // Surface the most specific protocol error id when present (e.g.
    // `...contract.balance_too_low`), else a generic message.
    for (final e in errors) {
      if (e is Map && e['id'] is String) {
        final id = e['id'] as String;
        final short = id.split('.').last.replaceAll('_', ' ');
        return 'Transaction would fail: $short';
      }
    }
    return 'Transaction simulation failed';
  }
}
