package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class BrowserAuthFlowStateTest {
    private var now = 0L
    private lateinit var flows: BrowserAuthFlowState
    private val endings = mutableListOf<BrowserAuthEnding>()
    private val redirect = BrowserAuthRedirect.DEFAULT

    @Before
    fun setUp() {
        now = 0L
        flows = BrowserAuthFlowState { now }
        endings.clear()
    }

    private fun begin(
        channel: BrowserAuthChannel,
        to: BrowserAuthRedirect = redirect,
        state: String = "s",
        into: MutableList<BrowserAuthEnding> = endings,
    ): Long = flows.begin(channel, to, state) { into += it }

    @Test
    fun aMatchingRedirectEndsTheFlowOnce() {
        begin(BrowserAuthChannel.CUSTOM_TABS)

        assertTrue(flows.deliver("conduit://oauth/callback?code=c&state=s"))
        assertFalse(flows.deliver("conduit://oauth/callback?code=again&state=s"))

        assertEquals(1, endings.size)
        val success = endings.single() as BrowserAuthEnding.Success
        assertEquals("conduit://oauth/callback?code=c&state=s", success.callbackUrl)
        assertNull(flows.pendingId)
    }

    @Test
    fun aRedirectThatDiffersInAnyPartIsIgnored() {
        begin(BrowserAuthChannel.EXTERNAL_BROWSER)

        for (uri in listOf(
            "conduit://oauth/other?code=c&state=s",
            "conduit://evil/callback?code=c&state=s",
            "other://oauth/callback?code=c&state=s",
            "conduit://oauth:443/callback?code=c&state=s",
            "conduit://user@oauth/callback?code=c&state=s",
            "conduit://oauth/callback?code=c&state=s#fragment",
            "conduit://oauth/callback/?code=c&state=s",
            "conduit:oauth/callback",
            "not a uri",
        )) {
            assertFalse(uri, flows.deliver(uri))
        }

        assertTrue(endings.isEmpty())
        assertTrue(flows.pendingId != null)
    }

    @Test
    fun aRedirectWithoutTheFlowsStateIsIgnored() {
        begin(BrowserAuthChannel.EXTERNAL_BROWSER)

        for (uri in listOf(
            "conduit://oauth/callback?code=c",
            "conduit://oauth/callback?code=c&state=",
            "conduit://oauth/callback?code=c&state=other",
            "conduit://oauth/callback?code=c&state=s&state=s",
        )) {
            assertFalse(uri, flows.deliver(uri))
        }

        assertTrue(endings.isEmpty())
        assertTrue(flows.deliver("conduit://oauth/callback?state=s&code=c"))
    }

    @Test
    fun aRedirectWithNoFlowWaitingIsIgnored() {
        assertFalse(flows.deliver("conduit://oauth/callback?code=c&state=s"))
    }

    @Test
    fun aSupersededFlowsRedirectNeverEndsTheNewerOne() {
        val first = mutableListOf<BrowserAuthEnding>()
        begin(BrowserAuthChannel.CUSTOM_TABS, state = "old", into = first)
        begin(BrowserAuthChannel.CUSTOM_TABS, state = "new")

        assertFalse(flows.deliver("conduit://oauth/callback?code=c&state=old"))
        assertTrue(endings.isEmpty())

        assertTrue(flows.deliver("conduit://oauth/callback?code=c&state=new"))
        assertTrue(endings.single() is BrowserAuthEnding.Success)
    }

    @Test
    fun anAuthTabOnlyEndsWithItsOwnResult() {
        begin(BrowserAuthChannel.AUTH_TAB)

        // A routed link is not the Auth Tab's redirect.
        assertFalse(flows.deliver("conduit://oauth/callback?code=forged&state=s"))
        assertTrue(endings.isEmpty())

        assertTrue(flows.authTabReturned(AuthTabReturn.OK, "conduit://oauth/callback?code=c&state=s"))
        assertTrue(endings.single() is BrowserAuthEnding.Success)
    }

    @Test
    fun anAuthTabOnAnotherRedirectFails() {
        begin(BrowserAuthChannel.AUTH_TAB)

        flows.authTabReturned(AuthTabReturn.OK, "conduit://oauth/elsewhere?code=c&state=s")

        assertEquals(
            BrowserAuthEnding.Failed(BrowserAuthErrorCodes.UNEXPECTED_CALLBACK),
            endings.single(),
        )
    }

    @Test
    fun anAuthTabRedirectWithoutAKnownStateIsTheCurrentFlowsWhenNoTabIsStale() {
        // Its own tab came back; Dart's state check judges the redirect.
        begin(BrowserAuthChannel.AUTH_TAB)

        assertTrue(flows.authTabReturned(AuthTabReturn.OK, "conduit://oauth/callback?error=e"))

        assertTrue(endings.single() is BrowserAuthEnding.Success)
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
        assertEquals(0, flows.staleAuthTabCount)
    }

    @Test
    fun anAuthTabResultForAnotherChannelIsIgnored() {
        begin(BrowserAuthChannel.CUSTOM_TABS)

        assertFalse(flows.authTabReturned(AuthTabReturn.CANCELED, null))
        assertTrue(endings.isEmpty())
    }

    @Test
    fun aLateCancelFromASupersededAuthTabLeavesTheNewFlow() {
        val first = mutableListOf<BrowserAuthEnding>()
        begin(BrowserAuthChannel.AUTH_TAB, state = "old", into = first)
        val secondId = begin(BrowserAuthChannel.AUTH_TAB, state = "new")
        assertEquals(1, flows.staleAuthTabCount)

        assertFalse(flows.authTabReturned(AuthTabReturn.CANCELED, null))

        assertEquals(
            listOf<BrowserAuthEnding>(BrowserAuthEnding.Failed(BrowserAuthErrorCodes.SUPERSEDED)),
            first,
        )
        assertTrue(endings.isEmpty())
        assertEquals(secondId, flows.pendingId)
        assertEquals(0, flows.staleAuthTabCount)

        // The new tab's own cancel, once the stale one has reported back.
        assertTrue(flows.authTabReturned(AuthTabReturn.CANCELED, null))
        assertEquals(listOf<BrowserAuthEnding>(BrowserAuthEnding.Cancelled), endings)
    }

    @Test
    fun aLateCancelFromAnAuthTabCancelledFromDartLeavesTheNewFlow() {
        begin(BrowserAuthChannel.AUTH_TAB, state = "old")
        assertTrue(flows.cancel())
        endings.clear()
        val secondId = begin(BrowserAuthChannel.AUTH_TAB, state = "new")

        assertFalse(flows.authTabReturned(AuthTabReturn.CANCELED, null))

        assertTrue(endings.isEmpty())
        assertEquals(secondId, flows.pendingId)
    }

    @Test
    fun aLateSuccessWithASupersededStateIsIgnored() {
        begin(BrowserAuthChannel.AUTH_TAB, state = "old", into = mutableListOf())
        val secondId = begin(BrowserAuthChannel.AUTH_TAB, state = "new")

        assertFalse(flows.authTabReturned(AuthTabReturn.OK, "conduit://oauth/callback?code=c&state=old"))

        assertTrue(endings.isEmpty())
        assertEquals(secondId, flows.pendingId)
        assertEquals(0, flows.staleAuthTabCount)
    }

    @Test
    fun aSuccessWithTheCurrentStateEndsTheCurrentFlowWhileATabIsStale() {
        begin(BrowserAuthChannel.AUTH_TAB, state = "old", into = mutableListOf())
        begin(BrowserAuthChannel.AUTH_TAB, state = "new")

        assertTrue(flows.authTabReturned(AuthTabReturn.OK, "conduit://oauth/callback?code=c&state=new"))

        val success = endings.single() as BrowserAuthEnding.Success
        assertEquals("conduit://oauth/callback?code=c&state=new", success.callbackUrl)
        // The superseded tab may still report back, and is still expected.
        assertEquals(1, flows.staleAuthTabCount)
    }

    @Test
    fun anAbandonedAuthTabsLateResultLeavesTheNextFlow() {
        begin(BrowserAuthChannel.AUTH_TAB, state = "old")
        flows.abandon()
        val secondId = begin(BrowserAuthChannel.AUTH_TAB, state = "new")

        assertFalse(flows.authTabReturned(AuthTabReturn.CANCELED, null))

        assertTrue(endings.isEmpty())
        assertEquals(secondId, flows.pendingId)
    }

    @Test
    fun aStaleAuthTabIsForgottenOnceItCanNoLongerReportBack() {
        begin(BrowserAuthChannel.AUTH_TAB, state = "old")
        flows.cancel()
        endings.clear()
        now += 10 * 60 * 1000L
        begin(BrowserAuthChannel.AUTH_TAB, state = "new")

        assertEquals(0, flows.staleAuthTabCount)
        assertTrue(flows.authTabReturned(AuthTabReturn.CANCELED, null))
        assertEquals(listOf<BrowserAuthEnding>(BrowserAuthEnding.Cancelled), endings)
    }

    @Test
    fun onlyAnAuthTabIsKeptAsStale() {
        begin(BrowserAuthChannel.CUSTOM_TABS, state = "old")
        begin(BrowserAuthChannel.EXTERNAL_BROWSER, state = "older")
        flows.cancel()
        endings.clear()
        begin(BrowserAuthChannel.AUTH_TAB, state = "new")

        assertEquals(0, flows.staleAuthTabCount)
        assertTrue(flows.authTabReturned(AuthTabReturn.CANCELED, null))
        assertEquals(listOf<BrowserAuthEnding>(BrowserAuthEnding.Cancelled), endings)
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
            "com.googleusercontent.apps.123-abc:/oauth2redirect?code=c&state=s",
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
    fun aFlowNeedsAState() {
        assertThrows(IllegalArgumentException::class.java) {
            begin(BrowserAuthChannel.AUTH_TAB, state = "")
        }
        assertNull(flows.pendingId)
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

        flows.deliver("conduit://oauth/callback?code=c&state=s")

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
        assertFalse(flows.deliver("conduit://oauth/callback?code=c&state=s"))

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
    fun anAuthTabThatNeverStartedIsNotStale() {
        val id = begin(BrowserAuthChannel.AUTH_TAB)

        flows.fail(id, BrowserAuthEnding.Failed(BrowserAuthErrorCodes.START_FAILED))

        assertEquals(0, flows.staleAuthTabCount)
    }

    @Test
    fun anAbandonedFlowNeverAnswers() {
        begin(BrowserAuthChannel.CUSTOM_TABS)

        flows.abandon()

        assertFalse(flows.deliver("conduit://oauth/callback?code=c&state=s"))
        assertTrue(endings.isEmpty())
    }

    @Test
    fun theStateIsTheOneStateParameter() {
        assertEquals("s", oauthStateOf("https://id.example.com/auth?client_id=c&state=s"))
        assertEquals("a-b_c", oauthStateOf("conduit://oauth/callback?code=c&state=a%2Db_c"))
        // A plus stays a plus.
        assertEquals("a+b", oauthStateOf("conduit://oauth/callback?state=a+b"))
        assertEquals(
            "s",
            oauthStateOf("com.googleusercontent.apps.1-a:/oauth2redirect?state=s&code=c"),
        )

        for (uri in listOf(
            "https://id.example.com/auth?client_id=c",
            "https://id.example.com/auth",
            "https://id.example.com/auth?state=",
            "https://id.example.com/auth?state",
            "https://id.example.com/auth?state=a&state=b",
            "https://id.example.com/auth?state=%zz",
            "not a uri",
        )) {
            assertNull(uri, oauthStateOf(uri))
        }
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
