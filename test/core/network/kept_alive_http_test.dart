import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/kept_alive_http.dart';

void main() {
  late HttpServer server;
  late List<int> ports;
  late String url;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    ports = [];
    server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      // Slow enough that warm-ups overlap and each needs its own socket.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
    });
    url = 'http://127.0.0.1:${server.port}/';
  });

  tearDown(() => server.close(force: true));

  test('pools idle connections for a minute, not 15 seconds', () {
    expect(keptAliveHttpClient().idleTimeout, const Duration(seconds: 60));
  });

  test('opens as many connections as asked, and keeps them', () async {
    final dio = keptAliveDio(BaseOptions());
    addTearDown(dio.close);
    await openConnections(dioHead(dio), url, connections: 3);
    expect(ports.toSet(), hasLength(3), reason: 'one socket each');

    // Three parallel calls afterwards find them open.
    await Future.wait([
      for (var i = 0; i < 3; i++)
        dio.post<void>(url, options: Options(validateStatus: (_) => true)),
    ]);
    expect(ports.toSet(), hasLength(3), reason: 'no new handshake');
  });

  test('a failed attempt is made once more, then given up', () async {
    var attempts = 0;
    await openConnections((_) async {
      attempts++;
      throw const SocketException('closed while away');
    }, url);
    expect(attempts, 2);
  });
}
