import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';

class _Wallet extends Mock implements WalletManager {}

/// A JSON-RPC endpoint on loopback that records what reaches it.
class _Node {
  _Node._(this._server) {
    _server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        method: request.method,
        uri: request.uri,
        rpc: body.isEmpty ? null : jsonDecode(body) as Map<String, Object?>,
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply));
      await request.response.close();
    });
  }

  static Future<_Node> start() async =>
      _Node._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final requests = <({String method, Uri uri, Map<String, Object?>? rpc})>[];
  int status = 200;
  Object? reply = {'jsonrpc': '2.0', 'id': 1, 'result': 'ok'};

  String get url => 'http://127.0.0.1:${_server.port}/';
  List<Object?> get methods => [for (final r in requests) r.rpc?['method']];

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _Node simulation;
  late _Node node;
  late SolanaDappAdapter adapter;

  setUp(() async {
    simulation = await _Node.start();
    node = await _Node.start();
    Config.debugOverrides
      ..['API_BASE_URL'] = 'https://api.example'
      ..['SOLANA_SIMULATION_URL'] = simulation.url
      ..['SOLANA_MAINNET_RPC_URL'] = node.url
      ..['RPC_PROXY_BASE_URL'] = node.url;
    adapter = SolanaDappAdapter(walletManager: _Wallet());
  });

  tearDown(() async {
    Config.debugOverrides.clear();
    await simulation.close();
    await node.close();
  });

  test(
    'a review\'s reads go to SOLANA_SIMULATION_URL, the rest do not',
    () async {
      for (final method in SolanaDappAdapter.simulationMethods) {
        expect(await adapter.rpc('solana:mainnet', method, [<String>[]]), 'ok');
      }
      await adapter.rpc('solana:mainnet', 'getSignatureStatuses', [<String>[]]);
      expect(
        simulation.methods,
        unorderedEquals(SolanaDappAdapter.simulationMethods),
      );
      expect(node.methods, ['getSignatureStatuses']);
      // DAS keeps its own params shape.
      expect(
        simulation.requests
            .singleWhere((r) => r.rpc?['method'] == 'getAssetBatch')
            .rpc?['params'],
        {'ids': <String>[]},
      );
    },
  );

  test('a refusing endpoint falls back to the usual path', () async {
    simulation.status = 401;
    expect(
      await adapter.rpc('solana:mainnet', 'simulateTransaction', ['tx', {}]),
      'ok',
    );
    expect(simulation.methods, ['simulateTransaction']);
    expect(node.methods, ['simulateTransaction']);
  });

  test('an answer that is not JSON-RPC falls back too', () async {
    simulation.reply = {'unexpected': true};
    await adapter.rpc('solana:mainnet', 'getMultipleAccounts', [<String>[]]);
    expect(node.methods, ['getMultipleAccounts']);
  });

  test('DAS falls back to the RPC proxy, not the plain node', () async {
    final proxy = await _Node.start();
    addTearDown(proxy.close);
    Config.debugOverrides['RPC_PROXY_BASE_URL'] = proxy.url;
    simulation.status = 503;
    await adapter.rpc('solana:mainnet', 'getAssetBatch', [<String>[]]);
    expect(proxy.methods, ['getAssetBatch']);
    expect(node.requests, isEmpty);
  });

  test('a JSON-RPC error is the answer, not a reason to ask again', () async {
    simulation.reply = {
      'jsonrpc': '2.0',
      'id': 1,
      'error': {'code': -32602, 'message': 'bad'},
    };
    await expectLater(
      adapter.rpc('solana:mainnet', 'simulateTransaction', ['tx', {}]),
      throwsA(
        isA<SolanaDappRpcException>().having((e) => e.code, 'code', -32602),
      ),
    );
    expect(node.requests, isEmpty);
  });

  test('devnet is selected on the simulation endpoint', () async {
    Config.debugOverrides['ENV'] = 'staging';
    await adapter.rpc('solana:devnet', 'simulateTransaction', ['tx', {}]);
    expect(simulation.requests.single.uri.queryParameters, {
      'network': 'devnet',
    });
  });

  test('unset, a review reads where it always did', () async {
    Config.debugOverrides.remove('SOLANA_SIMULATION_URL');
    expect(SolanaDappAdapter.simulationUrl('solana:mainnet'), isNull);
    await adapter.rpc('solana:mainnet', 'simulateTransaction', ['tx', {}]);
    expect(simulation.requests, isEmpty);
    expect(node.methods, ['simulateTransaction']);
  });

  test('warming opens the review endpoint without a JSON-RPC call', () async {
    await SolanaDappAdapter.warmConnections();
    expect(simulation.requests, hasLength(3));
    expect(simulation.requests.map((r) => r.method).toSet(), {'HEAD'});
    expect(node.requests, isEmpty);
  });

  test('unset, warming opens the usual hosts instead', () async {
    Config.debugOverrides.remove('SOLANA_SIMULATION_URL');
    await SolanaDappAdapter.warmConnections();
    expect(simulation.requests, isEmpty);
    expect(node.requests, hasLength(3));
  });
}
