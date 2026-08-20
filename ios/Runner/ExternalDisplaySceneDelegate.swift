import UIKit

/// Scene delegate for `UIWindowSceneSessionRoleExternalDisplayNonInteractive`.
///
/// UIKit instantiates this when iOS attaches a non-interactive external
/// display scene (e.g. AirPlay Mirroring to an Apple TV). This delegate
/// only hands the scene off to `ExternalDisplayHost`; the AirPlay plugin
/// observes the host and mounts the receiver `FlutterEngine` window on the
/// scene when it has media to display.
class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplayHost.shared.setScene(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplayHost.shared.setScene(nil)
    }
}
