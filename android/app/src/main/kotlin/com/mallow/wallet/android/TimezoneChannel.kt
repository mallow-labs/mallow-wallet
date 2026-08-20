package com.mallow.wallet.android

import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.time.ZoneId
import java.util.TimeZone

/**
 * Native lookup for the device's IANA time-zone name (e.g. `America/New_York`).
 *
 * This replaces the `flutter_timezone` package, which was dropped because its
 * iOS plugin header imports CoreLocation without ever calling it, tripping App
 * Store validation ITMS-90683. Android was never the problem; this side exists
 * only to keep both platforms on one channel.
 *
 * The API-level branch mirrors what flutter_timezone did, so the value handed
 * to `tz.getLocation` on Dart side is unchanged from before the swap.
 */
class TimezoneChannel : FlutterPlugin, MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "mallow_wallet/timezone"
    }

    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getLocalTimezone" -> result.success(localTimezone())
            else -> result.notImplemented()
        }
    }

    private fun localTimezone(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ZoneId.systemDefault().id
        } else {
            TimeZone.getDefault().id
        }
    }
}
