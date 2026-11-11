package app.cogwheel.conduit.push

import android.content.Context
import android.util.Log
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.UnifiedPush
import org.unifiedpush.android.connector.data.PublicKeySet
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage
import org.unifiedpush.android.connector.keys.KeyManager

/**
 * Receives UnifiedPush events (connector 3.x). The connector instance is the
 * subscription's sid, and messages are the raw aes128gcm body the user's
 * server encrypted to Conduit's own key (docs/push/PROTOCOL.md section 6).
 */
class ConduitUnifiedPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        UnifiedPushRegistrar.onNewEndpoint(applicationContext, instance, endpoint.url)
    }

    override fun onMessage(message: PushMessage, instance: String) {
        // Registrations use RawKeyManager, so the connector never holds keys
        // that could decrypt a message itself. Anything it did decrypt was
        // not encrypted to this subscription's key.
        if (message.decrypted) {
            Log.w(TAG, "Ignoring a message the connector decrypted")
            return
        }
        PushRuntime.receiver(applicationContext).handle(instance, message.content)
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        Log.w(TAG, "UnifiedPush registration failed: $reason")
        UnifiedPushRegistrar.onRegistrationFailed(instance)
    }

    override fun onUnregistered(instance: String) {
        UnifiedPushRegistrar.onUnregistered(applicationContext, instance)
    }

    private companion object {
        const val TAG = "ConduitUnifiedPush"
    }
}

/**
 * Tells the connector to keep no Web Push keys of its own. Conduit's keys
 * live in [PushKeyStore], so the connector delivers every message undecrypted.
 */
internal object RawKeyManager : KeyManager {
    override fun decrypt(instance: String, sealed: ByteArray): ByteArray? = null
    override fun generate(instance: String) = Unit
    override fun getPublicKeySet(instance: String): PublicKeySet? = null
    override fun exists(instance: String): Boolean = true
    override fun delete(instance: String) = Unit
}

/**
 * UnifiedPush registration for the push bridge. Registering answers through
 * [ConduitUnifiedPushService], so pending requests wait here for their
 * endpoint, a failure, or a timeout. Main thread only.
 */
internal object UnifiedPushRegistrar {
    private const val TAG = "ConduitUnifiedPush"
    const val TIMEOUT_MILLIS = 20_000L

    private class Pending(val callback: (String?) -> Unit, val timeout: Runnable)

    private val pending = HashMap<String, Pending>()

    /** Installed distributors, without Conduit itself. */
    fun distributors(context: Context): List<String> =
        UnifiedPush.getDistributors(context).filter { it != context.packageName }

    fun register(context: Context, sid: String, distributor: String, callback: (String?) -> Unit) {
        val appContext = context.applicationContext
        if (PushRuntime.keyStore(appContext).find(sid) == null || distributor !in distributors(appContext)) {
            callback(null)
            return
        }
        complete(sid, null)
        val timeout = Runnable { complete(sid, null) }
        pending[sid] = Pending(callback, timeout)
        PushRuntime.mainHandler.postDelayed(timeout, TIMEOUT_MILLIS)
        try {
            // The connector keeps one distributor for the whole app;
            // switching tells the old one to drop every registration.
            if (UnifiedPush.getSavedDistributor(appContext) != distributor) {
                UnifiedPush.saveDistributor(appContext, distributor)
            }
            UnifiedPush.register(
                appContext,
                instance = sid,
                messageForDistributor = "Conduit",
                vapid = null,
                keyManager = RawKeyManager,
            )
        } catch (error: Exception) {
            Log.w(TAG, "UnifiedPush registration could not start", error)
            complete(sid, null)
        }
    }

    fun unregister(context: Context, sid: String) {
        complete(sid, null)
        try {
            UnifiedPush.unregister(context.applicationContext, sid, RawKeyManager)
        } catch (error: Exception) {
            Log.w(TAG, "UnifiedPush unregistration failed", error)
        }
        clearEndpoint(context, sid)
    }

    fun onNewEndpoint(context: Context, sid: String, endpoint: String) {
        PushRuntime.mainHandler.post {
            val keyStore = PushRuntime.keyStore(context)
            val stored = try {
                keyStore.setEndpoint(sid, endpoint, PushTransportName.UNIFIED_PUSH)
            } catch (error: Exception) {
                Log.w(TAG, "Could not store UnifiedPush endpoint", error)
                complete(sid, null)
                return@post
            }
            if (!stored) {
                // The subscription is gone; stop the distributor delivering.
                unregister(context, sid)
                return@post
            }
            if (!complete(sid, endpoint)) {
                PushRuntime.bridge?.notifyUnifiedPushEndpoint(sid, endpoint)
            }
        }
    }

    fun onRegistrationFailed(sid: String) {
        PushRuntime.mainHandler.post { complete(sid, null) }
    }

    fun onUnregistered(context: Context, sid: String) {
        PushRuntime.mainHandler.post {
            complete(sid, null)
            clearEndpoint(context, sid)
            PushRuntime.bridge?.notifyUnregistered(sid)
        }
    }

    /** Answers a pending registration. False when none was waiting. */
    private fun complete(sid: String, endpoint: String?): Boolean {
        val request = pending.remove(sid) ?: return false
        PushRuntime.mainHandler.removeCallbacks(request.timeout)
        request.callback(endpoint)
        return true
    }

    private fun clearEndpoint(context: Context, sid: String) {
        try {
            val keyStore = PushRuntime.keyStore(context)
            if (keyStore.find(sid)?.transport == PushTransportName.UNIFIED_PUSH) {
                keyStore.setEndpoint(sid, null, null)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not clear UnifiedPush endpoint", error)
        }
    }
}
