import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import app_links

/// Scene delegate that hands the *cold-start* inbound link to the `app_links`
/// plugin.
///
/// `app_links` only implements the UIApplication delegate callbacks
/// (`application:openURL:options:` / `application:continue:restorationHandler:`).
/// This app runs the UIScene lifecycle (see `UIApplicationSceneManifest` in
/// Info.plist), where iOS delivers a launch URL to
/// `scene(_:willConnectTo:options:)` instead. Flutter routes that callback into
/// its own deep-linking path and never falls back to legacy plugin delegates,
/// so without this bridge `AppLinks.getInitialLink()` is always nil on iOS and
/// no cold-start link ever reaches `DeepLinkService`.
///
/// Warm links need no bridge: Flutter's scene delegate does fall back to
/// `application:openURL:options:` for `scene(_:openURLContexts:)` and
/// `scene(_:continue:)`, which `app_links` already handles.
class MallowSceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    // Custom scheme (`mallowwallet://`) first, then Universal Links.
    let url = connectionOptions.urlContexts.first?.url
      ?? connectionOptions.userActivities.compactMap { $0.webpageURL }.first
    if let url {
      AppLinks.shared.handleLink(url: url)
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Group that spawns the secondary engine for the AirPlay external-screen
  /// receiver. Lazy so it's only created once an AirPlay session needs it.
  lazy var castEngineGroup = FlutterEngineGroup(name: "art.mallow.cast", project: nil)

  private var privacyBlurView: UIVisualEffectView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Register custom plugins
    let airplayRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "AirPlayPlugin")!
    AirPlayPlugin.register(with: airplayRegistrar, engineGroup: castEngineGroup)

    let chromecastRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "IosChromecastPlugin")!
    IosChromecastPlugin.register(with: chromecastRegistrar)

    let vaultRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "MnemonicVaultChannel")!
    MnemonicVaultChannel.register(with: vaultRegistrar)

    let securityRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "SecurityChannel")!
    SecurityChannel.register(with: securityRegistrar)

    let timezoneRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "TimezoneChannel")!
    TimezoneChannel.register(with: timezoneRegistrar)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard privacyBlurView == nil, let window = self.window else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }
}
