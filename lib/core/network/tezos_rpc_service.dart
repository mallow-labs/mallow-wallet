import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../config/environment.dart';

/// Parsed result of a Tezos `run_operation` simulation: the gas the operation
/// would consume, the storage it would burn, and whether it applied cleanly.
///
/// Consumers (the forge/sign layer) turn these into the `gas_limit`,
/// `storage_limit`, and `fee` fields of the real operation, typically after
/// adding safety margins (see [TezosRpcService.gasSafetyMargin]) and running
/// [TezosRpcService.minimalFeeMutez] with the forged operation's byte size.
@immutable
class TezosOperationEstimate {
  const TezosOperationEstimate({
    required this.success,
    required this.consumedGas,
    required this.storageBytes,
    this.errors = const [],
  });

  /// Whether every content (and internal result) applied. False when any
  /// result reported a non-`applied` status (`failed`, `backtracked`,
  /// `skipped`) — [errors] then carries the node's error objects.
  final bool success;

  /// Total gas units the simulated operation consumed across all contents and
  /// their internal results, rounded up from the node's milligas figures.
  final int consumedGas;

  /// Total storage the operation would burn, in bytes: the sum of every
  /// `paid_storage_size_diff` plus [allocationBurnBytes] for each destination
  /// the transfer would have to allocate (a fresh implicit account).
  final int storageBytes;

  /// Node error objects when [success] is false; empty otherwise.
  final List<dynamic> errors;
}

/// One content's contribution to a `run_operation` estimate — its gas/storage
/// plus whether it (and its internal results) applied. The per-content
/// breakdown [TezosRpcService.perContentEstimates] returns; [parseEstimate]
/// sums these for the aggregate, and the send flow uses each entry's gas/storage
/// to set that operation's real limits.
class TezosContentEstimate {
  const TezosContentEstimate({
    required this.gas,
    required this.storage,
    required this.applied,
    this.errors = const [],
  });

  final int gas;
  final int storage;
  final bool applied;
  final List<dynamic> errors;
}

/// Thin client for a Tezos node's JSON-RPC surface, scoped to what the Tezos
/// send flow needs: read the head branch + chain id, a contract's
/// counter / balance / reveal state, simulate an operation for
/// fee/gas/storage, inject a signed operation, and poll for its inclusion.
///
/// This is the *foundation* layer — it neither forges nor signs (that is
/// the forge/sign layer's job); it only speaks HTTP to the node. The active
/// node is [Config.tezosRpcUrl] (shadownet on dev/staging, mainnet on
/// production).
@lazySingleton
class TezosRpcService {
  /// DI-registered instance, wired to the environment's node.
  TezosRpcService() : this.forBaseUrl(Config.tezosRpcUrl);

