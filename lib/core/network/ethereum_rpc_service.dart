import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:injectable/injectable.dart';
// web3dart 3.x re-homed EthereumAddress/EtherAmount in package:wallet; it
// imports them but does not re-export, so they need a direct import here.
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/json_rpc.dart' show RPCError;
import 'package:web3dart/web3dart.dart';

import '../config/environment.dart';
import '../observability/app_logger.dart';
import 'evm_simulation_decoder.dart';

const _logTag = 'EthereumRpc';

/// EIP-1559 fee parameters for a transaction, fetched from the node's latest
/// block. [maxFeePerGas] is the per-gas cap the tx signs (base-fee headroom);
/// [maxPriorityFeePerGas] is the miner tip; [baseFeePerGas] is the current base
/// fee used to compute the *expected* (as opposed to worst-case) fee shown to
/// the user.
class EthFeeData {
  const EthFeeData({
    required this.baseFeePerGas,
    required this.maxPriorityFeePerGas,
    required this.maxFeePerGas,
  });

  final BigInt baseFeePerGas;
  final BigInt maxPriorityFeePerGas;
  final BigInt maxFeePerGas;

  /// The per-gas price the tx is expected to actually pay: base fee + tip,
  /// capped at [maxFeePerGas]. Drives the displayed fee estimate.
  BigInt get effectiveGasPrice {
    final expected = baseFeePerGas + maxPriorityFeePerGas;
    return expected < maxFeePerGas ? expected : maxFeePerGas;
  }
}

/// Thin JSON-RPC client for Ethereum mainnet money movement, wrapping a
/// [Web3Client] over the env-selected node ([Config.ethereumRpcUrl], publicnode
/// by default). Mirrors [TezosRpcService] / [SolanaRpcService] in role: the
/// read + broadcast primitives the send flow needs — balance, nonce, gas
/// estimate, EIP-1559 fee data, raw-tx broadcast, and inclusion polling.
///
/// Ethereum is mainnet-only in every environment (see [Config.isEthereumMainnet]
/// and `EthereumTokenService`), so there is no per-environment network switch
/// here.
@lazySingleton
class EthereumRpcService {
  EthereumRpcService()
    : _client = Web3Client(Config.ethereumRpcUrl, http.Client());

  /// Test seam: inject a [Web3Client] pointed at a mock RPC. Not for app code —
  /// use the default constructor (DI-registered) everywhere else.
  EthereumRpcService.withClient(this._client);

  /// Money-movement client (balance, nonce, estimate, broadcast) — points at
  /// [Config.ethereumRpcUrl] (public node by default).
  final Web3Client _client;

  /// Plain HTTP client for the Infura Gas API REST call (not JSON-RPC). Lazily
  /// created; only [getSuggestedGasFees] uses it.
  final http.Client _gasHttpClient = http.Client();

  /// EIP-155 chain id signed into every transaction (mainnet = 1).
  int get chainId => Config.ethereumChainId;

  /// Native ETH balance of [address], in wei.
  Future<BigInt> getBalance(String address) async {
    final amount = await _guard(
      () => _client.getBalance(EthereumAddress.fromHex(address)),
    );
    return amount.getInWei;
  }

  /// Exact ERC-20 `balanceOf(owner)` for the token [contract], in the token's
  /// smallest units. Read from chain (not the cached [TokenBalance], which
  /// clamps 18-decimal raw balances to int64) so a Max send can format the full
  /// balance without a double round-trip rounding it past what's held.
  Future<BigInt> erc20BalanceOf({
    required String owner,
    required String contract,
  }) async {
    final token = DeployedContract(
      ContractAbi.fromJson(_erc20BalanceOfAbi, 'ERC20'),
      EthereumAddress.fromHex(contract),
    );
    final result = await _guard(
      () => _client.call(
        contract: token,
        function: token.function('balanceOf'),
        params: [EthereumAddress.fromHex(owner)],
      ),
    );
    return result.first as BigInt;
  }

