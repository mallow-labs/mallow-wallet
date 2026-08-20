import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/sentry_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// These tests encode two promises we make on the store privacy forms.
///
/// 1. **Polarity.** The one "Share usage analytics" switch governs Sentry as
///    well as the product-analytics pipeline, and it stores opt-**OUT**.
///    Inverting it ships the exact opposite of what the user asked for, and
///    nothing at runtime would look wrong — hence a test in both directions.
/// 2. **Scrubbing.** Even with diagnostics on, a mnemonic or private key must
///    never survive the beforeSend/beforeBreadcrumb hooks. These are the last
///    line of defence before secrets leave the device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Dummy secrets only. The mnemonic is the well-known BIP-39 all-`abandon`
  // test vector and the keys below are hand-typed filler — no funds anywhere.
  const twelveWords =
      'abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon abandon abandon about';
  final twelveWordList = twelveWords.split(' ');
  final twentyFourWordList = [...List.filled(23, 'abandon'), 'art'];
  const hexKey =
      '0x4c7a1f9b2e5d8c3a6f0b9d4e7a2c5f8b1d4e7a0c3f6b9d2e5a8c1f4b7d0e3a69';
  const base58SecretKey =
      '5Kb8kLf9zgWQnogidDA76MzPL6TsZZY36hWXMssSzNyd'
      'YXYB9KF35VWyYcMuXcqNJcSrPHhLB2sbtCLxD3PkNb2y';

  group('analytics opt-out polarity', () {
    setUp(() async {
      // Config.sentryDsn is empty with no --dart-define, which keeps the real
      // SDK out of the test while still exercising every gate around it.
      await sl.reset();
    });

    tearDownAll(() async {
      await sl.reset();
    });

    Future<void> registerPrefs(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }

    test(
      'opted out (pref true) leaves Sentry disabled and never inits',
      () async {
        await registerPrefs({'pref_analytics_opt_out': true});

        var ranApp = false;
        await SentryService.init(appRunner: () => ranApp = true);

        expect(SentryService.analyticsEnabled, isFalse);
        expect(SentryService.isEnabled, isFalse);
        // The opt-out must not cost the user their app.
        expect(ranApp, isTrue);
      },
    );

    test('opted in (pref false) leaves diagnostics enabled', () async {
      await registerPrefs({'pref_analytics_opt_out': false});

      await SentryService.init(appRunner: () {});

      expect(SentryService.analyticsEnabled, isTrue);
    });

    test(
      'absent pref means opted in — diagnostics are on by default',
      () async {
        await registerPrefs({});

        await SentryService.init(appRunner: () {});

        expect(SentryService.analyticsEnabled, isTrue);
      },
    );

    test(
      'applyAnalyticsPreference tracks the pref in both directions',
      () async {
        await registerPrefs({'pref_analytics_opt_out': false});
        await SentryService.init(appRunner: () {});
        expect(SentryService.analyticsEnabled, isTrue);

        // Mid-session opt-out: the hub must go down now, not on next launch.
        await sl<PreferencesService>().setAnalyticsOptOut(true);
        await SentryService.applyAnalyticsPreference();
        expect(SentryService.analyticsEnabled, isFalse);
        expect(SentryService.isEnabled, isFalse);

        // ...and back on again.
        await sl<PreferencesService>().setAnalyticsOptOut(false);
        await SentryService.applyAnalyticsPreference();
        expect(SentryService.analyticsEnabled, isTrue);
      },
    );

    test('falls back to enabled when DI has no PreferencesService', () async {
      // e.g. the cast receiver isolate. Fail toward the declared
      // on-by-default posture rather than silently going dark.
      await SentryService.init(appRunner: () {});

      expect(SentryService.analyticsEnabled, isTrue);
    });
  });

  group('scrubString', () {
    test('redacts a 12-word mnemonic written as a phrase', () {
      final out = SentryService.scrubString('seed was $twelveWords ok');

      expect(out, contains('[REDACTED_MNEMONIC]'));
      expect(out, isNot(contains('about')));
    });

    test('redacts a mnemonic written as a stringified list', () {
      final out = SentryService.scrubString('$twelveWordList');

      expect(out, contains('[REDACTED_MNEMONIC]'));
      expect(out, isNot(contains('about')));
    });

    test('redacts a 0x-prefixed private key', () {
      // Regression: `\b[a-fA-F0-9]{64}\b` cannot match this — there is no word
      // boundary between the `x` and the first hex digit.
      final out = SentryService.scrubString('key=$hexKey done');

      expect(out, contains('[REDACTED_KEY]'));
      expect(out, isNot(contains('4c7a1f9b')));
    });

    test('redacts a base58 secret key whole, not truncated', () {
      final out = SentryService.scrubString('kp $base58SecretKey');

      expect(out, contains('[REDACTED_KEY]'));
      // A truncating redaction would leave the first/last 4 chars behind.
      expect(out, isNot(contains('5Kb8')));
      expect(out, isNot(contains('Nb2y')));
    });

    test('still only truncates a plain wallet address', () {
      const address = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

      final out = SentryService.scrubString('owner $address');

      expect(out, isNot(contains(address)));
      expect(out, contains('HN7c'));
    });
  });

  group('beforeSend / beforeBreadcrumb', () {
    test('scrubs a secret out of an event message', () {
      final event = SentryService.beforeSend(
        SentryEvent(message: SentryMessage('boom with $hexKey')),
        Hint(),
      );

      expect(event!.message!.formatted, contains('[REDACTED_KEY]'));
      expect(event.message!.formatted, isNot(contains('4c7a1f9b')));
    });

    test('scrubs a List<String> mnemonic in breadcrumb data (12 words)', () {
      // Per-entry scrubbing cannot catch this: every word is innocuous alone.
      final crumb = SentryService.beforeBreadcrumb(
        Breadcrumb(message: 'import', data: {'words': twelveWordList}),
        Hint(),
      );

      expect('${crumb!.data}', isNot(contains('about')));
      expect('${crumb.data}', contains('[REDACTED_MNEMONIC]'));
    });

    test('scrubs a List<String> mnemonic in breadcrumb data (24 words)', () {
      final crumb = SentryService.beforeBreadcrumb(
        Breadcrumb(message: 'import', data: {'words': twentyFourWordList}),
        Hint(),
      );

      expect('${crumb!.data}', isNot(contains('art')));
      expect('${crumb.data}', contains('[REDACTED_MNEMONIC]'));
    });

    test('scrubs a base58 secret key in breadcrumb data', () {
      final crumb = SentryService.beforeBreadcrumb(
        Breadcrumb(message: 'sign', data: {'payload': base58SecretKey}),
        Hint(),
      );

      expect('${crumb!.data}', isNot(contains('5Kb8')));
      expect('${crumb.data}', contains('[REDACTED_KEY]'));
    });
  });
}
