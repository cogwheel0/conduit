package app.cogwheel.conduit.push

import android.security.keystore.KeyPermanentlyInvalidatedException
import java.io.IOException
import java.security.InvalidKeyException
import java.security.KeyStoreException
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class PushKeyStoreTest {
    private val raw = tempFile("keys.bin")
    private val cipher = FakeStoreCipher()

    private fun store() = PushKeyStore(AtomicBytesFile(raw), cipher, clock = { 1_234L })

    @Test
    fun createdSubscriptionsRoundTripThroughTheSealedFile() {
        val created = store().create("owui:acct-1")
        assertEquals(22, created.sid.length)
        assertEquals(65, created.publicKeyBytes.size)
        assertEquals(16, created.authBytes.size)
        assertEquals(1_234L, created.createdAtMillis)
        assertNull(created.endpoint)

        val reloaded = store().find(created.sid)!!
        assertEquals("owui:acct-1", reloaded.scope)
        assertArrayEquals(created.privateKey, reloaded.privateKey)
        assertEquals(created.p256dh, reloaded.p256dh)
        assertEquals(created.auth, reloaded.auth)

        // Nothing readable lands on disk.
        val onDisk = String(raw.readBytes(), Charsets.ISO_8859_1)
        assertFalse(onDisk.contains(created.sid))
        assertFalse(onDisk.contains(created.p256dh))
    }

    @Test
    fun aStoredSubscriptionDecryptsPushesSentToIt() {
        val created = store().create("hermes:conn")
        val stored = store().find(created.sid)!!
        val body = TestWebPush.encrypt("hi".toByteArray(), stored.publicKeyBytes, stored.authBytes)
        assertEquals(
            "hi",
            String(PushCrypto.decrypt(body, stored.privateKey, stored.publicKeyBytes, stored.authBytes)),
        )
    }

    @Test
    fun endpointsAndDeletesPersist() {
        val store = store()
        val first = store.create("owui:a")
        val second = store.create("owui:b")
        assertNotEquals(first.sid, second.sid)

        assertTrue(store.setEndpoint(first.sid, "https://relay.example/v1/push/x", PushTransportName.FCM))
        assertFalse(store.setEndpoint("missing", "https://e", PushTransportName.FCM))

        val reloaded = store()
        assertEquals("https://relay.example/v1/push/x", reloaded.find(first.sid)!!.endpoint)
        assertEquals(PushTransportName.FCM, reloaded.find(first.sid)!!.transport)
        assertEquals(listOf(first.sid, second.sid), reloaded.list().map { it.sid })

        assertEquals(second.sid, reloaded.delete(second.sid)!!.sid)
        assertNull(reloaded.delete(second.sid))
        assertEquals(listOf(first.sid), store().list().map { it.sid })

        assertTrue(reloaded.setEndpoint(first.sid, null, null))
        assertNull(store().find(first.sid)!!.endpoint)
    }

    @Test
    fun anUnreadableStoreStartsEmpty() {
        raw.writeBytes(byteArrayOf(1, 2, 3))
        val store = store()
        assertTrue(store.list().isEmpty())
        // The file and the key go, so nothing is left to refuse a write.
        assertFalse(raw.exists())
        assertEquals(1, cipher.resets)
        val created = store.create("owui:a")
        assertEquals(listOf(created.sid), store().list().map { it.sid })
    }

    @Test
    fun aKeyThatCanNeverOpenTheStoreAgainIsReplaced() {
        store().create("owui:a")
        cipher.failOpen = PushStoreUnreadableException("key invalidated")
        val store = store()
        assertTrue(store.list().isEmpty())
        assertEquals(1, cipher.resets)
        cipher.failOpen = null
        val created = store.create("owui:b")
        assertEquals(listOf(created.sid), store().list().map { it.sid })
    }

    @Test
    fun aKeyThatBrokeAfterReadingIsReplacedOnTheNextWrite() {
        val store = store()
        val first = store.create("owui:a")
        cipher.failNextSeal = PushStoreUnreadableException("key invalidated")
        val second = store.create("owui:b")
        assertEquals(1, cipher.resets)
        assertEquals(listOf(first.sid, second.sid), store().list().map { it.sid })
    }

    @Test
    fun aTransientKeystoreFailureNeverOverwritesTheStore() {
        val created = store().create("owui:a")
        cipher.failOpen = ProviderException("Keystore daemon busy")
        val failing = store()
        try {
            failing.create("owui:b")
            fail("created while the store was unreadable")
        } catch (_: ProviderException) {
            // Expected.
        }
        cipher.failOpen = null
        assertEquals(0, cipher.resets)
        assertEquals(listOf(created.sid), store().list().map { it.sid })
    }

    @Test
    fun aTransientSealFailureIsNotRetriedWithANewKey() {
        val store = store()
        store.create("owui:a")
        cipher.failNextSeal = ProviderException("Keystore daemon busy")
        try {
            store.create("owui:b")
            fail("created while the Keystore was busy")
        } catch (_: ProviderException) {
            // Expected.
        }
        assertEquals(0, cipher.resets)
        assertEquals(listOf("owui:a"), store().list().map { it.scope })
    }

    @Test
    fun onlyPermanentKeystoreFailuresDiscardTheStore() {
        listOf(
            UnrecoverableKeyException("gone"),
            KeyPermanentlyInvalidatedException("lock screen changed"),
            InvalidKeyException("unusable"),
            KeyStoreException("entry refused"),
        ).forEach { assertTrue("$it", it.isPermanentKeystoreFailure()) }
        listOf(
            IOException("disk"),
            ProviderException("Keystore daemon busy"),
            IllegalStateException("not ready"),
        ).forEach { assertFalse("$it", it.isPermanentKeystoreFailure()) }
    }
}
