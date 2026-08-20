import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/marketplace_action_flow.dart';
import 'package:mallow_wallet/core/services/transaction_flow_state.dart';

void main() {
  group('txFlowSink', () {
    // Regression guard: the parameterless flow states (`preparing`,
    // `broadcasting`) must be emitted as `<P, S>`, not the `<Never, Never>`
    // a bare `const TxFlowPreparing()` infers inside the generic adapter.
    // BLoC equality includes runtimeType, so a `<Never, Never>` state never
    // equals the bloc's declared `<P, S>` state — listeners (and bloc_test
    // `expect`) silently stop matching.
    test('emits states parameterized with <P, S>, not <Never, Never>', () {
      final emitted = <TransactionFlowState<int, String>>[];
      final sink = txFlowSink<int, String>(emitted.add);

      sink.onPreparing();
      sink.onReady(7);
      sink.onSigning('Approve in your wallet');
      sink.onBroadcasting();
      sink.onSuccess('sig123', 'ok');

      expect(emitted[0].runtimeType, TxFlowPreparing<int, String>);
      expect(emitted[1].runtimeType, TxFlowReady<int, String>);
      expect(emitted[2].runtimeType, TxFlowSigning<int, String>);
      expect(emitted[3].runtimeType, TxFlowBroadcasting<int, String>);
      expect(emitted[4].runtimeType, TxFlowSuccess<int, String>);
    });

    test('threads the ready / signing / success payloads through', () {
      final emitted = <TransactionFlowState<int, String>>[];
      txFlowSink<int, String>(emitted.add)
        ..onReady(42)
        ..onSigning('staged')
        ..onSuccess('sig', 'done');

      expect((emitted[0] as TxFlowReady<int, String>).data, 42);
      expect((emitted[1] as TxFlowSigning<int, String>).stage, 'staged');
      final success = emitted[2] as TxFlowSuccess<int, String>;
      expect(success.signature, 'sig');
      expect(success.result, 'done');
    });
  });
}
