package com.mallow.wallet.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Answers whether a runtime permission is already granted, without asking.
 *
 * The app explains a sensitive permission in its own words before the OS
 * dialog appears (prominent disclosure). That explanation has to be skipped
 * once the permission is granted, and the plugin that owns the camera only
 * reports permission state by requesting it — which would show the OS dialog
 * before the explanation. This read-only check is the missing half.
 *
 * Android only: iOS states each permission's purpose in Info.plist, which the
 * system dialog shows itself.
 */
class PermissionStatusChannel : FlutterPlugin, MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "mallow_wallet/permission_status"
    }

    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "isCameraGranted" -> result.success(
                ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED
            )
            else -> result.notImplemented()
        }
    }
}
