package com.mallow.wallet.android

import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.util.WeakHashMap
import kotlin.math.max

/**
 * Hands each WebView only the part of the window insets that actually covers it.
 *
 * Android dispatches the window's insets to every view wherever it sits, and
 * the WebView turns the system-bar, cutout and keyboard insets into the page's
 * `env(safe-area-inset-*)`. The app draws edge to edge, so the in-app browser's
 * WebView, laid out between its own bars, was told it sat under the status and
 * navigation bars: pages padded their fixed bottom navigation for a gesture bar
 * that was nowhere near them, and showed it raised above the browser's bar.
 *
 * Each inset is reduced by the WebView's distance from that edge of the window,
 * and handed out again whenever the WebView moves or resizes (the browser
 * moves it as a page starts or stops running under its bottom bar).
 */
object WebViewInsetFitter {
    private val types = intArrayOf(
        WindowInsetsCompat.Type.systemBars(),
        WindowInsetsCompat.Type.displayCutout(),
        WindowInsetsCompat.Type.ime(),
        WindowInsetsCompat.Type.systemGestures(),
        WindowInsetsCompat.Type.mandatorySystemGestures(),
        WindowInsetsCompat.Type.tappableElement(),
    )

    /** Each fitted WebView's last frame in its window: x, y, width, height. */
    private val frames = WeakHashMap<WebView, IntArray>()

    /**
     * Fits every WebView under [root], now and after each layout pass. Platform
     * views are native views, so adding or moving one is a native layout pass.
     */
    fun install(root: View) {
        root.viewTreeObserver.addOnGlobalLayoutListener { scan(root) }
    }

    private fun scan(view: View) {
        if (view is WebView) {
            check(view)
            return
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) scan(view.getChildAt(index))
        }
    }

    private fun check(webView: WebView) {
        val frame = frameOf(webView)
        val last = frames[webView]
        if (last == null) {
            ViewCompat.setOnApplyWindowInsetsListener(webView) { view, insets ->
                ViewCompat.onApplyWindowInsets(view, overlapOnly(view, insets))
            }
        } else if (last.contentEquals(frame)) {
            return
        }
        frames[webView] = frame
        ViewCompat.requestApplyInsets(webView)
    }

    private fun frameOf(view: View): IntArray {
        val location = IntArray(2)
        view.getLocationInWindow(location)
        return intArrayOf(location[0], location[1], view.width, view.height)
    }

    private fun overlapOnly(view: View, insets: WindowInsetsCompat): WindowInsetsCompat {
        val root = view.rootView
        val location = IntArray(2)
        view.getLocationInWindow(location)
        val left = location[0]
        val top = location[1]
        val right = root.width - (left + view.width)
        val bottom = root.height - (top + view.height)
        val builder = WindowInsetsCompat.Builder(insets)
        for (type in types) {
            val inset = insets.getInsets(type)
            builder.setInsets(
                type,
                Insets.of(
                    max(0, inset.left - left),
                    max(0, inset.top - top),
                    max(0, inset.right - right),
                    max(0, inset.bottom - bottom),
                ),
            )
        }
        // The WebView also reads the cutout itself. Drop it once the WebView
        // is clear of it; one it still overlaps is passed on whole.
        val cutout = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
        if (cutout.left <= left && cutout.top <= top &&
            cutout.right <= right && cutout.bottom <= bottom
        ) {
            builder.setDisplayCutout(null)
        }
        return builder.build()
    }
}
