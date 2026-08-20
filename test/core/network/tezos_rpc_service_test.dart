import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/network/tezos_rpc_service.dart';

/// Records the paths hit and returns canned responses keyed by path, so the
/// node-reading methods can be exercised without a live node. Any GET/POST to
/// an unscripted path throws, surfacing an unexpected request rather than
/// silently returning null.
class _StubTezosRpcService extends TezosRpcService {
  _StubTezosRpcService({
    this.getResponses = const {},
    this.postResponses = const {},
  }) : super.forBaseUrl('https://node.test');

  final Map<String, dynamic> getResponses;
  final Map<String, dynamic> postResponses;

  final List<String> getPaths = [];
  final List<({String path, Object body})> posts = [];

  @override
  Future<dynamic> rpcGet(String path) async {
    getPaths.add(path);
    if (!getResponses.containsKey(path)) {
      throw StateError('unexpected GET $path');
    }
    return getResponses[path];
  }

  @override
  Future<dynamic> rpcPost(String path, Object body) async {
    posts.add((path: path, body: body));
    if (!postResponses.containsKey(path)) {
      throw StateError('unexpected POST $path');
    }
    return postResponses[path];
  }
}

/// Stubs inclusion checks with a scripted list of outcomes; the last entry
/// repeats once the script is exhausted.
class _ConfirmStubTezosRpcService extends TezosRpcService {
  _ConfirmStubTezosRpcService({required this.outcomes})
    : super.forBaseUrl('https://node.test');

  final List<bool Function()> outcomes;
  int includedCalls = 0;

  @override
  Future<bool> isOperationIncluded(String opHash, {int lookback = 3}) async {
    final i = includedCalls < outcomes.length
        ? includedCalls
        : outcomes.length - 1;
    includedCalls++;
    return outcomes[i]();
  }
}

const _addr = 'tz1d1HPCWiRxb8N5q7nFRgvupy5E4dNJZiHG';

