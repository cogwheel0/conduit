package app.cogwheel.conduit.push

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import app.cogwheel.conduit.PlatformPushMessage
import app.cogwheel.conduit.PlatformPushToken
import app.cogwheel.conduit.PlatformPushTransport
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The process-wide push state. FCM and UnifiedPush services can start the
 * process without an activity, so nothing here depends on the Flutter engine;
 * [bridge] is set only while one is attached.
 */
internal object PushRuntime {
    private const val TAG = "ConduitPush"
    private const val KEY_STORE_FILE = "conduit_push_keys.bin"
    private const val LEDGER_FILE = "conduit_push_ledger.json"

    @Volatile
    var bridge: PushBridge? = null

    private var keyStore: PushKeyStore? = null
    private var ledger: PushLedger? = null
    private var config: PushConfigStore? = null
    private var receiver: PushReceiverCore? = null

    @Synchronized
    fun keyStore(context: Context): PushKeyStore = keyStore ?: PushKeyStore(
        AtomicBytesFile(File(context.applicationContext.noBackupFilesDir, KEY_STORE_FILE)),
        AndroidKeystoreStoreCipher(),
    ).also { keyStore = it }

    @Synchronized
    fun ledger(context: Context): PushLedger = ledger ?: PushLedger(
        AtomicBytesFile(File(context.applicationContext.noBackupFilesDir, LEDGER_FILE)),
    ).also { ledger = it }

    @Synchronized
    fun config(context: Context): PushConfigStore = config ?: PushConfigStore(
        SharedPreferencesStore(
            context.applicationContext.getSharedPreferences(PushConfigStore.PREFS_NAME, Context.MODE_PRIVATE)
        ),
    ).also { config = it }

    @Synchronized
    fun receiver(context: Context): PushReceiverCore {
        receiver?.let { return it }
        val appContext = context.applicationContext
        val keys = keyStore(appContext)
        return PushReceiverCore(
            subscriptions = { sid ->
                try {
                    keys.find(sid)
                } catch (error: Exception) {
                    Log.w(TAG, "Push key store unavailable", error)
                    null
                }
            },
            config = config(appContext),
            ledger = ledger(appContext),
            delivery = AndroidPushDelivery(appContext),
        ).also { receiver = it }
    }

    /** A new FCM registration token. Dart re-registers with the relay. */
    fun onFcmToken(context: Context, token: String) {
        val packageName = context.packageName
        mainHandler.post {
            bridge?.notifyToken(
                PlatformPushToken(
                    transport = PlatformPushTransport.FCM,
                    token = token,
                    app = packageName,
                    env = "prod",
                )
            )
        }
    }

    val mainHandler = Handler(Looper.getMainLooper())

    fun isMainThread(): Boolean = Looper.myLooper() == Looper.getMainLooper()
}

internal class AndroidPushDelivery(private val context: Context) : PushDelivery {
    override fun runOnMain(block: () -> Unit) {
        if (PushRuntime.isMainThread()) {
            block()
            return
        }
        // FCM and the UnifiedPush receiver may finish once this returns, so
        // wait (briefly) for the notification to be posted.
        val latch = CountDownLatch(1)
        PushRuntime.mainHandler.post {
            try {
                block()
            } finally {
                latch.countDown()
            }
        }
        latch.await(MAIN_THREAD_WAIT_SECONDS, TimeUnit.SECONDS)
    }

    // Resumed, not merely started: Dart treats anything short of resumed as
    // the background, where the receiver posts the push itself.
    override fun canForwardToApp(): Boolean =
        PushRuntime.bridge != null &&
            ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)

    override fun forwardToApp(sid: String, scope: String, payloadJson: String, done: (Boolean) -> Unit) {
        val bridge = PushRuntime.bridge ?: return done(false)
        bridge.forwardForegroundPush(PlatformPushMessage(sid = sid, scope = scope, payloadJson = payloadJson), done)
    }

    override fun post(scope: String, payload: PushPayload, content: PushNotificationContent): Boolean =
        PushNotifier(context).post(scope, payload.json, content)

    override fun testReceived(sid: String, nonce: String) {
        PushRuntime.mainHandler.post { PushRuntime.bridge?.notifyTestReceived(sid, nonce) }
    }

    override fun dropped(reason: String) {
        Log.i(TAG, "Push dropped: $reason")
    }

    private companion object {
        const val TAG = "ConduitPush"
        const val MAIN_THREAD_WAIT_SECONDS = 5L
    }
}
