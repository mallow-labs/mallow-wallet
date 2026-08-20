import 'ethereum_rpc_service.dart';
import 'evm_transfer_core.dart';

/// Decoder for `eth_simulateV1` results.
///
/// Alchemy sunsets `alchemy_simulateAssetChanges` on 2026-09-30. That method
/// returned *decoded* asset changes; the standard replacement returns raw event
/// logs. This file does the decoding Alchemy used to do for us, so the transfer
/// safety gate ([assertEvmSimulation]) keeps consuming the same
/// [EvmSimulationResult] model and stays byte-for-byte unchanged.
///
/// 🛑 Security-critical and deliberately **total** over the events that can move
/// assets: a log this decoder recognises but cannot decode with confidence
/// throws, because an undecoded movement is one the gate cannot see. Failing
/// closed on a malformed response is correct — the gate already treats a
/// transport failure the same way. Events outside that set are skipped; see
/// [_decodeLog] for why that stays a skip and where it does not.

/// `keccak256("Transfer(address,address,uint256)")` — ERC-20 (3 topics, amount
/// in `data`) and ERC-721 (4 topics, `tokenId` in topic 3) share this signature.
const _transferTopic =
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

/// `keccak256("Approval(address,address,uint256)")` — ERC-20 allowance and
/// ERC-721 single-token approval.
const _approvalTopic =
    '0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925';

/// `keccak256("ApprovalForAll(address,address,bool)")` — the operator-wide
/// approval, strictly more dangerous than a single-token one.
const _approvalForAllTopic =
    '0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31';

/// `keccak256("TransferSingle(address,address,address,uint256,uint256)")`.
const _transferSingleTopic =
    '0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62';

/// `keccak256("TransferBatch(address,address,address,uint256[],uint256[])")`.
/// Our own flows never emit this, but a hostile contract could — an undecoded
/// batch transfer would be an invisible outflow, so it is decoded, not skipped.
const _transferBatchTopic =
    '0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb';

/// Pseudo-emitter `eth_simulateV1` uses for native value moves when
/// `traceTransfers` is on: ETH transfers are reported as ERC-20 `Transfer` logs
/// whose emitting "contract" is this address.
const _nativeTransferEmitter = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

const _zeroAddress = '0x0000000000000000000000000000000000000000';

/// Decode the `result` of an `eth_simulateV1` call into the asset changes the
/// transfer gate asserts on.
///
/// The request submits exactly one call in one simulated block, so the result is
/// `[{calls: [<the one call>]}]`. A reverted call yields an [EvmSimulationResult]
/// with a non-null `error` and no changes — which is what the gate's revert
/// branch already expects.
///
/// Throws an [EthereumRpcException] when the response shape is not what we
/// asked for, or when a known event cannot be decoded.
EvmSimulationResult decodeSimulateV1(Object? result) {
  if (result is! List || result.isEmpty) {
    throw const EthereumRpcException('simulation returned no block result');
  }
  final block = result.first;
  if (block is! Map<String, dynamic>) {
    throw const EthereumRpcException('simulation block result malformed');
  }
  final calls = block['calls'];
  if (calls is! List || calls.isEmpty) {
    throw const EthereumRpcException('simulation returned no call result');
  }
  final call = calls.first;
  if (call is! Map<String, dynamic>) {
    throw const EthereumRpcException('simulation call result malformed');
  }

  // `status` is "0x1" on success. Anything else is a revert: surface it as the
  // gate's `error` so signing is blocked with the on-chain reason.
  final status = (call['status'] as String?)?.toLowerCase();
  if (status != '0x1') {
    return EvmSimulationResult(changes: const [], error: _revertMessage(call));
  }

  final logs = call['logs'];
  if (logs is! List) return const EvmSimulationResult(changes: []);

  final changes = <EvmAssetChange>[];
  for (final log in logs) {
    if (log is! Map<String, dynamic>) {
      throw const EthereumRpcException('simulation log malformed');
    }
    changes.addAll(_decodeLog(log));
  }
  return EvmSimulationResult(changes: changes);
}

/// The human-readable reason a simulated call failed. `eth_simulateV1` reports
/// this inconsistently across providers (an `error` object, a bare string, or
/// nothing at all), so every shape falls back to a usable message rather than
/// letting the gate report a null reason.
String _revertMessage(Map<String, dynamic> call) {
  final error = call['error'];
  if (error is Map) {
    final message = error['message']?.toString();
    if (message != null && message.isNotEmpty) return message;
  } else if (error is String && error.isNotEmpty) {
    return error;
  }
  return 'the transaction reverted';
}

