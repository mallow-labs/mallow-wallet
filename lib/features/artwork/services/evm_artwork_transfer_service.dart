import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
// web3dart 3.x re-homed EthereumAddress in package:wallet; it imports the type
// but does not re-export it.
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:web3dart/web3dart.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/network/evm_transfer_core.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/security/transaction_auth_gate.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/address_format.dart';
import '../../../di.dart';
import '../../../features/send/models/eth_gas.dart';

import '../../../shared/utils/chain.dart';
export '../../../core/network/evm_transfer_core.dart'
    show EvmTransferException, EvmTransferBlockedException;

const _logTag = 'EvmArtworkTransfer';

/// Client-side orchestrator for ERC-721 / ERC-1155 artwork transfers.
///
/// The backend (`/v2/tx/assets/transfer`, EVM branch) builds the
/// `safeTransferFrom` calldata; this service fills nonce + EIP-1559 fees, runs
/// the two-part safety gate, signs on-device, and broadcasts:
///
///  1. **Calldata assertion** — re-encode the intended `safeTransferFrom`
///     locally and byte-compare it to the backend calldata, asserting
///     `value == 0` and `to == the NFT contract`. Catches a compromised/buggy
///     builder returning `setApprovalForAll`, a swapped recipient/tokenId, or a
///     value-bearing tx (an approval moves no assets, so simulation alone can't
///     see it).
///  2. **State-change simulation** — `eth_simulateV1` (via the
///     mallow proxy) must show exactly the intended NFT leaving the wallet, no
///     approvals, no other outflow, and no revert.
///
/// Both must pass before the user is allowed to sign. Ethereum mainnet only.
@lazySingleton
class EvmArtworkTransferService {
  EvmArtworkTransferService(
    this._apiV2,
    this._rpc,
    this._walletManager,
    this._authGate,
  );

  final MallowApiV2Client _apiV2;
  final EthereumRpcService _rpc;
  final WalletManager _walletManager;
  final TransactionAuthGate _authGate;

  /// 20% gas headroom, matching `EthereumTransferService`.
  static final BigInt _headroomNum = BigInt.from(12);
  static final BigInt _headroomDen = BigInt.from(10);

  /// Owned copies of ERC-1155 [tokenId] on [contract] for the [holder] EVM
  /// wallet (or the active ETH wallet when [holder] is null) — the ceiling for
  /// the transfer quantity picker.
  Future<BigInt> ownedErc1155Amount({
    required String contract,
    required BigInt tokenId,
    String? holder,
  }) async {
    final wallet = await _resolveWallet(holder);
    if (wallet == null) throw const EvmTransferException('No Ethereum wallet');
    return _rpc.erc1155BalanceOf(
      owner: wallet.address,
      contract: contract,
      tokenId: tokenId,
    );
  }

  /// Resolve the signing wallet for the transfer. When [holder] is a session
  /// wallet — matched case-insensitively on its hex address, per EIP-55
  /// checksum — it wins, so a non-active ETH holder is prepared + signed with
  /// its own key. Otherwise falls back to the session's active ETH wallet
  /// (backward compatible with callers that pass no holder).
  ///
  /// The fallback goes through [SessionManager.sessionWalletForChain], not
  /// `WalletManager.activeWalletForChain`: the latter answers from the active
  /// *account*, whose ETH wallet is auto-derived and may not be linked to the
  /// active Profile — signing an NFT transfer with it would move an asset using
  /// a wallet outside the session.
  Future<WalletInfo?> _resolveWallet(String? holder) async {
    final session = sl<SessionManager>();
    if (holder != null && holder.isNotEmpty) {
      final match = session.sessionWalletForAddressCaseInsensitive(holder);
      if (match != null) return match;
    }
    return session.sessionWalletForChain(Chain.ethereum);
  }

  /// Fetch the live EIP-1559 fee market for the Edit Gas Fee sheet — one Infura
  /// `suggestedGasFees` call (via the mallow proxy) yielding the Low/Market
  /// tiers, base fee, priority-fee range, congestion, and history. Mirrors
  /// [EthereumTransferService.gasMarket]; the send and artwork flows share the
  /// same fee UI.
  Future<EthGasMarket> gasMarket() => EthGasMarket.fetch(_rpc);

