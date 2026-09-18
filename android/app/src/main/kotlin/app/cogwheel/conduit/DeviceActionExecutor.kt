package app.cogwheel.conduit

import android.Manifest
import android.app.SearchManager
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.Settings
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale

/**
 * Executes whitelisted, fully user-visible device actions behind the model
 * tool-call loop. Every action either completes a benign device change or
 * opens a system surface, so no confirmation gate is needed at this tier.
 * The narration returned here is fed back to the model as the tool result.
 */
class DeviceActionExecutor(private val context: Context) {
    private var torchOn: Boolean = false

    fun execute(name: String, args: JSONObject): String = try {
        when (name) {
            DeviceActions.SET_ALARM -> setAlarm(args)
            DeviceActions.SET_TIMER -> setTimer(args)
            DeviceActions.FLASHLIGHT -> setFlashlight(args)
            DeviceActions.SET_VOLUME -> setVolume(args)
            DeviceActions.OPEN_SETTINGS -> openSettings(args)
            DeviceActions.DIAL -> dial(args)
            DeviceActions.CALENDAR_EVENT -> calendarEvent(args)
            DeviceActions.PLAY_MEDIA -> playMedia(args)
            DeviceActions.WEB_SEARCH -> webSearch(args)
            DeviceActions.OPEN_APP -> openApp(args)
            DeviceActions.COMPOSE_SMS -> composeSms(args)
            DeviceActions.SHARE_TEXT -> shareText(args)
            else -> throw IllegalArgumentException("Unknown tool '$name'.")
        }
    } catch (error: Exception) {
        "The '$name' action failed: ${error.message ?: error.javaClass.simpleName}"
    }

    private fun setAlarm(args: JSONObject): String {
        val hour = args.getInt("hour")
        val minute = args.getInt("minute")
        require(hour in 0..23 && minute in 0..59) {
            "Hour must be 0-23 and minute 0-59."
        }
        val intent = Intent(AlarmClock.ACTION_SET_ALARM)
            .putExtra(AlarmClock.EXTRA_HOUR, hour)
            .putExtra(AlarmClock.EXTRA_MINUTES, minute)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        args.optString("label").takeIf { it.isNotBlank() }?.let {
            intent.putExtra(AlarmClock.EXTRA_MESSAGE, it)
        }
        context.startActivity(intent)
        return String.format(
            Locale.US,
            "Alarm scheduled for %02d:%02d.",
            hour,
            minute,
        )
    }

    private fun setTimer(args: JSONObject): String {
        val seconds = args.getInt("seconds")
        if (seconds <= 0 || seconds > 86_400) {
            throw IllegalArgumentException("Timer length must be 1-86400 seconds.")
        }
        val intent = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        args.optString("label").takeIf { it.isNotBlank() }?.let {
            intent.putExtra(AlarmClock.EXTRA_MESSAGE, it)
        }
        context.startActivity(intent)
        val minutes = seconds / 60
        return if (seconds % 60 == 0) {
            "Timer set for $minutes minutes."
        } else {
            "Timer set for $minutes min ${seconds % 60} s."
        }
    }

    private fun setFlashlight(args: JSONObject): String {
        val on = args.optBoolean("on", !torchOn)
        val cameraManager =
            context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = cameraManager.cameraIdList.firstOrNull()
            ?: throw IllegalStateException("No camera (flashlight) found on this device.")
        cameraManager.setTorchMode(cameraId, on)
        torchOn = on
        return if (on) "Flashlight on." else "Flashlight off."
    }

    private fun setVolume(args: JSONObject): String {
        val percent = args.getInt("volumePercent")
        if (percent !in 0..100) {
            throw IllegalArgumentException("Volume percent must be 0-100.")
        }
        val stream = when (args.optString("stream", "media")) {
            "ring" -> AudioManager.STREAM_RING
            "alarm" -> AudioManager.STREAM_ALARM
            "notification" -> AudioManager.STREAM_NOTIFICATION
            else -> AudioManager.STREAM_MUSIC
        }
        val audioManager =
            context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val maximum = audioManager.getStreamMaxVolume(stream)
        audioManager.setStreamVolume(stream, volumeIndexFor(maximum, percent), 0)
        return "Volume set to $percent%."
    }