/// Decode one log into zero or more asset changes. Events we do not model are
/// skipped: they are not asset movements, and a standards-compliant token always
/// emits one of the signatures above when value or rights actually move.
///
/// That skip is deliberately *not* widened into "throw on anything unmodelled":
/// legitimate contracts routinely emit auxiliary events during an ordinary
/// transfer (fee hooks, rebases, internal bookkeeping, chain-level fee logs), so
/// blocking on them would fail-closed honest sends for no gain. The one place it
/// would hide a movement is the native trace pseudo-emitter, which is handled
/// below.
List<EvmAssetChange> _decodeLog(Map<String, dynamic> log) {
  final rawTopics = log['topics'];
  if (rawTopics is! List || rawTopics.isEmpty) return const [];
  final topics = rawTopics.map((t) => t.toString().toLowerCase()).toList();
  final emitter = (log['address'] as String? ?? '').toLowerCase();
  final data = log['data'] as String? ?? '';

  // No contract is deployed at the trace pseudo-address: every log from it is
  // synthesised by the node for a *native* move, always as an ERC-20-shaped
  // `Transfer`. Any other signature there is ETH moving in a shape we cannot
  // read — and unlike an unknown token event, skipping it hides an outflow the
  // gate would otherwise see (a token send whose own change matches would pass
  // with the wallet's ETH leaving invisibly). Fail closed.
  if (emitter == _nativeTransferEmitter && topics.first != _transferTopic) {
    throw const EthereumRpcException(
      'native transfer trace log could not be decoded',
    );
  }

  switch (topics.first) {
    case _transferTopic:
      return [_decodeTransfer(topics, emitter, data)];
    case _transferSingleTopic:
      return [_decodeTransferSingle(topics, emitter, data)];
    case _transferBatchTopic:
      return _decodeTransferBatch(topics, emitter, data);
    case _approvalTopic:
      return [_decodeApproval(topics, emitter, data)];
    case _approvalForAllTopic:
      return [_decodeApprovalForAll(topics, emitter, data)];
    default:
      return const [];
  }
}

/// `Transfer(from, to, value|tokenId)`. Three topics means an unindexed amount
/// in `data` (ERC-20, or native ETH when the emitter is the trace
/// pseudo-address); four means the third operand is indexed.
///
/// 🛑 Four topics is **not** proof of an ERC-721: a legacy ERC-20 that declares
/// `uint256 indexed value` emits the identical shape, and without token metadata
/// (which the Alchemy call this replaced had and we do not) the two cannot be
/// told apart from the log. The label is therefore a best guess, and consumers
/// must not treat it as the identity of the asset — the *contract address* is.
/// `EthereumTransferService._assertSimulation` matches on the contract for
/// exactly this reason, and reads the amount from `tokenId` when the legacy
/// shape put it there; the NFT gate matches on contract + `tokenId`, which the
/// ERC-721 reading already gives it.
EvmAssetChange _decodeTransfer(
  List<String> topics,
  String emitter,
  String data,
) {
  if (topics.length == 4) {
    return EvmAssetChange(
      assetType: 'ERC721',
      changeType: 'TRANSFER',
      from: _addressFromTopic(topics[1]),
      to: _addressFromTopic(topics[2]),
      contractAddress: emitter,
      tokenId: _wordAt(data, 0, fromTopic: topics[3]).toString(),
    );
  }
  if (topics.length != 3) {
    throw const EthereumRpcException('Transfer log has unexpected topic count');
  }
  final isNative = emitter == _nativeTransferEmitter;
  return EvmAssetChange(
    assetType: isNative ? 'NATIVE' : 'ERC20',
    changeType: 'TRANSFER',
    from: _addressFromTopic(topics[1]),
    to: _addressFromTopic(topics[2]),
    // Native moves have no token contract, matching what the send gate expects.
    contractAddress: isNative ? null : emitter,
    rawAmount: _wordAt(data, 0).toString(),
  );
}

/// `TransferSingle(operator, from, to, id, value)` — `id` and `value` are both
/// unindexed, so they are the first two words of `data`.
EvmAssetChange _decodeTransferSingle(
  List<String> topics,
  String emitter,
  String data,
) {
  if (topics.length != 4) {
    throw const EthereumRpcException(
      'TransferSingle log has unexpected topic count',
    );
  }
  return EvmAssetChange(
    assetType: 'ERC1155',
    changeType: 'TRANSFER',
    from: _addressFromTopic(topics[2]),
    to: _addressFromTopic(topics[3]),
    contractAddress: emitter,
    tokenId: _wordAt(data, 0).toString(),
    rawAmount: _wordAt(data, 1).toString(),
  );
}

