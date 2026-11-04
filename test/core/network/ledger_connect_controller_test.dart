import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/ledger_connect_controller.dart';

void main() {
  test('cancellation resolves a pending Ledger connection request', () async {
    final controller = LedgerConnectController();
    final cancelled = Completer<void>();
    final requestReceived = Completer<LedgerConnectRequest>();
    final subscription = controller.requests.listen(requestReceived.complete);

    final result = controller.requestConnection(
      'ledger-address',
      cancelled: cancelled.future,
    );
    final request = await requestReceived.future;
    cancelled.complete();

    expect(await result, isFalse);
    expect(request.completer.isCompleted, isTrue);

    await subscription.cancel();
    controller.dispose();
  });
}
