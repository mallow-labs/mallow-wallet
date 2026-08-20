import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
// web3dart 3.x re-homed EthereumAddress in package:wallet; it imports the type
// but does not re-export it.
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:web3dart/web3dart.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/network/evm_transfer_core.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../core/utils/address_format.dart';
import '../../portfolio/models/token_balance.dart';
import '../models/eth_gas.dart';

export '../../../core/network/evm_transfer_core.dart'
    show EvmTransferException, EvmTransferBlockedException;

/// Fee estimate for an Ethereum transfer, surfaced to the confirm step. Fees
/// are EIP-1559: the tx signs a [maxFeePerGas] cap and a [maxPriorityFeePerGas]
/// tip, but only the *effective* price (base fee + tip, capped at the max) is
/// actually charged on the used gas — so [feeWei] shows the expected fee, while
/// [maxFeeWei] is the worst case reserved from a Max send.
@immutable
class EthereumSendEstimate {
  const EthereumSendEstimate({
    required this.gasLimit,
    required this.estimatedGasUsed,
    required this.maxFeePerGas,
    required this.maxPriorityFeePerGas,
    required this.effectiveGasPrice,
  });

  /// Gas cap written into the tx (estimate + headroom). Unused gas is refunded,
  /// so a padded cap never overcharges — it only guards against a slightly
  /// heavier-than-estimated execution.
  final int gasLimit;

  /// Node's raw `eth_estimateGas` result, used for the *expected* fee display.
  final BigInt estimatedGasUsed;

  /// Per-gas fee cap the tx signs (base-fee headroom).
  final BigInt maxFeePerGas;

  /// Miner tip per gas.
  final BigInt maxPriorityFeePerGas;

  /// Price actually expected to be charged per gas (base fee + tip, capped at
  /// [maxFeePerGas]).
  final BigInt effectiveGasPrice;

  /// Expected total fee, in wei: estimated gas × effective price.
  BigInt get feeWei => estimatedGasUsed * effectiveGasPrice;

  /// Worst-case total fee, in wei: the padded gas cap × the fee cap. Reserved
  /// from a native-ETH Max send so a base-fee bump can't strand the tx.
  BigInt get maxFeeWei => BigInt.from(gasLimit) * maxFeePerGas;

  /// Expected fee in whole ETH.
  double get feeEth => feeWei.toDouble() / 1e18;

  /// Miner tip in gwei, for the confirm-step detail line.
  double get priorityFeeGwei => maxPriorityFeePerGas.toDouble() / 1e9;
}

/// Fully-resolved call parameters for a transfer: where the tx points, how much
/// native value it carries, and any calldata. Native ETH sets [value] and no
/// [data]; an ERC-20 points [to] at the token contract with [value] zero and
/// the `transfer(address,uint256)` calldata in [data].
class _EthTxParams {
  const _EthTxParams({required this.to, required this.value, this.data});

  final EthereumAddress to;
  final BigInt value;
  final Uint8List? data;
}

/// Ethereum transfer orchestrator: the money-movement glue tying the backend
/// tx-builder ([MallowApiV2Client.getTransferTx]), the RPC client
/// ([EthereumRpcService]), local secp256k1 EIP-1559 signing
/// ([WalletManager.signEthereumTransaction]), and the send flow into a single
/// prepare → sign → broadcast → confirm path.
///
/// The **calldata is built server-side** (`/v2/tx/assets/transfer`, native/erc20
/// branch) and validated on-device by a two-part safety gate before signing —
/// mirroring the EVM artwork-transfer flow:
///
///  1. **Calldata assertion** — re-encode the intended transfer locally
///     ([_buildParams]) and byte-compare it to the backend calldata, asserting
///     `to`, `value`, and `data` all match. Catches a compromised/buggy builder
///     returning an approval, a swapped recipient/amount, or a value-bearing tx.
///  2. **State-change simulation** — `eth_simulateV1` (via the
///     mallow proxy) must show exactly the intended amount leaving the wallet,
///     no approvals, no other outflow, and no revert.
///
/// Both must pass before the user can sign. Ethereum mainnet only.
///
/// Scope: **native ETH** and **ERC-20** transfers from HD / imported-key /
/// Ledger Ethereum wallets. Social Ethereum wallets are out of scope —
/// [WalletManager.signEthereumTransaction] throws for them.
@lazySingleton
class EthereumTransferService {
  EthereumTransferService(this._apiV2, this._rpc, this._walletManager);

  final MallowApiV2Client _apiV2;
  final EthereumRpcService _rpc;
  final WalletManager _walletManager;

