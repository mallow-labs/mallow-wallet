package com.mallow.wallet.android

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Native AndroidKeystore handler for mnemonic/private-key storage.
 *
 * Each secret is encrypted with a hardware-backed AES-256-GCM key in
 * AndroidKeystore; the ciphertext + IV live in plaintext SharedPreferences
 * (worthless without the keystore key). The keystore key is NOT bound to user
 * authentication, so reads/writes need no BiometricPrompt and no device lock
 * screen — the same tier as the DB encryption key. The app's own dual-lock
 * (PIN and/or biometric app-lock) is the user-facing gate; see AppLockBloc.
 */
class MnemonicVaultChannel : FlutterPlugin, MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "art.mallow.wallet/mnemonic_vault"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val PREFS_NAME = "mallow_vault_prefs"
        private const val KEY_PREFIX_IV = "iv_"
        private const val KEY_PREFIX_CT = "ct_"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_LENGTH = 128
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
        val key = call.argument<String>("key")
        if (key == null) {
            result.error("invalid_args", "Missing key", null)
            return
        }
        when (call.method) {
            "write" -> {
                val value = call.argument<String>("value")
                if (value == null) {
                    result.error("invalid_args", "Missing value", null)
                    return
                }
                vaultWrite(key, value, result)
            }
            "read" -> vaultRead(key, result)
            "delete" -> vaultDelete(key, result)
            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Write: encrypt and store. No biometric needed to write.
    // -------------------------------------------------------------------------

    private fun vaultWrite(key: String, value: String, result: Result) {
        try {
            ensureKey(key)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey(key))
            val iv = cipher.iv
            val ct = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            prefs().edit()
                .putString(KEY_PREFIX_IV + key, Base64.encodeToString(iv, Base64.NO_WRAP))
                .putString(KEY_PREFIX_CT + key, Base64.encodeToString(ct, Base64.NO_WRAP))
                .apply()
            result.success(null)
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    // -------------------------------------------------------------------------
    // Read: decrypt with the keystore key. No authentication required.
    // -------------------------------------------------------------------------

    private fun vaultRead(key: String, result: Result) {
        val ivB64 = prefs().getString(KEY_PREFIX_IV + key, null)
        val ctB64 = prefs().getString(KEY_PREFIX_CT + key, null)
        if (ivB64 == null || ctB64 == null) {
            result.success(null) // not found
            return
        }

        val secretKey = try {
            loadKey(key) ?: run {
                result.success(null) // key deleted, treat as not found
                return
            }
        } catch (e: Exception) {
            result.error("key_load_failed", e.message, null)
            return
        }

        try {
            val iv = Base64.decode(ivB64, Base64.NO_WRAP)
            val ct = Base64.decode(ctB64, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_LENGTH, iv))
            val plaintext = cipher.doFinal(ct)
            result.success(String(plaintext, Charsets.UTF_8))
        } catch (e: Exception) {
            result.error("decrypt_failed", e.message, null)
        }
    }

    // -------------------------------------------------------------------------
    // Delete: remove ciphertext + IV and keystore key.
    // -------------------------------------------------------------------------

    private fun vaultDelete(key: String, result: Result) {
        prefs().edit()
            .remove(KEY_PREFIX_IV + key)
            .remove(KEY_PREFIX_CT + key)
            .apply()
        try {
            val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).also { it.load(null) }
            if (ks.containsAlias(keystoreAlias(key))) ks.deleteEntry(keystoreAlias(key))
        } catch (_: Exception) {}
        result.success(null)
    }

    // -------------------------------------------------------------------------
    // Keystore helpers
    // -------------------------------------------------------------------------

    private fun keystoreAlias(key: String) = "mallow_vault_$key"

    private fun ensureKey(key: String) {
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).also { it.load(null) }
        if (!ks.containsAlias(keystoreAlias(key))) {
            generateKey(key)
        }
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun generateKey(key: String) {
        val keyGen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        // No setUserAuthenticationRequired: the key is usable without a
        // BiometricPrompt and without a device lock screen, so onboarding
        // writes succeed regardless of biometric enrollment. At-rest
        // protection comes from the hardware-backed keystore; the user gate
        // is the app-lock layer.
        val spec = KeyGenParameterSpec.Builder(
            keystoreAlias(key),
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build()
        keyGen.init(spec)
        keyGen.generateKey()
    }

    private fun getOrCreateKey(key: String): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).also { it.load(null) }
        return ks.getKey(keystoreAlias(key), null) as? SecretKey ?: run {
            generateKey(key)
            ks.getKey(keystoreAlias(key), null) as SecretKey
        }
    }

    private fun loadKey(key: String): SecretKey? {
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).also { it.load(null) }
        return ks.getKey(keystoreAlias(key), null) as? SecretKey
    }

    private fun prefs(): SharedPreferences =
        appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