  /// Build (backend), assemble, estimate fees, and run the safety gate. Throws
  /// [EvmTransferBlockedException] when the gate fails (calldata mismatch,
  /// approval, unexpected asset movement, or a simulated revert) and
  /// [EvmTransferException] on infra failures. Returns a ready-to-sign transfer.
  ///
  /// Fees here are the node **defaults** — the gate (calldata assertion +
  /// simulation) is independent of the fee, so the user's [EthGasSelection]
  /// override is applied later, at [execute], without re-running the gate.
  /// [artworkName] / [imageUrl] are display-only and feed the pending-tx cell
  /// while the transfer is unconfirmed; when absent the cell falls back to a
  /// generic "Transfer" title and resolves the image from `artworkMint`.
  Future<PreparedEvmTransfer> prepare({
    required String contract,
    required String tokenId,
    required TokenStandard standard,
    required String recipient,
    int amount = 1,
    String? holder,
    String? artworkName,
    String? imageUrl,
  }) async {
    final wallet = await _resolveWallet(holder);
    if (wallet == null) throw const EvmTransferException('No Ethereum wallet');
    final source = wallet.address;

    // 1. Backend builds the calldata.
    final response = await _trace(
      'backend transfer build',
      () => _apiV2.getTransferTx(
        TransferTxRequest(
          authority: source,
          asset: '$contract-$tokenId',
          recipient: recipient,
          tokenStandard: standard.apiValue,
          amount: standard == TokenStandard.erc1155 ? amount.toString() : null,
        ),
      ),
    );
    final evm = response.result.evm;
    if (evm == null) {
      throw const EvmTransferException(
        'Backend did not return an EVM transfer',
      );
    }
    final to = evm.to;
    final data = evmHexToBytes(evm.data);
    final valueWei = evmHexToBigInt(evm.value);

    // 2. Client-side calldata assertion (hard gate).
    try {
      _assertCalldata(
        standard: standard,
        from: source,
        recipient: recipient,
        contract: contract,
        tokenId: tokenId,
        amount: amount,
        to: to,
        valueWei: valueWei,
        data: data,
      );
    } on Object catch (error) {
      _logFailure('calldata assertion', error);
      rethrow;
    }

    // 3-5. Fire the four independent reads in one round-trip window — none
    // consumes another's result:
    //   3. estimateGas (also reverts if the transfer would),
    //   4. getFeeData for the EIP-1559 fees,
    //   5. state-change simulation (hard gate; a transport failure fails
    //      closed), and the recipient-is-contract heads-up (non-blocking;
    //      safeTransferFrom already reverts for a non-ERC721Receiver contract —
    //      this is a proactive warn, so it swallows its own RPC errors).
    // Future.wait rethrows the first original error (unwrapped), so the caller's
    // typed catches still see the real exception.
    final gasFuture = _trace(
      'estimateGas',
      () => _rpc.estimateGas(
        from: source,
        to: to,
        valueWei: valueWei,
        data: data,
      ),
    );
    final feeFuture = _trace('fee data', _rpc.getFeeData);
    final simFuture = _trace(
      'asset-change simulation',
      () => _rpc.simulateAssetChanges(
        from: source,
        to: to,
        data: evm.data,
        value: evm.value,
      ),
    );
    AppLogger.debug(
      _logTag,
      'EVM estimateGas request: from=$source to=$to '
      'valueWei=$valueWei data=${evmBytesToHex(data)}',
    );
    final recipientIsContractFuture = _safeHasContractCode(recipient);
    await Future.wait([
      gasFuture,
      feeFuture,
      simFuture,
      recipientIsContractFuture,
    ]);
    final gasEstimate = await gasFuture;
    final feeData = await feeFuture;
    final sim = await simFuture;
    final recipientIsContract = await recipientIsContractFuture;
    AppLogger.debug(
      _logTag,
      'EVM asset-change simulation: error=${sim.error} '
      'changes=${_simulationSummary(sim.changes)}',
    );

    final gasLimit = (gasEstimate * _headroomNum ~/ _headroomDen).toInt();
    final maxFeePerGas = feeData.maxFeePerGas;
    final maxPriorityFeePerGas = feeData.maxPriorityFeePerGas;
    final feeWei = feeData.effectiveGasPrice * BigInt.from(gasLimit);

    try {
      _assertSimulation(
        sim,
        source: source,
        contract: contract,
        tokenId: tokenId,
        amount: amount,
        standard: standard,
      );
    } on Object catch (error) {
      _logFailure('asset-change safety gate', error);
      rethrow;
    }

    return PreparedEvmTransfer(
      walletId: wallet.id,
      source: source,
      to: to,
      data: data,
      valueWei: valueWei,
      estimatedGasUsed: gasEstimate,
      gasLimit: gasLimit,
      maxFeePerGas: maxFeePerGas,
      maxPriorityFeePerGas: maxPriorityFeePerGas,
      feeWei: feeWei,
      recipientIsContract: recipientIsContract,
      trackAs: PendingTxMetadata(
        title: 'Transfer',
        subtitle:
            artworkName ??
            'to ${truncateAddress(recipient, lead: 6, trail: 4)}',
        // The app's canonical EVM asset key (`<contract>-<tokenId>`), the same
        // string the artwork routes and image lookups take.
        artworkMint: '$contract-$tokenId',
        imageUrl: imageUrl,
      ),
    );
  }