  /// Explicit-endpoint constructor, for pinning a specific node (e.g.
  /// shadownet during verification) or tests.
  TezosRpcService.forBaseUrl(String baseUrl)
    : _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: {'Content-Type': 'application/json'},
        ),
      ) {
    if (kDebugMode) {
      debugPrint('[TezosRpc] node=$baseUrl');
    }
  }

  final Dio _dio;

  /// Well-known all-purpose dummy signature accepted by `run_operation`, which
  /// does not verify the signature but requires a syntactically valid one.
  static const String dummySignature =
      'edsigtXomBKi5CTRf5cjATJWSyaRvhfYNHqSUGrn4SdbYRcGwQrUGjzEfQD'
      'TuqHhuA8b2d8NarZjz8TRf65WkpQmo423BtomS8Q';

  /// Extra storage burn, in bytes, the protocol charges to allocate a fresh
  /// implicit account (the `allocated_destination_contract` case).
  static const int allocationBurnBytes = 257;

  /// Mutez the protocol burns per byte of storage (`cost_per_byte`). Unlike the
  /// baker `fee`, this is destroyed rather than paid, and it does **not** appear
  /// anywhere in [minimalFeeMutez] — so it must be added on top when quoting the
  /// user a total cost. At 250 mutez/byte, allocating a fresh destination
  /// ([allocationBurnBytes]) costs 0.06425 XTZ, ~160× a plain transfer's fee.
  static const int costPerByteMutez = 250;

  /// The mutez burned to write [storageBytes] bytes of storage.
  static int storageBurnMutez(int storageBytes) =>
      storageBytes * costPerByteMutez;

  /// Standard gas headroom to add to a simulated [TezosOperationEstimate.consumedGas]
  /// before using it as the operation's `gas_limit`. Simulation is exact, but a
  /// small buffer absorbs protocol rounding so the real operation never runs
  /// out of gas. Exposed for the forge layer.
  static const int gasSafetyMargin = 100;

  // --- Minimal-fee formula (protocol constants) -----------------------------
  // fee ≥ minimal_fees + minimal_nanotez_per_gas_unit × gas
  //         + minimal_nanotez_per_byte × operation_size
  // computed in nanotez, then rounded up to mutez.
  static const int _minimalFeeMutez = 100;
  static const int _feePerGasNanotez = 100;
  static const int _feePerByteNanotez = 1000;

  /// The minimal `fee` (in mutez) a baker will accept for an operation that
  /// consumes [gasLimit] gas and serializes to [operationSizeBytes] bytes.
  ///
  /// [operationSizeBytes] must be the size of the *forged and signed* operation
  /// — i.e. the forged branch+contents bytes plus the 64-byte signature — which
  /// the forge layer computes. Callers typically pass
  /// `gasLimit = consumedGas + gasSafetyMargin`.
  static int minimalFeeMutez({
    required int gasLimit,
    required int operationSizeBytes,
  }) {
    final nanotez =
        _feePerGasNanotez * gasLimit + _feePerByteNanotez * operationSizeBytes;
    return _minimalFeeMutez + (nanotez / 1000).ceil();
  }

  // --- Chain / block reads --------------------------------------------------

  /// Hash of the current head block — the `branch` of a fresh operation.
  Future<String> getBranchHash() async =>
      (await rpcGet('/chains/main/blocks/head/hash')) as String;

  /// Chain id of the connected node (e.g. `NetXdQprcVkpaWU` for mainnet),
  /// required in the `run_operation` request body.
  Future<String> getChainId() async =>
      (await rpcGet('/chains/main/chain_id')) as String;

  // --- Contract reads -------------------------------------------------------

  /// Current counter of [address]. The next operation from this account must
  /// use `counter + 1`; [nextCounter] returns that directly.
  Future<int> getCounter(String address) async {
    final raw = await rpcGet(
      '/chains/main/blocks/head/context/contracts/$address/counter',
    );
    return int.parse(raw as String);
  }

  /// The counter a new operation from [address] must carry (`counter + 1`).
  Future<int> nextCounter(String address) async =>
      (await getCounter(address)) + 1;

  /// Spendable balance of [address] in mutez (1 XTZ = 1_000_000 mutez).
  Future<BigInt> getBalance(String address) async {
    final raw = await rpcGet(
      '/chains/main/blocks/head/context/contracts/$address/balance',
    );
    return BigInt.parse(raw as String);
  }

  /// The revealed public key of [address], or null if the account has never
  /// revealed its manager key. A null result means a `reveal` op must be
  /// prepended before the first outgoing operation.
  Future<String?> getManagerKey(String address) async {
    final raw = await rpcGet(
      '/chains/main/blocks/head/context/contracts/$address/manager_key',
    );
    return raw as String?;
  }

  /// Whether [address] has already revealed its manager key. When false, the
  /// forge layer must prepend a `reveal` operation.
  Future<bool> isRevealed(String address) async =>
      (await getManagerKey(address)) != null;

  /// The named entrypoints of the originated contract [address], as a map of
  /// entrypoint name → its Michelson parameter type.
  ///
  /// This is how the send flow tells an FA2 token contract from an FA1.2 one:
  /// both expose `transfer`, and the wire the balances route speaks carries no
  /// standard field, so the contract's own parameter type is the only
  /// authority. Calling the wrong shape is not merely a failed send — the two
  /// take different arguments, so it is a malformed operation.
  Future<Map<String, dynamic>> getContractEntrypoints(String address) async {
    final raw = await rpcGet(
      '/chains/main/blocks/head/context/contracts/$address/entrypoints',
    );
    final entrypoints = raw is Map ? raw['entrypoints'] : null;
    if (entrypoints is! Map) return const {};
    return entrypoints.cast<String, dynamic>();
  }

  // --- Simulation (fee / gas / storage) -------------------------------------

  /// Simulate [contents] against the node via `run_operation` and return the
  /// raw response map. Prefer [estimateOperation], which parses the result into
  /// a [TezosOperationEstimate].
  ///
  /// [branch] is a recent block hash ([getBranchHash]); [chainId] is
  /// [getChainId]. A dummy [dummySignature] is attached — `run_operation` does
  /// not verify it. The caller's [contents] must already carry high enough
  /// `gas_limit` / `storage_limit` (e.g. protocol maxima) so the simulation is
  /// not itself gas-starved.
  Future<Map<String, dynamic>> runOperation({
    required String branch,
    required List<Map<String, dynamic>> contents,
    required String chainId,
  }) async {
    final result = await rpcPost(
      '/chains/main/blocks/head/helpers/scripts/run_operation',
      {
        'operation': {
          'branch': branch,
          'contents': contents,
          'signature': dummySignature,
        },
        'chain_id': chainId,
      },
    );
    return (result as Map).cast<String, dynamic>();
  }

  /// Simulate [contents] and parse the gas/storage/success outcome.
  Future<TezosOperationEstimate> estimateOperation({
    required String branch,
    required List<Map<String, dynamic>> contents,
    required String chainId,
  }) async {
    final response = await runOperation(
      branch: branch,
      contents: contents,
      chainId: chainId,
    );
    return parseEstimate(response);
  }

  /// Parse a `run_operation` response into a [TezosOperationEstimate], summing
  /// gas and storage across every content and its internal results.
  ///
  /// Static + pure so it can be unit-tested against captured node payloads
  /// without a live node.
  static TezosOperationEstimate parseEstimate(Map<String, dynamic> response) {
    var gas = 0;
    var storage = 0;
    var success = true;
    final errors = <dynamic>[];
    for (final content in perContentEstimates(response)) {
      gas += content.gas;
      storage += content.storage;
      if (!content.applied) {
        success = false;
        errors.addAll(content.errors);
      }
    }
    return TezosOperationEstimate(
      success: success,
      consumedGas: gas,
      storageBytes: storage,
      errors: errors,
    );
  }

  /// Per-content `(gas, storage, applied, errors)` from a `run_operation`
  /// response, in the order the contents were sent (one entry per content, even
  /// malformed ones, so callers can align results to the operations they sent).
  ///
  /// The single source of truth for the milligas→gas rounding and storage-burn
  /// accounting (`paid_storage_size_diff`, fresh-account allocation, internal
  /// originations) shared by [parseEstimate] and the send flow's per-operation
  /// limit planning. Static + pure for unit-testing against captured payloads.
  static List<TezosContentEstimate> perContentEstimates(
    Map<String, dynamic> response,
  ) {
    final out = <TezosContentEstimate>[];
    final contents = response['contents'];
    if (contents is! List) return out;
    for (final content in contents) {
      var gas = 0;
      var storage = 0;
      var applied = true;
      final errors = <dynamic>[];
      void accumulate(Map<String, dynamic> result) {
        final status = result['status'];
        if (status != 'applied') {
          applied = false;
          final errs = result['errors'];
          if (errs is List) errors.addAll(errs);
        }
        final milligas = result['consumed_milligas'];
        if (milligas is String) gas += (int.parse(milligas) / 1000).ceil();
        final paid = result['paid_storage_size_diff'];
        if (paid is String) storage += int.parse(paid);
        if (result['allocated_destination_contract'] == true) {
          storage += allocationBurnBytes;
        }
        // An origination (unlikely for a plain transfer, but FA calls can spawn
        // internal originations) also allocates a contract per entry.
        final originated = result['originated_contracts'];
        if (originated is List) {
          storage += allocationBurnBytes * originated.length;
        }
      }

      if (content is Map) {
        final metadata = content['metadata'];
        if (metadata is Map) {
          final result = metadata['operation_result'];
          if (result is Map) accumulate(result.cast<String, dynamic>());
          final internal = metadata['internal_operation_results'];
          if (internal is List) {
            for (final entry in internal) {
              final r = entry is Map ? entry['result'] : null;
              if (r is Map) accumulate(r.cast<String, dynamic>());
            }
          }
        }
      }
      out.add(
        TezosContentEstimate(
          gas: gas,
          storage: storage,
          applied: applied,
          errors: errors,
        ),
      );
    }
    return out;
  }

  // --- Injection / confirmation ---------------------------------------------

  /// Inject an already-forged and -signed operation (hex-encoded
  /// forged-bytes ++ signature) and return the resulting operation hash.
  ///
  /// The node expects the hex as a bare JSON string, so it is JSON-encoded
  /// (quoted) here.
  Future<String> injectOperation(String signedOperationHex) async {
    final result = await rpcPost(
      '/injection/operation?chain=main',
      // A JSON string value, not a Dio-encoded map: send the quoted hex.
      jsonEncode(signedOperationHex),
    );
    return result as String;
  }

  /// Whether [opHash] appears in any of the last [lookback] blocks. Manager
  /// operations land in validation pass 3, but every pass is scanned so this
  /// stays correct regardless of operation kind. Scanning a small window (not
  /// just head) tolerates the head advancing between polls.
  Future<bool> isOperationIncluded(String opHash, {int lookback = 3}) async {
    for (var i = 0; i < lookback; i++) {
      final block = i == 0 ? 'head' : 'head~$i';
      try {
        final hashes = await rpcGet(
          '/chains/main/blocks/$block/operation_hashes',
        );
        if (hashes is List) {
          for (final pass in hashes) {
            if (pass is List && pass.contains(opHash)) return true;
          }
        }
      } catch (_) {
        // A missing block (head~i before genesis on a fresh chain) or a
        // transient error just means "not found here" — keep scanning.
      }
    }
    return false;
  }

  /// Poll until [opHash] is included in a block or [timeout] elapses. Returns
  /// true on inclusion, false on timeout.
  ///
  /// A transient RPC failure mid-poll is swallowed (the operation is already
  /// injected and usually lands) — only the timeout ends the wait early,
  /// mirroring the Solana confirmation loop.
  Future<bool> waitForConfirmation(
    String opHash, {
    Duration timeout = const Duration(seconds: 120),
    Duration pollInterval = const Duration(seconds: 6),
  }) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      try {
        if (await isOperationIncluded(opHash)) return true;
      } catch (_) {}
      await Future<void>.delayed(pollInterval);
    }
    return false;
  }

  // --- HTTP seams -----------------------------------------------------------
  // Every node call funnels through these two methods so tests can stub the
  // network by overriding them (there is no Dio mock adapter in the project).

  /// GET [path] on the node and return the decoded JSON body (a String for
  /// scalar endpoints, a List/Map for structured ones, or null).
  @protected
  @visibleForTesting
  Future<dynamic> rpcGet(String path) async {
    try {
      final response = await _dio.get<dynamic>(path);
      return response.data;
    } on DioException catch (e) {
      throw TezosRpcException.fromDio('GET', path, e);
    }
  }

  /// POST [body] to [path] on the node and return the decoded JSON body.
  @protected
  @visibleForTesting
  Future<dynamic> rpcPost(String path, Object body) async {
    try {
      final response = await _dio.post<dynamic>(path, data: body);
      return response.data;
    } on DioException catch (e) {
      throw TezosRpcException.fromDio('POST', path, e);
    }
  }
}

