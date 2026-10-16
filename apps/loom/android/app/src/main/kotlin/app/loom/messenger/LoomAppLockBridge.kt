package app.loom.messenger

import android.app.Activity
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.UserNotAuthenticatedException
import android.util.Base64
import android.util.Log
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.AEADBadTagException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Crypto-bound local unlock. The non-exportable auth key wraps a random vault
 * key; the latter exists only in native process memory while this app is open.
 * No fallback to an unauthenticated key when the enrolled key is unavailable. */
class LoomAppLockBridge(private val activity: Activity) {
    private val prefs = activity.getSharedPreferences("loom.app_lock.v1", Activity.MODE_PRIVATE)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var vaultKey: ByteArray? = null
    private var prompt: CancellationSignal? = null
    private var authHandoffPending = false
    private var diagnostics = false
    private val authHandoffTimeout = Runnable {
        if (authHandoffPending) {
            trace("handoff_timeout")
            lock()
        }
    }
    val enabled: Boolean get() = prefs.contains("capsule")
    val locked: Boolean get() = enabled && vaultKey == null
    var onLocked: (() -> Unit)? = null

    // Fixed stages and exception class names only. Never log exception text,
    // MethodCall arguments, credential names, plaintext, keys or ciphertext.
    private fun trace(stage: String, error: Exception? = null) {
        if (diagnostics) {
            val suffix = error?.let { " error_class=${it.javaClass.simpleName}" } ?: ""
            Log.i("LoomAppLock", "stage=$stage$suffix")
        }
    }

