package app.cogwheel.conduit.push

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** One push subscription's key material and delivery state. */
class PushSubscriptionRecord(
    val sid: String,
    val scope: String,
    /** P-256 private scalar, 32 bytes. Never leaves the device. */
    val privateKey: ByteArray,
    /** Uncompressed public key, base64url. */
    val p256dh: String,
    /** Auth secret, base64url. */
    val auth: String,
    val createdAtMillis: Long,
    val endpoint: String?,
    /** [PushTransportName] the endpoint belongs to, or null before one is set. */
    val transport: String?,
) {
    val publicKeyBytes: ByteArray get() = Base64Url.decode(p256dh)
    val authBytes: ByteArray get() = Base64Url.decode(auth)

    fun withEndpoint(endpoint: String?, transport: String?) = PushSubscriptionRecord(
        sid, scope, privateKey, p256dh, auth, createdAtMillis, endpoint, transport
    )
}

/** Transport names as stored; they mirror `PlatformPushTransport`. */
object PushTransportName {
    const val APNS = "apns"
    const val FCM = "fcm"
    const val UNIFIED_PUSH = "unifiedPush"
}

/** Seals the key store file. Injectable so JVM tests run without a Keystore. */
interface PushStoreCipher {
    fun seal(plaintext: ByteArray): ByteArray

    /**
     * @throws PushStoreUnreadableException when the sealed bytes can never be
     *   opened again (key gone or data corrupt). Any other exception is
     *   treated as transient.
     */
    fun open(sealed: ByteArray): ByteArray
}

class PushStoreUnreadableException(message: String, cause: Throwable? = null) :
    IOException(message, cause)

/**
 * AES-256-GCM with a non-exportable key in the Android Keystore. The sealed
 * form is `0x01 ‖ iv (12) ‖ ciphertext+tag`.
 */
internal class AndroidKeystoreStoreCipher(private val alias: String = ALIAS) : PushStoreCipher {
    override fun seal(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.updateAAD(AAD)
        val sealed = cipher.doFinal(plaintext)
        val iv = cipher.iv
        check(iv.size == IV_LENGTH) { "Unexpected IV length ${iv.size}" }
        return byteArrayOf(FORMAT) + iv + sealed
    }

    override fun open(sealed: ByteArray): ByteArray {
        if (sealed.size < 1 + IV_LENGTH + 16 || sealed[0] != FORMAT) {
            throw PushStoreUnreadableException("Unknown push store format")
        }
        val key = key(create = false)
            ?: throw PushStoreUnreadableException("Push store key is gone")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(128, sealed, 1, IV_LENGTH),
        )
        cipher.updateAAD(AAD)
        return try {
            cipher.doFinal(sealed, 1 + IV_LENGTH, sealed.size - 1 - IV_LENGTH)
        } catch (error: AEADBadTagException) {
            throw PushStoreUnreadableException("Push store failed authentication", error)
        }
    }

    private fun key(create: Boolean): SecretKey? {
        val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    companion object {
        const val ALIAS = "conduit_push_store"
        private const val PROVIDER = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_LENGTH = 12
        private const val FORMAT: Byte = 0x01
        private val AAD = "conduit-push-store/1".toByteArray(Charsets.US_ASCII)
    }
}

/**
 * Every push subscription on this device, kept as one JSON document sealed
 * by [cipher] in a file that is excluded from backups (the keys would be
 * useless on another device, and must not leave this one).
 */
