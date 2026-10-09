package app.cogwheel.conduit.push

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives the relay's data-only FCM messages: `{cp_v, cp_s, cp_d}`
 * (docs/push/PROTOCOL.md section 5). The body is decrypted on the device.
 */
class ConduitFirebaseMessagingService : FirebaseMessagingService() {
    override fun onCreate() {
        // ConduitApplication already did this; a no-op unless it failed.
        FcmTransport.initializeIfOptedIn(applicationContext)
        super.onCreate()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data["cp_v"] != "1") return
        val sid = data["cp_s"]?.takeIf { it.isNotEmpty() } ?: return
        val body = try {
            Base64Url.decode(data["cp_d"] ?: return)
        } catch (_: IllegalArgumentException) {
            return
        }
        PushRuntime.receiver(applicationContext).handle(sid, body)
    }

    override fun onNewToken(token: String) {
        PushRuntime.onFcmToken(applicationContext, token)
    }
}