  /// Authorize (biometric/PIN), sign on-device, and broadcast a prepared
  /// transfer. Returns the tx hash. Throws [TransactionAuthCancelledException]
  /// when the user declines auth, [TransactionFlowDisabledException] when an
  /// operator has killed the `ethereum:nft-transfer` cell, or
  /// [EvmTransferException] on a signing / broadcast failure. [onBroadcasting]
  /// fires once the signed tx is dispatched. [onBroadcastRegistered] fires
  /// after the node accepts the raw transaction and the pending-tx tracker
  /// owns its nonce. The claim is held while this flow waits for inclusion, so
  /// a caller that exits early must release it when its bloc closes.
  ///
  /// [feeOverride] carries the fee the user picked on the Edit Gas Fee sheet —
  /// its `maxFeePerGas`/`maxPriorityFeePerGas` are signed verbatim, and its
  /// `gasLimit` is signed unless it falls below the prepared estimate, in which
  /// case the estimate floors it (see [effectiveSignedGasLimit]) — a stale
  /// low limit from another flow's persisted custom fee must never sign a
  /// safeTransferFrom that then reverts out-of-gas. When null, the EIP-1559 fee
  /// caps are re-fetched fresh at broadcast (a stale review estimate could
  /// otherwise sign an under-priced fee) — see [signAndBroadcastEvmTransfer].
  Future<String> execute(
    PreparedEvmTransfer prepared, {
    EthGasSelection? feeOverride,
    void Function()? onBroadcasting,
    void Function(PendingTxResolutionClaim? claim)? onBroadcastRegistered,
  }) async {
    // NFT sends carry no reliable USD value; pass null so the gate fail-closes
    // (prompts) when step-up auth is enabled — mirrors the send flow.
    final outcome = await _authGate.authorize(
      usdValue: null,
      flow: const FlowKey(Chain.ethereum, AppFlow.nftTransfer),
    );
    final disabledMessage = outcome.disabledMessage;
    if (disabledMessage != null) {
      // A remotely killed cell is NOT a user cancel — throwing the cancel type
      // here let silent-cancel surfaces swallow the operator's message, which is
      // the only copy that can say whether funds are safe. Mirrors
      // `signSendConfirm`.
      throw TransactionFlowDisabledException(disabledMessage);
    }
    if (outcome != TransactionAuthOutcome.allowed) {
      throw TransactionAuthCancelledException(outcome);
    }

    try {
      return await signAndBroadcastEvmTransfer(
        rpc: _rpc,
        walletManager: _walletManager,
        walletId: prepared.walletId,
        source: prepared.source,
        to: EthereumAddress.fromHex(prepared.to),
        value: prepared.valueWei,
        data: prepared.data,
        gasLimit: effectiveSignedGasLimit(
          overrideGasLimit: feeOverride?.gasLimit,
          preparedGasLimit: prepared.gasLimit,
        ),
        maxFeePerGas: feeOverride?.maxFeePerGas ?? prepared.maxFeePerGas,
        maxPriorityFeePerGas:
            feeOverride?.maxPriorityFeePerGas ?? prepared.maxPriorityFeePerGas,
        refreshFees: feeOverride == null,
        onBroadcasting: onBroadcasting,
        onBroadcastRegistered: onBroadcastRegistered,
        trackKind: PendingEvmTxKind.nftTransfer,
        trackAs: prepared.trackAs,
      );
    } on Object catch (error) {
      _logFailure('sign/broadcast', error);
      rethrow;
    }
  }

