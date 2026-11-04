package com.mallow.wallet.android

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import java.util.UUID

/**
 * Share-sheet target "Open in mallow browser": the Android twin of the iOS
 * action extension in `ios/OpenInMallow/`.
 *
 * A shared website becomes the same `mallowwallet://browser/open?url=…&request=…`
 * handoff the extension sends, so app_links delivers it to DeepLinkService and
 * the Dart side validates it again before the browser loads anything.
 *
 * This is a display-less trampoline rather than a SEND filter on MainActivity.
 * The share sheet starts its target inside the *sharing* app's task, so a filter
 * on MainActivity would create a second MainActivity there — a second Flutter
 * engine and DI graph opening the same encrypted database. [openInMainActivity]
 * hands it to the one existing MainActivity instead.
 *
 * This activity logs nothing: the shared text is whatever the other app put
 * in the share, and a URL can carry private query parameters.
 */
class ShareTargetActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Theme.NoDisplay requires finishing before onResume, on every path.
        val launchedFromHistory =
            intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (!launchedFromHistory && intent.action == Intent.ACTION_SEND) {
            handleShare(intent.getCharSequenceExtra(Intent.EXTRA_TEXT))
        }
        finish()
    }

    private fun handleShare(text: CharSequence?) {
        val candidate = firstWebLink(text?.toString())
        if (candidate == null) {
            toast("Share a website link to open it in mallow browser.")
            return
        }
        if (!isOpenableWebsite(candidate)) {
            toast("Only HTTPS website links without embedded credentials can be opened.")
            return
        }
        openInMallow(candidate)
    }

    /** Hands [website] to MainActivity in mallow's own task. */
    private fun openInMallow(website: String) {
        // Uri.Builder percent-encodes `+`, which Dart would otherwise decode as
        // a space. The request id gives repeated shares of one page distinct
        // identities, exactly as the iOS extension does.
        val handoff = Uri.Builder()
            .scheme("mallowwallet")
            .authority("browser")
            .path("/open")
            .appendQueryParameter("url", website)
            .appendQueryParameter("request", UUID.randomUUID().toString())
            .build()
        openInMainActivity(this, handoff)
    }

    private fun toast(message: String) {
        Toast.makeText(applicationContext, message, Toast.LENGTH_LONG).show()
    }

    companion object {
        // A link ends at any whitespace, separator or control character — the
        // Unicode set, not just ASCII, so an NBSP pasted after a link does not
        // become part of it. The Dart side rejects a URL that contains one.
        private val WEB_LINK =
            Regex("""https?://[^\s\p{Z}\p{C}]+""", RegexOption.IGNORE_CASE)
        private const val TRAILING_PUNCTUATION = ".,;:!?'\""
        private val CLOSERS = mapOf(')' to '(', ']' to '[', '}' to '{', '>' to '<')

        /**
         * The first https link in shared [text]; failing that the first http
         * one, which [isOpenableWebsite] then refuses with its own message.
         * Null when there is no link at all.
         *
         * Apps rarely share a bare URL: most send a title or a sentence with the
         * link inside it. Punctuation that ends the sentence is not part of the
         * link, and neither is a closing bracket with no opener inside the link,
         * as in "(see https://example.com)". A balanced one stays, so
         * `https://en.wikipedia.org/wiki/Mallow_(plant)` survives intact.
         */
        fun firstWebLink(text: String?): String? {
            val links = WEB_LINK.findAll(text ?: return null).map { trimLink(it.value) }
            return links.firstOrNull { it.startsWith("https://", ignoreCase = true) }
                ?: links.firstOrNull()
        }

        private fun trimLink(match: String): String {
            var link = match
            while (link.isNotEmpty()) {
                val last = link.last()
                val opener = CLOSERS[last]
                val strip = last in TRAILING_PUNCTUATION ||
                    (opener != null && link.count { it == opener } < link.count { it == last })
                if (!strip) break
                link = link.dropLast(1)
            }
            return link
        }

        /**
         * Whether [link] is an HTTPS website without embedded credentials.
         *
         * Whatever passes here goes on to the Dart validator, and a link it
         * rejects there opens nothing, so this refuses up front, with a message,
         * what Dart would refuse. Dart's parser is lenient (it takes `|`, `{`, a
         * bare `%`, non-ASCII hosts) but rejects a non-numeric port and an
         * unclosed IPv6 literal, both of which android.net.Uri lets through.
         */
        fun isOpenableWebsite(link: String): Boolean {
            val uri = Uri.parse(link)
            if (!uri.scheme.equals("https", ignoreCase = true) ||
                uri.host.isNullOrEmpty() ||
                uri.userInfo != null
            ) {
                return false
            }
            return hasValidHostAndPort(uri.encodedAuthority.orEmpty())
        }

        private fun hasValidHostAndPort(authority: String): Boolean {
            // Whatever follows the host: nothing, or `:` and an optional port.
            val afterHost = if (authority.startsWith("[")) {
                val close = authority.indexOf(']')
                if (close < 0) return false
                authority.substring(close + 1)
            } else {
                authority.substring(authority.indexOf(':').takeIf { it >= 0 } ?: authority.length)
            }
            return afterHost.isEmpty() ||
                (afterHost.startsWith(":") && afterHost.drop(1).all { it in '0'..'9' })
        }
    }
}
