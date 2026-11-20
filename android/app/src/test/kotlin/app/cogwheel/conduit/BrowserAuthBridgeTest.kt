package app.cogwheel.conduit

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class BrowserAuthBridgeTest {
    private val flows = BrowserAuthSession.flows

    @Before
    fun setUp() {
        flows.abandon()
    }

    @After
    fun tearDown() {
        flows.abandon()
    }

    @Test
    fun aSignInPageWithoutAStateIsRefusedBeforeAnyBrowserOpens() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).get()
        val bridge = BrowserAuthBridge(activity)

        for (url in listOf(
            "https://id.example.com/auth?client_id=c&code_challenge=x",
            "https://id.example.com/auth?client_id=c&state=",
            "https://id.example.com/auth?client_id=c&state=a&state=b",
        )) {
            var answer: PlatformBrowserAuthResult? = null
            bridge.authenticate(
                PlatformBrowserAuthRequest(
                    authorizationUrl = url,
                    callbackScheme = "conduit",
                    callbackHost = "oauth",
                    callbackPath = "/callback",
                    preferEphemeralSession = false,
                ),
            ) { answer = it.getOrThrow() }

            assertEquals(url, PlatformBrowserAuthOutcome.FAILED, answer?.outcome)
            assertEquals(url, BrowserAuthErrorCodes.INVALID_REQUEST, answer?.errorCode)
            assertNull(url, flows.pendingId)
            assertNull(url, shadowOf(activity).nextStartedActivity)
        }
    }
}
