import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/utils/local_timezone.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalTimezone.name', () {
    const channel = MethodChannel('mallow_wallet/timezone');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('returns the IANA name the platform reports', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'America/New_York';
      });

      expect(await LocalTimezone.name(), 'America/New_York');
      expect(calls.single.method, 'getLocalTimezone');
    });

    // `_initLocalTimezone` in main.dart wraps this call in a try/catch that
    // leaves the app on UTC. That fallback only runs if a bad platform reply
    // actually throws — returning null instead would hand `tz.getLocation` a
    // null and crash startup before the error screen exists.
    test(
      'throws rather than yielding null when the platform returns nothing',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async => null);

        expect(LocalTimezone.name(), throwsA(isA<StateError>()));
      },
    );

    // Web and unit tests have no native handler; the same UTC fallback covers
    // them, so the absence of a handler must surface as a throw too.
    test(
      'throws MissingPluginException when no handler is registered',
      () async {
        expect(LocalTimezone.name(), throwsA(isA<MissingPluginException>()));
      },
    );
  });
}
