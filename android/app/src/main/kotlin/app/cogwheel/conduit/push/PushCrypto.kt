package app.cogwheel.conduit.push

import java.math.BigInteger
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** A push body that is malformed or fails authentication. */
class PushDecryptException(message: String, cause: Throwable? = null) :
    GeneralSecurityException(message, cause)

/** A fresh subscription key set. [privateKey] never leaves the device. */
class PushKeyMaterial(
    /** P-256 private scalar, 32 bytes big-endian. */
    val privateKey: ByteArray,
    /** Uncompressed P-256 public point, 65 bytes (`p256dh`). */
    val publicKey: ByteArray,
    /** 16-byte auth secret. */
    val auth: ByteArray,
)

/**
 * Decrypts Conduit push bodies: Web Push message encryption (RFC 8291) with
 * the `aes128gcm` content coding (RFC 8188), restricted the way
 * docs/push/PROTOCOL.md section 3 requires. Decryption only; servers encrypt.
 */
object PushCrypto {
    const val SALT_LENGTH = 16
    const val KEY_ID_LENGTH = 65
    const val HEADER_LENGTH = SALT_LENGTH + 4 + 1 + KEY_ID_LENGTH
    const val TAG_LENGTH = 16
    const val AUTH_LENGTH = 16
    const val MIN_RECORD_SIZE = 18L

    /** The largest padding bucket (2048) plus the header. */
    const val MAX_BODY_LENGTH = HEADER_LENGTH + 2048

    private const val DELIMITER: Byte = 0x02

    // HKDF-Expand's single-block counter: every output here fits one block.
    private val COUNTER = byteArrayOf(0x01)
    private val KEY_INFO = "WebPush: info\u0000".toByteArray(Charsets.US_ASCII)
    private val CEK_INFO = "Content-Encoding: aes128gcm\u0000".toByteArray(Charsets.US_ASCII)
    private val NONCE_INFO = "Content-Encoding: nonce\u0000".toByteArray(Charsets.US_ASCII)

    // P-256 (secp256r1) domain parameters, used to check that a sender's
    // point is on the curve before it goes anywhere near ECDH.
    private val P = BigInteger("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
    private val A = P.subtract(BigInteger.valueOf(3))
    private val B = BigInteger("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", 16)
    private val N = BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)

    private val random = SecureRandom()

    /**
     * The provider's own P-256 parameters. Taken from a generated key so the
     * platform recognises them as the named curve.
     */
    private val curve: ECParameterSpec by lazy {
        (newKeyPairGenerator().generateKeyPair().public as ECPublicKey).params
    }

