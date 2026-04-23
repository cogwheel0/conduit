package app.cogwheel.conduit

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

/**
 * Custom Application class to perform early initialization tasks.
 *
 * Most importantly, this creates notification channels at app startup
 * to avoid ForegroundServiceDidNotStartInTimeException. Android requires
 * foreground services to call startForeground() within 5-10 seconds,
 * and having the notification channel ready beforehand prevents delays.
 */
class ConduitApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        // Create notification channels immediately at app startup
        // This ensures channels exist before any service tries to use them
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Background streaming service channel
        createChannelIfNeeded(
            notificationManager,
            channelId = BackgroundStreamingService.CHANNEL_ID,
            channelName = "Background Service",
            description = "Background service for Conduit",
            importance = NotificationManager.IMPORTANCE_LOW,
            recreateIfImportanceChanged = true,
        )

        // Voice call notification channel (used by VoiceCallNotificationService)
        createChannelIfNeeded(
            notificationManager,
            channelId = "voice_call_channel",
            channelName = "Voice Call",
            description = "Ongoing voice call notifications",
            importance = NotificationManager.IMPORTANCE_HIGH,
        )
    }

    private fun createChannelIfNeeded(
        manager: NotificationManager,
        channelId: String,
        channelName: String,
        description: String,
        importance: Int,
        recreateIfImportanceChanged: Boolean = false,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val existingChannel = manager.getNotificationChannel(channelId)
        if (existingChannel != null) {
            if (existingChannel.importance == importance) {
                return
            }
            if (!recreateIfImportanceChanged) {
                return
            }

            val canSafelyRecreate =
                existingChannel.importance == NotificationManager.IMPORTANCE_MIN &&
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    !existingChannel.hasUserSetImportance()
            if (!canSafelyRecreate) {
                return
            }

            manager.deleteNotificationChannel(channelId)
        }

        val channel = NotificationChannel(channelId, channelName, importance).apply {
            this.description = description
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_SECRET
        }

        manager.createNotificationChannel(channel)
    }
}
