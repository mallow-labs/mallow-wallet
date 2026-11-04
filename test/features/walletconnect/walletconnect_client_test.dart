import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_client.dart';
import 'package:reown_core/reown_core.dart';

void main() {
  test('A relay refusal keeps its code and the relay reason', () {
    expect(
      describeRelayError(
        const ReownCoreError(
          code: 3000,
          message: 'Unauthorized: origin not allowed',
        ),
      ),
      '3000: Unauthorized: origin not allowed',
    );
  });

  test('A refused handshake keeps only its HTTP status, never the URL', () {
    final reason = describeRelayError(
      Exception(
        "Connection to 'https://relay.example?auth=SECRETJWT&projectId=p' "
        'was not upgraded to websocket, HTTP status code: 403',
      ),
    );
    expect(reason, 'HTTP 403');
  });

  test('Anything else is summarised without its text', () {
    expect(describeRelayError(TimeoutException('x')), 'timeout');
    expect(
      describeRelayError(StateError('wss://relay?auth=SECRETJWT')),
      'no connection',
    );
    expect(describeRelayError(null), isNull);
  });
}