  /// Gas headroom multiplier over the node estimate (20%). ERC-20 execution can
  /// consume slightly more than the simulated amount if the recipient's storage
  /// state changes between estimate and inclusion; the extra is refunded when
  /// unused.
  static const int _gasHeadroomNum = 12;
  static const int _gasHeadroomDen = 10;

  /// Minimal ERC-20 `transfer(address,uint256)` ABI — used only to re-encode
  /// the expected calldata for the byte-assertion against the backend builder.
  static const String _erc20TransferAbi =
      '[{"constant":false,"inputs":[{"name":"_to","type":"address"},'
      '{"name":"_value","type":"uint256"}],"name":"transfer",'
      '"outputs":[{"name":"","type":"bool"}],"type":"function"}]';

  /// Native ETH balance of [address], in wei — for the Max-amount computation.
  Future<BigInt> nativeBalance(String address) => _rpc.getBalance(address);

  /// Exact ERC-20 balance of [source] for the token [contract], in the token's
  /// smallest units — for the Max-amount computation. Read full-precision from
  /// chain because the cached [TokenBalance] clamps 18-decimal raw balances to
  /// int64, so its double `uiBalance` would round Max past what's actually held.
  Future<BigInt> tokenBalance(String source, String contract) =>
      _rpc.erc20BalanceOf(owner: source, contract: contract);

  /// Standard native-ETH transfer gas (to an EOA), before headroom. Used to
  /// derive [nativeSendGasLimit] without a per-recipient estimate.
  static final BigInt _nativeTransferGas = BigInt.from(21000);

  /// The gas limit a native-ETH send is broadcast with: the standard 21 000
  /// transfer gas plus the same 20% headroom [prepare] pads into the estimate
  /// (→ 25 200). Exposed so the Max-send reserve ([maxNativeSendable]) and the
  /// execute-time signed gas limit are derived from one constant and agree.
  static final int nativeSendGasLimit =
      (_nativeTransferGas *
              BigInt.from(_gasHeadroomNum) ~/
              BigInt.from(_gasHeadroomDen))
          .toInt();

  /// Spendable native ETH for a Max send, in wei, reserving gas at the node's
  /// `getFeeData` fee cap over [nativeSendGasLimit]. This is the **fallback**
  /// reserve, used when the Edit-Gas fee market is unavailable — the same case
  /// where `execute` signs a null fee override and refreshes `getFeeData` at
  /// broadcast, so the reserve and the signed cap agree. Returns zero when the
  /// reserve would exceed the balance.
  ///
  /// When the fee market *is* available, [SendBloc] instead reserves against the
  /// exact fee selection `execute` will sign (persisted tier/custom caps over
  /// [nativeSendGasLimit]) via [nativeBalance] — so a persisted custom cap or a
  /// tier cap that differs from `getFeeData` can no longer leave the Max amount
  /// priced above the balance ("insufficient funds for gas * price + value")
  /// after the user passed review + biometric auth.
  Future<BigInt> maxNativeSendable(String source) async {
    final results = await Future.wait<Object>([
      _rpc.getBalance(source),
      _rpc.getFeeData(),
    ]);
    final balance = results[0] as BigInt;
    final fee = results[1] as EthFeeData;
    final spendable =
        balance - BigInt.from(nativeSendGasLimit) * fee.maxFeePerGas;
    return spendable > BigInt.zero ? spendable : BigInt.zero;
  }

  /// Fetch the live EIP-1559 fee market for the Edit Gas Fee sheet — one Infura
  /// `suggestedGasFees` call (via the mallow proxy) yielding the Low/Market
  /// tiers with real wait estimates, next-block base fee, priority-fee range,
  /// congestion, and historical ranges. Independent of the specific transfer
  /// (these are per-gas prices; the per-tier ETH/USD cost is gas-limit × price,
  /// computed by the caller).
  Future<EthGasMarket> gasMarket() => EthGasMarket.fetch(_rpc);

