package app.cogwheel.conduit.push

import android.content.Context

/**
 * The foss build has no Firebase code, so FCM is never available and push
 * arrives through UnifiedPush only. Same API as the play build's version.
 */
internal object FcmTransport {
    @Suppress("UNUSED_PARAMETER")
    fun isAvailable(context: Context): Boolean = false

    @Suppress("UNUSED_PARAMETER")
    fun initializeIfOptedIn(context: Context) = Unit

    @Suppress("UNUSED_PARAMETER")
    fun requestToken(context: Context, callback: (Result<String?>) -> Unit) {
        callback(Result.success(null))
    }
}
