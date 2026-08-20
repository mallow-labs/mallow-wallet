import UIKit

/// Shared coordination point between `ExternalDisplaySceneDelegate` and the
/// AirPlay plugin.
///
/// UIKit instantiates the scene delegate when iOS connects an external
/// non-interactive display scene (e.g. AirPlay Mirroring to an Apple TV).
/// The plugin owns the secondary `FlutterEngine` lifecycle and needs to be
/// notified when such a scene becomes available — this host bridges the two
/// without leaking UIKit details into the plugin or coupling the scene
/// delegate to plugin internals.
///
/// All access is on the main thread (UIKit + FlutterMethodChannel both
/// dispatch to main), so no synchronization is needed.
final class ExternalDisplayHost {
    static let shared = ExternalDisplayHost()

    private(set) var windowScene: UIWindowScene?
    var onSceneConnect: ((UIWindowScene) -> Void)?
    var onSceneDisconnect: (() -> Void)?

    private init() {}

    func setScene(_ scene: UIWindowScene?) {
        let previous = windowScene
        windowScene = scene
        if let scene, previous == nil {
            onSceneConnect?(scene)
        } else if scene == nil, previous != nil {
            onSceneDisconnect?()
        }
    }
}