  /// Build (backend), validate (calldata assertion + state-change simulation),
  /// and estimate fees for a transfer. [amountRaw] is in the token's smallest
  /// unit — wei for native ETH ([token] null/native), or the ERC-20's base
  /// units ([token] set). Returns a ready-to-sign transfer.
  ///
  /// Throws [EthTransferBlockedException] when the safety gate fails (calldata
  /// mismatch, an approval, an unexpected asset movement, or a simulated
  /// revert), and [EthTransferException] on infra failures (no wallet, backend
  /// error). A transport failure fails **closed** (throws → blocks signing).
  Future<PreparedEthTransfer> prepare({
    required String walletId,
    required String source,
    required String destination,
    required BigInt amountRaw,
    TokenBalance? token,
  }) async {
    final isNative = token == null || token.isNative;

    // 1. Backend builds the calldata.
    final response = await _apiV2.getTransferTx(
      TransferTxRequest(
        authority: source,
        asset: isNative ? 'native' : token.mint,
        recipient: destination,
        tokenStandard:
            (isNative ? TokenStandard.native : TokenStandard.erc20).apiValue,
        amount: amountRaw.toString(),
      ),
    );
    final evm = response.result.evm;
    if (evm == null) {
      throw const EthTransferException(
        'Backend did not return an EVM transfer',
      );
    }
    final to = evm.to;
    final data = evmHexToBytes(evm.data);
    final valueWei = evmHexToBigInt(evm.value);

    // 2. Client-side calldata assertion (hard gate).
    _assertCalldata(
      destination: destination,
      amountRaw: amountRaw,
      token: token,
      to: to,
      valueWei: valueWei,
      data: data,
    );

    // 3-4. Fire the state-change simulation and the fee/gas estimate in one
    // round-trip window — they are independent (the estimate reads only the
    // backend-built params, not the sim result), matching the artwork flow.
    // estimateGas independently reverts if the transfer would; the simulation is
    // a hard gate that fails closed on a transport failure. Future.wait rethrows
    // the first original error unwrapped, so a revert/transport failure in either
    // still surfaces as its real exception.
    final params = _EthTxParams(
      to: EthereumAddress.fromHex(to),
      value: valueWei,
      data: data.isEmpty ? null : data,
    );
    final simFuture = _rpc.simulateAssetChanges(
      from: source,
      to: to,
      data: evm.data,
      value: evm.value,
    );
    final estimateFuture = _estimate(source: source, params: params);
    await Future.wait<Object>([simFuture, estimateFuture]);
    // Assert the simulation result after the wait (hard gate).
    _assertSimulation(
      await simFuture,
      source: source,
      token: token,
      amountRaw: amountRaw,
    );
    final estimate = await estimateFuture;

    return PreparedEthTransfer(
      walletId: walletId,
      source: source,
      to: params.to,
      value: valueWei,
      data: params.data,
      estimate: estimate,
      trackAs: PendingTxMetadata(
        title: 'Send',
        subtitle: 'to ${truncateAddress(destination, lead: 6, trail: 4)}',
        tokenSymbol: isNative ? 'ETH' : token.symbol,
        // Negative: a send is an outflow, matching the activity rows' sign
        // convention. Display only — the replacement is rebuilt from the
        // signed `to`/`value`/`data`, never from this.
        amountRaw: '-$amountRaw',
        decimals: isNative ? 18 : token.decimals,
      ),
    );
  }

  /// Sign a validated [prepared] transfer on-device and broadcast it, returning
  /// the transaction hash. [onBroadcasting] fires once the tx is signed and
  /// about to be broadcast (drives the signing → broadcasting UI transition);
  /// [onBroadcastRegistered] fires once the node accepted it and the pending-tx
  /// tracker owns the nonce — the point from which the caller may let the user
  /// leave the flow — and carries the [PendingTxResolutionClaim] to hand back if
  /// they do (see [signAndBroadcastEvmTransfer]).
  ///
  /// [feeOverride] carries the fee the user picked/customized on the Edit Gas
  /// Fee sheet — its `maxFeePerGas`/`maxPriorityFeePerGas` are signed verbatim,
  /// and its `gasLimit` is signed unless it falls below the prepared estimate, in
  /// which case the estimate floors it (see [effectiveSignedGasLimit]). When
  /// null, the EIP-1559 fee caps are re-fetched fresh at broadcast (a stale
  /// review estimate could otherwise sign an under-priced fee) — see
  /// [signAndBroadcastEvmTransfer].
  Future<String> execute(
    PreparedEthTransfer prepared, {
    EthGasSelection? feeOverride,
    void Function()? onBroadcasting,
    void Function(PendingTxResolutionClaim? claim)? onBroadcastRegistered,
  }) {
    return signAndBroadcastEvmTransfer(
      rpc: _rpc,
      walletManager: _walletManager,
      walletId: prepared.walletId,
      source: prepared.source,
      to: prepared.to,
      value: prepared.value,
      data: prepared.data,
      gasLimit: effectiveSignedGasLimit(
        overrideGasLimit: feeOverride?.gasLimit,
        preparedGasLimit: prepared.estimate.gasLimit,
      ),
      maxFeePerGas: feeOverride?.maxFeePerGas ?? prepared.estimate.maxFeePerGas,
      maxPriorityFeePerGas:
          feeOverride?.maxPriorityFeePerGas ??
          prepared.estimate.maxPriorityFeePerGas,
      refreshFees: feeOverride == null,
      onBroadcasting: onBroadcasting,
      onBroadcastRegistered: onBroadcastRegistered,
      trackKind: PendingEvmTxKind.send,
      trackAs: prepared.trackAs,
    );
  }

