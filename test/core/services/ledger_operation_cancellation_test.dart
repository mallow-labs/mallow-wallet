import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';

void main() {
  test(
    'Given cancellation starts, a late Ledger reply cannot settle before teardown',
    () async {
      final operation = Completer<int>();
      final cancelled = Completer<void>();
      final teardown = Completer<void>();
      var teardownStarted = false;
      var settled = false;

      final result = raceLedgerOperationWithCancellation(
        operation: operation.future,
        cancelled: cancelled.future,
        cancelOperation: () {
          teardownStarted = true;
          return teardown.future;
        },
      );
      result.whenComplete(() => settled = true).ignore();

      cancelled.complete();
      await Future<void>.value();
      expect(teardownStarted, isTrue);

      operation.complete(7);
      await Future<void>.value();
      expect(settled, isFalse);

      teardown.complete();
      await expectLater(
        result,
        throwsA(isA<LedgerSigningCancelledException>()),
      );
      expect(settled, isTrue);
    },
  );

  test(
    'Given the Ledger replies first, later cancellation does not tear down',
    () async {
      final operation = Completer<int>();
      final cancelled = Completer<void>();
      var teardownCalls = 0;
      final result = raceLedgerOperationWithCancellation(
        operation: operation.future,
        cancelled: cancelled.future,
        cancelOperation: () async => teardownCalls++,
      );

      operation.complete(7);
      expect(await result, 7);
      cancelled.complete();
      await Future<void>.value();
      expect(teardownCalls, 0);
    },
  );
}
