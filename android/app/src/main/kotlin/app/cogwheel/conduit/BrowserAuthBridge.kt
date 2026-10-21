package app.cogwheel.conduit

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.browser.auth.AuthTabIntent
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger

/**
 * Runs a sign-in page in the system browser, where passkeys and security
 * keys work, and returns the redirect it ends on.
 *
 * The browser surface follows [chooseBrowserAuthLaunch]. Create this as a
 * property of the activity: the Auth Tab's result launcher must be
 * registered before the activity starts. Nothing here logs a URL: the
 * redirect carries a one-time code.
 */
class BrowserAuthBridge(private val activity: ComponentActivity) : BrowserAuthHostApi {
    private val flows = BrowserAuthSession.flows
    private val authTabLauncher: ActivityResultLauncher<Intent> =
        AuthTabIntent.registerActivityResultLauncher(activity) { result ->
            val outcome = when (result.resultCode) {
                AuthTabIntent.RESULT_OK -> AuthTabReturn.OK
                AuthTabIntent.RESULT_CANCELED -> AuthTabReturn.CANCELED
                else -> AuthTabReturn.FAILED
            }
            flows.authTabReturned(outcome, result.resultUri?.toString())
        }
    private val mainHandler = Handler(Looper.getMainLooper())
    private var messenger: BinaryMessenger? = null

    fun setup(flutterEngine: FlutterEngine) {
        val binaryMessenger = flutterEngine.dartExecutor.binaryMessenger
        messenger = binaryMessenger
        BrowserAuthHostApi.setUp(binaryMessenger, this)
    }

    fun dispose() {
        messenger?.let { BrowserAuthHostApi.setUp(it, null) }
        messenger = null
        mainHandler.removeCallbacksAndMessages(null)
        // Dart's call went with the engine; nobody is left to answer.
        flows.abandon()
    }

    fun onPause() {
        flows.onPaused()
    }

    fun onResume() {
        val id = flows.onResumed() ?: return
        mainHandler.postDelayed({ flows.cancelIfPending(id) }, CUSTOM_TAB_CLOSED_GRACE_MS)
    }

    override fun authenticate(
        request: PlatformBrowserAuthRequest,
        callback: (Result<PlatformBrowserAuthResult>) -> Unit,
    ) {
        val url = Uri.parse(request.authorizationUrl)
        val redirect = BrowserAuthRedirect.of(
            request.callbackScheme,
            request.callbackHost,
            request.callbackPath,
        )
        val scheme = url.scheme?.lowercase()
        if (redirect == null || (scheme != "https" && scheme != "http") || url.host.isNullOrEmpty()) {
            callback(Result.success(resultFor(BrowserAuthEnding.Failed(BrowserAuthErrorCodes.INVALID_REQUEST), null)))
            return
        }

        val launch = try {
            chooseLaunch(url, redirect)
        } catch (e: RuntimeException) {
            Log.w(TAG, "Browser lookup failed: ${e.javaClass.simpleName}")
            BrowserAuthLaunch.Refused(BrowserAuthEnding.Failed(BrowserAuthErrorCodes.START_FAILED))
        }
        val start = when (launch) {
            is BrowserAuthLaunch.Refused -> {
                callback(Result.success(resultFor(launch.ending, null)))
                return
            }
            is BrowserAuthLaunch.Start -> launch
        }

        val channel = start.channel
        val id = flows.begin(channel, redirect) { ending ->
            callback(Result.success(resultFor(ending, channel)))
        }
        try {
            when (channel) {
                BrowserAuthChannel.AUTH_TAB -> {
                    val authTab = AuthTabIntent.Builder()
                        .setEphemeralBrowsingEnabled(request.preferEphemeralSession)
                        .build()
                    authTab.intent.setPackage(start.browserPackage)
                    authTab.launch(authTabLauncher, url, redirect.scheme)
                }
                BrowserAuthChannel.CUSTOM_TABS -> {
                    val customTab = CustomTabsIntent.Builder()
                        .setEphemeralBrowsingEnabled(request.preferEphemeralSession)
                        .build()
                    customTab.intent.setPackage(start.browserPackage)
                    customTab.launchUrl(activity, url)
                }
                BrowserAuthChannel.EXTERNAL_BROWSER -> {
                    activity.startActivity(browserIntent(url))
                    mainHandler.postDelayed({ flows.cancelIfPending(id) }, EXTERNAL_BROWSER_TIMEOUT_MS)
                }
            }
        } catch (e: ActivityNotFoundException) {
            flows.fail(id, BrowserAuthEnding.Unavailable(BrowserAuthErrorCodes.NO_BROWSER))
        } catch (e: RuntimeException) {
            Log.w(TAG, "Browser sign-in did not start: ${e.javaClass.simpleName}")
            flows.fail(id, BrowserAuthEnding.Failed(BrowserAuthErrorCodes.START_FAILED))
        }
    }

    override fun cancel() {
        flows.cancel()
    }

    private fun chooseLaunch(url: Uri, redirect: BrowserAuthRedirect): BrowserAuthLaunch {
        // The default browser, when it supports Custom Tabs.
        val customTabsPackage = CustomTabsClient.getPackageName(activity, null)
        val authTabSupported = customTabsPackage != null &&
            CustomTabsClient.isAuthTabSupported(activity, customTabsPackage)
        val hasBrowser = browserIntent(url).resolveActivity(activity.packageManager) != null
        return chooseBrowserAuthLaunch(redirect, customTabsPackage, authTabSupported, hasBrowser)
    }

    private fun browserIntent(url: Uri): Intent =
        Intent(Intent.ACTION_VIEW, url).addCategory(Intent.CATEGORY_BROWSABLE)

    private fun resultFor(
        ending: BrowserAuthEnding,
        channel: BrowserAuthChannel?,
    ): PlatformBrowserAuthResult = when (ending) {
        is BrowserAuthEnding.Success -> PlatformBrowserAuthResult(
            outcome = PlatformBrowserAuthOutcome.SUCCESS,
            callbackUrl = ending.callbackUrl,
            channel = channel?.wireName,
        )
        BrowserAuthEnding.Cancelled -> PlatformBrowserAuthResult(
            outcome = PlatformBrowserAuthOutcome.CANCELLED,
            channel = channel?.wireName,
        )
        is BrowserAuthEnding.Unavailable -> PlatformBrowserAuthResult(
            outcome = PlatformBrowserAuthOutcome.UNAVAILABLE,
            errorCode = ending.code,
            channel = channel?.wireName,
        )
        is BrowserAuthEnding.Failed -> PlatformBrowserAuthResult(
            outcome = PlatformBrowserAuthOutcome.FAILED,
            errorCode = ending.code,
            channel = channel?.wireName,
        )
    }

    private companion object {
        const val TAG = "BrowserAuthBridge"

        /**
         * After a Custom Tab closes, how long a redirect still has to arrive
         * before the sign-in counts as cancelled.
         */
        const val CUSTOM_TAB_CLOSED_GRACE_MS = 300L

        /** How long a sign-in in the default browser may take. */
        const val EXTERNAL_BROWSER_TIMEOUT_MS = 10 * 60 * 1000L
    }
}
