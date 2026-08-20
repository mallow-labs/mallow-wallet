import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/cast/services/cast_failure.dart';

/// Cast failures reach the user through a sheet, not a log. These tests pin
/// the contract that makes that copy usable: every sentence has to name what
/// the tester can do next, and no native plumbing (error codes, exception
/// class names) may leak into it — that leak is what made the original
/// "Connecting…" hang impossible to diagnose from the device.
void main() {
  group('castConnectFailureMessage', () {
    const knownCodes = [
      'NO_DISCOVERY',
      'DEVICE_NOT_FOUND',
      'SESSION_FAILED',
      'NO_SESSION',
      'CAST_UNAVAILABLE',
    ];

    test('never leaks a native code or exception type', () {
      for (final code in [...knownCodes, 'SOMETHING_NEW']) {
        final message = castConnectFailureMessage(
          PlatformException(code: code, message: 'raw native detail'),
          deviceName: 'Living Room TV',
        );
        expect(message, isNot(contains(code)));
        expect(message, isNot(contains('PlatformException')));
        expect(message, isNot(contains('raw native detail')));
        expect(message, endsWith('.'));
      }
    });

    test('names the device the user tapped', () {
      final message = castConnectFailureMessage(
        PlatformException(code: 'DEVICE_NOT_FOUND'),
        deviceName: 'Living Room TV',
      );
      expect(message, contains('Living Room TV'));
    });

    test('falls back to a neutral noun for an unnamed device', () {
      final message = castConnectFailureMessage(
        PlatformException(code: 'DEVICE_NOT_FOUND'),
        deviceName: '  ',
      );
      // "  is no longer on the network" would read as a rendering bug.
      expect(message, contains('that screen'));
    });

    test(
      'maps the MultiCastService StateError, not just PlatformException',
      () {
        final message = castConnectFailureMessage(
          StateError('No backend for device abc (CastDeviceType.chromecast)'),
          deviceName: 'Living Room TV',
        );
        expect(message, isNot(contains('Bad state')));
        expect(message, isNot(contains('No backend')));
        expect(message, contains('Living Room TV'));
      },
    );
  });

  group('castDiscoveryFailureMessage', () {
    test('states the Play-services cause so an empty list is explained', () {
      final message = castDiscoveryFailureMessage(
        PlatformException(code: 'CAST_UNAVAILABLE', message: 'no play svc'),
      );
      expect(message, contains('Google Play services'));
      expect(message, isNot(contains('CAST_UNAVAILABLE')));
    });

    test('unknown failures still get actionable copy', () {
      final message = castDiscoveryFailureMessage(Exception('boom'));
      expect(message, contains('Wi-Fi'));
      expect(message, isNot(contains('boom')));
    });
  });
}