  Future<T> _trace<T>(String stage, Future<T> Function() operation) async {
    try {
      return await operation();
    } on Object catch (error) {
      _logFailure(stage, error);
      rethrow;
    }
  }

  void _logFailure(String stage, Object error) {
    AppLogger.error(_logTag, '$stage failed: ${_safeError(error)}');
  }

  String _safeError(Object error) {
    final message = error is EthereumRpcException
        ? error.diagnosticMessage
        : switch (error) {
            EvmTransferException(:final message) => message,
            EvmTransferBlockedException(:final message) => message,
            _ => error.toString(),
          };
    return message
        .replaceAll(RegExp(r'0x[a-fA-F0-9]{64,}'), '0x<hex>')
        .replaceAll(RegExp(r'0x[a-fA-F0-9]{40}'), '0x<address>');
  }

  String _simulationSummary(List<EvmAssetChange> changes) => changes
      .map(
        (change) =>
            '{assetType=${change.assetType}, '
            'changeType=${change.changeType}, from=${change.from}, '
            'to=${change.to}, contract=${change.contractAddress}, '
            'tokenId=${change.tokenId}, rawAmount=${change.rawAmount}}',
      )
      .join(', ');

  /// Re-encode the intended transfer locally and assert the backend calldata is
  /// byte-identical, `value` is zero, and the target is the NFT contract.
  void _assertCalldata({
    required TokenStandard standard,
    required String from,
    required String recipient,
    required String contract,
    required String tokenId,
    required int amount,
    required String to,
    required BigInt valueWei,
    required Uint8List data,
  }) {
    if (valueWei != BigInt.zero) {
      throw const EvmTransferBlockedException(
        'This transfer would send ETH, which an artwork transfer never does.',
      );
    }
    if (to.toLowerCase() != contract.toLowerCase()) {
      throw const EvmTransferBlockedException(
        'This transfer targets an unexpected contract.',
      );
    }
    final expected = _encodeSafeTransferFrom(
      standard: standard,
      contract: contract,
      from: from,
      to: recipient,
      tokenId: BigInt.parse(tokenId),
      amount: amount,
    );
    if (!listEquals(data, expected)) {
      throw const EvmTransferBlockedException(
        'This transfer does not match the artwork you chose to send.',
      );
    }
  }

  /// Assert the simulated state change is exactly the intended NFT leaving the
  /// wallet — no approvals, no other outflow, no revert.
  void _assertSimulation(
    EvmSimulationResult sim, {
    required String source,
    required String contract,
    required String tokenId,
    required int amount,
    required TokenStandard standard,
  }) {
    final wantContract = contract.toLowerCase();
    final wantTokenId = BigInt.parse(tokenId);
    assertEvmSimulation(
      sim,
      source: source,
      isIntendedAsset: (change) =>
          change.contractAddress == wantContract &&
          change.tokenId != null &&
          BigInt.tryParse(change.tokenId!) == wantTokenId,
      assertAmount: (change) {
        if (standard == TokenStandard.erc1155 &&
            change.rawAmount != null &&
            BigInt.tryParse(change.rawAmount!) != BigInt.from(amount)) {
          throw const EvmTransferBlockedException(
            'The simulated quantity does not match the amount you chose.',
          );
        }
      },
      noMovementMessage:
          'Simulation did not show the artwork leaving your wallet.',
    );
  }