  /// Minimal ERC-20 `balanceOf(address)` ABI — the only method the Max-amount
  /// read calls.
  static const String _erc20BalanceOfAbi =
      '[{"constant":true,"inputs":[{"name":"_owner","type":"address"}],'
      '"name":"balanceOf","outputs":[{"name":"","type":"uint256"}],'
      '"type":"function"}]';

  /// Current owner of ERC-721 [tokenId] on [contract], lowercased hex. Powers
  /// the artwork-transfer ownership gate (`ownerOf(tokenId) == wallet`). A
  /// non-existent / burned token reverts → [EthereumRpcException].
  Future<String> erc721OwnerOf({
    required String contract,
    required BigInt tokenId,
  }) async {
    final token = DeployedContract(
      ContractAbi.fromJson(_erc721OwnerOfAbi, 'ERC721'),
      EthereumAddress.fromHex(contract),
    );
    final result = await _guard(
      () => _client.call(
        contract: token,
        function: token.function('ownerOf'),
        params: [tokenId],
      ),
    );
    return (result.first as EthereumAddress).eip55With0x.toLowerCase();
  }

  /// ERC-1155 `balanceOf(owner, id)` — the number of copies of [tokenId] on
  /// [contract] held by [owner]. Powers the 1155 ownership gate and the transfer
  /// quantity ceiling.
  Future<BigInt> erc1155BalanceOf({
    required String owner,
    required String contract,
    required BigInt tokenId,
  }) async {
    final token = DeployedContract(
      ContractAbi.fromJson(_erc1155BalanceOfAbi, 'ERC1155'),
      EthereumAddress.fromHex(contract),
    );
    final result = await _guard(
      () => _client.call(
        contract: token,
        function: token.function('balanceOf'),
        params: [EthereumAddress.fromHex(owner), tokenId],
      ),
    );
    return result.first as BigInt;
  }

  /// True when [address] is a contract (has deployed code) rather than an EOA.
  /// Drives the "recipient is a contract" heads-up before an NFT `safeTransferFrom`.
  Future<bool> hasContractCode(String address) async {
    final code = await _guard(
      () => _client.getCode(EthereumAddress.fromHex(address)),
    );
    return code.isNotEmpty;
  }

  static const String _erc721OwnerOfAbi =
      '[{"constant":true,"inputs":[{"name":"tokenId","type":"uint256"}],'
      '"name":"ownerOf","outputs":[{"name":"","type":"address"}],'
      '"type":"function"}]';

  static const String _erc1155BalanceOfAbi =
      '[{"constant":true,"inputs":[{"name":"account","type":"address"},'
      '{"name":"id","type":"uint256"}],"name":"balanceOf",'
      '"outputs":[{"name":"","type":"uint256"}],"type":"function"}]';

  /// Next nonce for [address] — the *pending* count so back-to-back sends from
  /// the same wallet don't collide on a nonce already in the mempool.
  Future<int> getNonce(String address) => _guard(
    () => _client.getTransactionCount(
      EthereumAddress.fromHex(address),
      atBlock: const BlockNum.pending(),
    ),
  );

  /// Confirmed nonce for [address] — the *latest* (mined) count, i.e. the next
  /// nonce the chain will accept. Distinct from [getNonce], which counts the
  /// mempool too: the difference between the two is exactly the set of nonces
  /// with an unmined transaction sitting on them, which is how the pending
  /// tracker detects both its own unresolved sends and gaps left by a
  /// transaction broadcast from another device.
  Future<int> getLatestNonce(String address) => _guard(
    () => _client.getTransactionCount(
      EthereumAddress.fromHex(address),
      atBlock: const BlockNum.current(),
    ),
  );

  /// Receipt for [hash], or null when the transaction has not mined. Errors
  /// surface as an [EthereumRpcException] rather than a null, so a transport
  /// blip is never mistaken for "this transaction did not mine".
  Future<TransactionReceipt?> getTransactionReceipt(String hash) =>
      _guard(() => _client.getTransactionReceipt(hash));

  /// Mempool/chain record for [hash], or null when the node has never seen it.
  /// Read-only diagnostics (the detail sheet's "in mempool" line) — absence
  /// never removes a tracked entry, since a node's mempool view is partial.
  Future<TransactionInformation?> getTransactionByHash(String hash) =>
      _guard(() => _client.getTransactionByHash(hash));

