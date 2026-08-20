import Flutter
import UIKit

/// Flutter plugin for iOS AirPlay casting.
///
/// Method channel: com.mallow.wallet/airplay
/// Methods: startDiscovery, stopDiscovery, connectToDevice, disconnect,
///          loadMedia, updateOverlay, pause, resume, stop
///
/// Event channel: com.mallow.wallet/airplay_events
/// Events: {type: 'devices', devices: [{id, name}]}
///         {type: 'session', state: 'connecting'|'connected'|'disconnected'|'error'}
///         {type: 'mirror', state: 'active'|'inactive'}
///
/// The 'mirror' event tracks whether iOS has actually attached an external
/// display scene (i.e. the user enabled Screen Mirroring from Control
/// Center). 'session' goes 'connected' the moment the Flutter side dispatches
/// connectToDevice — independent of whether mirroring is live yet. The UI
/// uses 'mirror' to show / hide the "open Control Center → Screen Mirroring"
/// prompt and to auto-close it once content can actually reach the TV.
///
/// Mirrors a `CastReceiverView` Flutter widget onto an external scene (the
/// TV that AirPlay Mirroring is targeting) by spawning a secondary
/// `FlutterEngine` from a shared `FlutterEngineGroup` and mounting its
/// `FlutterViewController` on a `UIWindow` bound to that scene. The phone
/// keeps its own UI undisturbed.
///
/// AirPlay routing here is **screen mirroring**, not media routing — the user
/// enables it from Control Center → Screen Mirroring → Apple TV. The OS
/// then surfaces the mirror as a non-interactive external display scene,
/// which `ExternalDisplaySceneDelegate` registers with `ExternalDisplayHost`.
/// This plugin observes that host and mounts the receiver onto the scene.
class AirPlayPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let engineGroup: FlutterEngineGroup
    private var eventSink: FlutterEventSink?

    private var secondaryEngine: FlutterEngine?
    private var secondaryWindow: UIWindow?
    private var receiverChannel: FlutterMethodChannel?

    /// Last "show" payload — replayed once the secondary engine signals
    /// `ready`, so the first slide isn't dropped during engine boot.
    private var pendingShow: Any?
    /// Last "overlay" payload — same idea, in case the user toggles before
    /// any media is shown.
    private var pendingOverlay: Any?

    init(engineGroup: FlutterEngineGroup) {
        self.engineGroup = engineGroup
        super.init()
        wireExternalDisplayHost()
    }

    // MARK: - FlutterPlugin

    /// Required by FlutterPlugin but unused — call `register(with:engineGroup:)`
    /// from AppDelegate. Fails loudly if invoked from GeneratedPluginRegistrant.
    static func register(with registrar: FlutterPluginRegistrar) {
        fatalError(
            "AirPlayPlugin requires an engineGroup; call register(with:engineGroup:)"
        )
    }

    static func register(
        with registrar: FlutterPluginRegistrar,
        engineGroup: FlutterEngineGroup
    ) {
        let instance = AirPlayPlugin(engineGroup: engineGroup)

        let methodChannel = FlutterMethodChannel(
            name: "com.mallow.wallet/airplay",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "com.mallow.wallet/airplay_events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startDiscovery":
            // iOS doesn't expose AirPlay devices to apps; surface a single
            // virtual entry so the picker has something to render.
            eventSink?([
                "type": "devices",
                "devices": [["id": "airplay", "name": "AirPlay"]],
            ])
            result(nil)

        case "stopDiscovery":
            result(nil)

        case "connectToDevice":
            connect()
            result(nil)

        case "loadMedia":
            pendingShow = call.arguments
            forwardToReceiver("show", arguments: call.arguments)
            result(nil)

        case "updateOverlay":
            pendingOverlay = call.arguments
            forwardToReceiver("overlay", arguments: call.arguments)
            result(nil)

        case "preload":
            // Best-effort: forward to the receiver engine if it's up so it
            // can warm its painting cache. No need to cache the payload —
            // missing a preload only costs a redundant fetch later.
            forwardToReceiver("preload", arguments: call.arguments)
            result(nil)

        case "pause", "resume":
            // No-op for now: the slideshow timer pauses sender-side, which
            // keeps the current slide on screen. Per-video pause via Chewie
            // could be wired in a follow-up.
            result(nil)

        case "stop":
            forwardToReceiver("clear", arguments: nil)
            result(nil)

        case "disconnect":
            disconnect()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(
        withArguments arguments: Any?,
        eventSink: @escaping FlutterEventSink
    ) -> FlutterError? {
        self.eventSink = eventSink
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Private

    private func wireExternalDisplayHost() {
        ExternalDisplayHost.shared.onSceneConnect = { [weak self] scene in
            guard let self = self else { return }
            self.mount(on: scene)
            self.eventSink?(["type": "mirror", "state": "active"])
        }
        ExternalDisplayHost.shared.onSceneDisconnect = { [weak self] in
            guard let self = self else { return }
            self.teardown()
            // Emit mirror change before the session event so any UI keyed on
            // the mirror flag has time to dismiss before the bloc transitions
            // away from CastActive.
            self.eventSink?(["type": "mirror", "state": "inactive"])
            self.eventSink?(["type": "session", "state": "disconnected"])
        }
    }

    private func connect() {
        // Mount immediately if mirroring is already active; otherwise wait
        // for `ExternalDisplayHost.onSceneConnect`. Either way, emit
        // `connected` so the bloc transitions to CastActive and queues
        // `loadMedia`. The plugin caches that payload (see `pendingShow`)
        // and replays it once the receiver engine signals `ready`.
        let mirrorActive = ExternalDisplayHost.shared.windowScene != nil
        if let scene = ExternalDisplayHost.shared.windowScene {
            mount(on: scene)
        }
        // Mirror state is emitted BEFORE session=connected so the bloc's
        // synchronous `isExternalDisplayActive` getter reflects the current
        // state by the time `CastActive` is emitted — UI listeners that fire
        // on the transition into `CastActive` can check the mirror flag
        // immediately without racing against a follow-up event.
        eventSink?([
            "type": "mirror",
            "state": mirrorActive ? "active" : "inactive",
        ])
        eventSink?(["type": "session", "state": "connected"])
    }

    private func disconnect() {
        eventSink?(["type": "session", "state": "disconnected"])
        teardown()
        pendingShow = nil
        pendingOverlay = nil
    }

    private func mount(on windowScene: UIWindowScene) {
        guard secondaryEngine == nil else { return }

        let engine = engineGroup.makeEngine(
            withEntrypoint: "castReceiverMain",
            libraryURI: nil
        )
        // Plugins used by CastReceiverView (extended_image, video_player via
        // chewie, path_provider, etc.) need to be registered on the secondary
        // engine independently of the main engine.
        GeneratedPluginRegistrant.register(with: engine)

        let viewController = FlutterViewController(
            engine: engine,
            nibName: nil,
            bundle: nil
        )
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = viewController
        window.isHidden = false

        let channel = FlutterMethodChannel(
            name: "com.mallow.wallet/airplay_receiver",
            binaryMessenger: engine.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            if call.method == "ready" {
                // Receiver isolate is up — push whatever state we have.
                if let show = self.pendingShow {
                    self.receiverChannel?.invokeMethod("show", arguments: show)
                }
                if let overlay = self.pendingOverlay {
                    self.receiverChannel?.invokeMethod("overlay", arguments: overlay)
                }
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        self.secondaryEngine = engine
        self.secondaryWindow = window
        self.receiverChannel = channel
    }

    private func teardown() {
        secondaryWindow?.isHidden = true
        secondaryWindow?.rootViewController = nil
        secondaryWindow = nil
        receiverChannel?.setMethodCallHandler(nil)
        receiverChannel = nil
        secondaryEngine?.destroyContext()
        secondaryEngine = nil
    }

    private func forwardToReceiver(_ method: String, arguments: Any?) {
        receiverChannel?.invokeMethod(method, arguments: arguments)
    }

    deinit {
        // ExternalDisplayHost is a singleton, so its callbacks outlive the
        // plugin. Clear them to keep the host's state tidy in case the
        // plugin is re-registered (the [weak self] guards already prevent
        // calls into a deallocated instance).
        ExternalDisplayHost.shared.onSceneConnect = nil
        ExternalDisplayHost.shared.onSceneDisconnect = nil
        teardown()
    }
}
