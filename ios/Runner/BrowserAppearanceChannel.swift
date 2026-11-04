import Flutter
import UIKit

/// Puts the in-app browser's WKWebViews on the wallet's theme.
///
/// A WKWebView inherits its interface style from the views above it, which
/// follow the system. The wallet draws its own theme, which can differ, and
/// WebKit resolves both the page's `prefers-color-scheme` and its fallback
/// background (the band under the address bar on iOS 26) from that style.
///
/// `apply` overrides the interface style of each Flutter view controller's
/// root view. The browser's WebViews are platform views inside that view, so
/// they take the wallet's theme, including from the first paint of a WebView
/// created later. Flutter draws its own content in its own colours, and the
/// override sits below the view controller, whose traits are what Flutter
/// reports as the platform brightness.
///
/// The Dart side calls this when a browser WebView host mounts and when the
/// theme changes under it, so the view always holds the style of the browser
/// last shown.
class BrowserAppearanceChannel: NSObject, FlutterPlugin {
    static let channelName = "mallow_wallet/browser_appearance"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(BrowserAppearanceChannel(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "apply" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let args = call.arguments as? [String: Any],
              let dark = args["dark"] as? Bool else {
            result(FlutterError(code: "invalid_args", message: "Missing dark", details: nil))
            return
        }
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                guard let flutter = window.rootViewController as? FlutterViewController,
                      let view = flutter.viewIfLoaded,
                      view.overrideUserInterfaceStyle != style else { continue }
                view.overrideUserInterfaceStyle = style
            }
        }
        result(nil)
    }
}