/// Thrown when an injected operation was never observed in a block before
/// [TezosRpcService.waitForConfirmation]'s timeout elapsed.
///
/// **Indeterminate, not failed.** Injection already succeeded and a timeout
/// does not undo it — the operation usually lands, we just stopped watching.
/// [toString] is the user-facing copy and deliberately does not invite a
/// retry: re-injecting an in-flight transfer is how a user ends up sending
/// twice. Mirrors `SolanaTransactionUnconfirmedException`.
class TezosOperationUnconfirmedException implements Exception {
  const TezosOperationUnconfirmedException(this.opHash);

  /// The injected operation hash. Always surface it (explorer / Activity) — it
  /// is the only way the user can find out what actually happened.
  final String opHash;

  @override
  String toString() =>
      'This transaction may still land. Check Activity or the explorer before '
      'sending again.';
}

/// A failed HTTP call to the Tezos node, carrying the endpoint, host, and status
/// so a bad node is diagnosable at a glance instead of surfacing as an opaque
/// Dio/`ParallelWaitError`. A 401/403 on `run_operation` means the node blocks
/// the simulation the send flow needs — switch [Config.tezosRpcUrl] (or set
/// `TEZOS_RPC_URL`) to a node that permits it (e.g. TzKT's).
class TezosRpcException implements Exception {
  const TezosRpcException({
    required this.method,
    required this.path,
    this.host,
    this.statusCode,
    this.detail,
  });

