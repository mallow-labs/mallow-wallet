package com.mallow.wallet.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import com.solanamobile.seedvault.PublicKeyResponse
import com.solanamobile.seedvault.SeedVault
import com.solanamobile.seedvault.SigningRequest
import com.solanamobile.seedvault.SigningResponse
import com.solanamobile.seedvault.Wallet
import com.solanamobile.seedvault.WalletContractV1
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Solana Mobile Seed Vault bridge.
 *
 * Method channel: com.mallow.wallet/seed_vault
 *
 * Seed Vault is a hardware key store: mallow never sees the seed, and every
 * signature is produced by a separate OS Activity after the user approves it.
 * This channel is the whole Android surface — the Dart side owns policy
 * (which flows may raise a prompt), this file owns mechanism.
 *
 * Three things here are load-bearing and easy to break:
 *
 * 1. Availability is decided by [SeedVault.isAvailable], never by the device
 *    model. `Build.MODEL == "Seeker"` is a string any ROM can set; isAvailable
 *    checks that the Seed Vault implementation permission is signature-
 *    protected by the platform key, which a spoofed ROM cannot fake.
 * 2. Exactly one intent request may be in flight. Android can kill this
 *    process while the approval Activity is up, so a result can arrive with
 *    no pending request at all — that is dropped as a cancellation rather
 *    than crashing or wedging the channel.
 * 3. Content-provider reads are Binder IPC and never run on the platform
 *    thread. Their results are posted back to it, because a Flutter [Result]
 *    may only be completed there.
 *
 * Nothing here logs key material, signatures, payloads or auth tokens: an auth
 * token is a capability handle, and `SigningRequest.toString()` prints the
 * whole payload — so log codes and counts only, never the objects.
 *
 * The Seed Vault SDK's `Wallet` surface requires API 30, above this app's
 * minSdk of 26. [isVaultAvailable] therefore reports the vault as absent below
 * API 30, and every other method refuses before it can reach the SDK.
 */
