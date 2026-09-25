package com.mallow.wallet.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.view.WindowCompat
import com.mallow.wallet.android.SecurityChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Let Flutter paint through the system-bar regions while still
        // receiving their insets. Running this after super is important:
        // FlutterFragmentActivity creates and configures the window there.
        WindowCompat.enableEdgeToEdge(window)
        createNotificationChannel()
    }

    /**
     * Create the channel named by `default_notification_channel_id` in the
     * manifest, which is also the `channelId` the backend sends.
     *
     * Without this the FCM SDK auto-creates the channel at DEFAULT importance,
     * and an Android channel's importance — not the message's priority — is
     * what decides whether a notification appears as a heads-up banner. The
     * backend sends `priority: "high"`, and it was being silently downgraded to
     * a silent tray entry.
     *
     * A channel's importance is fixed at creation: once a device has installed
     * a build that let the SDK create it, only a reinstall or a new channel id
     * changes it. The user can still override importance in system settings,
     * which is deliberate and must not be fought.
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            "mallow_notifications",
            "mallow",
            NotificationManager.IMPORTANCE_HIGH,
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager?.createNotificationChannel(channel)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(CastPlugin())
        flutterEngine.plugins.add(MnemonicVaultChannel())
        flutterEngine.plugins.add(SecurityChannel())
        flutterEngine.plugins.add(SeedVaultChannel())
        flutterEngine.plugins.add(TimezoneChannel())
    }

    override fun onUserLeaveHint() {
        // Fires before the system captures the recents thumbnail when the
        // user explicitly leaves (home / recents / app switch). Setting the
        // flag in onPause alone is too late on many devices.
        applySecureFlag()
        super.onUserLeaveHint()
    }

    override fun onPause() {
        // Belt-and-suspenders: covers the cases onUserLeaveHint doesn't
        // (e.g., another activity launches over us, incoming call).
        applySecureFlag()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun applySecureFlag() {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }
}