    fun onResume() { trace("activity_resumed") }
    fun onPause() { trace("activity_paused") }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setDiagnostics" -> {
                    diagnostics = call.argument<Boolean>("enabled") == true
                    result.success(null)
                }
                "status" -> result.success(status())
                "completeAuthHandoff" -> {
                    completeAuthHandoff()
                    trace("handoff_complete")
                    result.success(null)
                }
                "openDeviceSecuritySettings" -> {
                    val intent = if (Build.VERSION.SDK_INT >= 30) {
                        Intent(Settings.ACTION_BIOMETRIC_ENROLL).putExtra(
                            Settings.EXTRA_BIOMETRIC_AUTHENTICATORS_ALLOWED,
                            BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                    } else Intent(Settings.ACTION_SECURITY_SETTINGS)
                    activity.startActivity(intent)
                    result.success(null)
                }
                "enable" -> authenticate(true, call.argument<String>("title") ?: "Unlock Loom", result)
                "unlock" -> authenticate(false, call.argument<String>("title") ?: "Unlock Loom", result)
                "lock" -> { lock(); result.success(null) }
                "disable" -> {
                    check(enabled && vaultKey != null && prompt == null) { "vault_locked" }
                    check(prefs.edit().remove("capsule").commit()) { "vault_persist_failed" }
                    lock()
                    KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS)
                    secureWindow(false)
                    result.success(null)
                }
                "wrap", "unwrap" -> {
                    val key = vaultKey ?: error("vault_locked")
                    val value = call.argument<ByteArray>("value") ?: error("invalid_value")
                    val name = call.argument<String>("key") ?: error("invalid_key")
                    require(value.size <= 4 * 1024 * 1024 && name.startsWith("loom."))
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    val output: ByteArray
                    try {
                        if (call.method == "wrap") {
                            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
                            cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
                            output = cipher.iv + cipher.doFinal(value)
                        } else {
                            require(value.size >= 28)
                            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, value.copyOfRange(0, 12)))
                            cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
                            output = cipher.doFinal(value, 12, value.size - 12)
                        }
                        try { result.success(output) } finally { output.fill(0) }
                    } finally { value.fill(0) }
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            reportFailure(result, error)
        }
    }

    private fun reportFailure(result: MethodChannel.Result, error: Exception) {
        val code = when (error) {
            is KeyPermanentlyInvalidatedException -> "vault_key_invalidated"
            is UserNotAuthenticatedException -> "vault_auth_required"
            is AEADBadTagException -> "vault_integrity_failed"
            else -> when (error.message) {
                "vault_locked", "vault_key_missing", "vault_persist_failed", "vault_unsupported", "vault_prompt_busy" -> error.message!!
                else -> "vault_unavailable"
            }
        }
        // Send only a bounded code, never exception text, key material or data.
        trace("native_failed:$code", error)
        result.error(code, "Protected storage operation could not finish.", null)
    }

    private fun status(): Map<String, Any> {
        val reason = if (Build.VERSION.SDK_INT < 30) "android_version" else {
            when (activity.getSystemService(BiometricManager::class.java).canAuthenticate(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)) {
                BiometricManager.BIOMETRIC_SUCCESS -> "ready"
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "not_enrolled"
                else -> "authenticator_unavailable"
            }
        }
        secureWindow(enabled)
        return mapOf("available" to (reason == "ready"), "reason" to reason, "enabled" to enabled, "locked" to locked)
    }

    fun onStop() {
        trace(when {
            prompt != null -> "activity_stopped_prompt"
            authHandoffPending -> "activity_stopped_handoff"
            else -> "activity_stopped"
        })
        // The OS credential prompt and its successful handoff can both stop the
        // Activity briefly. Keep the key only until Flutter confirms resumed;
        // a bounded timeout below still fails closed if that ACK never arrives.
        if (prompt == null && !authHandoffPending) lock()
    }

    private fun beginAuthHandoff() {
        authHandoffPending = true
        mainHandler.removeCallbacks(authHandoffTimeout)
        mainHandler.postDelayed(authHandoffTimeout, AUTH_HANDOFF_TIMEOUT_MS)
    }

    private fun completeAuthHandoff() {
        authHandoffPending = false
        mainHandler.removeCallbacks(authHandoffTimeout)
    }

    fun lock() {
        trace("vault_lock")
        completeAuthHandoff()
        vaultKey?.fill(0)
        vaultKey = null
        if (enabled) onLocked?.invoke()
    }

    fun dispose() { prompt?.cancel(); prompt = null; lock(); onLocked = null }

    private fun secureWindow(secure: Boolean) {
        if (secure) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(ALIAS, null) as? SecretKey
        if (existing != null) return existing
        check(create && !enabled && Build.VERSION.SDK_INT >= 30) { "vault_key_missing" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUserAuthenticationRequired(true)
                .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
                .build())
            generateKey()
        }
    }

    private fun authenticate(create: Boolean, title: String, result: MethodChannel.Result) {
        trace(if (create) "enable_native_start" else "unlock_native_start")
        check(Build.VERSION.SDK_INT >= 30) { "vault_unsupported" }
        check(prompt == null && !authHandoffPending) { "vault_prompt_busy" }
        if (create && enabled) { result.success(false); return }
        if (!create && !enabled) { result.success(true); return }
        val capsule = if (create) null else Base64.decode(prefs.getString("capsule", null), Base64.NO_WRAP)
        val fresh = if (create) ByteArray(32).also { SecureRandom().nextBytes(it) } else null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        try {
            if (create) cipher.init(Cipher.ENCRYPT_MODE, key(true))
            else {
                require(capsule != null && capsule.size == 60)
                cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, capsule.copyOfRange(0, 12)))
            }
            val cancellation = CancellationSignal()
            prompt = cancellation
            val biometric = BiometricPrompt.Builder(activity)
                .setTitle(title.take(100))
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                .build()
            biometric.authenticate(BiometricPrompt.CryptoObject(cipher), cancellation, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        trace("authentication_error:$code")
                        fresh?.fill(0)
                        if (prompt !== cancellation) return
                        prompt = null
                        when (code) {
                            BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
                            BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED -> result.success(false)
                            BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
                            BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> result.error("vault_auth_lockout", "Device authentication is temporarily locked.", null)
                            else -> result.error("vault_auth_unavailable", "Device authentication could not finish.", null)
                        }
                    }
                    override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                        if (prompt !== cancellation) { fresh?.fill(0); return }
                        trace("biometric_success")
                        prompt = null
                        try {
                            val authorized = auth.cryptoObject?.cipher ?: error("authentication_not_bound")
                            // updateAAD submits an operation to Android Keystore.
                            // Auth-per-use keys cannot process it before the OS
                            // prompt authorizes this exact CryptoObject.
                            authorized.updateAAD(ALIAS.toByteArray(Charsets.UTF_8))
                            if (create) {
                                val protected = authorized.iv + authorized.doFinal(fresh!!)
                                check(prefs.edit().putString("capsule", Base64.encodeToString(protected, Base64.NO_WRAP)).commit()) { "vault_persist_failed" }
                                vaultKey?.fill(0)
                                vaultKey = fresh.copyOf()
                            } else {
                                val opened = authorized.doFinal(capsule!!, 12, capsule.size - 12)
                                check(opened.size == 32)
                                vaultKey?.fill(0)
                                vaultKey = opened
                            }
                            beginAuthHandoff()
                            trace("vault_key_ready")
                            secureWindow(true)
                            result.success(true)
                        } catch (error: Exception) {
                            lock()
                            reportFailure(result, error)
                        } finally { fresh?.fill(0) }
                    }
                })
        } catch (error: Exception) { fresh?.fill(0); prompt = null; throw error }
    }

    companion object {
        const val CHANNEL = "loom/app_lock"
        private const val ALIAS = "loom.app_lock.auth_key.v1"
        private const val AUTH_HANDOFF_TIMEOUT_MS = 5_000L
    }
}
