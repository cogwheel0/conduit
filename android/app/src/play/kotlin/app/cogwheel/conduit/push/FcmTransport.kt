package app.cogwheel.conduit.push

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import app.cogwheel.conduit.BuildConfig
import app.cogwheel.conduit.FlutterError
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging

/**
 * Firebase Cloud Messaging for the play build.
 *
 * There is no google-services.json: the Firebase project comes from
 * BuildConfig (CONDUIT_FCM_* Gradle properties). Firebase's own start-up
 * provider is removed, so nothing talks to Google until the user turns push
 * on and Dart asks for a token. From then on the app re-initializes Firebase
 * at every start so pushes decrypt after a process restart.
 */
internal object FcmTransport {
    private const val TAG = "ConduitFcm"
    private const val PLAY_SERVICES_PACKAGE = "com.google.android.gms"

    /**
     * The token deletion [release] started. Firebase runs deletion and token
     * requests on different executors, so a request made while this runs
     * could return the token the deletion is about to invalidate.
     */
    @Volatile
    private var pendingDeletion: Task<Void>? = null

    private fun options(): FirebaseOptions? {
        val projectId = BuildConfig.CONDUIT_FCM_PROJECT_ID
        val appId = BuildConfig.CONDUIT_FCM_APP_ID
        val apiKey = BuildConfig.CONDUIT_FCM_API_KEY
        val senderId = BuildConfig.CONDUIT_FCM_SENDER_ID
        if (listOf(projectId, appId, apiKey, senderId).any { it.isBlank() }) return null
        return FirebaseOptions.Builder()
            .setProjectId(projectId)
            .setApplicationId(appId)
            .setApiKey(apiKey)
            .setGcmSenderId(senderId)
            .build()
    }

    /** This build has a Firebase project and the device has Play services. */
    fun isAvailable(context: Context): Boolean = options() != null && hasPlayServices(context)

    /** Starts Firebase at app start, but only once the user opted in. */
    fun initializeIfOptedIn(context: Context) {
        if (!PushRuntime.config(context).fcmOptedIn) return
        try {
            ensureInitialized(context)
        } catch (error: RuntimeException) {
            Log.w(TAG, "Firebase could not start", error)
        }
    }

    fun requestToken(context: Context, callback: (Result<String?>) -> Unit) {
        val appContext = context.applicationContext
        if (!isAvailable(appContext)) {
            callback(Result.success(null))
            return
        }
        val messaging = try {
            ensureInitialized(appContext)
            PushRuntime.config(appContext).fcmOptedIn = true
            FirebaseMessaging.getInstance()
        } catch (error: RuntimeException) {
            callback(Result.failure(FlutterError("fcm_unavailable", error.message, null)))
            return
        }
        // The manifest keeps auto-init off until now; from here on FCM
        // refreshes the token by itself. Not before a deletion still running
        // has ended: Firebase's own sync could fetch the token it is about to
        // invalidate.
        fun fetchToken() {
            messaging.isAutoInitEnabled = true
            messaging.token.addOnCompleteListener { task ->
                if (task.isSuccessful) {
                    callback(Result.success(task.result))
                } else {
                    val message = task.exception?.message ?: "FCM did not issue a token"
                    callback(Result.failure(FlutterError("fcm_token_failed", message, null)))
                }
            }
        }
        // Wait for every deletion still running, whether or not it succeeds,
        // then ask for a token: it is a new one. Each time one ends, look
        // again: a release meanwhile may have started another. Released
        // (push turned off) when none is left, this request is stale and gets
        // no token; a later one opts in again.
        fun afterDeletions() {
            val deletion = pendingDeletion
            if (deletion != null && !deletion.isComplete) {
                deletion.addOnCompleteListener { afterDeletions() }
            } else if (PushRuntime.config(appContext).fcmOptedIn) {
                fetchToken()
            } else {
                callback(Result.success(null))
            }
        }
        afterDeletions()
    }

    /**
     * Stops using FCM: Firebase no longer starts at launch, auto-init is off
     * again and the token is deleted, so Google stops issuing one. A later
     * [requestToken] opts in again.
     */
    fun release(context: Context) {
        val appContext = context.applicationContext
        PushRuntime.config(appContext).fcmOptedIn = false
        if (FirebaseApp.getApps(appContext).none { it.name == FirebaseApp.DEFAULT_APP_NAME }) return
        try {
            FirebaseMessaging.getInstance().apply {
                isAutoInitEnabled = false
                val deletion = deleteToken().addOnFailureListener { error ->
                    Log.w(TAG, "FCM token could not be deleted", error)
                }
                // Releases can overlap, and a later deletion may end first: a
                // token request waits for every one still running.
                val earlier = pendingDeletion
                pendingDeletion = if (earlier == null || earlier.isComplete) {
                    deletion
                } else {
                    Tasks.whenAll(earlier, deletion)
                }
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "Firebase could not stop", error)
        }
    }

    @Synchronized
    private fun ensureInitialized(context: Context) {
        val options = options() ?: throw IllegalStateException("FCM is not configured in this build")
        if (FirebaseApp.getApps(context).none { it.name == FirebaseApp.DEFAULT_APP_NAME }) {
            FirebaseApp.initializeApp(context.applicationContext, options)
        }
    }

    private fun hasPlayServices(context: Context): Boolean = try {
        context.packageManager.getApplicationInfo(PLAY_SERVICES_PACKAGE, 0).enabled
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }
}
