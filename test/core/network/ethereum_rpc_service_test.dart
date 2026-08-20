import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web3dart/web3dart.dart';

class _MockWeb3Client extends Mock implements Web3Client {}

void main() {
  late _MockWeb3Client client;
  late EthereumRpcService rpc;

  setUp(() {
    client = _MockWeb3Client();
    rpc = EthereumRpcService.withClient(client);
  });

  tearDown(Config.debugOverrides.clear);

  // WHY: the send funnel claims the pending-transaction tracker's resolution
  // notice for the slot it is waiting on and marks it *reported* when this call
  // returns — which permanently suppresses the tracker's confirmed/reverted
  // toast for that nonce. Returning normally on a deadline therefore silently
  // drops an under-priced transaction that mines a minute later from every
  // surface the user has. The timeout must be distinguishable from inclusion.
  group('waitForConfirmation', () {
    test('throws EvmInclusionTimeoutException when no receipt arrives', () {
      when(
        () => client.getTransactionReceipt(any()),
      ).thenAnswer((_) async => null);

      expect(
        rpc.waitForConfirmation(
          '0xhash',
          timeout: const Duration(milliseconds: 10),
          interval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<EvmInclusionTimeoutException>()),
      );
    });

    test('returns normally once a receipt is read', () async {
      when(() => client.getTransactionReceipt(any())).thenAnswer(
        (_) async => TransactionReceipt(
          transactionHash: Uint8List(0),
          transactionIndex: 0,
          blockHash: Uint8List(0),
          blockNumber: const BlockNum.exact(1),
          cumulativeGasUsed: BigInt.zero,
          status: true,
        ),
      );

      await expectLater(
        rpc.waitForConfirmation(
          '0xhash',
          timeout: const Duration(milliseconds: 10),
          interval: const Duration(milliseconds: 1),
        ),
        completes,
      );
    });
  });

  // WHY: both endpoints used to fall back to a route derived from
  // RPC_PROXY_BASE_URL, which is a *Solana* proxy. That guess only resolves
  // where the same proxy also serves EVM routes — anywhere else it pointed the
  // transfer safety gate at whatever answered that path, and a build that
  // forgot the variable was indistinguishable from a proxy having a bad day.
  // The defaults are gone, so an unset variable must be named in the error.
  // Matching on the message is the load-bearing part: every failure in these
  // methods is wrapped as EthereumRpcException, so a type-only expectation
  // still passes if the guard is deleted and the empty URL reaches http.
  group('required EVM endpoints', () {
    test('simulateAssetChanges names EVM_SIMULATION_URL when unset', () {
      Config.debugOverrides['EVM_SIMULATION_URL'] = '';

      expect(Config.ethereumSimulationUrl, isEmpty);
      expect(
        rpc.simulateAssetChanges(
          from: '0x0000000000000000000000000000000000000001',
          to: '0x0000000000000000000000000000000000000002',
          data: '0x',
        ),
        throwsA(
          isA<EthereumRpcException>().having(
            (e) => e.message,
            'message',
            contains('EVM_SIMULATION_URL'),
          ),
        ),
      );
    });

    test('getSuggestedGasFees names EVM_GAS_API_URL when unset', () {
      Config.debugOverrides['EVM_GAS_API_URL'] = '';

      expect(Config.ethereumGasApiBaseUrl, isEmpty);
      expect(
        rpc.getSuggestedGasFees(),
        throwsA(
          isA<EthereumRpcException>().having(
            (e) => e.message,
            'message',
            contains('EVM_GAS_API_URL'),
          ),
        ),
      );
    });
  });
}