  /// Estimate the gas units [from] → [to] with [valueWei] and optional call
  /// [data] (ERC-20 transfer payload) consumes. Reverts here (e.g. an ERC-20
  /// balance too low) surface as an [EthereumRpcException].
  Future<BigInt> estimateGas({
    required String from,
    required String to,
    BigInt? valueWei,
    Uint8List? data,
  }) async {
    try {
      return await _guard(
        () => _client.estimateGas(
          sender: EthereumAddress.fromHex(from),
          to: EthereumAddress.fromHex(to),
          value: valueWei == null ? null : EtherAmount.inWei(valueWei),
          data: data,
        ),
      );
    } on EthereumRpcException catch (error) {
      AppLogger.debug(
        _logTag,
        'eth_estimateGas raw error: code=${error.code} data=${error.data}',
      );
      rethrow;
    }
  }

  /// Current EIP-1559 fee parameters from the latest block. Uses a fixed 1.5
  /// gwei priority tip and `maxFee = 2·baseFee + tip` (web3dart's own default
  /// formula) so a base-fee bump between review and inclusion can't strand the
  /// tx. Falls back to the legacy `eth_gasPrice` as the base fee on a
  /// pre-London node (never the case on mainnet, but keeps the math defined).
  Future<EthFeeData> getFeeData() async {
    final block = await _guard(() => _client.getBlockInformation());
    final baseFee =
        block.baseFeePerGas?.getInWei ??
        (await _guard(() => _client.getGasPrice())).getInWei;
    final priority = _priorityTipWei;
    return EthFeeData(
      baseFeePerGas: baseFee,
      maxPriorityFeePerGas: priority,
      maxFeePerGas: baseFee * BigInt.two + priority,
    );
  }

  /// 1.5 gwei miner tip.
  static final BigInt _priorityTipWei = BigInt.from(1500000000);

