import 'package:flutter/services.dart';

/// Reads the device's IANA time-zone name from the platform.
///
/// Backed by `TimezoneChannel` on both platforms (`ios/Runner/`,
/// `android/app/src/main/kotlin/com/mallow/wallet/android/`). This exists
/// instead of the `flutter_timezone` package because that plugin's iOS header
/// imports CoreLocation without ever calling it, which autolinks
/// CoreLocation.framework into the app binary and gets the App Store upload
/// rejected with ITMS-90683 — a demand for an `NSLocationWhenInUseUsageDescription`
/// purpose string covering a permission the wallet never requests.
class LocalTimezone {
  const LocalTimezone._();

  static const _channel = MethodChannel('mallow_wallet/timezone');

  /// The current IANA zone name, e.g. `America/New_York`.
  ///
  /// Throws [MissingPluginException] on platforms with no native handler
  /// (web, unit tests) and [PlatformException] if the native lookup fails.
  /// Callers are expected to fall back to UTC — see `_initLocalTimezone` in
  /// `main.dart`.
  static Future<String> name() async {
    final name = await _channel.invokeMethod<String>('getLocalTimezone');
    if (name == null) {
      throw StateError('Platform returned no timezone name');
    }
    return name;
  }
}
