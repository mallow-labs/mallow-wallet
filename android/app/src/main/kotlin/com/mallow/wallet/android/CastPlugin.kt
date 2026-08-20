package com.mallow.wallet.android

import android.app.Activity
import android.util.Log
import androidx.mediarouter.media.MediaControlIntent
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.CastStatusCodes
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManager
import com.google.android.gms.cast.framework.SessionManagerListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject

/**
 * Flutter plugin for Google Chromecast casting.
 *
 * Method channel: com.mallow.wallet/cast
 * Methods: startDiscovery, stopDiscovery, connectToDevice, disconnect,
 *          loadMedia, updateOverlay, pause, resume, stop
 *
 * Event channel: com.mallow.wallet/cast_events
 * Events: {type: 'devices', devices: [{id, name}]}
 *         {type: 'session', state: 'connecting'|'connected'|'disconnected'|'error'}
 *
 * Drives the mallow custom HTML receiver via [NAMESPACE]. The default media
 * receiver and `RemoteMediaClient.load` path are intentionally not used —
 * the receiver renders artwork + overlay itself in response to JSON messages.
 */
class CastPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    companion object {
        private const val NAMESPACE = "urn:x-cast:art.mallow.cast"
        private const val TAG = "CastPlugin"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var castContext: CastContext? = null
    private var sessionManager: SessionManager? = null
    private var mediaRouter: MediaRouter? = null
    private var routerCallback: MediaRouter.Callback? = null

    // Reason the Cast SDK could not initialise (almost always missing/outdated
    // Google Play services). Reported to Dart on startDiscovery as
    // CAST_UNAVAILABLE so the UI can explain the empty device list instead of
    // leaving the user staring at a silent "Searching…".
    private var castInitFailure: String? = null
    private val routeSelector = MediaRouteSelector.Builder()
        .addControlCategory(MediaControlIntent.CATEGORY_REMOTE_PLAYBACK)
        .build()