/// `TransferBatch(operator, from, to, ids[], values[])` — two ABI dynamic
/// arrays, so `data` starts with their byte offsets. Emits one change per pair
/// so a batch that smuggles in a second token is still visible to the gate.
List<EvmAssetChange> _decodeTransferBatch(
  List<String> topics,
  String emitter,
  String data,
) {
  if (topics.length != 4) {
    throw const EthereumRpcException(
      'TransferBatch log has unexpected topic count',
    );
  }
  final ids = _readDynamicArray(data, wordIndex: 0);
  final values = _readDynamicArray(data, wordIndex: 1);
  if (ids.length != values.length) {
    throw const EthereumRpcException(
      'TransferBatch ids and values length mismatch',
    );
  }
  final from = _addressFromTopic(topics[2]);
  final to = _addressFromTopic(topics[3]);
  return [
    for (var i = 0; i < ids.length; i++)
      EvmAssetChange(
        assetType: 'ERC1155',
        changeType: 'TRANSFER',
        from: from,
        to: to,
        contractAddress: emitter,
        tokenId: ids[i].toString(),
        rawAmount: values[i].toString(),
      ),
  ];
}

/// `Approval(owner, spender, value|tokenId)`. The gate blocks any approval whose
/// spender is not the zero address, so the parties decide the outcome — but the
/// operand still has to be carried.
///
/// A zero-spender approval *is* allowed through (ERC-721 transfers clear their
/// own approval that way), and the gate then checks it against
/// `isIntendedAsset`. For the ERC-721 form that predicate matches on `tokenId`,
/// so dropping it here would make every OpenZeppelin-v4 NFT transfer fail as an
/// "unexpected asset".
EvmAssetChange _decodeApproval(
  List<String> topics,
  String emitter,
  String data,
) {
  final isNft = topics.length == 4;
  if (topics.length != 3 && !isNft) {
    throw const EthereumRpcException('Approval log has unexpected topic count');
  }
  return EvmAssetChange(
    assetType: isNft ? 'ERC721' : 'ERC20',
    changeType: 'APPROVE',
    from: _addressFromTopic(topics[1]),
    to: _addressFromTopic(topics[2]),
    contractAddress: emitter,
    tokenId: isNft ? evmHexToBigInt(topics[3]).toString() : null,
    rawAmount: isNft ? null : _wordAt(data, 0).toString(),
  );
}

/// `ApprovalForAll(owner, operator, approved)` — the operator-wide grant. A
/// `false` flag is a *revocation*, reported with the zero-address spender so the
/// gate's existing revocation carve-out treats it as harmless.
EvmAssetChange _decodeApprovalForAll(
  List<String> topics,
  String emitter,
  String data,
) {
  if (topics.length != 3) {
    throw const EthereumRpcException(
      'ApprovalForAll log has unexpected topic count',
    );
  }
  final granted = _wordAt(data, 0) != BigInt.zero;
  return EvmAssetChange(
    assetType: 'ERC721',
    changeType: 'APPROVE',
    from: _addressFromTopic(topics[1]),
    to: granted ? _addressFromTopic(topics[2]) : _zeroAddress,
    contractAddress: emitter,
  );
}

/// The 20-byte address packed in the low bytes of a 32-byte indexed topic.
String _addressFromTopic(String topic) {
  final clean = topic.startsWith('0x') ? topic.substring(2) : topic;
  if (clean.length != 64) {
    throw const EthereumRpcException('simulation log topic is not 32 bytes');
  }
  return '0x${clean.substring(24)}';
}

/// The 32-byte word at [index] of `data`. [fromTopic] short-circuits to an
/// indexed value instead, so callers can treat indexed and unindexed operands
/// the same way.
BigInt _wordAt(String data, int index, {String? fromTopic}) {
  if (fromTopic != null) return evmHexToBigInt(fromTopic);
  final clean = data.startsWith('0x') ? data.substring(2) : data;
  final start = index * 64;
  if (clean.length < start + 64) {
    throw const EthereumRpcException('simulation log data is truncated');
  }
  return evmHexToBigInt(clean.substring(start, start + 64));
}

/// Read the ABI dynamic `uint256[]` whose byte offset lives at [wordIndex].
List<BigInt> _readDynamicArray(String data, {required int wordIndex}) {
  final byteOffset = _wordAt(data, wordIndex);
  if (!byteOffset.isValidInt || byteOffset % BigInt.from(32) != BigInt.zero) {
    throw const EthereumRpcException('simulation log array offset invalid');
  }
  final head = byteOffset.toInt() ~/ 32;
  final length = _wordAt(data, head);
  if (!length.isValidInt || length > BigInt.from(1024)) {
    throw const EthereumRpcException('simulation log array length invalid');
  }
  return [for (var i = 1; i <= length.toInt(); i++) _wordAt(data, head + i)];
}
