package app.cogwheel.conduit.push

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class PushLedgerTest {
    private var now = 1_760_000_000_000L

    private fun ledger(file: AtomicBytesFile? = null, maxEntries: Int = PushLedger.MAX_ENTRIES) =
        PushLedger(file, clock = { now }, maxEntries = maxEntries)

    @Test
    fun aKeyIsClaimedOnce() {
        val ledger = ledger()
        assertTrue(ledger.claim("owui:a|chat:c:m", null))
        assertFalse(ledger.claim("owui:a|chat:c:m", null))
        assertFalse(ledger.claim("owui:a|chat:c:m", "17"))
        // Same dk under another account is a different message.
        assertTrue(ledger.claim("owui:b|chat:c:m", null))
    }

    @Test
    fun claimsExpireAfterThreeDays() {
        val ledger = ledger()
        assertTrue(ledger.claim("k", null))
        now += PushLedger.RETENTION_MILLIS
        assertFalse(ledger.claim("k", null))
        now += 1
        assertTrue(ledger.claim("k", null))
    }

    @Test
    fun aClockGoingBackwardsDoesNotPinClaims() {
        val ledger = ledger()
        assertTrue(ledger.claim("k", null))
        now -= 60_000
        assertTrue(ledger.claim("k", null))
    }

    @Test
    fun claimsSurviveAProcessRestart() {
        val file = AtomicBytesFile(tempFile("ledger.json"))
        assertTrue(ledger(file).claim("owui:a|chat:c:m", "42"))

        val reloaded = ledger(file)
        assertFalse(reloaded.claim("owui:a|chat:c:m", null))
        val claims = reloaded.claimsFor("owui:a")
        assertEquals(1, claims.size)
        assertEquals("42", claims.single().localNotificationId)
    }

    @Test
    fun claimsForMatchesTheWholeScope() {
        val ledger = ledger()
        ledger.claim("owui:a|chat:c:1", "1")
        ledger.claim("owui:ab|chat:c:2", "2")
        ledger.claim("hermes:x|hermes:s:t", null)
        assertEquals(listOf("owui:a|chat:c:1"), ledger.claimsFor("owui:a").map { it.key })
    }

    @Test
    fun oldestClaimsGoFirstPastTheCap() {
        val ledger = ledger(maxEntries = 3)
        (1..4).forEach { ledger.claim("k$it", null) }
        assertTrue(ledger.claim("k1", null))
        assertFalse(ledger.claim("k4", null))
    }

    @Test
    fun aCorruptFileStartsEmpty() {
        val raw = tempFile("ledger-corrupt.json")
        raw.writeText("{not json")
        val ledger = ledger(AtomicBytesFile(raw))
        assertTrue(ledger.claim("k", null))
        assertFalse(ledger(AtomicBytesFile(raw)).claim("k", null))
    }

    @Test
    fun concurrentClaimsHaveExactlyOneWinner() {
        val ledger = ledger(AtomicBytesFile(tempFile("ledger-race.json")))
        val pool = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val winners = AtomicInteger()
        repeat(32) {
            pool.execute {
                start.await()
                if (ledger.claim("owui:a|chat:c:m", null)) winners.incrementAndGet()
            }
        }
        start.countDown()
        pool.shutdown()
        assertTrue(pool.awaitTermination(10, TimeUnit.SECONDS))
        assertEquals(1, winners.get())
    }
}
