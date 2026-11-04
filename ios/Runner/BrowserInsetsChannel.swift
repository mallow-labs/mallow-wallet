import Flutter
import UIKit
import WebKit

/// Tells the in-app browser's WKWebView which edges the browser chrome covers.
///
/// The browser lays its WebView out under the whole screen and floats its bars
/// over the page. Two settings together make those edges unsafe, as Safari's
/// own bars are:
///
/// - `WKWebView.obscuredContentInsets` (iOS 26) shrinks the page's layout
///   viewport, so fixed and sticky elements stay clear of the bars.
/// - The scroll view's `contentInset` adds the same room to the scroll range.
///   Without it the end of a page can never scroll out from under the bottom
///   bar: the obscured insets alone do not extend the range.
///
/// Older systems have no public equivalent of the first; the browser keeps
/// its WebView between the bars there instead (`supported` answers false).
///
/// The WebView is a Flutter platform view, so it is found by the frame the
/// Dart side laid it out at (logical pixels equal points), never by a handle.
class BrowserInsetsChannel: NSObject, FlutterPlugin {
    static let channelName = "mallow_wallet/browser_insets"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(BrowserInsetsChannel(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "supported":
            if #available(iOS 26.0, *) {
                result(true)
            } else {
                result(false)
            }
        case "apply":
            guard let args = call.arguments as? [String: Any],
                  let x = args["x"] as? Double,
                  let y = args["y"] as? Double,
                  let width = args["width"] as? Double,
                  let height = args["height"] as? Double,
                  let top = args["top"] as? Double,
                  let bottom = args["bottom"] as? Double else {
                result(FlutterError(code: "invalid_args", message: "Missing frame or insets", details: nil))
                return
            }
            guard #available(iOS 26.0, *) else {
                result(0)
                return
            }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            let insets = UIEdgeInsets(
                top: max(0, top), left: 0, bottom: max(0, bottom), right: 0
            )
            lastRequest = (frame, insets)
            result(apply(insets, toWebViewsAt: frame))
            // A replacement WebView can attach after an outgoing one at the
            // same frame took this apply; catch it on a later pass unless a
            // newer request has superseded this one.
            for delay in [0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let last = self.lastRequest,
                          last.frame == frame, last.insets == insets else { return }
                    _ = self.apply(insets, toWebViewsAt: frame, fresh: true)
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private var lastRequest: (frame: CGRect, insets: UIEdgeInsets)?

    /// The scroll insets each browser WebView must keep, held weakly by view.
    private let guards = NSMapTable<UIScrollView, ScrollInsetGuard>.weakToStrongObjects()

    /// The WebViews the last walk found at a frame. The browser sends insets
    /// on every frame while its address bar animates, so those calls reuse
    /// this instead of walking every window again.
    private var cache: (frame: CGRect, webViews: [WeakWebView])?

    @available(iOS 26.0, *)
    private func apply(
        _ insets: UIEdgeInsets, toWebViewsAt frame: CGRect, fresh: Bool = false
    ) -> Int {
        let matches = webViews(matching: frame, fresh: fresh)
        for webView in matches {
            if webView.obscuredContentInsets != insets {
                webView.obscuredContentInsets = insets
            }
            let scrollView = webView.scrollView
            if let existing = guards.object(forKey: scrollView) {
                existing.insets = insets
            } else {
                guards.setObject(ScrollInsetGuard(scrollView, insets: insets), forKey: scrollView)
            }
        }
        return matches.count
    }

    /// [webViews(matching:)], from [cache] while every view in it is still
    /// attached at [frame] and [fresh] is false.
    private func webViews(matching frame: CGRect, fresh: Bool) -> [WKWebView] {
        if !fresh, let cache, cache.frame == frame {
            let views = cache.webViews.compactMap(\.view)
            if !views.isEmpty, views.count == cache.webViews.count,
               views.allSatisfy({ Self.isAttached($0, at: frame) }) {
                return views
            }
        }
        let found = Self.webViews(matching: frame)
        cache = (frame, found.map(WeakWebView.init))
        return found
    }

    private static func isAttached(_ webView: WKWebView, at frame: CGRect) -> Bool {
        guard let window = webView.window else { return false }
        return matches(webView.convert(webView.bounds, to: window), frame)
    }

    private static func matches(_ rect: CGRect, _ frame: CGRect) -> Bool {
        abs(rect.minX - frame.minX) <= 1 && abs(rect.minY - frame.minY) <= 1 &&
            abs(rect.width - frame.width) <= 1 && abs(rect.height - frame.height) <= 1
    }

    /// Every attached WKWebView whose frame, in its window, is [frame] to
    /// within a point.
    private static func webViews(matching frame: CGRect) -> [WKWebView] {
        var found: [WKWebView] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                collect(in: window, window: window, frame: frame, into: &found)
            }
        }
        return found
    }

    private static func collect(
        in view: UIView, window: UIWindow, frame: CGRect, into found: inout [WKWebView]
    ) {
        if let webView = view as? WKWebView {
            if matches(webView.convert(webView.bounds, to: window), frame) {
                found.append(webView)
            }
            // A WKWebView's own subviews are WebKit's; no browser lives there.
            return
        }
        for subview in view.subviews {
            collect(in: subview, window: window, frame: frame, into: &found)
        }
    }
}

private struct WeakWebView {
    weak var view: WKWebView?

    init(_ view: WKWebView) {
        self.view = view
    }
}

/// Holds a scroll view's content and indicator insets at [insets]. The
/// WebView plugin rewrites `contentInset` whenever it sets the view's frame
/// (and around the keyboard), which would otherwise drop the scroll room the
/// bars need until the next apply.
private final class ScrollInsetGuard {
    var insets: UIEdgeInsets {
        didSet { enforce() }
    }

    private weak var scrollView: UIScrollView?
    private var observation: NSKeyValueObservation?

    init(_ scrollView: UIScrollView, insets: UIEdgeInsets) {
        self.scrollView = scrollView
        self.insets = insets
        observation = scrollView.observe(\.contentInset) { [weak self] _, _ in
            self?.enforce()
        }
        enforce()
    }

    private func enforce() {
        guard let scrollView else { return }
        if scrollView.contentInset != insets {
            scrollView.contentInset = insets
        }
        if scrollView.verticalScrollIndicatorInsets != insets {
            scrollView.verticalScrollIndicatorInsets = insets
        }
    }
}
