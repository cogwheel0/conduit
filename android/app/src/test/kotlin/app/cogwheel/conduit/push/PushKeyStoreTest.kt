package app.cogwheel.conduit.push

import java.security.KeyStoreException
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
        val created = store.create("owui:a")
        assertEquals(listOf(created.sid), store().list().map { it.sid })
    }

    @Test
    fun aTransientKeystoreFailureNeverOverwritesTheStore() {
        val created = store().create("owui:a")
        cipher.failOpen = KeyStoreException("busy")
        val failing = store()
        try {
            failing.create("owui:b")
            fail("created while the store was unreadable")
        } catch (_: KeyStoreException) {
            // Expected.
        }
        cipher.failOpen = null
        assertEquals(listOf(created.sid), store().list().map { it.sid })
    }
}
