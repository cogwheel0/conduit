package app.cogwheel.conduit.push

import java.io.File
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

/** The shared vectors in push/test-vectors, on the unit-test classpath. */
internal object PushVectors {
    val cp1: JSONObject by lazy { load("cp1_vectors.json") }
    val rfc8291: JSONObject by lazy { load("rfc8291.json") }

    private fun load(name: String): JSONObject {
        val stream = checkNotNull(PushVectors::class.java.classLoader?.getResourceAsStream(name)) {
            "$name is missing from the test classpath (push/test-vectors)"
        }
        return JSONObject(stream.use { String(it.readBytes(), Charsets.UTF_8) })
    }

    fun cases(): List<JSONObject> {
        val array = cp1.getJSONArray("cases")
        return (0 until array.length()).map(array::getJSONObject)
    }
}

internal fun JSONObject.bytes(key: String): ByteArray = Base64Url.decode(getString(key))

/**
 * A sender, for round trips through the decryptor: RFC 8291 aes128gcm with
 * Conduit's padding buckets, as in server-plugins/common/conduit_webpush.
 */
internal object TestWebPush {
    private val buckets = listOf(512, 1024, 2048)

    fun encrypt(plaintext: ByteArray, uaPublic: ByteArray, auth: ByteArray): ByteArray {
        val sender = PushCrypto.generateKeyMaterial()
        val salt = PushCrypto.randomBytes(16)
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(PushCrypto.decodePrivateKey(sender.privateKey))
        agreement.doPhase(PushCrypto.decodePublicKey(uaPublic), true)
        val secret = agreement.generateSecret()

        val counter = byteArrayOf(1)
        val prkKey = hmac(auth, secret)
        val ikm = hmac(prkKey, "WebPush: info\u0000".toByteArray() + uaPublic + sender.publicKey + counter)
        val prk = hmac(salt, ikm)
        val key = hmac(prk, "Content-Encoding: aes128gcm\u0000".toByteArray() + counter).copyOf(16)
        val nonce = hmac(prk, "Content-Encoding: nonce\u0000".toByteArray() + counter).copyOf(12)

        val bucket = buckets.first { plaintext.size + 1 + 16 <= it }
        val record = plaintext + byteArrayOf(2) + ByteArray(bucket - 16 - plaintext.size - 1)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        val header = salt + byteArrayOf(0, 0, 0x10, 0) + byteArrayOf(65) + sender.publicKey
        return header + cipher.doFinal(record)
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(data)
        }
}

/** Reversible stand-in for the Android Keystore cipher. */
internal class FakeStoreCipher : PushStoreCipher {
    var failOpen: Exception? = null

    /** Thrown by the next seal only. */
    var failNextSeal: Exception? = null
    var resets = 0

    override fun seal(plaintext: ByteArray): ByteArray {
        failNextSeal?.let { failNextSeal = null; throw it }
        return byteArrayOf(0x7f) + plaintext.map { (it.toInt() xor 0x5a).toByte() }.toByteArray()
    }

    override fun reset() {
        resets++
    }

    override fun open(sealed: ByteArray): ByteArray {
        failOpen?.let { throw it }
        if (sealed.isEmpty() || sealed[0] != 0x7f.toByte()) {
            throw PushStoreUnreadableException("not sealed by FakeStoreCipher")
        }
        return sealed.drop(1).map { (it.toInt() xor 0x5a).toByte() }.toByteArray()
    }
}

internal class MemoryKeyValueStore : KeyValueStore {
    val values = HashMap<String, String>()

    override fun getString(key: String): String? = values[key]

    override fun putString(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }
}

internal fun tempFile(name: String): File =
    File.createTempFile("conduit-push-", "-$name").also { it.delete(); it.deleteOnExit() }
