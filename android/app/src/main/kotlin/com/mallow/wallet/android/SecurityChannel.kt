package com.mallow.wallet.android

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Native handler for sensitive clipboard writes.
 *
 * Android has no per-clip OS expiration API, but on API 33+ the system will
 * auto-clear the clipboard after its own timeout when a clip is marked
 * sensitive, and it suppresses the on-screen preview that would otherwise
 * leak the value. We also set the legacy "android.content.extra.IS_SENSITIVE"
 * key honored by some OEM builds back to API 24.
 *
 * A Dart-side in-process Timer cannot be relied on (the JVM/process may be
 * killed in background), so the Dart layer should not assume it ran.
 */
class SecurityChannel : FlutterPlugin, MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "mallow_wallet/security"
        private const val EXTRA_IS_SENSITIVE_LEGACY = "android.content.extra.IS_SENSITIVE"
    }

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "copyToClipboardWithExpiration" -> {
                val text = call.argument<String>("text")
                if (text == null) {
                    result.error("invalid_args", "Missing text", null)
                    return
                }
                copySensitive(text)
                result.success(null)
            }
            "clearClipboard" -> {
                clearClipboard()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun copySensitive(text: String) {
        val cm = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("", text)
        val extras = PersistableBundle().apply {
            putBoolean(EXTRA_IS_SENSITIVE_LEGACY, true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        clip.description.extras = extras
        cm.setPrimaryClip(clip)
    }

    private fun clearClipboard() {
        val cm = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            cm.clearPrimaryClip()
        } else {
            cm.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }
}
