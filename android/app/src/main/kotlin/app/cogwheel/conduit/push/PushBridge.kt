package app.cogwheel.conduit.push

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import app.cogwheel.conduit.FlutterError
import app.cogwheel.conduit.MainActivity
import app.cogwheel.conduit.PlatformPushConfig
import app.cogwheel.conduit.PlatformPushMessage
import app.cogwheel.conduit.PlatformPushSubscription
import app.cogwheel.conduit.PlatformPushTap
import app.cogwheel.conduit.PlatformPushToken
import app.cogwheel.conduit.PlatformPushTransport
import app.cogwheel.conduit.PushFlutterApi
import app.cogwheel.conduit.PushHostApi
import io.flutter.embedding.engine.FlutterEngine

/**
 * The Android side of `PushHostApi`: subscriptions and their keys, the
 * mirrored notification settings, the shared dedup ledger, FCM tokens and
 * UnifiedPush registration. See docs/push/PROTOCOL.md.
 */
class PushBridge(private val activity: MainActivity) : PushHostApi {
    private val context = activity.applicationContext
    private var engine: FlutterEngine? = null
    private var flutterApi: PushFlutterApi? = null
    private var permissionLauncher: ActivityResultLauncher<String>? = null
    private val permissionCallbacks = mutableListOf<(Result<Boolean>) -> Unit>()

    fun setup(flutterEngine: FlutterEngine) {
        engine = flutterEngine
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        PushHostApi.setUp(messenger, this)
        flutterApi = PushFlutterApi(messenger)
        PushRuntime.bridge = this
    }

    fun dispose() {
        engine?.let { PushHostApi.setUp(it.dartExecutor.binaryMessenger, null) }
        engine = null
        flutterApi = null
        if (PushRuntime.bridge === this) PushRuntime.bridge = null
        permissionLauncher?.unregister()
        permissionLauncher = null
        val waiting = permissionCallbacks.toList()
        permissionCallbacks.clear()
        waiting.forEach { it(Result.success(false)) }
    }

    /** A notification tap while the app runs. */
    fun handleNewIntent(intent: Intent) {
        val tap = PushTaps.read(context, intent) ?: return
        val api = flutterApi
        if (api == null) {
            PushTaps.stash(tap)
            return
        }
        api.onTap(tap) { result ->
            // Dart may not listen yet (still starting); keep it for takeLaunchTap.
            if (result.isFailure) PushTaps.stash(tap)
        }
    }

    // Called by the receivers on the main thread.

    internal fun forwardForegroundPush(message: PlatformPushMessage, done: (Boolean) -> Unit) {
        val api = flutterApi ?: return done(false)
        api.onForegroundPush(message) { result -> done(result.isSuccess) }
    }

    internal fun notifyToken(token: PlatformPushToken) {
        flutterApi?.onToken(token) {}
    }

    internal fun notifyTestReceived(sid: String, nonce: String) {
        flutterApi?.onTestReceived(sid, nonce) {}
    }

    internal fun notifyUnregistered(sid: String) {
        flutterApi?.onUnregistered(sid) {}
    }

    internal fun notifyUnifiedPushEndpoint(sid: String, endpoint: String) {
        flutterApi?.onUnifiedPushEndpoint(sid, endpoint) {}
    }

    // PushHostApi

    override fun availableTransports(): List<PlatformPushTransport> = buildList {
        if (FcmTransport.isAvailable(context)) add(PlatformPushTransport.FCM)
        if (UnifiedPushRegistrar.distributors(context).isNotEmpty()) add(PlatformPushTransport.UNIFIED_PUSH)
    }

