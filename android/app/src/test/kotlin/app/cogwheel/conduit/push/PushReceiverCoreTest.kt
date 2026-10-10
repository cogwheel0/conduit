package app.cogwheel.conduit.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushReceiverCoreTest {
    private class FakeDelivery : PushDelivery {
        var foreground = false
        var dartTakesPushes = true
        var notificationsAllowed = true
        /** Runs on the main thread before the receiver's work there. */
        var beforeMain: () -> Unit = {}
        /** Runs while Dart has the push, before it answers. */
        var beforeDartAnswers: () -> Unit = {}
        val forwarded = mutableListOf<Triple<String, String, String>>()
        val posted = mutableListOf<PushNotificationContent>()
        val tests = mutableListOf<Pair<String, String>>()
        val drops = mutableListOf<String>()

        override fun runOnMain(block: () -> Unit) {
            beforeMain()
            block()
        }
        override fun canForwardToApp() = foreground
        override fun forwardToApp(sid: String, scope: String, payloadJson: String, done: (Boolean) -> Unit) {
            forwarded += Triple(sid, scope, payloadJson)
            beforeDartAnswers()
            done(dartTakesPushes)
        }
        override fun post(scope: String, payload: PushPayload, content: PushNotificationContent): Boolean {
            if (!notificationsAllowed) return false
            posted += content
            return true
        }
        override fun testReceived(sid: String, nonce: String) {
            tests += sid to nonce
        }
        override fun dropped(reason: String) {
            drops += reason
        }
    }

    private val delivery = FakeDelivery()
    private val config = PushConfigStore(MemoryKeyValueStore())
    private val ledger = PushLedger(file = null)
    // Vector cases reuse sids with different keys, so each case installs its
    // own subscription when its body is taken.
    private val subscriptions = HashMap<String, PushSubscriptionRecord>()
    private val core = PushReceiverCore(subscriptions::get, config, ledger, delivery)

    private fun body(name: String): Pair<String, ByteArray> {
        val case = PushVectors.cases().first { it.getString("name") == name }
        val sid = case.getString("sid")
        subscriptions[sid] = PushSubscriptionRecord(
            sid = sid,
            scope = case.getString("scope"),
            privateKey = case.bytes("ua_private"),
            p256dh = case.getString("ua_public"),
            auth = case.getString("auth"),
            createdAtMillis = 0,
            endpoint = null,
            transport = PushTransportName.FCM,
        )
        return sid to case.bytes("body")
    }

    @Test
    fun aBackgroundPushIsClaimedAndPosted() {
        val (sid, body) = body("owui_reply")
        core.handle(sid, body)
        assertEquals(listOf("owui:acct-1|chat:4f1c2a7e:b9d0e3f1"), delivery.posted.map { it.tag })
        // The app's own notification for the same reply now loses the claim.
        assertEquals(false, ledger.claim("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", "9"))
    }

    @Test
    fun aRepeatedPushIsShownOnce() {
        val (sid, body) = body("hermes_reply")
        core.handle(sid, body)
        core.handle(sid, body)
        assertEquals(1, delivery.posted.size)
        assertEquals("already shown", delivery.drops.single())
    }

    @Test
    fun aMessageTheAppAlreadyShowedIsDropped() {
        ledger.claim("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", "3")
        val (sid, body) = body("owui_reply")
        core.handle(sid, body)
        assertTrue(delivery.posted.isEmpty())
    }

    @Test
    fun inTheForegroundDartDecides() {
        delivery.foreground = true
        val (sid, body) = body("owui_reply")
        core.handle(sid, body)
        assertEquals(sid, delivery.forwarded.single().first)
        assertEquals("owui:acct-1", delivery.forwarded.single().second)
        assertTrue(delivery.forwarded.single().third.contains("\"dk\":\"chat:4f1c2a7e:b9d0e3f1\""))
        assertTrue(delivery.posted.isEmpty())
        // Claimed before Dart saw it, as Dart assumes (alreadyClaimed), so
        // the app's own notification for the same reply loses.
        assertFalse(ledger.claim("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", "9"))
    }

    @Test
    fun aForegroundPushTheAppAlreadyShowedIsNotForwarded() {
        delivery.foreground = true
        assertTrue(ledger.claim("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", "3"))
        val (sid, body) = body("owui_reply")
        core.handle(sid, body)
        core.handle(sid, body)
        assertTrue(delivery.forwarded.isEmpty())
        assertTrue(delivery.posted.isEmpty())
        assertEquals(listOf("already shown", "already shown"), delivery.drops)
    }

    @Test
    fun aRepeatedForegroundPushIsForwardedOnce() {
        delivery.foreground = true
        val (sid, body) = body("hermes_reply")
        core.handle(sid, body)
        core.handle(sid, body)
        assertEquals(1, delivery.forwarded.size)
    }

    @Test
    fun aPushDartDoesNotTakeIsPosted() {
        delivery.foreground = true
        delivery.dartTakesPushes = false
        val (sid, body) = body("owui_reply")
        core.handle(sid, body)
        assertEquals(1, delivery.forwarded.size)
        assertEquals(1, delivery.posted.size)
        // Posted under the claim taken before forwarding; a repeat is not.
        core.handle(sid, body)
        assertEquals(1, delivery.posted.size)
    }

    @Test
    fun unknownSidsAndBadBodiesAreDropped() {
        val (sid, body) = body("owui_reply")
        core.handle("unknown", body)
        val tampered = body.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        core.handle(sid, tampered)
        // A body sealed for another subscription.
        core.handle(body("hermes_reply").first, body)
        assertTrue(delivery.posted.isEmpty())
        assertTrue(delivery.forwarded.isEmpty())
        assertEquals(3, delivery.drops.size)
    }

    @Test
    fun disabledSettingsDropBeforeAnythingIsShownOrForwarded() {
        delivery.foreground = true
        config.save(PushDisplayConfig.DEFAULT.copy(disabledScopes = setOf("owui:acct-1")))
        val (sid, body) = body("owui_reply")
        core.handle(sid, body)
        assertTrue(delivery.forwarded.isEmpty())
        assertTrue(delivery.posted.isEmpty())
    }

    @Test
    fun anAccountRemovedBeforeTheMainThreadRunsIsNotShown() {
        val (sid, body) = body("owui_reply")
        // Removal runs on the main thread, after the worker read the key.
        delivery.beforeMain = { subscriptions.remove(sid) }
        core.handle(sid, body)
        assertTrue(delivery.posted.isEmpty())
        assertEquals(listOf("subscription removed"), delivery.drops)
        assertTrue(ledger.claim("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", "9"))
    }

    @Test
    fun settingsChangedBeforeTheMainThreadRunsApply() {
        delivery.foreground = true
        val (sid, body) = body("owui_reply")
        delivery.beforeMain = {
            config.save(PushDisplayConfig.DEFAULT.copy(disabledScopes = setOf("owui:acct-1")))
        }
        core.handle(sid, body)
        assertTrue(delivery.forwarded.isEmpty())
        assertTrue(delivery.posted.isEmpty())
        assertTrue(ledger.claim("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", "9"))
    }

    @Test
    fun aPushDartDoesNotTakeIsNotPostedOnceItsAccountIsGone() {
        delivery.foreground = true
        delivery.dartTakesPushes = false
        val (sid, body) = body("owui_reply")
        delivery.beforeDartAnswers = { subscriptions.remove(sid) }
        core.handle(sid, body)
        assertEquals(1, delivery.forwarded.size)
        assertTrue(delivery.posted.isEmpty())
        assertTrue(ledger.claim("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", "9"))
    }

    @Test
    fun aPushThatCouldNotBePostedGivesItsClaimBack() {
        delivery.notificationsAllowed = false
        val (sid, body) = body("owui_reply")
        core.handle(sid, body)
        assertTrue(delivery.posted.isEmpty())
        assertEquals(listOf("not posted"), delivery.drops)

        // Once notifications are allowed again, the same message shows.
        delivery.notificationsAllowed = true
        core.handle(sid, body)
        assertEquals(1, delivery.posted.size)
    }

    @Test
    fun aPushDartDoesNotTakeThatCouldNotBePostedGivesItsClaimBack() {
        delivery.foreground = true
        delivery.dartTakesPushes = false
        delivery.notificationsAllowed = false
        val (sid, body) = body("owui_reply")
        core.handle(sid, body)
        assertTrue(delivery.posted.isEmpty())
        assertTrue(ledger.claim("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", "9"))
    }

    @Test
    fun aTestPushRecordsItsNonce() {
        // Even with test notifications hidden, the device proves delivery.
        config.save(PushDisplayConfig.DEFAULT.copy(enabledKinds = emptySet()))
        val (sid, body) = body("test")
        core.handle(sid, body)
        assertEquals(listOf(sid to "Nn3wq0Xk"), delivery.tests)
        assertEquals(listOf("Nn3wq0Xk"), config.takeNonces(sid))
        assertTrue(config.takeNonces(sid).isEmpty())
        assertTrue(delivery.posted.isEmpty())
    }
}