class SeedVaultChannel :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val CHANNEL_NAME = "com.mallow.wallet/seed_vault"
        private const val TAG = "SeedVaultChannel"

        // Seed Vault defines exactly one purpose, so the channel hardcodes it
        // rather than letting Dart pass a value that can only ever be 0.
        private const val PURPOSE = WalletContractV1.PURPOSE_SIGN_SOLANA_TRANSACTION

        // Request codes stay below 256: FragmentActivity has historically
        // rejected permission request codes using more than the low 8 bits,
        // and MainActivity is a FlutterFragmentActivity.
        private const val REQ_AUTHORIZE_SEED = 0x51
        private const val REQ_SIGN_TRANSACTIONS = 0x52
        private const val REQ_SIGN_MESSAGES = 0x53
        private const val REQ_PUBLIC_KEYS = 0x54
        private const val REQ_SEED_SETTINGS = 0x55
        private const val REQ_PERMISSION = 0x5A

        private val ACTIVITY_REQUEST_CODES = setOf(
            REQ_AUTHORIZE_SEED,
            REQ_SIGN_TRANSACTIONS,
            REQ_SIGN_MESSAGES,
            REQ_PUBLIC_KEYS,
            REQ_SEED_SETTINGS,
        )

        // Error codes. Dart branches on these strings, so they are API:
        // INVALID_AUTH_TOKEN drives a re-resolve of the auth token and
        // CANCELED distinguishes "the user said no" from a real failure.
        // Never fold either into UNKNOWN_ERROR.
        private const val ERR_UNAVAILABLE = "SEED_VAULT_UNAVAILABLE"
        private const val ERR_PERMISSION_DENIED = "PERMISSION_DENIED"
        private const val ERR_INVALID_AUTH_TOKEN = "INVALID_AUTH_TOKEN"
        private const val ERR_CANCELED = "CANCELED"
        private const val ERR_NO_ACTIVITY = "NO_ACTIVITY"
        private const val ERR_REQUEST_IN_FLIGHT = "REQUEST_IN_FLIGHT"
        private const val ERR_AUTHENTICATION_FAILED = "AUTHENTICATION_FAILED"
        private const val ERR_INVALID_PAYLOAD = "INVALID_PAYLOAD"
        private const val ERR_IMPLEMENTATION_LIMIT = "IMPLEMENTATION_LIMIT_EXCEEDED"
        private const val ERR_NOT_MODIFIED = "NOT_MODIFIED"
        private const val ERR_UNKNOWN = "UNKNOWN_ERROR"
    }

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var io: ExecutorService? = null
    private val platformHandler = Handler(Looper.getMainLooper())

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    // The single-in-flight slot. Only ever touched from the platform thread
    // (onMethodCall and both listener callbacks all run there), so it needs no
    // synchronization — but it does need every exit path to clear it.
    private var pendingResult: Result? = null
    private var pendingRequestCode = 0
    private var pendingExpectedCount = 0

    // ---------------------------------------------------------------------------
    // FlutterPlugin
    // ---------------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        io = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        io?.shutdown()
        io = null
    }

    // ---------------------------------------------------------------------------
    // ActivityAware
    // ---------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attach(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detach()
    }

    override fun onDetachedFromActivity() {
        detach()
    }

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    private fun detach() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        // Fail rather than leak: without an Activity no result can ever
        // arrive, so a pending Result held here would never complete and the
        // Dart caller would await forever.
        takePending()?.error(
            ERR_NO_ACTIVITY,
            "Activity detached while a Seed Vault request was in flight",
            null,
        )
    }

    // ---------------------------------------------------------------------------
    // MethodCallHandler
    // ---------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "isAvailable" -> result.success(isVaultAvailable(appContext))
            "hasPermission" -> result.success(hasSeedVaultPermission(appContext))
            "requestPermission" -> requestPermission(result)
            "getAuthorizedSeeds" -> getAuthorizedSeeds(result)
            "hasUnauthorizedSeeds" -> hasUnauthorizedSeeds(result)
            "getAccounts" -> getAccounts(call, result)
            "authorizeSeed" -> authorizeSeed(result)
            "deauthorizeSeed" -> deauthorizeSeed(call, result)
            "signTransactions" -> sign(call, result, messages = false)
            "signMessages" -> sign(call, result, messages = true)
            "requestPublicKeys" -> requestPublicKeys(call, result)
            "updateAccountName" -> updateAccountName(call, result)
            "setAccountIsUserWallet" -> setAccountIsUserWallet(call, result)
            "showSeedSettings" -> showSeedSettings(call, result)
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------------
    // Availability and permission
    // ---------------------------------------------------------------------------

    private fun isVaultAvailable(ctx: Context): Boolean {
        // Below API 30 the SDK's Wallet surface is unusable, so there is no
        // honest answer other than "absent".
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        // Never gate on Build.MODEL — it is a spoofable string. isAvailable
        // checks that the implementation permission carries signature
        // protection from the platform key, which is what actually makes the
        // vault trustworthy.
        //
        // Debuggable builds accept the Seed Vault Simulator so the flow can be
        // developed without a Seeker. Anything shippable demands a secure
        // implementation: a simulated vault keeps the seed in an ordinary app,
        // which is exactly the trust the rest of this feature assumes away.
        val debuggable =
            (ctx.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        return SeedVault.isAvailable(ctx, debuggable)
    }

    private fun hasSeedVaultPermission(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            SeedVault.getAccessType(ctx).isGranted

    private fun requestPermission(result: Result) {
        if (!isVaultAvailable(appContext)) {
            result.error(ERR_UNAVAILABLE, "No Seed Vault implementation on this device", null)
            return
        }
        if (hasSeedVaultPermission(appContext)) {
            result.success(true)
            return
        }
        val act = beginRequest(result, REQ_PERMISSION, expectedCount = 0) ?: return
        try {
            // A permanently denied permission still reports back immediately
            // through onRequestPermissionsResult with DENIED, so this resolves
            // false rather than hanging. Sending the user to app settings is
            // the Dart side's call, not ours.
            ActivityCompat.requestPermissions(
                act,
                arrayOf(WalletContractV1.PERMISSION_ACCESS_SEED_VAULT),
                REQ_PERMISSION,
            )
        } catch (e: Exception) {
            Log.e(TAG, "requestPermissions failed to launch", e)
            takePending()?.error(ERR_UNKNOWN, e.message ?: e.javaClass.simpleName, null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_PERMISSION) return false
        if (!hasPending(requestCode)) {
            Log.w(TAG, "orphaned permission result; dropping")
            return true
        }
        val result = takePending()!!
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        Log.i(TAG, "permission result granted=$granted")
        result.success(granted)
        return true
    }

    // ---------------------------------------------------------------------------
    // Content-provider reads and writes — Binder IPC, never on the platform thread
    // ---------------------------------------------------------------------------

    private fun getAuthorizedSeeds(result: Result) {
        val ctx = requireReady(result) ?: return
        offPlatformThread(result) {
            val projection = arrayOf(
                WalletContractV1.AUTHORIZED_SEEDS_AUTH_TOKEN,
                WalletContractV1.AUTHORIZED_SEEDS_AUTH_PURPOSE,
                WalletContractV1.AUTHORIZED_SEEDS_SEED_NAME,
            )
            val rows = ArrayList<Map<String, Any?>>()
            Wallet.getAuthorizedSeeds(ctx, projection)?.use { c: Cursor ->
                while (c.moveToNext()) {
                    rows.add(
                        mapOf(
                            "authToken" to c.getLong(0),
                            "purpose" to c.getInt(1),
                            "name" to c.getString(2).nullIfBlank(),
                        ),
                    )
                }
            }
            rows
        }
    }

    private fun hasUnauthorizedSeeds(result: Result) {
        val ctx = requireReady(result) ?: return
        offPlatformThread(result) {
            Wallet.hasUnauthorizedSeedsForPurpose(ctx, PURPOSE)
        }
    }

    private fun getAccounts(call: MethodCall, result: Result) {
        val ctx = requireReady(result) ?: return
        val authToken = call.longArg("authToken") ?: return result.missing("authToken")
        offPlatformThread(result) {
            val projection = arrayOf(
                WalletContractV1.ACCOUNTS_ACCOUNT_ID,
                WalletContractV1.ACCOUNTS_BIP32_DERIVATION_PATH,
                WalletContractV1.ACCOUNTS_PUBLIC_KEY_ENCODED,
                WalletContractV1.ACCOUNTS_ACCOUNT_NAME,
                WalletContractV1.ACCOUNTS_ACCOUNT_IS_USER_WALLET,
                WalletContractV1.ACCOUNTS_ACCOUNT_IS_VALID,
            )
            val rows = ArrayList<Map<String, Any?>>()
            Wallet.getAccounts(ctx, authToken, projection)?.use { c: Cursor ->
                while (c.moveToNext()) {
                    rows.add(
                        mapOf(
                            "accountId" to c.getLong(0),
                            "derivationPath" to c.getString(1),
                            "publicKeyEncoded" to c.getString(2),
                            "name" to c.getString(3).nullIfBlank(),
                            "isUserWallet" to (c.getShort(4).toInt() != 0),
                            "isValid" to (c.getShort(5).toInt() != 0),
                        ),
                    )
                }
            }
            rows
        }
    }

    private fun deauthorizeSeed(call: MethodCall, result: Result) {
        val ctx = requireReady(result) ?: return
        val authToken = call.longArg("authToken") ?: return result.missing("authToken")
        offPlatformThread(result) {
            Wallet.deauthorizeSeed(ctx, authToken)
            null
        }
    }

    private fun updateAccountName(call: MethodCall, result: Result) {
        val ctx = requireReady(result) ?: return
        val authToken = call.longArg("authToken") ?: return result.missing("authToken")
        val accountId = call.longArg("accountId") ?: return result.missing("accountId")
        val name = call.argument<String>("name")
        offPlatformThread(result) {
            Wallet.updateAccountName(ctx, authToken, accountId, name)
            null
        }
    }

    private fun setAccountIsUserWallet(call: MethodCall, result: Result) {
        val ctx = requireReady(result) ?: return
        val authToken = call.longArg("authToken") ?: return result.missing("authToken")
        val accountId = call.longArg("accountId") ?: return result.missing("accountId")
        val isUserWallet = call.argument<Boolean>("isUserWallet")
            ?: return result.missing("isUserWallet")
        offPlatformThread(result) {
            Wallet.updateAccountIsUserWallet(ctx, authToken, accountId, isUserWallet)
            null
        }
    }

    // ---------------------------------------------------------------------------
    // Intent-based calls — each shows Seed Vault's own approval Activity
    // ---------------------------------------------------------------------------

    private fun authorizeSeed(result: Result) {
        val ctx = requireReady(result) ?: return
        launch(result, REQ_AUTHORIZE_SEED, expectedCount = 0) {
            Wallet.authorizeSeed(ctx, PURPOSE)
        }
    }

    private fun sign(call: MethodCall, result: Result, messages: Boolean) {
        val ctx = requireReady(result) ?: return
        val authToken = call.longArg("authToken") ?: return result.missing("authToken")
        val path = call.argument<String>("derivationPath") ?: return result.missing("derivationPath")
        val payloads = call.argument<List<ByteArray>>("payloads")
        if (payloads.isNullOrEmpty()) return result.missing("payloads")

        // One SigningRequest per payload, each asking for a signature from the
        // single requested path, so responses come back one-to-one and in the
        // order Dart sent them.
        val requests = ArrayList<SigningRequest>(payloads.size)
        val paths = listOf(Uri.parse(path))
        for (payload in payloads) {
            requests.add(SigningRequest(payload, paths))
        }

        val code = if (messages) REQ_SIGN_MESSAGES else REQ_SIGN_TRANSACTIONS
        launch(result, code, expectedCount = payloads.size) {
            if (messages) {
                Wallet.signMessages(ctx, authToken, requests)
            } else {
                Wallet.signTransactions(ctx, authToken, requests)
            }
        }
    }

    private fun requestPublicKeys(call: MethodCall, result: Result) {
        val ctx = requireReady(result) ?: return
        val authToken = call.longArg("authToken") ?: return result.missing("authToken")
        val paths = call.argument<List<String>>("derivationPaths")
        if (paths.isNullOrEmpty()) return result.missing("derivationPaths")
        val uris = ArrayList<Uri>(paths.size)
        for (p in paths) uris.add(Uri.parse(p))
        launch(result, REQ_PUBLIC_KEYS, expectedCount = uris.size) {
            Wallet.requestPublicKeys(ctx, authToken, uris)
        }
    }

    private fun showSeedSettings(call: MethodCall, result: Result) {
        val ctx = requireReady(result) ?: return
        val authToken = call.longArg("authToken") ?: return result.missing("authToken")
        if (Build.VERSION.SDK_INT < SeedVault.MIN_API_FOR_SEED_VAULT_PRIVILEGED) {
            // ACTION_SEED_SETTINGS only exists on implementations that can
            // support the privileged permission, which is Android 13 and up.
            result.error(ERR_UNAVAILABLE, "Seed Vault settings need Android 13 or newer", null)
            return
        }
        launch(result, REQ_SEED_SETTINGS, expectedCount = 0) {
            Wallet.showSeedSettings(ctx, authToken)
        }
    }

    /**
     * Claim the single in-flight slot, build the intent and start it. Any
     * failure before the Activity is actually running releases the slot, so a
     * failed launch never blocks the next request.
     */
    private fun launch(result: Result, requestCode: Int, expectedCount: Int, build: () -> Intent) {
        val act = beginRequest(result, requestCode, expectedCount) ?: return
        val intent = try {
            build()
        } catch (e: IllegalStateException) {
            // No Seed Vault implementation can receive this intent, or we hold
            // no Seed Vault permission — resolveComponentForIntent's two cases.
            takePending()?.error(ERR_UNAVAILABLE, e.message ?: "Seed Vault unavailable", null)
            return
        } catch (e: Exception) {
            takePending()?.error(ERR_UNKNOWN, e.message ?: e.javaClass.simpleName, null)
            return
        }
        try {
            act.startActivityForResult(intent, requestCode)
        } catch (e: Exception) {
            Log.e(TAG, "startActivityForResult failed requestCode=$requestCode", e)
            takePending()?.error(ERR_UNKNOWN, e.message ?: e.javaClass.simpleName, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in ACTIVITY_REQUEST_CODES) return false
        if (!hasPending(requestCode)) {
            // The approval Activity outlived our process (or the request was
            // already failed at detach). Nothing was broadcast on-chain, so
            // treat it as a cancellation: consume the result and move on.
            Log.w(
                TAG,
                "orphaned activity result requestCode=$requestCode " +
                    "resultCode=${resultName(resultCode)}; dropping",
            )
            return true
        }
        val expected = pendingExpectedCount
        val result = takePending()!!

        if (resultCode != Activity.RESULT_OK) {
            // showSeedSettings is informational: the user backing out of it is
            // a success, not a failure.
            if (requestCode == REQ_SEED_SETTINGS && resultCode == Activity.RESULT_CANCELED) {
                result.success(null)
                return true
            }
            val (code, message) = mapResultCode(resultCode)
            Log.i(TAG, "requestCode=$requestCode failed with $code")
            result.error(code, message, null)
            return true
        }

        try {
            when (requestCode) {
                REQ_AUTHORIZE_SEED ->
                    result.success(Wallet.onAuthorizeSeedResult(resultCode, data))

                REQ_SIGN_TRANSACTIONS ->
                    result.completeSignatures(
                        Wallet.onSignTransactionsResult(resultCode, data),
                        expected,
                    )

                REQ_SIGN_MESSAGES ->
                    result.completeSignatures(
                        Wallet.onSignMessagesResult(resultCode, data),
                        expected,
                    )

                REQ_PUBLIC_KEYS ->
                    result.completePublicKeys(
                        Wallet.onRequestPublicKeysResult(resultCode, data),
                        expected,
                    )

                REQ_SEED_SETTINGS -> result.success(null)
            }
        } catch (e: Wallet.ActionFailedException) {
            Log.e(TAG, "requestCode=$requestCode returned an unusable OK result")
            result.error(ERR_UNKNOWN, e.message ?: "Seed Vault returned no result", null)
        } catch (e: Exception) {
            Log.e(TAG, "requestCode=$requestCode result handling failed", e)
            result.error(ERR_UNKNOWN, e.message ?: e.javaClass.simpleName, null)
        }
        return true
    }

    private fun Result.completeSignatures(responses: List<SigningResponse>, expected: Int) {
        if (responses.size != expected) {
            error(
                ERR_UNKNOWN,
                "Seed Vault returned ${responses.size} responses for $expected payloads",
                null,
            )
            return
        }
        val signatures = ArrayList<ByteArray>(expected)
        for (response in responses) {
            // One requested path per request, so exactly one signature each.
            val sigs = response.signatures
            if (sigs.size != 1) {
                error(
                    ERR_UNKNOWN,
                    "Seed Vault returned ${sigs.size} signatures for one requested path",
                    null,
                )
                return
            }
            signatures.add(sigs[0])
        }
        success(signatures)
    }

    private fun Result.completePublicKeys(responses: List<PublicKeyResponse>, expected: Int) {
        if (responses.size != expected) {
            error(
                ERR_UNKNOWN,
                "Seed Vault returned ${responses.size} public keys for $expected paths",
                null,
            )
            return
        }
        val encoded = ArrayList<String>(expected)
        for ((i, response) in responses.withIndex()) {
            try {
                encoded.add(response.publicKeyEncoded)
            } catch (_: PublicKeyResponse.KeyNotValidException) {
                // Not every key exists in every derivation scheme. Fail loudly
                // rather than substituting a placeholder — a wrong address here
                // becomes a valid signature nobody can spend.
                error(ERR_UNKNOWN, "No key exists at requested derivation path $i", null)
                return
            }
        }
        success(encoded)
    }

    // ---------------------------------------------------------------------------
    // In-flight slot
    // ---------------------------------------------------------------------------

    /**
     * Reserve the single in-flight slot, or fail [result] outright. Returns
     * the Activity to launch from, or null when the caller must stop.
     */
    private fun beginRequest(result: Result, requestCode: Int, expectedCount: Int): Activity? {
        val act = activity
        if (act == null) {
            result.error(ERR_NO_ACTIVITY, "No Activity attached", null)
            return null
        }
        if (pendingResult != null) {
            // Refuse rather than replace: overwriting would strand the first
            // caller's Result forever.
            result.error(
                ERR_REQUEST_IN_FLIGHT,
                "Another Seed Vault request is already awaiting the user",
                null,
            )
            return null
        }
        pendingResult = result
        pendingRequestCode = requestCode
        pendingExpectedCount = expectedCount
        return act
    }

    /** Take the pending Result, if any, clearing the slot. */
    private fun takePending(): Result? {
        val result = pendingResult
        pendingResult = null
        pendingRequestCode = 0
        pendingExpectedCount = 0
        return result
    }

    /** True when the slot holds a request launched under [requestCode]. */
    private fun hasPending(requestCode: Int): Boolean =
        pendingResult != null && pendingRequestCode == requestCode

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /**
     * Check the two preconditions every call past `isAvailable` shares, and
     * hand back the Context to talk to Seed Vault with.
     *
     * That Context is the application's, not the Activity's: the SDK only
     * needs a PackageManager and a ContentResolver here, while the provider
     * work below runs on a background thread that must not outlive — or hold
     * on to — an Activity. The Activity is used for one thing only, launching
     * the approval intent.
     */
    private fun requireReady(result: Result): Context? {
        if (!isVaultAvailable(appContext)) {
            result.error(ERR_UNAVAILABLE, "No Seed Vault implementation on this device", null)
            return null
        }
        if (!hasSeedVaultPermission(appContext)) {
            result.error(ERR_PERMISSION_DENIED, "ACCESS_SEED_VAULT not granted", null)
            return null
        }
        return appContext
    }

    /**
     * Run [work] on the IO thread and complete [result] back on the platform
     * thread — a Flutter Result may only be completed there, and every caller
     * of this helper is doing Binder IPC that must not block the platform
     * thread.
     */
    private fun offPlatformThread(result: Result, work: () -> Any?) {
        val executor = io
        if (executor == null) {
            result.error(ERR_UNKNOWN, "Plugin detached from engine", null)
            return
        }
        executor.execute {
            try {
                val value = work()
                platformHandler.post { result.success(value) }
            } catch (e: Throwable) {
                val (code, message) = mapProviderError(e)
                Log.w(TAG, "content provider call failed with $code")
                platformHandler.post { result.error(code, message, null) }
            }
        }
    }

    private fun mapProviderError(e: Throwable): Pair<String, String> {
        val message = e.message ?: e.javaClass.simpleName
        return when (e) {
            is Wallet.NotModifiedException -> ERR_NOT_MODIFIED to message
            // Every provider call here passes a fixed projection and no
            // filter, so the SDK's only remaining IllegalArgumentException
            // case is an auth token this app may not use.
            is IllegalArgumentException -> ERR_INVALID_AUTH_TOKEN to message
            is SecurityException -> ERR_PERMISSION_DENIED to message
            is IllegalStateException -> ERR_UNAVAILABLE to message
            else -> ERR_UNKNOWN to message
        }
    }

    /**
     * The contract names an error code for each result the Dart side acts on.
     * INVALID_AUTH_TOKEN triggers a re-resolve and CANCELED means the user
     * declined, so neither may collapse into UNKNOWN_ERROR. The results with
     * no distinct code still carry their name in the message.
     */
    private fun mapResultCode(resultCode: Int): Pair<String, String> = when (resultCode) {
        Activity.RESULT_CANCELED ->
            ERR_CANCELED to "The user dismissed the Seed Vault request"
        WalletContractV1.RESULT_INVALID_AUTH_TOKEN ->
            ERR_INVALID_AUTH_TOKEN to "The seed is no longer authorized for this app"
        WalletContractV1.RESULT_AUTHENTICATION_FAILED ->
            ERR_AUTHENTICATION_FAILED to "Seed Vault authentication failed"
        WalletContractV1.RESULT_INVALID_PAYLOAD ->
            ERR_INVALID_PAYLOAD to "Seed Vault rejected the payload"
        WalletContractV1.RESULT_IMPLEMENTATION_LIMIT_EXCEEDED ->
            ERR_IMPLEMENTATION_LIMIT to "Seed Vault implementation limit exceeded"
        else -> ERR_UNKNOWN to "Seed Vault failed: ${resultName(resultCode)}"
    }

    private fun resultName(resultCode: Int): String = when (resultCode) {
        Activity.RESULT_OK -> "RESULT_OK"
        Activity.RESULT_CANCELED -> "RESULT_CANCELED"
        WalletContractV1.RESULT_UNSPECIFIED_ERROR -> "RESULT_UNSPECIFIED_ERROR"
        WalletContractV1.RESULT_INVALID_AUTH_TOKEN -> "RESULT_INVALID_AUTH_TOKEN"
        WalletContractV1.RESULT_INVALID_PAYLOAD -> "RESULT_INVALID_PAYLOAD"
        WalletContractV1.RESULT_AUTHENTICATION_FAILED -> "RESULT_AUTHENTICATION_FAILED"
        WalletContractV1.RESULT_NO_AVAILABLE_SEEDS -> "RESULT_NO_AVAILABLE_SEEDS"
        WalletContractV1.RESULT_INVALID_PURPOSE -> "RESULT_INVALID_PURPOSE"
        WalletContractV1.RESULT_INVALID_DERIVATION_PATH -> "RESULT_INVALID_DERIVATION_PATH"
        WalletContractV1.RESULT_IMPLEMENTATION_LIMIT_EXCEEDED ->
            "RESULT_IMPLEMENTATION_LIMIT_EXCEEDED"
        else -> "UNKNOWN($resultCode)"
    }

    /**
     * Auth tokens and account ids are Java longs, but the standard method
     * codec sends a small Dart int as an Integer — so read them as Number.
     */
    private fun MethodCall.longArg(name: String): Long? =
        (argument<Any>(name) as? Number)?.toLong()

    private fun Result.missing(name: String) =
        error(ERR_INVALID_PAYLOAD, "Missing or invalid argument: $name", null)

    /** Seed Vault stores "no name" as a blank string; the channel reports null. */
    private fun String?.nullIfBlank(): String? = if (isNullOrBlank()) null else this
}
