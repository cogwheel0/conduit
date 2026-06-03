package app.cogwheel.conduit

import android.app.ActivityOptions
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.RemoteViews

/**
 * Home screen widget provider for Conduit.
 * 
 * Provides quick actions:
 * - New Chat: Start a fresh conversation
 * - Mic: Start voice input
 * - Camera: Take a photo and attach to chat
 * - Photos: Pick from gallery and attach to chat
 * - Clipboard: Paste clipboard content as prompt
 */
class ConduitWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onEnabled(context: Context) {
        // Called when the first widget is created
    }

    override fun onDisabled(context: Context) {
        // Called when the last widget is removed
    }

    companion object {
        private const val ACTION_NEW_CHAT = "new_chat"
        private const val ACTION_MIC = "mic"
        private const val ACTION_CAMERA = "camera"
        private const val ACTION_PHOTOS = "photos"
        private const val ACTION_CLIPBOARD = "clipboard"
        private const val HOME_WIDGET_LAUNCH_ACTION = "es.antonborri.home_widget.action.LAUNCH"

        private fun updateAppWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val views = RemoteViews(context.packageName, R.layout.conduit_widget)

            // Set up click handlers using home_widget's launch intent
            // The homeWidget=true query param is required for the home_widget package to
            // recognize these URLs and forward them to the Flutter widgetClicked stream
            views.setOnClickPendingIntent(
                R.id.widget_container,
                homeWidgetLaunchIntent(
                    context,
                    Uri.parse("conduit://$ACTION_NEW_CHAT?homeWidget=true")
                )
            )
            views.setOnClickPendingIntent(
                R.id.btn_new_chat,
                homeWidgetLaunchIntent(
                    context,
                    Uri.parse("conduit://$ACTION_NEW_CHAT?homeWidget=true")
                )
            )
            views.setOnClickPendingIntent(
                R.id.btn_mic,
                homeWidgetLaunchIntent(
                    context,
                    Uri.parse("conduit://$ACTION_MIC?homeWidget=true")
                )
            )
            views.setOnClickPendingIntent(
                R.id.btn_camera,
                homeWidgetLaunchIntent(
                    context,
                    Uri.parse("conduit://$ACTION_CAMERA?homeWidget=true")
                )
            )
            views.setOnClickPendingIntent(
                R.id.btn_photos,
                homeWidgetLaunchIntent(
                    context,
                    Uri.parse("conduit://$ACTION_PHOTOS?homeWidget=true")
                )
            )
            views.setOnClickPendingIntent(
                R.id.btn_clipboard,
                homeWidgetLaunchIntent(
                    context,
                    Uri.parse("conduit://$ACTION_CLIPBOARD?homeWidget=true")
                )
            )

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }

        @Suppress("DEPRECATION")
        private fun homeWidgetLaunchIntent(context: Context, uri: Uri): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                data = uri
                action = HOME_WIDGET_LAUNCH_ACTION
            }

            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }

            if (Build.VERSION.SDK_INT < 34) {
                return PendingIntent.getActivity(context, uri.hashCode(), intent, flags)
            }

            val options = ActivityOptions.makeBasic()
            if (Build.VERSION.SDK_INT >= 35) {
                options.setPendingIntentCreatorBackgroundActivityStartMode(
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                )
            } else {
                options.pendingIntentBackgroundActivityStartMode =
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
            }

            return PendingIntent.getActivity(
                context,
                uri.hashCode(),
                intent,
                flags,
                options.toBundle()
            )
        }
    }
}
