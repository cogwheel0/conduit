package app.cogwheel.qonduit

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

class QonduitApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        createChannelIfNeeded(
            notificationManager,
            channelId = BackgroundStreamingService.CHANNEL_ID,
            channelName = "Background Service",
            description = "Background service for Qonduit",
            importance = NotificationManager.IMPORTANCE_MIN,
        )

        createChannelIfNeeded(
            notificationManager,
            channelId = "voice_call_channel",
            channelName = "Voice Call",
            description = "Ongoing voice call notifications",
            importance = NotificationManager.IMPORTANCE_HIGH,
        )

        createChannelIfNeeded(
            notificationManager,
            channelId = "qonduit_router_ready_channel",
            channelName = "Qonduit Router Ready",
            description = "Notifies when llama.cpp is ready",
            importance = NotificationManager.IMPORTANCE_HIGH,
        )

        createChannelIfNeeded(
            notificationManager,
            channelId = "qonduit_test_channel",
            channelName = "Qonduit Test",
            description = "Test notifications",
            importance = NotificationManager.IMPORTANCE_HIGH,
        )
    }

    private fun createChannelIfNeeded(
        manager: NotificationManager,
        channelId: String,
        channelName: String,
        description: String,
        importance: Int,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(channelId) != null) return

        val channel = NotificationChannel(channelId, channelName, importance).apply {
            this.description = description
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_SECRET
        }

        manager.createNotificationChannel(channel)
    }
}