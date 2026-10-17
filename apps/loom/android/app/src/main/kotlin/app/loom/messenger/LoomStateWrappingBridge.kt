package app.loom.messenger

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * App-scoped Android Keystore wrapping boundary for serialized v2 provider state.
 *
 * One non-exportable AES-256 key wraps account/session pickles before SQLite.
 * StrongBox is requested when the device advertises it, but ordinary Android
 * Keystore is the required fallback. This bridge never stores plaintext or the
 * wrapping key in Flutter/SQLite and never exports the key material.
 */
class LoomStateWrappingBridge(
    private val activity: Activity,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "status" -> {
                executor.execute {
                    try {
                        getOrCreateKey()
                        post {
                            result.success(
                                mapOf(
                                    "available" to true,
                                    "scheme" to SCHEME,
                                    "strongBoxPreference" to canRequestStrongBox(),
                                ),
                            )
                        }
                    } catch (_: Throwable) {
                        post {
                            result.success(
                                mapOf(
                                    "available" to false,
                                    "scheme" to SCHEME,
                                    "strongBoxPreference" to canRequestStrongBox(),
                                ),
                            )
                        }
                    }
                }
                return true
            }
            "wrap" -> {
                val plaintext = call.argument<ByteArray>("plaintext")
                val associatedData = call.argument<ByteArray>("associatedData")
                if (plaintext == null || associatedData == null) {
                    result.error("invalid_state", "Missing state wrapping input", null)
                } else {
                    wrap(plaintext, associatedData, result)
                }
                return true
            }
            "unwrap" -> {
                val protectedState = call.argument<ByteArray>("protectedState")
                val associatedData = call.argument<ByteArray>("associatedData")
                if (protectedState == null || associatedData == null) {
                    result.error("invalid_state", "Missing protected state input", null)
                } else {
                    unwrap(protectedState, associatedData, result)
                }
                return true
            }
            else -> return false
        }
    }

    fun shutdown() {
        executor.shutdownNow()
    }

    private fun wrap(
        plaintext: ByteArray,
        associatedData: ByteArray,
        result: MethodChannel.Result,
    ) {
        if (!validPlaintext(plaintext) || !validAssociatedData(associatedData)) {
            result.error("invalid_state", "State wrapping input exceeds bounds", null)
            return
        }
        executor.execute {
            try {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
                val iv = cipher.iv
                if (iv == null || iv.size != IV_BYTES) {
                    throw IllegalStateException("Unexpected Android Keystore GCM IV length")
                }
                cipher.updateAAD(associatedData)
                val ciphertext = cipher.doFinal(plaintext)
                val output = ByteBuffer.allocate(2 + iv.size + ciphertext.size)
                    .put(FORMAT_VERSION)
                    .put(iv.size.toByte())
                    .put(iv)
                    .put(ciphertext)
                    .array()
                post { result.success(output) }
            } catch (_: Throwable) {
                post { result.error("state_wrap_failed", "Protected state wrapping failed", null) }
            }
        }
    }

    private fun unwrap(
        protectedState: ByteArray,
        associatedData: ByteArray,
        result: MethodChannel.Result,
    ) {
        if (!validProtectedState(protectedState) || !validAssociatedData(associatedData)) {
            result.error("invalid_state", "Protected state input exceeds bounds", null)
            return
        }
        executor.execute {
            try {
                val buffer = ByteBuffer.wrap(protectedState)
                val version = buffer.get()
                val ivLength = buffer.get().toInt() and 0xff
                if (version != FORMAT_VERSION || ivLength != IV_BYTES || buffer.remaining() <= TAG_BYTES) {
                    throw IllegalArgumentException("Unsupported protected-state envelope")
                }
                val iv = ByteArray(ivLength)
                buffer.get(iv)
                val ciphertext = ByteArray(buffer.remaining())
                buffer.get(ciphertext)

                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    getOrCreateKey(),
                    GCMParameterSpec(TAG_BITS, iv),
                )
                cipher.updateAAD(associatedData)
                val plaintext = cipher.doFinal(ciphertext)
                if (!validPlaintext(plaintext)) {
                    throw IllegalArgumentException("Unwrapped state exceeds bounds")
                }
                post { result.success(plaintext) }
            } catch (_: AEADBadTagException) {
                post { result.error("state_authentication_failed", "Protected state authentication failed", null) }
            } catch (_: Throwable) {
                post { result.error("state_unwrap_failed", "Protected state unwrapping failed", null) }
            }
        }
    }

    private fun getOrCreateKey(): SecretKey {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            throw UnsupportedOperationException("Android Keystore AES-GCM requires Android 6 or newer")
        }
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        if (canRequestStrongBox()) {
            try {
                return generateKey(strongBox = true)
            } catch (_: StrongBoxUnavailableException) {
                // StrongBox is optional by Architecture-v2 policy. Fall through
                // to the regular Android Keystore rather than making it a
                // cryptographic availability prerequisite.
            }
        }
        return generateKey(strongBox = false)
    }

    private fun generateKey(strongBox: Boolean): SecretKey {
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun canRequestStrongBox(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)

    private fun validPlaintext(value: ByteArray): Boolean =
        value.isNotEmpty() && value.size <= MAX_STATE_BYTES

    private fun validProtectedState(value: ByteArray): Boolean =
        value.size >= 2 + IV_BYTES + TAG_BYTES &&
            value.size <= MAX_STATE_BYTES + 2 + IV_BYTES + TAG_BYTES

    private fun validAssociatedData(value: ByteArray): Boolean =
        value.isNotEmpty() && value.size <= MAX_AAD_BYTES

    private fun post(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }

    companion object {
        const val CHANNEL = "loom/state_wrapping"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "loom.v2.provider_state_wrapping.v1"
        private const val SCHEME = "android-keystore-aes256-gcm-v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val MAX_STATE_BYTES = 1024 * 1024
        private const val MAX_AAD_BYTES = 4096
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
        private const val TAG_BYTES = TAG_BITS / 8
        private const val FORMAT_VERSION: Byte = 1
    }
}