  /// The padded gas limit a native ETH transfer to [destination] would be
  /// broadcast with — the same `estimateGas` + 20% headroom [prepare] bakes into
  /// its review estimate. Exposed so the Max-send reserve ([SendBloc]) reserves
  /// gas over the *actual* per-recipient limit rather than the flat EOA
  /// [nativeSendGasLimit]: a contract-wallet recipient (Safe/Argent) runs its
  /// receive/fallback, so its transfer costs more than 21 000 gas, and reserving
  /// only the flat limit would leave `value + signedGasLimit × cap` above the
  /// balance — a node rejection after review + biometric auth.
  Future<int> nativeSendGasLimitFor({
    required String source,
    required String destination,
  }) async {
    final estimate = await _rpc.estimateGas(from: source, to: destination);
    return (estimate *
            BigInt.from(_gasHeadroomNum) ~/
            BigInt.from(_gasHeadroomDen))
        .toInt();
  }

  /// Re-encode the intended transfer locally and assert the backend calldata is
  /// byte-identical — same target, native value, and calldata. Catches a
  /// builder returning an approval, a swapped recipient/amount, or an
  /// unexpected value-bearing tx before the user can sign.
  void _assertCalldata({
    required String destination,
    required BigInt amountRaw,
    required TokenBalance? token,
    required String to,
    required BigInt valueWei,
    required Uint8List data,
  }) {
    final expected = _buildParams(
      destination: destination,
      amountRaw: amountRaw,
      token: token,
    );
    if (to.toLowerCase() != expected.to.with0x.toLowerCase()) {
      throw const EthTransferBlockedException(
        'This transfer targets an unexpected address.',
      );
    }
    if (valueWei != expected.value) {
      throw const EthTransferBlockedException(
        'This transfer would move a different amount than you chose to send.',
      );
    }
    if (!listEquals(data, expected.data ?? Uint8List(0))) {
      throw const EthTransferBlockedException(
        'This transfer does not match what you chose to send.',
      );
    }
  }

  /// Assert the simulated state change is exactly the intended amount leaving
  /// the wallet — no approvals, no other outflow, no revert.
  ///
  /// The exact-amount check (moved amount must equal the requested amount) is a
  /// deliberate fail-closed gate. **Known limitation:** it also blocks
  /// fee-on-transfer and rebasing ERC-20s, where a different amount arrives than
  /// is sent — those tokens deterministically fail this check and cannot be sent
  /// from the app. This is intentional (an off-by-fee movement is
  /// indistinguishable from a tampered amount here); the block message tells the
  /// user why rather than reading as a generic mismatch.
  ///
  /// The token match keys on the **contract**, not on the asset label, because
  /// the label is not always knowable. A legacy ERC-20 that declares
  /// `uint256 indexed value` emits a four-topic `Transfer` that is
  /// byte-identical to an ERC-721's, so `decodeSimulateV1` — which has no token
  /// metadata, unlike the Alchemy call it replaced — can only read it as
  /// `ERC721` with the amount in `tokenId`. Requiring the `ERC20` label would
  /// block *every* send of such a token as "an unexpected asset". An address is
  /// one contract, so on the contract the user chose there is no second asset
  /// for either label to be confused with; the amount check below still holds
  /// the movement to the requested amount exactly, reading it from whichever
  /// field the shape put it in.
  void _assertSimulation(
    EvmSimulationResult sim, {
    required String source,
    required TokenBalance? token,
    required BigInt amountRaw,
  }) {
    final isNative = token == null || token.isNative;
    final wantContract = isNative ? null : token.mint.toLowerCase();
    assertEvmSimulation(
      sim,
      source: source,
      isIntendedAsset: (change) => isNative
          ? change.assetType == 'NATIVE'
          : change.contractAddress == wantContract &&
                (change.assetType == 'ERC20' ||
                    // The legacy indexed-`value` shape above. Transfers only —
                    // the approval path keeps the stricter label check.
                    (change.assetType == 'ERC721' && !change.isApprove)),
      assertAmount: (change) {
        // A modern ERC-20 carries the amount in `rawAmount`; the legacy
        // indexed-`value` shape carries it in `tokenId`. Absent in both (or
        // unparseable) stays null, which fails the comparison below.
        final movedRaw = BigInt.tryParse(
          change.rawAmount ?? change.tokenId ?? '',
        );
        if (movedRaw != amountRaw) {
          throw const EthTransferBlockedException(
            'This token moved a different amount than you requested. Tokens '
            'that take a transfer fee or rebalance the amount on send (e.g. '
            'fee-on-transfer or rebasing tokens) are not supported.',
          );
        }
      },
      noMovementMessage:
          'Simulation did not show your funds leaving your wallet.',
    );
  }

