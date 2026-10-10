package app.cogwheel.conduit.push

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PushCryptoTest {
    @Test
    fun rfc8291AppendixAVectorDecrypts() {
        val vector = PushVectors.rfc8291
        val plaintext = PushCrypto.decrypt(
            vector.bytes("body"),
            vector.bytes("ua_private"),
            vector.bytes("ua_public"),
            vector.bytes("auth"),
        )
        assertArrayEquals(vector.bytes("plaintext"), plaintext)
    }

    @Test
    fun everyCp1CaseDecryptsToItsPlaintext() {
        val cases = PushVectors.cases()
        assertTrue("expected the shared cp/1 cases", cases.size >= 7)
        cases.forEach { case ->
            val body = case.bytes("body")
            assertEquals(case.getString("name"), PushCrypto.HEADER_LENGTH + case.getInt("bucket"), body.size)
            val plaintext = PushCrypto.decrypt(
                body,
                case.bytes("ua_private"),
                case.bytes("ua_public"),
                case.bytes("auth"),
            )
            assertArrayEquals(case.getString("name"), case.bytes("plaintext"), plaintext)
        }
    }

    @Test
    fun everyRejectBodyIsRejected() {
        val reject = PushVectors.cp1.getJSONObject("reject")
        val bodies = reject.getJSONObject("bodies")
        val names = bodies.keys().asSequence().toList().sorted()
        assertTrue(
            names.containsAll(
                listOf(
                    "wrong_auth",
                    "not_last_record_delimiter",
                    "keyid_not_65",
                    "record_size_too_small",
                    "truncated",
                    "flipped_tag_bit",
                    "too_large",
                )
            )
        )
        names.forEach { name ->
            try {
                PushCrypto.decrypt(
                    Base64Url.decode(bodies.getString(name)),
                    reject.bytes("ua_private"),
                    reject.bytes("ua_public"),
                    reject.bytes("auth"),
                )
                fail("$name decrypted")
            } catch (_: PushDecryptException) {
                // Expected.
            }
        }
    }

    @Test
    fun aCorrectBodyWithTheRejectKeysDecrypts() {
        // Guards the reject test: the keys themselves are fine.
        val reject = PushVectors.cp1.getJSONObject("reject")
        val body = TestWebPush.encrypt("{\"v\":1}".toByteArray(), reject.bytes("ua_public"), reject.bytes("auth"))
        val plaintext = PushCrypto.decrypt(body, reject.bytes("ua_private"), reject.bytes("ua_public"), reject.bytes("auth"))
        assertEquals("{\"v\":1}", String(plaintext))
    }

    @Test
    fun rejectsSenderKeysOffTheCurve() {
        val case = PushVectors.cases().first()
        val body = case.bytes("body")
        // Corrupt the sender's y coordinate (header bytes 21..85).
        body[85] = (body[85].toInt() xor 0x01).toByte()
        assertRejected(body, case.bytes("ua_private"), case.bytes("ua_public"), case.bytes("auth"))
    }

    @Test
    fun rejectsBadLengths() {
        val case = PushVectors.cases().first()
        val priv = case.bytes("ua_private")
        val pub = case.bytes("ua_public")
        val auth = case.bytes("auth")
        assertRejected(ByteArray(0), priv, pub, auth)
        assertRejected(case.bytes("body").copyOf(PushCrypto.HEADER_LENGTH + 16), priv, pub, auth)
        assertRejected(case.bytes("body"), priv, pub, auth.copyOf(15))
        assertRejected(case.bytes("body"), priv.copyOf(31), pub, auth)
    }

    @Test
    fun generatedKeysHaveProtocolShapes() {
        val keys = PushCrypto.generateKeyMaterial()
        assertEquals(32, keys.privateKey.size)
        assertEquals(65, keys.publicKey.size)
        assertEquals(0x04.toByte(), keys.publicKey[0])
        assertEquals(16, keys.auth.size)
        // Decodes as a point on P-256.
        PushCrypto.decodePublicKey(keys.publicKey)
        assertFalse(keys.auth.contentEquals(PushCrypto.generateKeyMaterial().auth))
    }

    @Test
    fun generatedKeysDecryptEveryPaddingBucket() {
        val keys = PushCrypto.generateKeyMaterial()
        listOf(1, 400, 495, 496, 1000, 2031).forEach { size ->
            val message = ByteArray(size) { 'a'.code.toByte() }
            val body = TestWebPush.encrypt(message, keys.publicKey, keys.auth)
            assertArrayEquals(message, PushCrypto.decrypt(body, keys.privateKey, keys.publicKey, keys.auth))
        }
    }

    private fun assertRejected(body: ByteArray, priv: ByteArray, pub: ByteArray, auth: ByteArray) {
        try {
            PushCrypto.decrypt(body, priv, pub, auth)
            fail("decrypted")
        } catch (_: PushDecryptException) {
            // Expected.
        }
    }
}
