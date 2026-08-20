import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/twitter_connect_notifier.dart';

void main() {
  group('TwitterConnectNotifier.emitFromCallback', () {
    late TwitterConnectNotifier notifier;

    setUp(() => notifier = TwitterConnectNotifier());

    // The backend redirect carries the outcome as a `twitter=` query value;
    // mapping it wrong would either suppress the success refresh or show the
    // wrong toast, so each documented value must land on its status.
    test('maps success', () {
      expectLater(notifier.results, emits(TwitterConnectStatus.success));
      notifier.emitFromCallback('success');
    });

    test('maps error_user_exists to userExists', () {
      expectLater(notifier.results, emits(TwitterConnectStatus.userExists));
      notifier.emitFromCallback('error_user_exists');
    });

    test('maps explicit error', () {
      expectLater(notifier.results, emits(TwitterConnectStatus.error));
      notifier.emitFromCallback('error');
    });

    test('maps unrecognised values to error (fail closed)', () {
      expectLater(notifier.results, emits(TwitterConnectStatus.error));
      notifier.emitFromCallback('something_unexpected');
    });
  });
}