    override fun requestPermission(callback: (Result<Boolean>) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            callback(Result.success(NotificationManagerCompat.from(context).areNotificationsEnabled()))
            return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            callback(Result.success(true))
            return
        }
        permissionCallbacks += callback
        if (permissionCallbacks.size > 1) return
        val launcher = permissionLauncher ?: activity.activityResultRegistry.register(
            PERMISSION_REQUEST_KEY,
            ActivityResultContracts.RequestPermission(),
        ) { granted ->
            val waiting = permissionCallbacks.toList()
            permissionCallbacks.clear()
            waiting.forEach { it(Result.success(granted)) }
        }.also { permissionLauncher = it }
        try {
            launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } catch (error: RuntimeException) {
            val waiting = permissionCallbacks.toList()
            permissionCallbacks.clear()
            waiting.forEach { it(Result.failure(FlutterError("permission_failed", error.message, null))) }
        }
    }

    override fun currentToken(
        transport: PlatformPushTransport,
        callback: (Result<PlatformPushToken?>) -> Unit,
    ) {
        if (transport != PlatformPushTransport.FCM) {
            callback(Result.success(null))
            return
        }
        FcmTransport.requestToken(context) { result ->
            callback(
                result.map { token ->
                    token?.let {
                        PlatformPushToken(
                            transport = PlatformPushTransport.FCM,
                            token = it,
                            app = context.packageName,
                            env = "prod",
                        )
                    }
                }
            )
        }
    }

    override fun createSubscription(scope: String): PlatformPushSubscription {
        if (scope.isBlank()) throw FlutterError("invalid_scope", "Scope must not be empty", null)
        return keyStoreCall { it.create(scope) }.toPlatform()
    }

    override fun listSubscriptions(): List<PlatformPushSubscription> =
        keyStoreCall { it.list() }.map { it.toPlatform() }

    override fun setEndpoint(sid: String, endpoint: String, transport: PlatformPushTransport) {
        val previous = keyStoreCall { it.find(sid) }
            ?: throw FlutterError("unknown_sid", "No push subscription $sid", null)
        keyStoreCall { it.setEndpoint(sid, endpoint, transport.storedName()) }
        if (previous.transport == PushTransportName.UNIFIED_PUSH &&
            transport != PlatformPushTransport.UNIFIED_PUSH
        ) {
            // Moved off UnifiedPush: stop the distributor delivering to it.
            UnifiedPushRegistrar.unregister(context, sid)
        }
    }

    override fun deleteSubscription(sid: String) {
        val removed = keyStoreCall { it.delete(sid) } ?: return
        if (removed.transport == PushTransportName.UNIFIED_PUSH) {
            UnifiedPushRegistrar.unregister(context, sid)
        }
        PushRuntime.config(context).clearNonces(sid)
    }

    override fun setConfig(config: PlatformPushConfig) {
        PushRuntime.config(context).save(
            PushDisplayConfig(
                enabled = config.enabled,
                sound = config.sound,
                enabledKinds = config.enabledKinds.toSet(),
                disabledScopes = config.disabledScopes.toSet(),
                scopeLabels = config.scopeLabels,
                showScopeLabel = config.showScopeLabel,
                strings = config.strings,
            )
        )
    }

    /**
     * Dart claims before it posts and again, with the same id, right after,
     * so iOS can remove a copy a push overtook. Here the second claim only
     * answers false: the receiver shares this in-process ledger and never
     * takes over a key the app claimed, so there is no copy to remove.
     */
    override fun claimNotification(dedupKey: String, localNotificationId: String?): Boolean =
        PushRuntime.ledger(context).claim(dedupKey, localNotificationId)

    override fun cancelScope(scope: String) {
        val local = PushRuntime.ledger(context).claimsFor(scope).mapNotNull { claim ->
            claim.localNotificationId?.toIntOrNull()?.let { id -> claim.key to id }
        }
        PushNotifier(context).cancelScope(scope, local)
    }

    override fun takeLaunchTap(): PlatformPushTap? = PushTaps.takeLaunchTap()

    override fun takeVerifiedNonces(sid: String): List<String> = PushRuntime.config(context).takeNonces(sid)

    override fun unifiedPushDistributors(): List<String> = UnifiedPushRegistrar.distributors(context)

    override fun registerUnifiedPush(sid: String, distributor: String, callback: (Result<String?>) -> Unit) {
        // Pigeon does not catch exceptions from async methods. The registrar
        // only throws before it has taken the callback, so this answers once.
        try {
            UnifiedPushRegistrar.register(context, sid, distributor) { endpoint ->
                callback(Result.success(endpoint))
            }
        } catch (error: Exception) {
            Log.w(TAG, "UnifiedPush registration failed", error)
            callback(Result.failure(FlutterError("unified_push_failed", error.message, null)))
        }
    }

    override fun unregisterUnifiedPush(sid: String) {
        UnifiedPushRegistrar.unregister(context, sid)
    }

    /** Push stopped using [transport]; for FCM, Firebase stops for good. */
    override fun releaseTransport(transport: PlatformPushTransport) {
        if (transport == PlatformPushTransport.FCM) FcmTransport.release(context)
    }

    private fun <T> keyStoreCall(block: (PushKeyStore) -> T): T = try {
        block(PushRuntime.keyStore(context))
    } catch (error: FlutterError) {
        throw error
    } catch (error: Exception) {
        Log.w(TAG, "Push key store failed", error)
        throw FlutterError("key_store_unavailable", error.message ?: error.javaClass.simpleName, null)
    }

    private fun PushSubscriptionRecord.toPlatform() = PlatformPushSubscription(
        sid = sid,
        scope = scope,
        p256dh = p256dh,
        auth = auth,
        createdAtMillis = createdAtMillis,
        endpoint = endpoint,
        transport = when (transport) {
            PushTransportName.FCM -> PlatformPushTransport.FCM
            PushTransportName.UNIFIED_PUSH -> PlatformPushTransport.UNIFIED_PUSH
            PushTransportName.APNS -> PlatformPushTransport.APNS
            else -> null
        },
    )

    private fun PlatformPushTransport.storedName(): String = when (this) {
        PlatformPushTransport.FCM -> PushTransportName.FCM
        PlatformPushTransport.UNIFIED_PUSH -> PushTransportName.UNIFIED_PUSH
        PlatformPushTransport.APNS -> PushTransportName.APNS
    }

    companion object {
        private const val TAG = "PushBridge"
        private const val PERMISSION_REQUEST_KEY = "conduit_push_notification_permission"

        /**
         * Keeps the tap that launched [MainActivity] until Dart calls
         * `takeLaunchTap`. Skipped when the activity is being recreated,
         * which would replay the same intent.
         */
        fun captureLaunchIntent(activity: MainActivity, intent: Intent?, isRecreated: Boolean) {
            if (isRecreated) return
            PushTaps.read(activity.applicationContext, intent)?.let(PushTaps::stash)
        }
    }
}
