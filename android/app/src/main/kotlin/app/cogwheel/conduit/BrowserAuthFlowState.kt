package app.cogwheel.conduit

import java.net.URI
import java.net.URISyntaxException

/** Stable reasons a browser sign-in did not finish, shared with Dart. */
internal object BrowserAuthErrorCodes {
    const val PRESENTATION_FAILED = "presentation_failed"
    const val NO_BROWSER = "no_browser"
    const val START_FAILED = "start_failed"
    const val UNEXPECTED_CALLBACK = "unexpected_callback"
    const val AUTH_TAB_REQUIRED = "auth_tab_required"
    const val SUPERSEDED = "superseded"
    const val INVALID_REQUEST = "invalid_request"
}

/** The browser surface a sign-in runs in, by the name Dart knows it by. */
internal enum class BrowserAuthChannel(val wireName: String) {
    AUTH_TAB("auth_tab"),
    CUSTOM_TABS("custom_tabs"),
    EXTERNAL_BROWSER("external_browser"),
}

/** How a sign-in ended. Never prints the redirect, which holds a code. */
internal sealed class BrowserAuthEnding {
    class Success(val callbackUrl: String) : BrowserAuthEnding() {
        override fun toString() = "Success"
    }

    object Cancelled : BrowserAuthEnding() {
        override fun toString() = "Cancelled"
    }

    data class Unavailable(val code: String) : BrowserAuthEnding()

    data class Failed(val code: String) : BrowserAuthEnding()
}

/**
 * The redirect a sign-in must end on: scheme, host (empty for a redirect
 * without one, such as Google's `com.googleusercontent.apps.<id>:/oauth2redirect`)
 * and path, matched exactly.
 */
internal data class BrowserAuthRedirect(
    val scheme: String,
    val host: String,
    val path: String,
) {
    /**
     * Whether [BrowserAuthCallbackActivity]'s intent filter receives this
     * redirect. Any other can only come back through an Auth Tab, which
     * returns it without the system routing a link.
     */
    val reachesCallbackActivity: Boolean get() = this == DEFAULT

    /** Whether [uri] is this redirect with only a query added. */
    fun matches(uri: String): Boolean {
        val parsed = try {
            URI(uri)
        } catch (e: URISyntaxException) {
            return false
        }
        return !parsed.isOpaque &&
            parsed.scheme?.lowercase() == scheme &&
            (parsed.host ?: "").lowercase() == host &&
            parsed.rawPath == path &&
            parsed.port == -1 &&
            parsed.rawUserInfo == null &&
            parsed.rawFragment == null &&
            // A host java.net.URI cannot parse leaves only the authority.
            (parsed.host != null || parsed.rawAuthority == null)
    }

    companion object {
        val DEFAULT = BrowserAuthRedirect("conduit", "oauth", "/callback")

        private val schemePattern = Regex("^[a-z][a-z0-9+.-]*$")

        /** The redirect Dart asked for, or null when it is not an app redirect. */
        fun of(scheme: String, host: String, path: String): BrowserAuthRedirect? {
            val normalizedScheme = scheme.lowercase()
            if (!schemePattern.matches(normalizedScheme)) return null
            if (normalizedScheme == "http" || normalizedScheme == "https") return null
            if (!path.startsWith("/")) return null
            return BrowserAuthRedirect(normalizedScheme, host.lowercase(), path)
        }
    }
}

/** Where a sign-in can run, given what the device has. */
internal sealed class BrowserAuthLaunch {
    /** Open the sign-in page in [channel], in [browserPackage] when set. */
    data class Start(
        val channel: BrowserAuthChannel,
        val browserPackage: String?,
    ) : BrowserAuthLaunch()

    /** The sign-in cannot run here. */
    data class Refused(val ending: BrowserAuthEnding) : BrowserAuthLaunch()
}

/**
 * Picks the browser surface for [redirect].
 *
 * An Auth Tab when the default browser has one: it returns the redirect
 * straight to the app, for any scheme, so no other app can intercept it.
 * Otherwise a Custom Tab, else the default browser, both of which return
 * through [BrowserAuthCallbackActivity] and so only for its redirect.
 *
 * [customTabsPackage] is the default browser when it supports Custom Tabs;
 * [hasBrowser] says whether anything opens the sign-in page at all.
 */
internal fun chooseBrowserAuthLaunch(
    redirect: BrowserAuthRedirect,
    customTabsPackage: String?,
    authTabSupported: Boolean,
    hasBrowser: Boolean,
): BrowserAuthLaunch {
    if (customTabsPackage != null && authTabSupported) {
        return BrowserAuthLaunch.Start(BrowserAuthChannel.AUTH_TAB, customTabsPackage)
    }
    if (customTabsPackage == null && !hasBrowser) {
        return BrowserAuthLaunch.Refused(
            BrowserAuthEnding.Unavailable(BrowserAuthErrorCodes.NO_BROWSER),
        )
    }
    if (!redirect.reachesCallbackActivity) {
        return BrowserAuthLaunch.Refused(
            BrowserAuthEnding.Unavailable(BrowserAuthErrorCodes.AUTH_TAB_REQUIRED),
        )
    }
    if (customTabsPackage != null) {
        return BrowserAuthLaunch.Start(BrowserAuthChannel.CUSTOM_TABS, customTabsPackage)
    }
    return BrowserAuthLaunch.Start(BrowserAuthChannel.EXTERNAL_BROWSER, null)
}

