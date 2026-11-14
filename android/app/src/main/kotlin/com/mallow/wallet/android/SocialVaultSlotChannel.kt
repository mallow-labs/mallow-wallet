package com.mallow.wallet.android

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.BlockstoreClient
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * The Android platform slot of the social vault, in Google Block Store.
 *
 * Block Store keeps a few small byte blobs per app, survives an uninstall on
 * the device, and — with `setShouldBackupToCloud(true)` — is restored onto a
 * new Android device during that device's setup (not later). That backup is
 * end-to-end encrypted only while the device has a screen lock (and runs
 * Android 9 or later), and Block Store has no "require encryption" option. So
 * the app asks, and acts on the answer:
 *
 * - `isAvailable` and `isBackupEncrypted` both answer
 *   `isEndToEndEncryptionAvailable()` — the first as "may a platform slot be
 *   created here", the second as "is the backup encrypted right now", which
 *   the app re-reads every time it comes forward. No Play services, or any
 *   error, reads as "not encrypted".
 * - Every write re-checks it and stores the entry without cloud backup
 *   whenever the answer is not a clear yes, rather than in a backup Google
 *   could read. `add` and `setCloudBackup` return whether the entry was
 *   stored with cloud backup on.
 * - `setCloudBackup` rewrites an existing entry with the bytes it already
 *   holds and the requested flag: off when the screen lock is gone, on again
 *   when it is back. It never takes a value, so it cannot replace a secret.
 *
 * This is deliberately NOT MnemonicVaultChannel: wallet keys and phrases stay
 * in the hardware-backed, this-device-only Keystore. Only per-slot secrets
 * live here, and one alone opens nothing.
 *
 * One Block Store entry per (vault, slot), keyed `mallow.sv.<vaultId>.<slotId>`.
 * A new entry never replaces one (`add` fails on an existing key) and Block
 * Store's 16-entry limit is respected (`add` fails with `store_full`).
 */
class SocialVaultSlotChannel : FlutterPlugin, MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "art.mallow.wallet/social_vault_slot"
        const val MAX_ENTRIES = 16
    }

    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    private val client: BlockstoreClient by lazy { Blockstore.getClient(context) }

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
            // The same question on Android, asked for two reasons: whether a
            // platform slot may be created, and whether the backup that holds
            // the existing ones is encrypted right now.
            "isAvailable", "isBackupEncrypted" -> endToEndEncrypted { result.success(it) }
            "list" -> {
                val prefix = call.argument<String>("prefix")
                if (prefix == null) {
                    result.error("invalid_args", "Missing prefix", null)
                    return
                }
                readAll(result) { all ->
                    result.success(all.filterKeys { it.startsWith(prefix) })
                }
            }
            "add" -> {
                val key = call.argument<String>("key")
                val value = call.argument<String>("value")
                if (key == null || value == null) {
                    result.error("invalid_args", "Missing key or value", null)
                    return
                }
                readAll(result) { all ->
                    when {
                        all.containsKey(key) -> result.error("exists", "Slot entry already exists", null)
                        all.size >= MAX_ENTRIES -> result.error("store_full", "Block Store holds $MAX_ENTRIES entries", null)
                        else -> store(key, value.toByteArray(Charsets.UTF_8), true, result)
                    }
                }
            }
            "setCloudBackup" -> {
                val key = call.argument<String>("key")
                val cloudBackup = call.argument<Boolean>("cloudBackup")
                if (key == null || cloudBackup == null) {
                    result.error("invalid_args", "Missing key or cloudBackup", null)
                    return
                }
                // The entry's own bytes, read back and stored again under the
                // same key (which replaces it) with the requested flag.
                val request = RetrieveBytesRequest.Builder().setKeys(listOf(key)).build()
                client.retrieveBytes(request)
                    .addOnSuccessListener { response ->
                        val bytes = response.blockstoreDataMap[key]?.bytes
                        if (bytes == null) {
                            result.error("not_found", "No such slot entry", null)
                        } else {
                            store(key, bytes, cloudBackup, result)
                        }
                    }
                    .addOnFailureListener { result.error("read_failed", it.javaClass.simpleName, null) }
            }
            "delete" -> {
                val key = call.argument<String>("key")
                if (key == null) {
                    result.error("invalid_args", "Missing key", null)
                    return
                }
                val request = DeleteBytesRequest.Builder().setKeys(listOf(key)).build()
                client.deleteBytes(request)
                    .addOnSuccessListener { result.success(null) }
                    .addOnFailureListener { result.error("delete_failed", it.javaClass.simpleName, null) }
            }
            else -> result.notImplemented()
        }
    }

    /** Every entry this app holds, as key → UTF-8 value. */
    private fun readAll(result: Result, then: (Map<String, String>) -> Unit) {
        val request = RetrieveBytesRequest.Builder().setRetrieveAll(true).build()
        client.retrieveBytes(request)
            .addOnSuccessListener { response ->
                val all = response.blockstoreDataMap.mapValues { (_, data) ->
                    String(data.bytes, Charsets.UTF_8)
                }
                then(all)
            }
            .addOnFailureListener { result.error("read_failed", it.javaClass.simpleName, null) }
    }

    /**
     * Whether Block Store's backup is end-to-end encrypted right now. Anything
     * but a clear yes — no Play services, an error — is a no.
     */
    private fun endToEndEncrypted(then: (Boolean) -> Unit) {
        try {
            client.isEndToEndEncryptionAvailable
                .addOnCompleteListener { task -> then(task.isSuccessful && task.result == true) }
        } catch (e: Exception) {
            then(false)
        }
    }

    /**
     * Store [bytes] under [key], replacing what is there. The entry goes to
     * the cloud backup only when [cloudBackup] asks for it AND the backup is
     * end-to-end encrypted at this moment; otherwise it stays on this device
     * alone. Answers which of the two happened.
     */
    private fun store(key: String, bytes: ByteArray, cloudBackup: Boolean, result: Result) {
        endToEndEncrypted { encrypted ->
            val backedUp = cloudBackup && encrypted
            val data = StoreBytesData.Builder()
                .setKey(key)
                .setBytes(bytes)
                .setShouldBackupToCloud(backedUp)
                .build()
            client.storeBytes(data)
                .addOnSuccessListener { result.success(backedUp) }
                .addOnFailureListener { result.error("write_failed", it.javaClass.simpleName, null) }
        }
    }
}
