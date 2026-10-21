package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class BrowserAuthFlowStateTest {
    private lateinit var flows: BrowserAuthFlowState
    private val endings = mutableListOf<BrowserAuthEnding>()
    private val redirect = BrowserAuthRedirect.DEFAULT

    @Before
    fun setUp() {
        flows = BrowserAuthFlowState()
        endings.clear()
    }

    private fun begin(
        channel: BrowserAuthChannel,
        to: BrowserAuthRedirect = redirect,
        into: MutableList<BrowserAuthEnding> = endings,
    ): Long = flows.begin(channel, to) { into += it }

    @Test
    fun aMatchingRedirectEndsTheFlowOnce() {
        begin(BrowserAuthChannel.CUSTOM_TABS)

        assertTrue(flows.deliver("conduit://oauth/callback?code=c&state=s"))
        assertFalse(flows.deliver("conduit://oauth/callback?code=again"))

        assertEquals(1, endings.size)
        val success = endings.single() as BrowserAuthEnding.Success
        assertEquals("conduit://oauth/callback?code=c&state=s", success.callbackUrl)
        assertNull(flows.pendingId)
    }

    @Test
    fun aRedirectThatDiffersInAnyPartIsIgnored() {
        begin(BrowserAuthChannel.EXTERNAL_BROWSER)

        for (uri in listOf(
            "conduit://oauth/other?code=c",
            "conduit://evil/callback?code=c",
            "other://oauth/callback?code=c",
            "conduit://oauth:443/callback?code=c",
            "conduit://user@oauth/callback?code=c",
            "conduit://oauth/callback?code=c#fragment",
            "conduit://oauth/callback/?code=c",
            "conduit:oauth/callback",
            "not a uri",
        )) {
            assertFalse(uri, flows.deliver(uri))
        }

        assertTrue(endings.isEmpty())
        assertTrue(flows.pendingId != null)
    }

    @Test
    fun aRedirectWithNoFlowWaitingIsIgnored() {
        assertFalse(flows.deliver("conduit://oauth/callback?code=c"))
    }

    @Test
    fun anAuthTabOnlyEndsWithItsOwnResult() {
        begin(BrowserAuthChannel.AUTH_TAB)

        // A routed link is not the Auth Tab's redirect.
        assertFalse(flows.deliver("conduit://oauth/callback?code=forged"))
        assertTrue(endings.isEmpty())

        assertTrue(flows.authTabReturned(AuthTabReturn.OK, "conduit://oauth/callback?code=c"))
        assertTrue(endings.single() is BrowserAuthEnding.Success)
    }

    @Test
    fun anAuthTabOnAnotherRedirectFails() {
        begin(BrowserAuthChannel.AUTH_TAB)

        flows.authTabReturned(AuthTabReturn.OK, "conduit://oauth/elsewhere?code=c")

        assertEquals(
            BrowserAuthEnding.Failed(BrowserAuthErrorCodes.UNEXPECTED_CALLBACK),
            endings.single(),
        )
    }

    @Test
    fun anAuthTabCancelledOrFailedSaysSo() {
        begin(BrowserAuthChannel.AUTH_TAB)
        flows.authTabReturned(AuthTabReturn.CANCELED, null)
        begin(BrowserAuthChannel.AUTH_TAB)
        flows.authTabReturned(AuthTabReturn.FAILED, null)

        assertEquals(
            listOf(
                BrowserAuthEnding.Cancelled,
                BrowserAuthEnding.Failed(BrowserAuthErrorCodes.START_FAILED),
            ),
            endings,
        )
    }

    @Test
    fun anAuthTabResultForAnotherChannelIsIgnored() {
        begin(BrowserAuthChannel.CUSTOM_TABS)

        assertFalse(flows.authTabReturned(AuthTabReturn.CANCELED, null))
        assertTrue(endings.isEmpty())
    }

    @Test
    fun aGoogleRedirectWithoutAHostMatchesExactly() {
        val google = BrowserAuthRedirect.of(
            "com.googleusercontent.apps.123-abc",
            "",
            "/oauth2redirect",
        )!!
        begin(BrowserAuthChannel.AUTH_TAB, to = google)

        flows.authTabReturned(
            AuthTabReturn.OK,
            "com.googleusercontent.apps.123-abc:/oauth2redirect?code=c",
        )

        assertTrue(endings.single() is BrowserAuthEnding.Success)
    }

    @Test
    fun aNewFlowSupersedesTheOneInProgress() {
        val first = mutableListOf<BrowserAuthEnding>()
        val firstId = begin(BrowserAuthChannel.CUSTOM_TABS, into = first)
        val secondId = begin(BrowserAuthChannel.CUSTOM_TABS)

        assertEquals(
            listOf<BrowserAuthEnding>(BrowserAuthEnding.Failed(BrowserAuthErrorCodes.SUPERSEDED)),
            first,
        )
        // A late check for the first flow leaves the second alone.
        assertFalse(flows.cancelIfPending(firstId))
        assertEquals(secondId, flows.pendingId)
        assertTrue(endings.isEmpty())
    }

    @Test
    fun aCustomTabClosedWithoutARedirectIsCancelledAfterTheGracePeriod() {
        val id = begin(BrowserAuthChannel.CUSTOM_TABS)

        // Resuming before the tab ever covered the app is not a close.
        assertNull(flows.onResumed())

        flows.onPaused()
        assertEquals(id, flows.onResumed())
        assertTrue(flows.cancelIfPending(id))

        assertEquals(listOf<BrowserAuthEnding>(BrowserAuthEnding.Cancelled), endings)
    }

    @Test
    fun aRedirectInsideTheGracePeriodWins() {
        val id = begin(BrowserAuthChannel.CUSTOM_TABS)
        flows.onPaused()
        val check = flows.onResumed()

        flows.deliver("conduit://oauth/callback?code=c")

        assertFalse(flows.cancelIfPending(check!!))
        assertEquals(id, check)
        assertTrue(endings.single() is BrowserAuthEnding.Success)
    }

    @Test
    fun theExternalBrowserIsNeverCancelledByComingBack() {
        val id = begin(BrowserAuthChannel.EXTERNAL_BROWSER)
        flows.onPaused()

        assertNull(flows.onResumed())
        assertEquals(id, flows.pendingId)

        // Only its timeout ends it.
        assertTrue(flows.cancelIfPending(id))
        assertEquals(listOf<BrowserAuthEnding>(BrowserAuthEnding.Cancelled), endings)
    }

    @Test
    fun anAuthTabIsNeverCancelledByComingBack() {
        begin(BrowserAuthChannel.AUTH_TAB)
        flows.onPaused()

        assertNull(flows.onResumed())
    }

    @Test
    fun cancelEndsTheFlowInProgress() {
        begin(BrowserAuthChannel.EXTERNAL_BROWSER)

        assertTrue(flows.cancel())
        assertFalse(flows.cancel())
        assertFalse(flows.deliver("conduit://oauth/callback?code=c"))

        assertEquals(listOf<BrowserAuthEnding>(BrowserAuthEnding.Cancelled), endings)
    }

    @Test
    fun aFailedStartEndsOnlyItsOwnFlow() {
        val id = begin(BrowserAuthChannel.CUSTOM_TABS)

        assertFalse(flows.fail(id + 1, BrowserAuthEnding.Failed(BrowserAuthErrorCodes.START_FAILED)))
        assertTrue(flows.fail(id, BrowserAuthEnding.Unavailable(BrowserAuthErrorCodes.NO_BROWSER)))

        assertEquals(
            listOf<BrowserAuthEnding>(BrowserAuthEnding.Unavailable(BrowserAuthErrorCodes.NO_BROWSER)),
            endings,
        )
    }

    @Test
    fun anAbandonedFlowNeverAnswers() {
        begin(BrowserAuthChannel.CUSTOM_TABS)

        flows.abandon()

        assertFalse(flows.deliver("conduit://oauth/callback?code=c"))
        assertTrue(endings.isEmpty())
    }

    @Test
    fun onlyAppRedirectsAreAccepted() {
        assertNull(BrowserAuthRedirect.of("https", "app.example.com", "/callback"))
        assertNull(BrowserAuthRedirect.of("http", "app.example.com", "/callback"))
        assertNull(BrowserAuthRedirect.of("", "oauth", "/callback"))
        assertNull(BrowserAuthRedirect.of("con duit", "oauth", "/callback"))
        assertNull(BrowserAuthRedirect.of("conduit", "oauth", "callback"))
        assertEquals(
            BrowserAuthRedirect.DEFAULT,
            BrowserAuthRedirect.of("Conduit", "OAuth", "/callback"),
        )
    }

    @Test
    fun aSuccessNeverPrintsItsRedirect() {
        val ending = BrowserAuthEnding.Success("conduit://oauth/callback?code=secret")

        assertFalse(ending.toString().contains("secret"))
    }
}