class PushKeyStore internal constructor(
    private val file: AtomicBytesFile,
    private val cipher: PushStoreCipher,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private var cache: List<PushSubscriptionRecord>? = null

    /** Generates a key pair, auth secret and sid for [scope] and stores them. */
    @Synchronized
    fun create(scope: String): PushSubscriptionRecord {
        val records = load()
        val keys = PushCrypto.generateKeyMaterial()
        var sid: String
        do {
            sid = Base64Url.encode(PushCrypto.randomBytes(16))
        } while (records.any { it.sid == sid })
        val record = PushSubscriptionRecord(
            sid = sid,
            scope = scope,
            privateKey = keys.privateKey,
            p256dh = Base64Url.encode(keys.publicKey),
            auth = Base64Url.encode(keys.auth),
            createdAtMillis = clock(),
            endpoint = null,
            transport = null,
        )
        save(records + record)
        return record
    }

    @Synchronized
    fun list(): List<PushSubscriptionRecord> = load()

    @Synchronized
    fun find(sid: String): PushSubscriptionRecord? = load().firstOrNull { it.sid == sid }

    /** @return false when [sid] is unknown. */
    @Synchronized
    fun setEndpoint(sid: String, endpoint: String?, transport: String?): Boolean {
        val records = load()
        if (records.none { it.sid == sid }) return false
        save(records.map { if (it.sid == sid) it.withEndpoint(endpoint, transport) else it })
        return true
    }

    /** @return the removed record, or null when [sid] is unknown. */
    @Synchronized
    fun delete(sid: String): PushSubscriptionRecord? {
        val records = load()
        val removed = records.firstOrNull { it.sid == sid } ?: return null
        save(records.filter { it.sid != sid })
        return removed
    }

    private fun load(): List<PushSubscriptionRecord> {
        cache?.let { return it }
        val sealed = file.readOrNull()
        val records = if (sealed == null) {
            emptyList()
        } else {
            try {
                decode(cipher.open(sealed))
            } catch (error: PushStoreUnreadableException) {
                // The keys are lost for good (Keystore wiped, data corrupt).
                // Start over; the app re-subscribes every account.
                Log.w(TAG, "Push key store unreadable, starting empty", error)
                emptyList()
            } catch (error: JSONException) {
                Log.w(TAG, "Push key store corrupt, starting empty", error)
                emptyList()
            } catch (error: IllegalArgumentException) {
                Log.w(TAG, "Push key store corrupt, starting empty", error)
                emptyList()
            }
            // Anything else (a transient Keystore failure) propagates, so a
            // later write can't replace subscriptions that still exist.
        }
        cache = records
        return records
    }

    private fun save(records: List<PushSubscriptionRecord>) {
        try {
            file.write(cipher.seal(encode(records)))
        } catch (error: GeneralSecurityException) {
            throw IOException("Could not seal the push key store", error)
        }
        cache = records
    }

    internal companion object {
        private const val TAG = "PushKeyStore"
        private const val VERSION = 1

        fun encode(records: List<PushSubscriptionRecord>): ByteArray {
            val array = JSONArray()
            records.forEach { record ->
                array.put(
                    JSONObject()
                        .put("sid", record.sid)
                        .put("scope", record.scope)
                        .put("d", Base64Url.encode(record.privateKey))
                        .put("p256dh", record.p256dh)
                        .put("auth", record.auth)
                        .put("createdAt", record.createdAtMillis)
                        .put("endpoint", record.endpoint ?: JSONObject.NULL)
                        .put("transport", record.transport ?: JSONObject.NULL)
                )
            }
            return JSONObject()
                .put("v", VERSION)
                .put("subscriptions", array)
                .toString()
                .toByteArray(Charsets.UTF_8)
        }

        fun decode(bytes: ByteArray): List<PushSubscriptionRecord> {
            val root = JSONObject(String(bytes, Charsets.UTF_8))
            if (root.optInt("v") != VERSION) throw JSONException("Unknown push store version")
            val array = root.getJSONArray("subscriptions")
            return (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                PushSubscriptionRecord(
                    sid = item.getString("sid"),
                    scope = item.getString("scope"),
                    privateKey = Base64Url.decode(item.getString("d")),
                    p256dh = item.getString("p256dh"),
                    auth = item.getString("auth"),
                    createdAtMillis = item.getLong("createdAt"),
                    endpoint = item.optStringOrNull("endpoint"),
                    transport = item.optStringOrNull("transport"),
                )
            }
        }

        private fun JSONObject.optStringOrNull(key: String): String? =
            if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }
    }
}
