/// Setup-only FA2 origination for the shadownet E2E harness — NOT app-code
/// verification.
///
/// Originates a copy of a proven shadownet SmartPy FA2 contract with the
/// funded test source as administrator and 1000 units of token 0 pre-seeded in
/// the initial ledger, so the FA2 transfer leg of
/// `test/integration/tezos_ghostnet_e2e_test.dart` has a token to move. Uses
/// REMOTE forging (RPC `helpers/forge/operations`) because origination is
/// outside the local forge's scope — acceptable for setup; the FA2 *transfer*
/// under test still goes through the local forge. Relies on `runOperation`'s
/// valid dummy signature (PR #94) for the simulation step.
///
/// Existing fixtures (only re-run this after a testnet reset or to mint a
/// fresh token supply):
///
///  - `KT1Xn4hDXpTfRoVvVhWpRvKrR8iV1ATQF3qJ` — canonical (token 0)
///  - `KT1BZiU6ntyLNhjoppFLS7doBzyKq4PUW5WG` — first copy (token 0)
///
/// `FA2_CODE_JSON` must point at a file holding the contract's script JSON
/// (`{"code": …, "storage": …}`); fetch it from an existing on-chain copy:
///
/// ```bash
/// curl https://rpc.shadownet.teztnets.com/chains/main/blocks/head/context\
/// /contracts/KT1Xn4hDXpTfRoVvVhWpRvKrR8iV1ATQF3qJ/script > /tmp/fa2_script.json
///
/// TEZOS_GHOSTNET_FUNDING_SEED_HEX=… \
/// FA2_CODE_JSON=/tmp/fa2_script.json \
///   flutter test test/integration/fa2_origination_setup_test.dart \
///   --tags live-ghostnet
/// ```
///
/// (Env names keep the `TEZOS_GHOSTNET_` prefix for continuity — Ghostnet is
/// decommissioned; the values are Shadownet's. See the E2E harness header.)
@Tags(['live-ghostnet'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/network/tezos_rpc_service.dart';

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  final seedHex =
      Platform.environment['TEZOS_GHOSTNET_FUNDING_SEED_HEX']?.trim() ?? '';
  final rpcUrl =
      Platform.environment['TEZOS_GHOSTNET_RPC_URL'] ??
      'https://rpc.shadownet.teztnets.com';
  final codePath = Platform.environment['FA2_CODE_JSON'] ?? '';
  final skip = seedHex.length == 64 && codePath.isNotEmpty
      ? false
      : 'setup-only: needs TEZOS_GHOSTNET_FUNDING_SEED_HEX and FA2_CODE_JSON';

  test(
    'originate FA2 with pre-seeded balance',
    () async {
      final seed = _hexToBytes(seedHex);
      final tz1 = await MultiChainDerivation.tezosAddressFromSeed(seed);
      final rpc = TezosRpcService.forBaseUrl(rpcUrl);

      final script =
          jsonDecode(File(codePath).readAsStringSync()) as Map<String, dynamic>;
      final code = script['code'];

      // Storage type of the template:
      // pair (pair %administrator (pair %all_tokens %ledger))
      //      (pair (pair %metadata %operators) (pair %paused %tokens))
      final storage = {
        'prim': 'Pair',
        'args': [
          {
            'prim': 'Pair',
            'args': [
              {'string': tz1},
              {
                'prim': 'Pair',
                'args': [
                  {'int': '1'},
                  [
                    {
                      'prim': 'Elt',
                      'args': [
                        {
                          'prim': 'Pair',
                          'args': [
                            {'string': tz1},
                            {'int': '0'},
                          ],
                        },
                        {'int': '1000'},
                      ],
                    },
                  ],
                ],
              },
            ],
          },
          {
            'prim': 'Pair',
            'args': [
              {
                'prim': 'Pair',
                'args': [<dynamic>[], <dynamic>[]],
              },
              {
                'prim': 'Pair',
                'args': [
                  {'prim': 'False'},
                  [
                    {
                      'prim': 'Elt',
                      'args': [
                        {'int': '0'},
                        {
                          'prim': 'Pair',
                          'args': [
                            <dynamic>[],
                            {'int': '1000'},
                          ],
                        },
                      ],
                    },
                  ],
                ],
              },
            ],
          },
        ],
      };

      final branch = await rpc.getBranchHash();
      final chainId = await rpc.getChainId();
      final counter = await rpc.nextCounter(tz1);

      Map<String, dynamic> op(String fee, int gas, int storageLimit) => {
        'kind': 'origination',
        'source': tz1,
        'fee': fee,
        'counter': '$counter',
        'gas_limit': '$gas',
        'storage_limit': '$storageLimit',
        'balance': '0',
        'script': {'code': code, 'storage': storage},
      };

      // Simulate at generous caps to learn real gas/storage.
      final sim = await rpc.runOperation(
        branch: branch,
        contents: [op('0', 500000, 60000)],
        chainId: chainId,
      );
      final overall = TezosRpcService.parseEstimate(sim);
      expect(
        overall.success,
        isTrue,
        reason: 'simulation failed: ${overall.errors}',
      );
      final result =
          (((sim['contents'] as List).first as Map)['metadata']
                  as Map)['operation_result']
              as Map;
      final gasUsed = (int.parse(result['consumed_milligas'] as String) / 1000)
          .ceil();
      final paidStorage = int.parse(
        (result['paid_storage_size_diff'] ?? '0') as String,
      );
      final originatedCount =
          ((result['originated_contracts'] as List?) ?? const []).length;
      final gas = gasUsed + TezosRpcService.gasSafetyMargin;
      final storageLimit =
          paidStorage +
          TezosRpcService.allocationBurnBytes * originatedCount +
          20;

      // Size the op with fee 0, then compute the minimal fee and re-forge.
      final sizingHex =
          await rpc.rpcPost(
                '/chains/main/blocks/head/helpers/forge/operations',
                {
                  'branch': branch,
                  'contents': [op('0', gas, storageLimit)],
                },
              )
              as String;
      final fee =
          TezosRpcService.minimalFeeMutez(
            gasLimit: gas,
            operationSizeBytes: sizingHex.length ~/ 2 + 64,
          ) +
          200;
      final forgedHex =
          await rpc.rpcPost(
                '/chains/main/blocks/head/helpers/forge/operations',
                {
                  'branch': branch,
                  'contents': [op('$fee', gas, storageLimit)],
                },
              )
              as String;

      final signed = await MultiChainDerivation.signTezosOperationWithSeed(
        seed,
        forgedHex,
      );
      final opHash = await rpc.injectOperation(signed.signedOperationHex);
      // ignore: avoid_print
      print(
        '[FA2-ORIGINATION] injected $opHash '
        '(fee $fee, gas $gas, storage $storageLimit)',
      );
      final included = await rpc.waitForConfirmation(opHash);
      expect(
        included,
        isTrue,
        reason: 'origination not included before timeout',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
