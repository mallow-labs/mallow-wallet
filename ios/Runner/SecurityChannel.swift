import Flutter
import UIKit

/// Native handler for clipboard auto-expiration.
///
/// An in-process Timer does not fire while the app is backgrounded or
/// suspended, so a Dart-side clear is unreliable for sensitive data like
/// seed phrases. UIPasteboard.setItems(_:options:) with .expirationDate
/// hands clearing responsibility to the OS, which honors it regardless of
/// app lifecycle state. .localOnly also keeps the entry off Universal
/// Clipboard so it does not propagate to other Apple devices.
class SecurityChannel: NSObject, FlutterPlugin {
    static let channelName = "mallow_wallet/security"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = SecurityChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "copyToClipboardWithExpiration":
            guard let args = call.arguments as? [String: Any],
                  let text = args["text"] as? String else {
                result(FlutterError(code: "invalid_args", message: "Missing text", details: nil))
                return
            }
            let seconds = (args["expirationSeconds"] as? Double) ?? 60.0
            let expiration = Date(timeIntervalSinceNow: seconds)
            UIPasteboard.general.setItems(
                [["public.utf8-plain-text": text]],
                options: [
                    UIPasteboard.OptionsKey.expirationDate: expiration,
                    UIPasteboard.OptionsKey.localOnly: true,
                ]
            )
            result(nil)
        case "clearClipboard":
            UIPasteboard.general.items = []
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