  factory TezosRpcException.fromDio(
    String method,
    String path,
    DioException e,
  ) {
    final data = e.response?.data;
    final detail = data is String
        ? data
        : (data != null ? jsonEncode(data) : e.message);
    return TezosRpcException(
      method: method,
      path: path,
      host: e.requestOptions.uri.host,
      statusCode: e.response?.statusCode,
      detail: detail == null ? null : _clip(detail.toString()),
    );
  }

  final String method;
  final String path;
  final String? host;
  final int? statusCode;
  final String? detail;

  static String _clip(String s) =>
      s.length > 200 ? '${s.substring(0, 200)}…' : s;

  /// The last path segment names the operation (`run_operation`, `hash`,
  /// `counter`, `manager_key`, `chain_id`) for a readable one-line message.
  String get _endpoint => path.split('?').first.split('/').last;

  bool get _blocked => statusCode == 401 || statusCode == 403;

  @override
  String toString() {
    final at = host == null ? '' : ' on $host';
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    if (_blocked) {
      return 'Tezos node$at blocked $_endpoint$status — this node does not '
          'permit the request. Point TEZOS_RPC_URL at a node that does.';
    }
    return 'Tezos node$at failed $method $_endpoint$status'
        '${detail == null ? '' : ' — $detail'}';
  }
}