  /// Fetch Infura's `suggestedGasFees` (MetaMask Gas API, chainId 1) via the
  /// mallow proxy — the source for the Edit Gas Fee sheet. One authenticated GET
  /// returns ready-made Low/Market/High tiers (each with a suggested max fee +
  /// priority tip and wait-time estimates), the estimated base fee, network
  /// congestion (0..1), and historical fee ranges. Parsed by
  /// `EthGasMarket.fromSuggestedGasFees`. Throws an [EthereumRpcException] on a
  /// non-200 (e.g. proxy 401/403/429 or an Infura error), and before any request
  /// when `EVM_GAS_API_URL` is unset — the endpoint has no default, so an
  /// unconfigured build must say so rather than call a guessed URL.
  Future<Map<String, dynamic>> getSuggestedGasFees() async {
    final base = Config.ethereumGasApiBaseUrl;
    if (base.isEmpty) {
      throw const EthereumRpcException(
        'gas API not configured: set EVM_GAS_API_URL',
      );
    }
    final uri = Uri.parse('$base/suggestedGasFees');
    final http.Response response;
    try {
      response = await _gasHttpClient.get(
        uri,
        headers: Config.clientIdHeadersFor(uri),
      );
    } catch (e) {
      throw EthereumRpcException('gas API request failed: $e');
    }
    if (response.statusCode != 200) {
      throw EthereumRpcException(
        'gas API ${response.statusCode}: ${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Simulate the fully-formed EVM transfer via the mallow proxy's Alchemy
  /// route and return the asset movements + approvals it would produce. The
  /// artwork-transfer safety gate blocks signing unless the only change is the
  /// single intended NFT leaving the wallet (no approval grants, no other
  /// outflow) and the sim reports no revert. Approval revocations to the zero
  /// address are expected during standard ERC-721 transfers.
  ///
  /// Uses `eth_simulateV1`, which returns raw event logs rather than decoded
  /// asset changes — [decodeSimulateV1] reconstructs the change list. Two
  /// request options are load-bearing:
  ///  * `traceTransfers` reports native ETH moves as synthetic `Transfer` logs;
  ///    without it a plain ETH send shows no movement and the gate blocks it.
  ///  * `validation` stays off to preserve the semantics of the
  ///    `alchemy_simulateAssetChanges` call this replaced — this is a
  ///    state-change check, not a balance/nonce/fee check. `eth_estimateGas`
  ///    already fails the prepare if the transfer could not execute.
  ///
  /// Throws an [EthereumRpcException] on a proxy/transport error, and before any
  /// request when `EVM_SIMULATION_URL` is unset. The endpoint has no default, so
  /// an unconfigured build fails the gate closed — the transfer stops — instead
  /// of aiming it at a guessed URL.
  Future<EvmSimulationResult> simulateAssetChanges({
    required String from,
    required String to,
    required String data,
    String value = '0x0',
  }) async {
    final endpoint = Config.ethereumSimulationUrl;
    if (endpoint.isEmpty) {
      throw const EthereumRpcException(
        'simulation not configured: set EVM_SIMULATION_URL',
      );
    }
    final uri = Uri.parse(endpoint);
    final body = jsonEncode({
      'id': 1,
      'jsonrpc': '2.0',
      'method': 'eth_simulateV1',
      'params': [
        {
          'blockStateCalls': [
            {
              'calls': [
                {'from': from, 'to': to, 'value': value, 'data': data},
              ],
            },
          ],
          'traceTransfers': true,
          'validation': false,
        },
        'latest',
      ],
    });
    final http.Response response;
    try {
      response = await _gasHttpClient.post(
        uri,
        headers: {
          ...Config.clientIdHeadersFor(uri),
          'Content-Type': 'application/json',
        },
        body: body,
      );
    } catch (e) {
      throw EthereumRpcException('simulation request failed: $e');
    }
    if (response.statusCode != 200) {
      throw EthereumRpcException(
        'simulation ${response.statusCode}: ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (decoded['error'] != null) {
      // JSON-RPC transport-level error (bad params, upstream failure).
      final error = decoded['error'];
      if (error is Map) {
        throw EthereumRpcException(
          error['message']?.toString() ?? 'simulation RPC error',
          code: error['code'] is int ? error['code'] as int : null,
          data: error['data'],
        );
      }
      throw EthereumRpcException('simulation error: $error');
    }
    return decodeSimulateV1(decoded['result']);
  }

  /// Broadcast a signed raw transaction, returning its hash.
  Future<String> sendRawTransaction(Uint8List signed) =>
      _guard(() => _client.sendRawTransaction(signed));

  /// Best-effort inclusion wait — polls for the receipt until it appears or
  /// [timeout] elapses. Mirrors the Tezos/Solana confirmation loop: the tx is
  /// already broadcast, so a timeout does not undo it (the caller returns the
  /// hash regardless).
  ///
  /// Returning normally means a receipt was read, and nothing else: a deadline
  /// reached with no receipt throws [EvmInclusionTimeoutException]. Callers hand
  /// the pending-transaction tracker's resolution notice back on that, so a
  /// timeout that returned like an inclusion would permanently silence the
  /// toast for a transaction that is still in the mempool.
  Future<void> waitForConfirmation(
    String hash, {
    Duration timeout = const Duration(seconds: 60),
    Duration interval = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final receipt = await getTransactionReceipt(hash).catchError((_) => null);
      if (receipt != null) return;
      await Future<void>.delayed(interval);
    }
    throw const EvmInclusionTimeoutException();
  }

  /// Wrap web3dart/transport errors in an [EthereumRpcException] carrying a
  /// human-readable message, so the send pipeline surfaces "insufficient funds"
  /// / "execution reverted" instead of an opaque RPCError string.
  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on RPCError catch (e) {
      throw EthereumRpcException(e.message, code: e.errorCode, data: e.data);
    } catch (e) {
      throw EthereumRpcException(e.toString());
    }
  }
}

/// Thrown when an Ethereum JSON-RPC call fails (transport error, node error, or
/// a reverted `eth_estimateGas`). [message] is the node's error text.
class EthereumRpcException implements Exception {
  const EthereumRpcException(this.message, {this.code, this.data});

  final String message;
  final int? code;
  final Object? data;

  /// A diagnostic-only representation that retains the node's error code and
  /// whether it supplied revert data without exposing raw calldata or any
  /// address embedded in that data.
  String get diagnosticMessage {
    final details = <String>[];
    if (code != null) details.add('rpcCode=$code');
    if (data != null) details.add(_summarizeRpcData(data!));
    return details.isEmpty ? message : '$message (${details.join(', ')})';
  }

  @override
  String toString() => 'Ethereum RPC error: $message';
}

String _summarizeRpcData(Object data) {
  if (data is String) {
    final clean = data.startsWith('0x') ? data.substring(2) : data;
    if (RegExp(r'^[a-fA-F0-9]*$').hasMatch(clean)) {
      final selector = clean.length >= 8
          ? '0x${clean.substring(0, 8)}'
          : 'none';
      return 'revertDataSelector=$selector dataBytes=${clean.length ~/ 2}';
    }
  }
  return 'revertDataType=${data.runtimeType}';
}

/// The inclusion wait reached its deadline without reading a receipt.
///
/// Deliberately **not** an [EthereumRpcException]: nothing failed and nothing
/// was learned. The transaction is broadcast and may still mine, so the caller
/// keeps its hash and hands reporting the outcome back to the
/// pending-transaction tracker rather than surfacing an error.
class EvmInclusionTimeoutException implements Exception {
  const EvmInclusionTimeoutException();

  @override
  String toString() => 'Timed out waiting for the transaction to be included';
}

/// The three broadcast rejections a replace-by-fee flow has to act on rather
/// than just surface. Everything else is [EvmBroadcastError.other].
enum EvmBroadcastError {
  /// The node requires a bigger bump over the transaction already occupying
  /// this nonce. The blind-cancel ladder retries at a higher fee.
  replacementUnderpriced,

  /// The nonce is already mined — the transaction we were replacing won. Not an
  /// error to show: refresh and report the resolution instead.
  nonceTooLow,

  /// The exact same raw transaction is already in the mempool. Treated as
  /// success (the broadcast we wanted has already happened).
  alreadyKnown,

  other,
}

/// Classify a broadcast failure by the node's error text. Geth, Erigon,
/// Nethermind and the public RPC proxies all phrase these the same way, and the
/// message is the only machine-readable signal available (the JSON-RPC codes
/// are not standardised across clients).
EvmBroadcastError classifyEvmBroadcastError(Object error) {
  final message = (error is EthereumRpcException ? error.message : '$error')
      .toLowerCase();
  if (message.contains('replacement transaction underpriced')) {
    return EvmBroadcastError.replacementUnderpriced;
  }
  if (message.contains('nonce too low')) return EvmBroadcastError.nonceTooLow;
  if (message.contains('already known')) return EvmBroadcastError.alreadyKnown;
  return EvmBroadcastError.other;
}

/// Parsed simulation result: the asset changes the tx would produce and, when
/// the tx would revert, an [error] message. Built by [decodeSimulateV1] and
/// consumed by the artwork-transfer safety gate.
class EvmSimulationResult {
  const EvmSimulationResult({required this.changes, this.error});

  final List<EvmAssetChange> changes;

  /// Non-null when the simulated tx would revert, carrying the reason.
  final String? error;
}

/// A single asset movement or approval from a simulated tx.
class EvmAssetChange {
  const EvmAssetChange({
    required this.assetType,
    required this.changeType,
    this.from,
    this.to,
    this.contractAddress,
    this.tokenId,
    this.rawAmount,
  });

  /// `NATIVE` | `ERC20` | `ERC721` | `ERC1155`.
  final String assetType;

  /// `TRANSFER` | `APPROVE`.
  final String changeType;
  final String? from;
  final String? to;
  final String? contractAddress;
  final String? tokenId;

  /// Raw (smallest-unit) amount as a decimal string; for ERC-1155 this is the
  /// number of copies moved.
  final String? rawAmount;

  bool get isApprove => changeType.toUpperCase() == 'APPROVE';
}