    private fun openSettings(args: JSONObject): String {
        val screen = args.optString("screen", "home")
        val action = when (screen) {
            "wifi" -> Settings.ACTION_WIFI_SETTINGS
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            "sound" -> Settings.ACTION_SOUND_SETTINGS
            "display" -> Settings.ACTION_DISPLAY_SETTINGS
            "airplane" -> Settings.ACTION_AIRPLANE_MODE_SETTINGS
            "battery" -> Settings.ACTION_BATTERY_SAVER_SETTINGS
            "date" -> Settings.ACTION_DATE_SETTINGS
            "security" -> Settings.ACTION_SECURITY_SETTINGS
            "storage" -> Settings.ACTION_INTERNAL_STORAGE_SETTINGS
            "apps" -> Settings.ACTION_APPLICATION_SETTINGS
            "hotspot" -> "android.settings.TETHER_SETTINGS"
            "notifications" -> "android.settings.NOTIFICATION_SETTINGS"
            "home" -> Settings.ACTION_HOME_SETTINGS
            "vpn" -> Settings.ACTION_VPN_SETTINGS
            else -> Settings.ACTION_SETTINGS
        }
        context.startActivity(
            Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        return "Opened ${screen.replaceFirstChar { it.uppercase() }} settings."
    }

    private fun dial(args: JSONObject): String {
        val number = args.optString("number").takeIf { it.isNotBlank() }
        val intent = if (number != null) {
            Intent(Intent.ACTION_DIAL, Uri.parse("tel:$number"))
        } else {
            Intent(Intent.ACTION_DIAL)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return if (number != null) "Opened the dialer with $number." else "Opened the dialer."
    }

    private fun calendarEvent(args: JSONObject): String {
        val title = args.optString("title").takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("A calendar event needs a title.")
        val beginTime = Calendar.getInstance().apply {
            parseDateAndTime(args)
        }
        val durationMinutes = args.optInt("durationMinutes", 30)
            .takeIf { it in 1..24 * 60 } ?: 30
        val beginMillis = beginTime.timeInMillis
        val intent = Intent(Intent.ACTION_INSERT)
            .setData(CalendarContract.Events.CONTENT_URI)
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, beginMillis)
            .putExtra(
                CalendarContract.EXTRA_EVENT_END_TIME,
                beginMillis + durationMinutes * 60_000L,
            )
            .putExtra(CalendarContract.Events.TITLE, title)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        args.optString("description").takeIf { it.isNotBlank() }?.let {
            intent.putExtra(CalendarContract.Events.DESCRIPTION, it)
        }
        context.startActivity(intent)
        return "Drafted a calendar event '$title'."
    }

    private fun playMedia(args: JSONObject): String {
        val query = args.optString("query").takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("A media query is required.")
        context.startActivity(
            Intent(android.provider.MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
                .putExtra(SearchManager.QUERY, query)
                .putExtra("android.intent.extra.MEDIA_FOCUS", "vnd.android.cursor.item/*")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "Asked your music app to play '$query'."
    }

    private fun webSearch(args: JSONObject): String {
        val query = args.optString("query").takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("A search query is required.")
        context.startActivity(
            Intent(Intent.ACTION_WEB_SEARCH)
                .putExtra("query", query)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "Searched the web for '$query'."
    }

    private fun openApp(args: JSONObject): String {
        val name = args.optString("appName").takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("An app name is required.")
        val matches = context.packageManager.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER),
            0,
        )
        val target = matches.firstOrNull {
            it.loadLabel(context.packageManager).toString()
                .equals(name, ignoreCase = true)
        } ?: matches.firstOrNull {
            it.loadLabel(context.packageManager).toString()
                .startsWith(name, ignoreCase = true)
        } ?: throw IllegalArgumentException("No installed app named '$name'.")
        context.startActivity(
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setClassName(target.activityInfo.packageName, target.activityInfo.name)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "Opened ${target.loadLabel(context.packageManager)}."
    }

    private fun composeSms(args: JSONObject): String {
        val to = args.optString("to").takeIf { it.isNotBlank() }
        val body = args.optString("body").takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("A message body is required.")
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + (to ?: "")))
            .putExtra("sms_body", body)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return "Opened a drafted message${to?.let { " to $it" } ?: ""}."
    }

    private fun shareText(args: JSONObject): String {
        val text = args.optString("text").takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("Text to share is required.")
        context.startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_SEND)
                    .setType("text/plain")
                    .putExtra(Intent.EXTRA_TEXT, text),
                null,
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "Opened the share sheet."
    }

    /** Mutates [calendar] from `date` (yyyy-MM-dd) and optional `time` (HH:mm). */
    private fun Calendar.parseDateAndTime(args: JSONObject) {
        val date = args.optString("date").takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("A date (yyyy-MM-dd) is required.")
        val dateParts = date.split("-").map { it.trim() }
        require(dateParts.size == 3) { "Date must be yyyy-MM-dd." }
        val time = args.optString("time").takeIf { it.isNotBlank() } ?: "09:00"
        val timeParts = time.split(":").map { it.trim() }
        if (timeParts.size != 2) throw IllegalArgumentException("Time must be HH:mm.")
        set(
            dateParts[0].toInt(),
            dateParts[1].toInt() - 1,
            dateParts[2].toInt(),
            timeParts[0].toInt(),
            timeParts[1].toInt(),
            0,
        )
    }

    companion object {
        const val SET_ALARM_PERMISSION = Manifest.permission.SET_ALARM

        fun volumeIndexFor(maximum: Int, percent: Int): Int =
            (maximum * percent + 50) / 100
    }
}