/** How an Auth Tab reported back. */
internal enum class AuthTabReturn { OK, CANCELED, FAILED }

/**
 * The one browser sign-in in progress, and every way it can end.
 *
 * Pure, and confined to the main thread: [BrowserAuthBridge] feeds it the
 * activity's lifecycle and the Auth Tab's result, and
 * [BrowserAuthCallbackActivity] the redirects the system routes to the app.
 * Each flow ends exactly once; whatever arrives after that, or for a flow
 * already replaced, is ignored.
 *
 * - Auth Tab: ends only with the tab's own result.
 * - Custom Tab: ends with a matching redirect, or, when the app comes back
 *   to the front without one, as cancelled after a short grace period
 *   ([onResumed]): the user closed the tab.
 * - External browser: the user may switch back and forth, so it ends only
 *   with a matching redirect, a cancel from Dart, or the timeout.
 */
internal class BrowserAuthFlowState {
    private class Flow(
        val id: Long,
        val channel: BrowserAuthChannel,
        val redirect: BrowserAuthRedirect,
        val onEnd: (BrowserAuthEnding) -> Unit,
    ) {
        var leftApp = false
    }

    private var flow: Flow? = null
    private var lastId = 0L

    /** The flow in progress, if any. */
    val pendingId: Long? get() = flow?.id

    val pendingChannel: BrowserAuthChannel? get() = flow?.channel

    /**
     * Starts a flow, ending the one in progress as superseded. [onEnd] runs
     * once, when the flow ends.
     */
    fun begin(
        channel: BrowserAuthChannel,
        redirect: BrowserAuthRedirect,
        onEnd: (BrowserAuthEnding) -> Unit,
    ): Long {
        flow?.let { end(it.id, BrowserAuthEnding.Failed(BrowserAuthErrorCodes.SUPERSEDED)) }
        val started = Flow(++lastId, channel, redirect, onEnd)
        flow = started
        return started.id
    }

    /** The app went to the background, presumably for the browser. */
    fun onPaused() {
        flow?.leftApp = true
    }

    /**
     * The app is in front again. Returns the Custom Tab flow to cancel after
     * the grace period unless a redirect ends it first.
     */
    fun onResumed(): Long? {
        val current = flow ?: return null
        if (current.channel != BrowserAuthChannel.CUSTOM_TABS || !current.leftApp) return null
        return current.id
    }

    /** Ends flow [id] as cancelled, unless it already ended. */
    fun cancelIfPending(id: Long): Boolean = end(id, BrowserAuthEnding.Cancelled)

    /** Ends the flow in progress as cancelled, as Dart asked. */
    fun cancel(): Boolean = flow?.let { end(it.id, BrowserAuthEnding.Cancelled) } ?: false

    /** Ends flow [id] because its browser could not start. */
    fun fail(id: Long, ending: BrowserAuthEnding): Boolean = end(id, ending)

    /**
     * A redirect the system routed to [BrowserAuthCallbackActivity]. Ends a
     * Custom Tab or external browser flow when it matches exactly; an Auth Tab
     * returns its own redirect, so one routed here is not its.
     */
    fun deliver(uri: String): Boolean {
        val current = flow ?: return false
        if (current.channel == BrowserAuthChannel.AUTH_TAB) return false
        if (!current.redirect.matches(uri)) return false
        return end(current.id, BrowserAuthEnding.Success(uri))
    }

    /** The Auth Tab's result, with the redirect it ended on when [result] is OK. */
    fun authTabReturned(result: AuthTabReturn, uri: String?): Boolean {
        val current = flow ?: return false
        if (current.channel != BrowserAuthChannel.AUTH_TAB) return false
        val ending = when (result) {
            AuthTabReturn.OK ->
                if (uri != null && current.redirect.matches(uri)) {
                    BrowserAuthEnding.Success(uri)
                } else {
                    BrowserAuthEnding.Failed(BrowserAuthErrorCodes.UNEXPECTED_CALLBACK)
                }
            AuthTabReturn.CANCELED -> BrowserAuthEnding.Cancelled
            AuthTabReturn.FAILED -> BrowserAuthEnding.Failed(BrowserAuthErrorCodes.START_FAILED)
        }
        return end(current.id, ending)
    }

    /** Drops the flow without ending it: whoever was waiting is gone. */
    fun abandon() {
        flow = null
    }

    private fun end(id: Long, ending: BrowserAuthEnding): Boolean {
        val current = flow ?: return false
        if (current.id != id) return false
        flow = null
        current.onEnd(ending)
        return true
    }
}

/** The sign-in state shared by the bridge and the callback activity. */
internal object BrowserAuthSession {
    val flows = BrowserAuthFlowState()
}
