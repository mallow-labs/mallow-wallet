import Flutter
import Foundation

/// Native lookup for the device's IANA time-zone name (e.g. `America/New_York`).
///
/// This replaces the `flutter_timezone` package. That plugin's public header
/// carries `#import <CoreLocation/CoreLocation.h>` while its implementation
/// never calls a single CoreLocation API. Clang module autolinking promotes
/// that unused import into `-framework CoreLocation` on the Runner binary, and
/// App Store validation rejects the upload with ITMS-90683 (missing
/// `NSLocationWhenInUseUsageDescription`) because its scan reads linked
/// frameworks, not runtime behavior. The import is still present upstream as of
/// flutter_timezone 5.1.0, so upgrading does not clear it.
///
/// `TimeZone.current.identifier` is Foundation-only and already an IANA
/// identifier, which is exactly what the Dart `timezone` package's
/// `tz.getLocation` expects.
class TimezoneChannel: NSObject, FlutterPlugin {
    static let channelName = "mallow_wallet/timezone"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = TimezoneChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getLocalTimezone":
            result(TimeZone.current.identifier)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
