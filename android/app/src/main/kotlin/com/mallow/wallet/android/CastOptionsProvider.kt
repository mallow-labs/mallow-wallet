package com.mallow.wallet.android

import android.content.Context
import android.content.pm.PackageManager
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider

/**
 * Registers the custom Chromecast receiver with the Cast Framework.
 *
 * The Cast SDK locates this class via the `OPTIONS_PROVIDER_CLASS_NAME`
 * meta-data entry in AndroidManifest.xml and instantiates it on first call to
 * `CastContext.getSharedInstance(...)`.
 *
 * The receiver is the HTML app registered on the Google Cast Developer
 * Console. Its id comes from the `CAST_RECEIVER_APP_ID` build variable, which
 * `build.gradle.kts` resolves into the `art.mallow.cast.RECEIVER_APP_ID`
 * manifest entry read below. Unset, it falls back to [DEFAULT_APP_ID] —
 * mallow's own receiver, so casting works in a build that configured nothing.
 * That default is right for evaluating the app and wrong for a fork you
 * distribute: register your own receiver and set the variable, or your users
 * cast into mallow's receiver, on mallow's bandwidth and under mallow's
 * branding. See TRADEMARK.md.
 *
 * Read from the manifest rather than passed from Dart because the SDK builds
 * this object before any Dart has run. iOS takes the same value over the cast
 * method channel instead, where init is lazy enough to wait for it.
 */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions {
        return CastOptions.Builder()
            .setReceiverApplicationId(receiverAppId(context))
            .build()
    }

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null

    companion object {
        const val META_DATA_KEY: String = "art.mallow.cast.RECEIVER_APP_ID"

        /**
         * Fallback for a build assembled without the manifest entry — an
         * older Gradle file, or a host project that inlines this class. Keep
         * it in step with `kDefaultCastReceiverAppId` in
         * lib/core/config/environment.dart.
         */
        const val DEFAULT_APP_ID: String = "3B14DCF8"

        /**
         * The prefix AndroidManifest.xml puts in front of the id, stripped
         * here. aapt types a meta-data value by its content, so an id made of
         * decimal digits only — roughly one valid Cast id in fifty — would be
         * compiled to an Int, [android.os.Bundle.getString] would return null,
         * and a fork that registered such a receiver would cast into mallow's
         * instead. Reading the Int back is not a fix: the conversion also
         * destroys a leading zero. A value that never parses as anything but a
         * string is.
         *
         * A value without the prefix is passed through unchanged, for a host
         * project that writes the meta-data entry itself.
         */
        const val VALUE_PREFIX: String = "id:"

        /**
         * The receiver id this build casts to. Blank is treated as absent: the
         * Cast SDK rejects an empty id with an error that names nothing, so a
         * placeholder that failed to resolve must not reach it.
         */
        fun receiverAppId(context: Context): String {
            val fromManifest = runCatching {
                context.packageManager
                    .getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
                    .metaData
                    ?.getString(META_DATA_KEY)
            }.getOrNull()
            return fromManifest
                ?.removePrefix(VALUE_PREFIX)
                ?.takeIf { it.isNotBlank() }
                ?: DEFAULT_APP_ID
        }
    }
}
