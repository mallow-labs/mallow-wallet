package com.mallow.wallet.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle

/**
 * Receives every inbound `VIEW` link: the verified mallow.art App Links (the
 * return of Sign in with Apple's web flow among them), the `mallowwallet://`
 * scheme and WalletConnect `wc:` pairing links.
 *
 * This is a display-less trampoline rather than intent filters on MainActivity.
 * An app that sends the link without FLAG_ACTIVITY_NEW_TASK starts the
 * target inside *its own* task. A camera scanning a QR code does exactly this.
 * `singleTop` reuses an instance only at the top of that same task, so a filter
 * on MainActivity would create a second MainActivity there. That means a second
 * Flutter engine and DI graph in the process, opening the same encrypted
 * database, with both isolates on the main thread. The first one, still on its
 * own screen, keeps running.
 *
 * [openInMainActivity] hands the link to the one existing MainActivity
 * instead. This activity logs nothing: a link can carry private query
 * parameters, a pairing key, a one-time completion token or an ID token.
 */
class LinkTrampolineActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Theme.NoDisplay requires finishing before onResume, on every path.
        // Relaunching from recents would replay a link that was already
        // handled, so that case forwards nothing.
        val launchedFromHistory =
            intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        val link = intent.data
        if (!launchedFromHistory && intent.action == Intent.ACTION_VIEW && link != null) {
            openInMainActivity(this, link)
        }
        finish()
    }
}

/**
 * Delivers [link] to MainActivity in mallow's own task as a `VIEW` intent, the
 * shape app_links reads: as the launch intent on a cold start, through
 * onNewIntent otherwise.
 *
 * NEW_TASK alone is not enough. It finds mallow's task, but delivers to
 * onNewIntent only when MainActivity is that task's top activity. Otherwise it
 * stacks a second MainActivity on top. Something else is on top whenever the
 * link comes back from a Custom Tab that mallow opened (the X connect
 * callback, the Sign in with Apple return), or from mallow's own share sheet, where the share trampoline is itself still
 * on top. CLEAR_TOP plus SINGLE_TOP keeps the existing instance, delivers to
 * onNewIntent and finishes everything above it, so such a Custom Tab closes.
 */
internal fun openInMainActivity(context: Context, link: Uri) {
    context.startActivity(
        Intent(Intent.ACTION_VIEW, link, context, MainActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            ),
    )
}
