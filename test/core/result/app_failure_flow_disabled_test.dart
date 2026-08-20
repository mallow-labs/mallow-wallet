import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';

/// a remote kill must not arrive at
/// the UI wearing a cancel's clothes. Swap and the staking pipeline drop
/// cancels *silently*, so a `flowDisabled` folded into
/// [AppFailureKind.cancelled] means the operator's incident copy — the only
/// thing that can tell a user whether their funds are safe — never renders.
void main() {
  const operatorCopy = 'Swaps are paused while we fix a router bug.';

  group('AppFailure.from — kill switch', () {
    test('maps TransactionFlowDisabledException to flowDisabled, verbatim', () {
      final failure = AppFailure.from(
        const TransactionFlowDisabledException(operatorCopy),
      );

      expect(failure.kind, AppFailureKind.flowDisabled);
      expect(failure.message, operatorCopy);
      expect(failure.isFlowDisabled, isTrue);
      // The load-bearing half: every silent-cancel branch keys off this, so a
      // `true` here is exactly how the message gets swallowed.
      expect(failure.isCancelled, isFalse);
    });

    test('re-routes a cancel exception that wraps a flowDisabled outcome', () {
      // Defense in depth for throw sites not yet converted to the kill-specific
      // exception: the outcome they carry still says it was a kill, so
      // classification must not trust the exception type alone.
      final failure = AppFailure.from(
        const TransactionAuthCancelledException(
          TransactionAuthOutcome.flowDisabled(operatorCopy),
        ),
      );

      expect(failure.kind, AppFailureKind.flowDisabled);
      expect(failure.message, operatorCopy);
      expect(failure.isCancelled, isFalse);
    });

    test('a genuine cancel outcome still classifies as cancelled', () {
      final failure = AppFailure.from(
        const TransactionAuthCancelledException(
          TransactionAuthOutcome.cancelled,
        ),
      );

      expect(failure.kind, AppFailureKind.cancelled);
      expect(failure.isFlowDisabled, isFalse);
    });

    test('prefixedWith leaves the operator copy untouched', () {
      // "Listing failed: Buying is paused, your funds are safe" is not
      // acceptable copy — the flow-disabled path renders the operator's message as sent.
      const failure = AppFailure.flowDisabled(operatorCopy);

      expect(failure.prefixedWith('Listing failed').message, operatorCopy);
    });

    test('survives Result.guard, which is how blocs see it', () async {
      final result = await Result.guard<void>(
        () async => throw const TransactionFlowDisabledException(operatorCopy),
      );

      expect(result.errorOrNull?.kind, AppFailureKind.flowDisabled);
      expect(result.errorOrNull?.message, operatorCopy);
    });
  });
}