  Uint8List _encodeSafeTransferFrom({
    required TokenStandard standard,
    required String contract,
    required String from,
    required String to,
    required BigInt tokenId,
    required int amount,
  }) {
    final address = EthereumAddress.fromHex(contract);
    if (standard == TokenStandard.erc721) {
      final c = DeployedContract(
        ContractAbi.fromJson(_erc721SafeTransferFromAbi, 'ERC721'),
        address,
      );
      return c.function('safeTransferFrom').encodeCall([
        EthereumAddress.fromHex(from),
        EthereumAddress.fromHex(to),
        tokenId,
      ]);
    }
    final c = DeployedContract(
      ContractAbi.fromJson(_erc1155SafeTransferFromAbi, 'ERC1155'),
      address,
    );
    return c.function('safeTransferFrom').encodeCall([
      EthereumAddress.fromHex(from),
      EthereumAddress.fromHex(to),
      tokenId,
      BigInt.from(amount),
      Uint8List(0),
    ]);
  }

  static const String _erc721SafeTransferFromAbi =
      '[{"inputs":[{"name":"from","type":"address"},'
      '{"name":"to","type":"address"},{"name":"tokenId","type":"uint256"}],'
      '"name":"safeTransferFrom","outputs":[],"type":"function"}]';

  static const String _erc1155SafeTransferFromAbi =
      '[{"inputs":[{"name":"from","type":"address"},'
      '{"name":"to","type":"address"},{"name":"id","type":"uint256"},'
      '{"name":"amount","type":"uint256"},{"name":"data","type":"bytes"}],'
      '"name":"safeTransferFrom","outputs":[],"type":"function"}]';

  /// Recipient-is-contract probe that fails soft: a transport error resolves to
  /// `false` rather than aborting the prepare, so it can join the parallel read.
  Future<bool> _safeHasContractCode(String recipient) async {
    try {
      return await _rpc.hasContractCode(recipient);
    } on EthereumRpcException {
      return false;
    }
  }
}

/// A validated, ready-to-sign EVM artwork transfer. Produced by
/// [EvmArtworkTransferService.prepare] and consumed by `execute`.
class PreparedEvmTransfer {
  const PreparedEvmTransfer({
    required this.walletId,
    required this.source,
    required this.to,
    required this.data,
    required this.valueWei,
    required this.estimatedGasUsed,
    required this.gasLimit,
    required this.maxFeePerGas,
    required this.maxPriorityFeePerGas,
    required this.feeWei,
    required this.recipientIsContract,
    this.trackAs = const PendingTxMetadata(title: 'Transfer'),
  });

  final String walletId;
  final String source;
  final String to;
  final Uint8List data;
  final BigInt valueWei;

  /// Node's raw `eth_estimateGas` result — the expected gas used. Drives the
  /// per-tier fee math on the Edit Gas Fee sheet (fee = gasUsed × price).
  final BigInt estimatedGasUsed;

  /// Padded gas cap (estimate + 20% headroom) signed when no fee override.
  final int gasLimit;
  final BigInt maxFeePerGas;
  final BigInt maxPriorityFeePerGas;

  /// Expected network fee in wei (effective gas price × gas limit) for display,
  /// at node-default fees. The confirm UI recomputes this from the active
  /// [EthGasSelection] when the user edits the fee.
  final BigInt feeWei;

  /// True when the recipient address is a contract — surfaced as a heads-up.
  final bool recipientIsContract;

  /// Display payload recorded with the broadcast so the transfer can be shown
  /// in the Pending section (and sped up / cancelled) after the transfer flow
  /// is gone. Never used to build a transaction.
  final PendingTxMetadata trackAs;
}
