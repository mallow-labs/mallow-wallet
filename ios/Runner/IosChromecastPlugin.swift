import Flutter
import GoogleCast
import UIKit

/// Flutter plugin for Chromecast on iOS via the Google Cast SDK.
///
/// Method channel: com.mallow.wallet/cast_ios
/// Methods: startDiscovery, stopDiscovery, connectToDevice, disconnect,
///          loadMedia, updateOverlay, pause, resume, stop
///
/// Event channel: com.mallow.wallet/cast_ios_events
/// Events: {type: 'devices', devices: [{id, name}]}
///         {type: 'session', state: 'connecting'|'connected'|'disconnected'|'error'}
///
/// Mirrors the Android `CastPlugin.kt` 1:1 — same receiver app id, same
/// custom namespace, same JSON message shape — so a single HTML receiver
/// registered on the Cast developer console serves both platforms.
///
/// SDK init is **lazy**: `GCKCastContext.setSharedInstance` (and the
/// downstream local-network permission prompt) only runs the first time
/// `startDiscovery` is invoked from Dart, i.e. when the user actually taps
/// the Cast button.
class IosChromecastPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
    GCKDiscoveryManagerListener, GCKSessionManagerListener
{
    /// Receiver app id, supplied by Dart on the first `startDiscovery`
    /// (`Config.castReceiverAppId`), which falls back to mallow's own receiver
    /// when `CAST_RECEIVER_APP_ID` is unset. A fork you distribute registers
    /// its own receiver and sets that variable, or its users cast into
    /// mallow's receiver. See TRADEMARK.md.
    private var appId: String?
    private static let namespace = "urn:x-cast:art.mallow.cast"

    private var eventSink: FlutterEventSink?
    private var initialized = false
    private var castChannel: GCKCastChannel?

    /// Cached payloads replayed once a session is active so the first slide
    /// after connect isn't dropped while the receiver app is loading.
    private var pendingShow: [String: Any]?
    private var pendingOverlay: [String: Any]?

    // MARK: - FlutterPlugin

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = IosChromecastPlugin()

        let methodChannel = FlutterMethodChannel(
            name: "com.mallow.wallet/cast_ios",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "com.mallow.wallet/cast_ios_events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startDiscovery":
            // Recorded before init; `ensureInitialized` is a no-op afterwards, so
            // the id that arrives with the FIRST call is the one that sticks.
            if appId == nil {
                appId = (call.arguments as? [String: Any])?["appId"] as? String
            }
            ensureInitialized()
            pushDeviceList()
            result(nil)

        case "stopDiscovery":
            // Keep the SDK warm — re-starting discovery is cheap.
            result(nil)

        case "connectToDevice":
            let deviceId = (call.arguments as? [String: Any])?["deviceId"] as? String ?? ""
            connectToDevice(deviceId, result: result)

        case "disconnect":
            disconnect()
            result(nil)

        case "loadMedia":
            forwardToReceiver(type: "show", args: call.arguments, result: result)

        case "updateOverlay":
            forwardToReceiver(type: "overlay", args: call.arguments, result: result)

        case "preload":
            // Best-effort: drop silently if no session, since missing a
            // preload only costs a redundant fetch later.
            let urls = (call.arguments as? [String: Any])?["urls"] as? [String] ?? []
            sendNamespaceMessage(
                payload: ["type": "preload", "urls": urls],
                result: result
            )

        case "pause":
            sendControlMessage(type: "pause", result: result)

        case "resume":
            sendControlMessage(type: "resume", result: result)

        case "stop":
            sendControlMessage(type: "stop", result: result)

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

    // MARK: - SDK lifecycle

    private func ensureInitialized() {
        if initialized { return }
        guard let appId, !appId.isEmpty else {
            // Refuse rather than guess. An empty receiver id is not a degraded
            // mode — the SDK rejects it — so failing here names the cause
            // instead of surfacing as "no devices found".
            NSLog("[Cast] startDiscovery without an appId; not initialising")
            return
        }
        initialized = true

        let options = GCKCastOptions(receiverApplicationID: appId)
        // Don't hijack the device's volume buttons.
        options.physicalVolumeButtonsWillControlDeviceVolume = false
        GCKCastContext.setSharedInstanceWith(options)

        let context = GCKCastContext.sharedInstance()
        context.discoveryManager.add(self)
        context.sessionManager.add(self)
        context.discoveryManager.startDiscovery()
    }

    // MARK: - Discovery

    private func pushDeviceList() {
        let manager = GCKCastContext.sharedInstance().discoveryManager
        var devices: [[String: String]] = []
        for i in 0..<manager.deviceCount {
            let device = manager.device(at: i)
            devices.append([
                "id": device.deviceID,
                "name": device.friendlyName ?? "Chromecast",
            ])
        }
        eventSink?(["type": "devices", "devices": devices])
    }

    // MARK: - Session

    private func connectToDevice(_ deviceId: String, result: @escaping FlutterResult) {
        let manager = GCKCastContext.sharedInstance().discoveryManager
        var found: GCKDevice?
        for i in 0..<manager.deviceCount {
            let device = manager.device(at: i)
            if device.deviceID == deviceId {
                found = device
                break
            }
        }
        guard let device = found else {
            result(FlutterError(
                code: "DEVICE_NOT_FOUND",
                message: "Device \(deviceId) not found",
                details: nil
            ))
            return
        }
        let started = GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
        if !started {
            result(FlutterError(
                code: "SESSION_FAILED",
                message: "Failed to start cast session",
                details: nil
            ))
            return
        }
        result(nil)
    }

    private func disconnect() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        pendingShow = nil
        pendingOverlay = nil
    }

    // MARK: - Custom-namespace messaging

    private func forwardToReceiver(
        type: String,
        args: Any?,
        result: @escaping FlutterResult
    ) {
        guard let argsMap = args as? [String: Any] else {
            result(FlutterError(code: "BAD_ARGS", message: "Expected map", details: nil))
            return
        }
        if type == "show" {
            pendingShow = argsMap
        } else if type == "overlay" {
            pendingOverlay = argsMap
        }
        sendNamespaceMessage(payload: payloadFor(type: type, args: argsMap), result: result)
    }

    private func sendControlMessage(type: String, result: @escaping FlutterResult) {
        sendNamespaceMessage(payload: ["type": type], result: result)
    }

    private func payloadFor(type: String, args: [String: Any]) -> [String: Any] {
        // Keep the wire format identical to Android (CastPlugin.kt) so the
        // HTML receiver doesn't need to branch on sender platform.
        switch type {
        case "show":
            return [
                "type": "show",
                "item": args["item"] ?? [:],
                "overlay": args["overlay"] ?? [:],
            ]
        case "overlay":
            return [
                "type": "overlay",
                "overlay": args["overlay"] ?? [:],
            ]
        default:
            return ["type": type]
        }
    }

    private func sendNamespaceMessage(payload: [String: Any], result: @escaping FlutterResult) {
        guard let channel = castChannel, channel.isConnected else {
            // Session not yet active (or already torn down). The next
            // session start will replay pendingShow / pendingOverlay.
            result(nil)
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let message = String(data: data, encoding: .utf8) else {
                result(FlutterError(
                    code: "ENCODE_FAILED",
                    message: "Could not encode JSON",
                    details: nil
                ))
                return
            }
            var sendError: GCKError?
            let queued = channel.sendTextMessage(message, error: &sendError)
            if !queued {
                result(FlutterError(
                    code: "SEND_FAILED",
                    message: sendError?.localizedDescription ?? "Cast channel rejected message",
                    details: nil
                ))
                return
            }
            result(nil)
        } catch {
            result(FlutterError(
                code: "SEND_FAILED",
                message: "\(error)",
                details: nil
            ))
        }
    }

    // MARK: - GCKDiscoveryManagerListener

    func didUpdateDeviceList() {
        pushDeviceList()
    }

    // MARK: - GCKSessionManagerListener

    func sessionManager(_ sessionManager: GCKSessionManager, willStart session: GCKSession) {
        emitSession(state: "connecting")
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        attachChannel(to: session)
        emitSession(state: "connected")
        replayPending()
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didResumeCastSession session: GCKCastSession
    ) {
        attachChannel(to: session)
        emitSession(state: "connected")
        replayPending()
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didEnd session: GCKSession,
        withError error: Error?
    ) {
        castChannel = nil
        emitSession(state: error == nil ? "disconnected" : "error")
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didSuspend session: GCKSession,
        with reason: GCKConnectionSuspendReason
    ) {
        emitSession(state: "disconnected")
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didFailToStart session: GCKSession,
        withError error: Error
    ) {
        emitSession(state: "error")
    }

    private func attachChannel(to session: GCKSession) {
        let channel = GCKCastChannel(namespace: Self.namespace)
        if let castSession = session as? GCKCastSession {
            castSession.add(channel)
        }
        self.castChannel = channel
    }

    private func replayPending() {
        if let show = pendingShow {
            sendNamespaceMessage(payload: payloadFor(type: "show", args: show)) { _ in }
        }
        if let overlay = pendingOverlay {
            sendNamespaceMessage(payload: payloadFor(type: "overlay", args: overlay)) { _ in }
        }
    }

    private func emitSession(state: String) {
        eventSink?(["type": "session", "state": state])
    }
}
