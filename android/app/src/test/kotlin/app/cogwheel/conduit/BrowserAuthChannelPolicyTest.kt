package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Test

class BrowserAuthChannelPolicyTest {
    private val conduit = BrowserAuthRedirect.DEFAULT
    private val google = BrowserAuthRedirect.of(
        "com.googleusercontent.apps.123-abc",
        "",
        "/oauth2redirect",
    )!!

    @Test
    fun prefersAnAuthTabForAnyRedirect() {
        for (redirect in listOf(conduit, google)) {
            assertEquals(
                BrowserAuthLaunch.Start(BrowserAuthChannel.AUTH_TAB, "com.android.chrome"),
                chooseBrowserAuthLaunch(redirect, "com.android.chrome", true, true),
            )
        }
    }

    @Test
    fun fallsBackToACustomTabForTheAppRedirect() {
        assertEquals(
            BrowserAuthLaunch.Start(BrowserAuthChannel.CUSTOM_TABS, "org.mozilla.firefox"),
            chooseBrowserAuthLaunch(conduit, "org.mozilla.firefox", false, true),
        )
    }

    @Test
    fun fallsBackToTheDefaultBrowserWithoutCustomTabs() {
        assertEquals(
            BrowserAuthLaunch.Start(BrowserAuthChannel.EXTERNAL_BROWSER, null),
            chooseBrowserAuthLaunch(conduit, null, false, true),
        )
    }

    @Test
    fun anotherRedirectNeedsAnAuthTab() {
        val authTabRequired = BrowserAuthLaunch.Refused(
            BrowserAuthEnding.Unavailable(BrowserAuthErrorCodes.AUTH_TAB_REQUIRED),
        )

        assertEquals(authTabRequired, chooseBrowserAuthLaunch(google, "org.mozilla.firefox", false, true))
        assertEquals(authTabRequired, chooseBrowserAuthLaunch(google, null, false, true))
        // Only the callback activity's exact redirect may fall back.
        val otherConduit = BrowserAuthRedirect.of("conduit", "oauth", "/other")!!
        assertEquals(authTabRequired, chooseBrowserAuthLaunch(otherConduit, null, false, true))
    }

    @Test
    fun noBrowserAtAllIsUnavailable() {
        val noBrowser = BrowserAuthLaunch.Refused(
            BrowserAuthEnding.Unavailable(BrowserAuthErrorCodes.NO_BROWSER),
        )

        assertEquals(noBrowser, chooseBrowserAuthLaunch(conduit, null, false, false))
        assertEquals(noBrowser, chooseBrowserAuthLaunch(google, null, false, false))
    }
}