void main() {
  group('Config.tezosRpcUrl', () {
    // Tezos is pinned to mainnet in every environment (the backend balance
    // source is mainnet-only), so the mainnet node is selected regardless of
    // ENV and a TEZOS_RPC_URL override wins over it.
    tearDown(Config.debugOverrides.clear);

    test('defaults to the mainnet node, pinned in every environment', () {
      expect(Config.tezosRpcUrl, Config.tezosMainnetRpcUrl);
      expect(Config.isTezosMainnet, isTrue);
    });

    test('a TEZOS_RPC_URL override wins over the default', () {
      Config.debugOverrides['TEZOS_RPC_URL'] = 'https://my.node';
      expect(Config.tezosRpcUrl, 'https://my.node');
    });
  });

  group('contract reads', () {
    test('getCounter / nextCounter parse the quoted integer', () async {
      final rpc = _StubTezosRpcService(
        getResponses: {
          '/chains/main/blocks/head/context/contracts/$_addr/counter':
              '20716301',
        },
      );
      expect(await rpc.getCounter(_addr), 20716301);
      expect(await rpc.nextCounter(_addr), 20716302);
    });

    test('getBalance parses mutez as BigInt', () async {
      final rpc = _StubTezosRpcService(
        getResponses: {
          '/chains/main/blocks/head/context/contracts/$_addr/balance':
              '537964525221',
        },
      );
      expect(await rpc.getBalance(_addr), BigInt.from(537964525221));
    });

    test('isRevealed is true for a non-null manager_key', () async {
      final rpc = _StubTezosRpcService(
        getResponses: {
          '/chains/main/blocks/head/context/contracts/$_addr/manager_key':
              'edpkth813m5HQe5xs6cs6TDs43p5PDgF6FnLS9Hf2V4S5rQqLVoa4K',
        },
      );
      expect(await rpc.isRevealed(_addr), isTrue);
      expect(await rpc.getManagerKey(_addr), startsWith('edpk'));
    });

    test('isRevealed is false when manager_key is null (unrevealed)', () async {
      final rpc = _StubTezosRpcService(
        getResponses: {
          '/chains/main/blocks/head/context/contracts/$_addr/manager_key': null,
        },
      );
      expect(await rpc.isRevealed(_addr), isFalse);
    });

    test('getContractEntrypoints unwraps the `entrypoints` map', () async {
      const kt1 = 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o';
      final rpc = _StubTezosRpcService(
        getResponses: {
          '/chains/main/blocks/head/context/contracts/$kt1/entrypoints': {
            'unreachable': <dynamic>[],
            'entrypoints': {
              'transfer': {'prim': 'list'},
              'balance_of': {'prim': 'pair'},
            },
          },
        },
      );

      final entrypoints = await rpc.getContractEntrypoints(kt1);
      expect(entrypoints.keys, containsAll(['transfer', 'balance_of']));
      expect(entrypoints['transfer'], {'prim': 'list'});
    });

    test('getContractEntrypoints is empty for an unexpected body', () async {
      const kt1 = 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o';
      final rpc = _StubTezosRpcService(
        getResponses: {
          '/chains/main/blocks/head/context/contracts/$kt1/entrypoints': null,
        },
      );
      // Empty, not a throw: the caller turns "no FA transfer here" into its own
      // user-facing refusal, which is the same answer either way.
      expect(await rpc.getContractEntrypoints(kt1), isEmpty);
    });
  });

  group('runOperation', () {
    test('wraps contents with a dummy signature + chain id', () async {
      final rpc = _StubTezosRpcService(
        postResponses: {
          '/chains/main/blocks/head/helpers/scripts/run_operation': {
            'contents': <dynamic>[],
          },
        },
      );
      await rpc.runOperation(
        branch: 'BLbranch',
        contents: [
          {'kind': 'transaction'},
        ],
        chainId: 'NetXdQprcVkpaWU',
      );
      final body = rpc.posts.single.body as Map<String, dynamic>;
      expect(body['chain_id'], 'NetXdQprcVkpaWU');
      final operation = body['operation'] as Map<String, dynamic>;
      expect(operation['branch'], 'BLbranch');
      expect(operation['signature'], TezosRpcService.dummySignature);
      expect(operation['contents'], [
        {'kind': 'transaction'},
      ]);
    });
  });

  group('parseEstimate', () {
    test('sums gas (milligas→gas, rounded up) and storage across contents', () {
      final estimate = TezosRpcService.parseEstimate({
        'contents': [
          {
            'kind': 'reveal',
            'metadata': {
              'operation_result': {
                'status': 'applied',
                'consumed_milligas': '1000000', // 1000 gas
              },
            },
          },
          {
            'kind': 'transaction',
            'metadata': {
              'operation_result': {
                'status': 'applied',
                'consumed_milligas': '168501', // ceil → 169 gas
                'paid_storage_size_diff': '42',
              },
            },
          },
        ],
      });
      expect(estimate.success, isTrue);
      expect(estimate.consumedGas, 1000 + 169);
      expect(estimate.storageBytes, 42);
      expect(estimate.errors, isEmpty);
    });

    test('adds the allocation burn for a fresh destination', () {
      final estimate = TezosRpcService.parseEstimate({
        'contents': [
          {
            'metadata': {
              'operation_result': {
                'status': 'applied',
                'consumed_milligas': '1000',
                'paid_storage_size_diff': '0',
                'allocated_destination_contract': true,
              },
            },
          },
        ],
      });
      expect(estimate.storageBytes, TezosRpcService.allocationBurnBytes);
    });

    test('accumulates internal FA-transfer results', () {
      final estimate = TezosRpcService.parseEstimate({
        'contents': [
          {
            'metadata': {
              'operation_result': {
                'status': 'applied',
                'consumed_milligas': '2000', // 2 gas
              },
              'internal_operation_results': [
                {
                  'result': {
                    'status': 'applied',
                    'consumed_milligas': '5000', // 5 gas
                    'paid_storage_size_diff': '67',
                  },
                },
              ],
            },
          },
        ],
      });
      expect(estimate.consumedGas, 7);
      expect(estimate.storageBytes, 67);
    });

    test('reports failure and surfaces node errors', () {
      final estimate = TezosRpcService.parseEstimate({
        'contents': [
          {
            'metadata': {
              'operation_result': {
                'status': 'failed',
                'errors': [
                  {'id': 'proto.contract.balance_too_low'},
                ],
              },
            },
          },
        ],
      });
      expect(estimate.success, isFalse);
      expect(estimate.errors, hasLength(1));
    });
  });

  group('minimalFeeMutez', () {
    test('applies the protocol fee formula (base + gas + bytes)', () {
      // 100 mutez base + ceil((100×1000 + 1000×200)/1000) = 100 + 300 = 400.
      expect(
        TezosRpcService.minimalFeeMutez(
          gasLimit: 1000,
          operationSizeBytes: 200,
        ),
        400,
      );
    });

    test('rounds the nanotez total up to the next mutez', () {
      // nanotez = 100×1 + 1000×0 = 100 → ceil(100/1000) = 1 → 101 mutez.
      expect(
        TezosRpcService.minimalFeeMutez(gasLimit: 1, operationSizeBytes: 0),
        101,
      );
    });
  });

  group('injectOperation', () {
    test('sends the forged hex as a quoted JSON string', () async {
      final rpc = _StubTezosRpcService(
        postResponses: {'/injection/operation?chain=main': 'oojEcT'},
      );
      final hash = await rpc.injectOperation('abcd1234');
      expect(hash, 'oojEcT');
      expect(rpc.posts.single.body, jsonEncode('abcd1234'));
    });
  });

  group('waitForConfirmation', () {
    test('returns true once the operation is included', () async {
      final rpc = _ConfirmStubTezosRpcService(
        outcomes: [() => throw Exception('rpc blip'), () => false, () => true],
      );
      final confirmed = await rpc.waitForConfirmation(
        'op',
        pollInterval: Duration.zero,
      );
      expect(confirmed, isTrue);
      expect(rpc.includedCalls, 3);
    });

    test('times out to false when never included', () async {
      final rpc = _ConfirmStubTezosRpcService(outcomes: [() => false]);
      final confirmed = await rpc.waitForConfirmation(
        'op',
        timeout: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 5),
      );
      expect(confirmed, isFalse);
    });
  });
}
