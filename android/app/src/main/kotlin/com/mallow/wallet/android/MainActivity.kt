package com.mallow.wallet.android

import android.os.Bundle
import android.view.WindowManager
import androidx.core.view.WindowCompat
import com.mallow.wallet.android.SecurityChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Let the app draw behind system bars so Flutter receives the real
        // safe-area insets (status bar, display cutout, navigation bar).
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(CastPlugin())
        flutterEngine.plugins.add(MnemonicVaultChannel())
        flutterEngine.plugins.add(SecurityChannel())
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
