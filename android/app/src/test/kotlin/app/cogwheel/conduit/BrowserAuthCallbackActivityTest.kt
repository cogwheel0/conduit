package app.cogwheel.conduit

import android.content.Intent
import android.net.Uri
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class BrowserAuthCallbackActivityTest {
    private val flows = BrowserAuthSession.flows
    private val endings = mutableListOf<BrowserAuthEnding>()

    @Before
    fun setUp() {
        flows.abandon()
        endings.clear()
    }

    @After
    fun tearDown() {
        flows.abandon()
    }

    private fun launch(uri: String): BrowserAuthCallbackActivity {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
        return Robolectric.buildActivity(BrowserAuthCallbackActivity::class.java, intent)
            .create()
            .get()
    }

    private fun assertReturnedToTheAppWithoutTheRedirect(activity: BrowserAuthCallbackActivity) {
        val next = shadowOf(activity).nextStartedActivity
        assertEquals(MainActivity::class.java.name, next.component?.className)
        assertNull(next.data)
        assertNull(next.extras)
        assertEquals(
            Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
            next.flags and (Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
        assertTrue(activity.isFinishing)
    }

    @Test
    fun deliversTheRedirectToTheWaitingSignIn() {
        flows.begin(BrowserAuthChannel.CUSTOM_TABS, BrowserAuthRedirect.DEFAULT) { endings += it }

        val activity = launch("conduit://oauth/callback?code=c&state=s")

        val success = endings.single() as BrowserAuthEnding.Success
        assertEquals("conduit://oauth/callback?code=c&state=s", success.callbackUrl)
        assertReturnedToTheAppWithoutTheRedirect(activity)
    }

    @Test
    fun aSecondRedirectIsDropped() {
        flows.begin(BrowserAuthChannel.EXTERNAL_BROWSER, BrowserAuthRedirect.DEFAULT) { endings += it }

        launch("conduit://oauth/callback?code=first")
        val second = launch("conduit://oauth/callback?code=second")

        assertEquals(1, endings.size)
        assertReturnedToTheAppWithoutTheRedirect(second)
    }

    @Test
    fun aRedirectWithNoSignInWaitingOnlyReturnsToTheApp() {
        val activity = launch("conduit://oauth/callback?code=c")

        assertTrue(endings.isEmpty())
        assertReturnedToTheAppWithoutTheRedirect(activity)
    }

    @Test
    fun anAuthTabSignInIgnoresARoutedRedirect() {
        flows.begin(BrowserAuthChannel.AUTH_TAB, BrowserAuthRedirect.DEFAULT) { endings += it }

        val activity = launch("conduit://oauth/callback?code=forged")

        assertTrue(endings.isEmpty())
        assertReturnedToTheAppWithoutTheRedirect(activity)
    }
}