    // Memoized accepted-route signature so pushDeviceList only logs/emits
    // when the user-visible device set changes (not on every framework tick).
    private var lastAcceptedSignature: List<String>? = null

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) {
            Log.i(TAG, "session: starting")
            sendSessionState("connecting")
        }

        override fun onSessionStarted(session: CastSession, sessionId: String) {
            Log.i(
                TAG,
                "session: started sessionId=$sessionId connected=${session.isConnected} " +
                    "device=${session.castDevice?.friendlyName}",
            )
            sendSessionState("connected")
        }

        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            Log.i(TAG, "session: resumed wasSuspended=$wasSuspended")
            sendSessionState("connected")
        }

        override fun onSessionEnding(session: CastSession) {
            Log.i(TAG, "session: ending")
        }

        override fun onSessionEnded(session: CastSession, error: Int) {
            Log.i(TAG, "session: ended error=$error (${castStatusName(error)})")
            sendSessionState("disconnected")
        }

        override fun onSessionSuspended(session: CastSession, reason: Int) {
            Log.w(TAG, "session: suspended reason=$reason")
            sendSessionState("disconnected")
        }

        override fun onSessionStartFailed(session: CastSession, error: Int) {
            Log.e(TAG, "session: startFailed error=$error (${castStatusName(error)})")
            sendSessionState("error")
        }

        override fun onSessionResumeFailed(session: CastSession, error: Int) {
            Log.e(TAG, "session: resumeFailed error=$error (${castStatusName(error)})")
            sendSessionState("error")
        }

        override fun onSessionResuming(session: CastSession, sessionId: String) {
            Log.i(TAG, "session: resuming sessionId=$sessionId")
        }
    }

    // ---------------------------------------------------------------------------
    // FlutterPlugin
    // ---------------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "com.mallow.wallet/cast")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "com.mallow.wallet/cast_events")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    // ---------------------------------------------------------------------------
    // ActivityAware
    // ---------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        initCastContext()
    }

    override fun onDetachedFromActivityForConfigChanges() {}

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        initCastContext()
    }

    override fun onDetachedFromActivity() {
        stopDiscovery()
        sessionManager?.removeSessionManagerListener(sessionListener, CastSession::class.java)
        activity = null
        castContext = null
        sessionManager = null
    }

    // ---------------------------------------------------------------------------
    // MethodCallHandler
    // ---------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startDiscovery" -> {
                // Retry init first: onAttachedToActivity may have run before
                // Play services was ready, and a retry is cheap.
                if (castContext == null) initCastContext()
                val failure = castInitFailure
                if (castContext == null && failure != null) {
                    result.error(
                        "CAST_UNAVAILABLE",
                        "Cast SDK unavailable (Google Play services): $failure",
                        null,
                    )
                } else {
                    startDiscovery()
                    result.success(null)
                }
            }
            "stopDiscovery" -> {
                stopDiscovery()
                result.success(null)
            }
            "connectToDevice" -> {
                val deviceId = call.argument<String>("deviceId") ?: ""
                connectToDevice(deviceId, result)
            }
            "disconnect" -> {
                disconnect()
                result.success(null)
            }
            "loadMedia" -> {
                val url = call.argument<String>("url") ?: ""
                val mimeType = call.argument<String>("mimeType") ?: "image/jpeg"
                val title = call.argument<String>("title") ?: ""
                val imageUrl = call.argument<String>("imageUrl") ?: ""
                @Suppress("UNCHECKED_CAST")
                val overlay = call.argument<Map<String, Any?>>("overlay") ?: emptyMap()
                loadMedia(url, mimeType, title, imageUrl, overlay, result)
            }
            "updateOverlay" -> {
                @Suppress("UNCHECKED_CAST")
                val overlay = call.argument<Map<String, Any?>>("overlay") ?: emptyMap()
                updateOverlay(overlay, result)
            }
            "preload" -> {
                @Suppress("UNCHECKED_CAST")
                val urls = call.argument<List<String>>("urls") ?: emptyList()
                preload(urls, result)
            }
            "pause" -> sendControlMessage("pause", result)
            "resume" -> sendControlMessage("resume", result)
            "stop" -> sendControlMessage("stop", result)
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------------
    // Implementation
    // ---------------------------------------------------------------------------

    private fun initCastContext() {
        val act = activity ?: return
        try {
            castContext = CastContext.getSharedInstance(act)
            castInitFailure = null
            sessionManager = castContext?.sessionManager
            // Defensive: remove first in case we're reattaching after a config
            // change so we don't accumulate duplicate listeners.
            sessionManager?.removeSessionManagerListener(sessionListener, CastSession::class.java)
            sessionManager?.addSessionManagerListener(sessionListener, CastSession::class.java)
            Log.i(
                TAG,
                "CastContext ready. AppId=${CastOptionsProvider.receiverAppId(act)} " +
                    "namespace=$NAMESPACE",
            )

            // Cast SDK does not replay session events to listeners attached
            // *after* a session is already established. If the previous app
            // run left a session up (or another Cast app on this phone has one
            // active), surface it now so the bloc transitions to active.
            val existing = sessionManager?.currentCastSession
            if (existing != null && existing.isConnected) {
                Log.i(
                    TAG,
                    "Found pre-existing connected session " +
                        "device=${existing.castDevice?.friendlyName} — emitting connected",
                )
                sendSessionState("connected")
            }
        } catch (e: Exception) {
            // Most common cause: Google Play Services missing/outdated
            // (Fire OS doesn't ship Play Services, so the Cast SDK can't run
            // on a Fire tablet/phone — but this code path is on the *sender*
            // phone, not the receiver TV).
            // Swallowing this used to leave the sender with a permanently empty
            // device list, which is indistinguishable from "no Chromecasts on
            // this Wi-Fi". Remember it so startDiscovery can tell Dart why.
            Log.e(TAG, "CastContext init failed — Play Services issue?", e)
            castContext = null
            sessionManager = null
            castInitFailure = e.message ?: e.javaClass.simpleName
        }
    }

    private fun startDiscovery() {
        val act = activity ?: return
        mediaRouter = MediaRouter.getInstance(act)

        Log.i(
            TAG,
            "startDiscovery — selector categories=" +
                "[${MediaControlIntent.CATEGORY_REMOTE_PLAYBACK}, " +
                "${CastMediaControlIntent.categoryForCast(CastOptionsProvider.receiverAppId(act))}]",
        )
        logAllRoutes("at startDiscovery")

        routerCallback = object : MediaRouter.Callback() {
            override fun onRouteAdded(router: MediaRouter, info: MediaRouter.RouteInfo) {
                pushDeviceList()
            }

            override fun onRouteRemoved(router: MediaRouter, info: MediaRouter.RouteInfo) {
                pushDeviceList()
            }

            override fun onRouteChanged(router: MediaRouter, info: MediaRouter.RouteInfo) {
                // Don't log here — the Cast SDK churns onRouteChanged constantly
                // for liveness; pushDeviceList logs only when the set changes.
                pushDeviceList()
            }
        }

        mediaRouter?.addCallback(
            routeSelector,
            routerCallback!!,
            MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY,
        )

        pushDeviceList()
    }

    private fun stopDiscovery() {
        Log.i(TAG, "stopDiscovery")
        routerCallback?.let {
            mediaRouter?.removeCallback(it)
        }
        routerCallback = null
        mediaRouter = null
        lastAcceptedSignature = null
    }

    private fun connectToDevice(deviceId: String, result: Result) {
        val router = mediaRouter
        if (router == null) {
            Log.e(TAG, "connectToDevice($deviceId) — no discovery active")
            result.error("NO_DISCOVERY", "Call startDiscovery first", null)
            return
        }

        val route = router.routes.firstOrNull { it.id == deviceId }

        if (route == null) {
            Log.e(
                TAG,
                "connectToDevice($deviceId) — route not found. Known routes: " +
                    router.routes.joinToString { "${it.id}('${it.name}')" },
            )
            result.error("DEVICE_NOT_FOUND", "Device $deviceId not found", null)
            return
        }

        Log.i(TAG, "connectToDevice — selecting ${describeRoute(route)}")
        route.select()
        Log.i(
            TAG,
            "connectToDevice — route.select() returned. selectedRoute=${router.selectedRoute.id}",
        )

        // If the framework already has a connected session to this device
        // (e.g. left over from a prior app run), select() won't trigger a
        // fresh onSessionStarted — emit connected synthetically so the bloc
        // doesn't sit in CastConnecting forever.
        val existing = sessionManager?.currentCastSession
        if (existing != null && existing.isConnected && route.connectionState == MediaRouter.RouteInfo.CONNECTION_STATE_CONNECTED) {
            Log.i(
                TAG,
                "connectToDevice — route already CONNECTED with active session " +
                    "(${existing.castDevice?.friendlyName}); emitting connected",
            )
            sendSessionState("connected")
        }

        result.success(null)
    }

    private fun disconnect() {
        sessionManager?.endCurrentSession(true)
    }

    private fun loadMedia(
        url: String,
        mimeType: String,
        title: String,
        imageUrl: String,
        overlay: Map<String, Any?>,
        result: Result,
    ) {
        val payload = JSONObject().apply {
            put("type", "show")
            put(
                "item",
                JSONObject().apply {
                    put("mediaUrl", url)
                    put("imageUrl", imageUrl)
                    put("mimeType", mimeType)
                    put("title", title)
                },
            )
            put("overlay", overlay.toJson())
        }
        sendNamespaceMessage(payload, result)
    }

    private fun updateOverlay(overlay: Map<String, Any?>, result: Result) {
        val payload = JSONObject().apply {
            put("type", "overlay")
            put("overlay", overlay.toJson())
        }
        sendNamespaceMessage(payload, result)
    }

    private fun preload(urls: List<String>, result: Result) {
        if (urls.isEmpty()) {
            result.success(null)
            return
        }
        val payload = JSONObject().apply {
            put("type", "preload")
            put("urls", org.json.JSONArray(urls))
        }
        sendNamespaceMessage(payload, result)
    }

    private fun sendControlMessage(type: String, result: Result) {
        val payload = JSONObject().apply { put("type", type) }
        sendNamespaceMessage(payload, result)
    }

    private fun sendNamespaceMessage(payload: JSONObject, result: Result) {
        val session = sessionManager?.currentCastSession
        if (session == null || !session.isConnected) {
            Log.w(
                TAG,
                "sendNamespaceMessage — no active session " +
                    "(session=${session?.let { "present, isConnected=${it.isConnected}" } ?: "null"})",
            )
            result.error("NO_SESSION", "No active cast session", null)
            return
        }
        val type = payload.optString("type")
        Log.d(TAG, "sendNamespaceMessage type=$type bytes=${payload.toString().length}")
        session.sendMessage(NAMESPACE, payload.toString())
            .setResultCallback { status ->
                if (status.isSuccess) {
                    Log.d(TAG, "sendNamespaceMessage type=$type ✓")
                    result.success(null)
                } else {
                    Log.e(
                        TAG,
                        "sendNamespaceMessage type=$type ✗ " +
                            "code=${status.statusCode} (${castStatusName(status.statusCode)})",
                    )
                    result.error(
                        "SEND_FAILED",
                        "Cast sendMessage failed: ${status.statusCode}",
                        null,
                    )
                }
            }
    }

    private fun Map<String, Any?>.toJson(): JSONObject {
        val obj = JSONObject()
        for ((k, v) in this) {
            if (v != null) obj.put(k, v)
        }
        return obj
    }

    private fun pushDeviceList() {
        val router = mediaRouter ?: return
        val accepted = router.routes
            .filter { !it.isDefault && it.matchesSelector(routeSelector) }

        // Dedupe: only log/emit when the accepted set actually changes.
        // The Cast SDK fires onRouteChanged constantly for liveness checks
        // even when nothing user-visible changed.
        val signature = accepted.map { "${it.id}|${it.name}|${it.connectionState}" }
        if (signature == lastAcceptedSignature) return
        lastAcceptedSignature = signature

        Log.i(
            TAG,
            "pushDeviceList — accepted=${accepted.size}: " +
                accepted.joinToString { "${it.name}(connState=${it.connectionState})" },
        )

        val payload = accepted.map { mapOf("id" to it.id, "name" to it.name.toString()) }
        activity?.runOnUiThread {
            eventSink?.success(mapOf("type" to "devices", "devices" to payload))
        }
    }

    /**
     * Snapshot every route the framework currently knows about, regardless of
     * whether it matches our selector. Useful for diagnosing "device shows up
     * in Google Home but not in our picker" scenarios — if it's not in here at
     * all, the issue is upstream (mDNS, network, Play Services, permissions).
     */
    private fun logAllRoutes(label: String) {
        val router = mediaRouter ?: return
        val routes = router.routes
        val summary = routes.joinToString { route ->
            "${route.name}(id=${route.id.takeLast(12)}, " +
                "match=${route.matchesSelector(routeSelector)}, " +
                "connState=${route.connectionState})"
        }
        Log.i(TAG, "All routes ($label) count=${routes.size}: $summary")
    }

    private fun castStatusName(code: Int): String = when (code) {
        CastStatusCodes.SUCCESS -> "SUCCESS"
        CastStatusCodes.NETWORK_ERROR -> "NETWORK_ERROR"
        CastStatusCodes.TIMEOUT -> "TIMEOUT"
        CastStatusCodes.AUTHENTICATION_FAILED -> "AUTHENTICATION_FAILED"
        CastStatusCodes.INVALID_REQUEST -> "INVALID_REQUEST"
        CastStatusCodes.CANCELED -> "CANCELED"
        CastStatusCodes.NOT_ALLOWED -> "NOT_ALLOWED"
        CastStatusCodes.APPLICATION_NOT_FOUND -> "APPLICATION_NOT_FOUND"
        CastStatusCodes.APPLICATION_NOT_RUNNING -> "APPLICATION_NOT_RUNNING"
        CastStatusCodes.MESSAGE_TOO_LARGE -> "MESSAGE_TOO_LARGE"
        CastStatusCodes.MESSAGE_SEND_BUFFER_TOO_FULL -> "MESSAGE_SEND_BUFFER_TOO_FULL"
        CastStatusCodes.FAILED -> "FAILED"
        CastStatusCodes.REPLACED -> "REPLACED"
        CastStatusCodes.INTERRUPTED -> "INTERRUPTED"
        else -> "UNKNOWN($code)"
    }

    private fun describeRoute(info: MediaRouter.RouteInfo): String {
        val matches = runCatching { info.matchesSelector(routeSelector) }.getOrNull()
        val categories = info.controlFilters.flatMap { filter ->
            (0 until filter.countCategories()).map { filter.getCategory(it) }
        }
        return buildString {
            append("id=${info.id} ")
            append("name='${info.name}' ")
            append("desc='${info.description}' ")
            append("isDefault=${info.isDefault} ")
            append("isEnabled=${info.isEnabled} ")
            append("connState=${info.connectionState} ")
            append("deviceType=${info.deviceType} ")
            append("matchesSelector=$matches ")
            append("categories=$categories")
        }
    }

    private fun sendSessionState(state: String) {
        activity?.runOnUiThread {
            eventSink?.success(mapOf("type" to "session", "state" to state))
        }
    }
}
