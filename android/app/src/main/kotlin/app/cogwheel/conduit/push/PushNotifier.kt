package app.cogwheel.conduit.push

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import app.cogwheel.conduit.MainActivity
import app.cogwheel.conduit.PlatformPushTap
import app.cogwheel.conduit.R

/** Posts decrypted pushes on the app's `conduit_messages` channel. */
internal class PushNotifier(context: Context) {
    private val context = context.applicationContext

    fun post(scope: String, payloadJson: String, content: PushNotificationContent): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            Log.i(TAG, "Notification permission missing; push not shown")
            return false
        }
        ensureChannel(context)

        val publicVersion = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(content.publicTitle)
            .setContentText(content.publicBody)
            .build()
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(content.title)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setAutoCancel(true)
            .setSilent(content.silent)
            .setContentIntent(PushTaps.pendingIntent(context, content.tag, scope, payloadJson))
        if (content.body.isNotEmpty()) {
            builder.setContentText(content.body)
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(content.body))
        }
        content.subtitle?.let(builder::setSubText)
        content.group?.let(builder::setGroup)
        content.timestampMillis?.let { builder.setWhen(it).setShowWhen(true) }

        return try {
            NotificationManagerCompat.from(context).notify(content.tag, NOTIFICATION_ID, builder.build())
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Notification permission revoked; push not shown", error)
            false
        }
    }

    /**
     * Removes this scope's notifications: pushes and the app's own, which
     * flutter_local_notifications tags with their dedup key, so both are
     * tagged `scope|…`. [localNotifications] are the (dedup key, id) pairs
     * the app claimed, cancelled exactly even if listing fails. Nothing is
     * cancelled by id alone: untagged ids such as the voice call's belong to
     * other features.
     */
    fun cancelScope(scope: String, localNotifications: Collection<Pair<String, Int>>) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val prefix = "$scope|"
        try {
            manager.activeNotifications
                .filter { it.tag?.startsWith(prefix) == true }
                .forEach { manager.cancel(it.tag, it.id) }
        } catch (error: RuntimeException) {
            Log.w(TAG, "Could not list active notifications", error)
        }
        localNotifications
            .filter { (tag, _) -> tag.startsWith(prefix) }
            .forEach { (tag, id) -> manager.cancel(tag, id) }
    }

    companion object {
        private const val TAG = "PushNotifier"
        const val CHANNEL_ID = "conduit_messages"

        /** Push notifications differ by tag; the id only has to stay fixed. */
        const val NOTIFICATION_ID = 0x7075

        /**
         * Creates `conduit_messages` with the settings the Dart side gives it
         * (high importance, default sound, vibration, badge) when it does not
         * exist yet, so a push that cold-starts the app can post. The Dart
         * side renames it to the user's language when it next runs.
         */
        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.push_channel_messages_name),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = context.getString(R.string.push_channel_messages_description)
                setSound(
                    Settings.System.DEFAULT_NOTIFICATION_URI,
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build(),
                )
                enableVibration(true)
                enableLights(false)
                setShowBadge(true)
            }
            manager.createNotificationChannel(channel)
        }
    }
}

/**
 * Tap intents for push notifications: `PUSH_TAP` to [MainActivity] with the
 * scope and the `cp/1` plaintext. Each carries a per-install secret, so an
 * intent from another app can't pose as a notification tap.
 */
internal object PushTaps {
    const val ACTION = "app.cogwheel.conduit.PUSH_TAP"
    const val EXTRA_SCOPE = "scope"
    const val EXTRA_PAYLOAD = "payload"
    private const val EXTRA_TOKEN = "app.cogwheel.conduit.PUSH_TAP_TOKEN"

    @Volatile
    private var pendingLaunchTap: PlatformPushTap? = null

    fun pendingIntent(context: Context, tag: String, scope: String, payloadJson: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = ACTION
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_SCOPE, scope)
            putExtra(EXTRA_PAYLOAD, payloadJson)
            putExtra(EXTRA_TOKEN, PushRuntime.config(context).tapToken())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) identifier = tag
        }
        return PendingIntent.getActivity(
            context,
            tag.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun isTap(intent: Intent?): Boolean = intent?.action == ACTION

    /** The tap [intent] describes, if it is a genuine Conduit push tap. */
    fun read(context: Context, intent: Intent?): PlatformPushTap? {
        if (intent == null || !isTap(intent)) return null
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        val token = intent.getStringExtra(EXTRA_TOKEN) ?: return null
        if (token != PushRuntime.config(context).tapToken()) return null
        val scope = intent.getStringExtra(EXTRA_SCOPE)?.takeIf { it.isNotEmpty() } ?: return null
        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: return null
        return PlatformPushTap(scope = scope, payloadJson = payload)
    }

    /** Keeps the tap that launched the app until Dart asks for it. */
    fun stash(tap: PlatformPushTap) = synchronized(this) {
        pendingLaunchTap = tap
    }

    fun takeLaunchTap(): PlatformPushTap? = synchronized(this) {
        pendingLaunchTap.also { pendingLaunchTap = null }
    }
}