    private fun newKeyPairGenerator(): KeyPairGenerator =
        KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"), random)
        }

    /** A software P-256 key pair and auth secret for a new subscription. */
    fun generateKeyMaterial(): PushKeyMaterial {
        val pair = newKeyPairGenerator().generateKeyPair()
        val private = pair.private as ECPrivateKey
        val public = pair.public as ECPublicKey
        return PushKeyMaterial(
            privateKey = unsigned(private.s, 32),
            publicKey = encodePoint(public.w),
            auth = randomBytes(AUTH_LENGTH),
        )
    }

    fun randomBytes(length: Int): ByteArray = ByteArray(length).also(random::nextBytes)

    /**
     * Decrypts one push [body] for the subscription that owns [privateKey]
     * (raw 32-byte scalar), [publicKey] (its 65-byte `p256dh`) and [auth].
     *
     * @return the plaintext without padding or delimiter.
     * @throws PushDecryptException when the body breaks any rule of
     *   PROTOCOL section 3 or fails authentication.
     */
    fun decrypt(body: ByteArray, privateKey: ByteArray, publicKey: ByteArray, auth: ByteArray): ByteArray {
        if (body.size > MAX_BODY_LENGTH) throw PushDecryptException("body too large")
        if (body.size < HEADER_LENGTH + TAG_LENGTH + 1) throw PushDecryptException("body too short")
        if (auth.size != AUTH_LENGTH) throw PushDecryptException("auth secret must be 16 bytes")

        val salt = body.copyOfRange(0, SALT_LENGTH)
        val recordSize = readUInt32(body, SALT_LENGTH)
        val keyIdLength = body[SALT_LENGTH + 4].toInt() and 0xff
        if (keyIdLength != KEY_ID_LENGTH) throw PushDecryptException("keyid must be a 65-byte P-256 key")
        if (recordSize < MIN_RECORD_SIZE) throw PushDecryptException("record size too small")
        val senderPublic = body.copyOfRange(SALT_LENGTH + 5, HEADER_LENGTH)
        val ciphertext = body.copyOfRange(HEADER_LENGTH, body.size)
        if (ciphertext.size.toLong() > recordSize) throw PushDecryptException("more than one record")

        val sharedSecret = try {
            val agreement = KeyAgreement.getInstance("ECDH")
            agreement.init(decodePrivateKey(privateKey))
            agreement.doPhase(decodePublicKey(senderPublic), true)
            agreement.generateSecret()
        } catch (error: PushDecryptException) {
            throw error
        } catch (error: GeneralSecurityException) {
            throw PushDecryptException("key agreement failed", error)
        }

        val prkKey = hmac(auth, sharedSecret)
        val ikm = hmac(prkKey, KEY_INFO + publicKey + senderPublic + COUNTER)
        val prk = hmac(salt, ikm)
        val contentKey = hmac(prk, CEK_INFO + COUNTER).copyOf(16)
        val nonce = hmac(prk, NONCE_INFO + COUNTER).copyOf(12)

        val record = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(contentKey, "AES"),
                GCMParameterSpec(TAG_LENGTH * 8, nonce),
            )
            cipher.doFinal(ciphertext)
        } catch (error: GeneralSecurityException) {
            throw PushDecryptException("authentication failed", error)
        }

        var end = record.size
        while (end > 0 && record[end - 1] == 0.toByte()) end--
        if (end == 0 || record[end - 1] != DELIMITER) {
            throw PushDecryptException("missing last-record delimiter")
        }
        return record.copyOfRange(0, end - 1)
    }

    internal fun decodePrivateKey(raw: ByteArray): ECPrivateKey {
        if (raw.size != 32) throw PushDecryptException("private key must be 32 bytes")
        val scalar = BigInteger(1, raw)
        if (scalar.signum() <= 0 || scalar >= N) throw PushDecryptException("private key out of range")
        return KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(scalar, curve)) as ECPrivateKey
    }

    internal fun decodePublicKey(raw: ByteArray): ECPublicKey {
        if (raw.size != 65 || raw[0] != 0x04.toByte()) {
            throw PushDecryptException("public key must be an uncompressed P-256 point")
        }
        val x = BigInteger(1, raw.copyOfRange(1, 33))
        val y = BigInteger(1, raw.copyOfRange(33, 65))
        if (x >= P || y >= P || y.multiply(y).mod(P) != x.pow(3).add(A.multiply(x)).add(B).mod(P)) {
            throw PushDecryptException("public key is not on P-256")
        }
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), curve)) as ECPublicKey
    }

    internal fun encodePoint(point: ECPoint): ByteArray =
        byteArrayOf(0x04) + unsigned(point.affineX, 32) + unsigned(point.affineY, 32)

    private fun unsigned(value: BigInteger, length: Int): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == length -> bytes
            bytes.size == length + 1 && bytes[0] == 0.toByte() -> bytes.copyOfRange(1, bytes.size)
            bytes.size < length -> ByteArray(length - bytes.size) + bytes
            else -> throw IllegalArgumentException("value does not fit $length bytes")
        }
    }

    private fun readUInt32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xff) shl 24) or
            ((bytes[offset + 1].toLong() and 0xff) shl 16) or
            ((bytes[offset + 2].toLong() and 0xff) shl 8) or
            (bytes[offset + 3].toLong() and 0xff)

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(data)
        }
}