  /// Resolve the destination, native value, and calldata for [token]:
  ///  - native ETH ([token] null/native): pay [amountRaw] wei straight to
  ///    [destination], no calldata.
  ///  - ERC-20 ([token] set): call `transfer(destination, amountRaw)` on the
  ///    token contract, carrying zero native value.
  _EthTxParams _buildParams({
    required String destination,
    required BigInt amountRaw,
    required TokenBalance? token,
  }) {
    if (token == null || token.isNative) {
      return _EthTxParams(
        to: EthereumAddress.fromHex(destination),
        value: amountRaw,
      );
    }
    final contract = DeployedContract(
      ContractAbi.fromJson(_erc20TransferAbi, 'ERC20'),
      EthereumAddress.fromHex(token.mint),
    );
    final data = contract.function('transfer').encodeCall([
      EthereumAddress.fromHex(destination),
      amountRaw,
    ]);
    return _EthTxParams(
      to: EthereumAddress.fromHex(token.mint),
      value: BigInt.zero,
      data: data,
    );
  }

  Future<EthereumSendEstimate> _estimate({
    required String source,
    required _EthTxParams params,
  }) async {
    // Two independent reads — fetch concurrently rather than serially.
    final results = await Future.wait<Object>([
      _rpc.getFeeData(),
      _rpc.estimateGas(
        from: source,
        to: params.to.with0x,
        valueWei: params.value == BigInt.zero ? null : params.value,
        data: params.data,
      ),
    ]);
    final fee = results[0] as EthFeeData;
    final estimatedGas = results[1] as BigInt;
    final gasLimit =
        (estimatedGas *
                BigInt.from(_gasHeadroomNum) ~/
                BigInt.from(_gasHeadroomDen))
            .toInt();

    return EthereumSendEstimate(
      gasLimit: gasLimit,
      estimatedGasUsed: estimatedGas,
      maxFeePerGas: fee.maxFeePerGas,
      maxPriorityFeePerGas: fee.maxPriorityFeePerGas,
      effectiveGasPrice: fee.effectiveGasPrice,
    );
  }
}

/// A validated, ready-to-sign Ethereum transfer. Produced by
/// [EthereumTransferService.prepare] and consumed by `execute`.
class PreparedEthTransfer {
  const PreparedEthTransfer({
    required this.walletId,
    required this.source,
    required this.to,
    required this.value,
    required this.data,
    required this.estimate,
    this.trackAs = const PendingTxMetadata(title: 'Send'),
  });

  final String walletId;
  final String source;
  final EthereumAddress to;
  final BigInt value;

  /// ABI calldata; null for a native ETH transfer.
  final Uint8List? data;

  /// Gas estimate + default EIP-1559 fees, used for the confirm-step fee
  /// display and as the fallback fee when no [EthGasSelection] override is set.
  final EthereumSendEstimate estimate;

  /// Display payload recorded with the broadcast so the transaction can be
  /// shown in the Pending section (and sped up / cancelled) after the send flow
  /// is gone. Never used to build a transaction.
  final PendingTxMetadata trackAs;
}

/// Infra failure while preparing/executing an Ethereum transfer (no wallet,
/// backend error, RPC failure). Distinct from [EthTransferBlockedException],
/// which is a deliberate safety-gate rejection. A thin subclass of the shared
/// [EvmTransferException] that keeps the Ethereum-specific `toString` prefix.
class EthTransferException extends EvmTransferException {
  const EthTransferException(super.message);
  @override
  String toString() => 'Ethereum transfer error: $message';
}

/// The safety gate refused the transfer — the calldata or the simulated state
/// change did not match a clean, single-asset transfer. [message] is
/// user-facing (surfaced verbatim via `toString`). Aliased to the shared
/// [EvmTransferBlockedException] the transfer core throws, so a single runtime
/// type flows through both the send and artwork gates.
typedef EthTransferBlockedException = EvmTransferBlockedException;
