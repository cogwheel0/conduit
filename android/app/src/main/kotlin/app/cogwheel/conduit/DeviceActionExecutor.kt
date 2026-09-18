package app.cogwheel.conduit

import android.Manifest
import android.app.SearchManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.location.LocationManager
import android.media.AudioManager
import android.net.Uri
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.Settings
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Calendar
import java.util.Locale

/**
 * Executes whitelisted, fully user-visible device actions behind the model
 * tool-call loop. Every action either completes a benign device change,
 * opens a system surface, or reads public data (weather). The narration
 * returned here is fed back to the model as the tool result.
 */
class DeviceActionExecutor(private val context: Context) {
    private var torchOn: Boolean = false

    /** Ollama web-search API key, pushed from Dart when a cloud profile has one. */
    @Volatile
    var webSearchApiKey: String? = null

    /** Forecast summaries by resolved place, valid for a few minutes. */
    private val weatherCache = mutableMapOf<String, Pair<Long, String>>()

    suspend fun execute(name: String, args: JSONObject): String = try {
        withContext(kotlinx.coroutines.Dispatchers.IO) {
            when (name) {
                DeviceActions.SET_ALARM -> setAlarm(args)
                DeviceActions.SET_TIMER -> setTimer(args)
                DeviceActions.FLASHLIGHT -> setFlashlight(args)
                DeviceActions.SET_VOLUME -> setVolume(args)
                DeviceActions.OPEN_SETTINGS -> openSettings(args)
                DeviceActions.DIAL -> dial(args)
                DeviceActions.CALENDAR_EVENT -> calendarEvent(args)
                DeviceActions.PLAY_MEDIA -> playMedia(args)
                DeviceActions.WEB_SEARCH -> webLookup(args, webSearchApiKey)
                DeviceActions.OPEN_APP -> openApp(args)
                DeviceActions.COMPOSE_SMS -> composeSms(args)
                DeviceActions.SHARE_TEXT -> shareText(args)
                DeviceActions.GET_WEATHER -> getWeather(args)
                DeviceActions.WEB_LOOKUP -> webLookup(args, webSearchApiKey)
                else -> throw IllegalArgumentException("Unknown tool '$name'.")
            }
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

    /**
     * Reads public weather data (Open-Meteo, keyless) and returns a compact
     * narration the model can answer from. A named area is geocoded; without
     * one, the device's last known location is used when location permission
     * has been granted. A missing location is a soft outcome the model can
     * explain, not a failure.
     */
    private fun getWeather(args: JSONObject): String {
        val place = args.optString("location").takeIf { it.isNotBlank() }
        val requestedDays = (args.optInt("days", 1)).coerceIn(1, 3)
        if (place == null && !hasLocationPermission()) {
            return "I could not read the device location because location permission " +
                "is not granted for Conduit. Ask the user to name a city instead."
        }
        val resolved = place?.let { geocode(it) } ?: deviceLocation()
            ?: return "I could not find a place for this weather request. " +
                "Ask the user to name a city."
        val label = resolved.second ?: place ?: "your area"
        val (latitude, longitude) = resolved.first
        val cacheKey = "%.3f,%.3f:%d".format(Locale.US, latitude, longitude, requestedDays)
        weatherCache[cacheKey]?.let { (at, text) ->
            if (System.currentTimeMillis() - at < WEATHER_CACHE_MILLIS) return text
        }
        val days = requestedDays
        val query = "latitude=$latitude&longitude=$longitude" +
            "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m" +
            "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max" +
            "&timezone=auto&forecast_days=$days"
        val body = fetchJson("$WEATHER_BASE/v1/forecast?$query")
        val current = body.optJSONObject("current")
        val daily = body.optJSONObject("daily")
        if (current == null || daily == null) {
            throw IllegalStateException("Weather service returned no data.")
        }
        val timezone = body.optString("timezone", "")
        val parts = mutableListOf<String>()
        parts.add(
            "$label — now ${round1(current.optDouble("temperature_2m", Double.NaN))}°C" +
                ", feels ${round1(current.optDouble("apparent_temperature", Double.NaN))}°C" +
                ", ${weatherDescription(current.optInt("weather_code", -1))}" +
                ", wind ${round1(current.optDouble("wind_speed_10m", Double.NaN))} km/h" +
                (if (timezone.isNotEmpty()) " (timezone $timezone)" else ""),
        )
        val maxima = daily.optJSONArray("temperature_2m_max")
        val minima = daily.optJSONArray("temperature_2m_min")
        val rain = daily.optJSONArray("precipitation_probability_max")
        val days_ = daily.optJSONArray("time") ?: org.json.JSONArray()
        for (index in 0 until days_.length().coerceAtMost(3)) {
            if (index >= (maxima?.length() ?: 0)) break
            val day = days_.optString(index)
            val text = buildString {
                append("Day $day: high ")
                append(round1(maxima?.optDouble(index, Double.NaN) ?: Double.NaN))
                append("°C, low ")
                append(round1(minima?.optDouble(index, Double.NaN) ?: Double.NaN))
                append("°C")
                rain?.optInt(index, -1)?.takeIf { it >= 0 }?.let {
                    append(", rain chance $it%")
                }
            }
            parts.add(text)
        }
        val narration = parts.joinToString(". ")
        weatherCache[cacheKey] = System.currentTimeMillis() to narration
        return narration
    }

    /** Geocodes a place name; returns (lat,lon) to display label, or null. */
    private fun geocode(place: String): Pair<Pair<Double, Double>, String>? {
        val body = fetchJson(
            "$GEOCODING_BASE/api/v1/search?name=" +
                URLEncoder.encode(place, "UTF-8") + "&count=1&language=en&format=json"
        )
        val first = body.optJSONArray("results")?.optJSONObject(0)
            ?: return null
        return Pair(
            Pair(first.optDouble("latitude", Double.NaN), first.optDouble("longitude", Double.NaN)),
            first.optString("name", place),
        )
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

    private fun deviceLocation(): Pair<Pair<Double, Double>, String?>? {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val last = listOfNotNull(
            LocationManager.PASSIVE_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER,
        ).mapNotNull { provider ->
            try {
                manager.getLastKnownLocation(provider)
            } catch (_: SecurityException) {
                null
            }
        }.maxByOrNull { it.time } ?: return null
        return Pair(Pair(last.latitude, last.longitude), null as String?)
    }

    private fun fetchJson(url: String): JSONObject {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        connection.setRequestProperty("User-Agent", HTTP_USER_AGENT)
        try {
            connection.inputStream.bufferedReader().use { reader: BufferedReader ->
                return JSONObject(reader.readText())
            }
        } finally {
            connection.disconnect()
        }
    }

    /**
     * Fetches live web results and returns them as a compact list the model
     * can answer from in this chat. Uses the Ollama web-search API when an
     * Ollama Cloud API key has been supplied, falling back to keyless Bing
     * RSS (whose terms cover rendering results for personal, non-commercial
     * use).
     */
    private fun webLookup(args: JSONObject, ollamaApiKey: String?): String {
        val query = args.optString("query").takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("A search query is required.")
        val maxResults = args.optInt("maxResults", 5).coerceIn(1, 5)
        if (!ollamaApiKey.isNullOrBlank()) {
            try {
                android.util.Log.i(
                    TAG,
                    "web_lookup via ollama (query=${query.take(40)})",
                )
                val payload = postJson(
                    url = "$OLLAMA_BASE/api/web_search",
                    body = JSONObject()
                        .put("query", query)
                        .put("max_results", maxResults),
                    bearerToken = ollamaApiKey,
                )
                val results = formatOllamaSearchResults(payload, maxResults)
                if (results.isNotEmpty()) return results
                android.util.Log.i(TAG, "ollama search returned no results; falling back")
            } catch (error: Exception) {
                android.util.Log.w(
                    TAG,
                    "ollama search failed (${error.message ?: error.javaClass.simpleName}); falling back",
                )
                // Ollama search failed (network, quota, auth) — fall through
                // to the keyless source rather than failing the turn.
            }
        } else {
            android.util.Log.i(TAG, "web_lookup via bing (no ollama key)")
        }
        val url = "$BING_BASE/search?" +
            "q=${URLEncoder.encode(query, "UTF-8")}&format=rss&count=$maxResults"
        val xml = fetchText(url)
        val results = parseBingRss(xml)
        if (results.isEmpty()) return "No web results found for '$query'."
        return results.mapIndexed { index, result ->
            "${index + 1}. ${result.first} — ${result.second} (${result.third})"
        }.joinToString("\n")
    }

    private fun postJson(url: String, body: JSONObject, bearerToken: String): JSONObject {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.setRequestProperty("User-Agent", HTTP_USER_AGENT)
        connection.setRequestProperty(
            "Authorization",
            "Bearer ${bearerToken.trim()}",
        )
        try {
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = connection.responseCode
            if (code !in 200..299) {
                val errorBody = try {
                    connection.errorStream?.bufferedReader()?.use { it.readText() }
                } catch (_: Exception) {
                    null
                }?.take(200)
                throw IllegalStateException(
                    "HTTP $code" + (errorBody?.takeIf { it.isNotBlank() }?.let { ": $it" } ?: ""),
                )
            }
            return JSONObject(
                connection.inputStream.bufferedReader().use { it.readText() },
            )
        } finally {
            connection.disconnect()
        }
    }

    /** Renders Ollama search results as indexed narration lines. */
    fun formatOllamaSearchResults(body: JSONObject, maxResults: Int): String {
        val results = body.optJSONArray("results") ?: return ""
        val lines = mutableListOf<String>()
        for (index in 0 until results.length().coerceAtMost(maxResults)) {
            val result = results.optJSONObject(index) ?: continue
            val title = result.optString("title").takeIf { it.isNotBlank() }
                ?: result.optString("url")
            val content = truncateSnippet(
                result.optString("content"),
                SNIPPET_CHAR_LIMIT,
            ).takeIf { it.isNotBlank() }
            if (content == null && title.isBlank()) continue
            lines.add(
                "${lines.size + 1}. $title" +
                    (content?.let { " — $it" } ?: "") +
                    " (${result.optString("url")})",
            )
        }
        return lines.joinToString("\n")
    }

    private fun fetchText(url: String): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        connection.setRequestProperty("User-Agent", HTTP_USER_AGENT)
        connection.setRequestProperty("Accept", "application/rss+xml, text/xml")
        try {
            return connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
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
            // Lenient calendars silently normalize impossible dates
            // (2026-02-31 becomes March); reject them instead.
            isLenient = false
        }
        // Force field resolution so an invalid date throws before the
        // calendar intent is built.
        beginTime.timeInMillis
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
        private const val TAG = "DeviceActionExecutor"
        const val SET_ALARM_PERMISSION = Manifest.permission.SET_ALARM

        private const val WEATHER_BASE = "https://api.open-meteo.com"
        private const val GEOCODING_BASE = "https://geocoding-api.open-meteo.com"
        private const val BING_BASE = "https://www.bing.com"
        private const val OLLAMA_BASE = "https://ollama.com"
        private const val WEATHER_CACHE_MILLIS = 10L * 60L * 1000L

        /**
         * A plain app user agent. Android's default ("Dalvik/...") is blocked
         * by some web application firewalls (observed on ollama.com with a
         * bare HTML 403), so every request we make announces itself.
         */
        private const val HTTP_USER_AGENT = "conduit-android/4.1.6"

        /**
         * Per-result cap on web-result page content. Ollama's web_search
         * returns near-full article text; Gemini Nano's context window is
         * small (8K tokens), so unbounded content overflows the follow-up
         * prompt ("Input text length exceeds the limit").
         */
        const val SNIPPET_CHAR_LIMIT = 400

        /** Cuts [text] to [maxChars] at a word boundary, with an ellipsis. */
        fun truncateSnippet(text: String, maxChars: Int): String {
            if (text.length <= maxChars) return text
            val cut = text.take(maxChars)
            val lastSpace = cut.lastIndexOf(' ')
            val trimmed = if (lastSpace > maxChars / 2) cut.take(lastSpace) else cut
            return "$trimmed…"
        }

        /**
         * Parses a Bing RSS search feed into (title, description, url) triples.
         * Kept here (unit-testable) and tolerant: Bing's feed shape has been
         * stable for years, and a parse miss degrades to "no results".
         */
        fun parseBingRss(xml: String): List<Triple<String, String, String>> {
            val results = mutableListOf<Triple<String, String, String>>()
            val items = xml.split("<item>").drop(1)
            for (item in items.take(5)) {
                val title = extractTag(item, "title") ?: continue
                val link = extractTag(item, "link") ?: ""
                val description = extractTag(item, "description") ?: ""
                results.add(
                    Triple(
                        unescapeXml(title),
                        unescapeXml(description),
                        unescapeXml(link),
                    )
                )
            }
            return results
        }

        private fun extractTag(source: String, tag: String): String? {
            val start = source.indexOf("<$tag")
            if (start < 0) return null
            val openEnd = source.indexOf('>', start)
            if (openEnd < 0) return null
            val close = source.indexOf("</$tag>", openEnd)
            if (close < 0) return null
            return source.substring(openEnd + 1, close).trim()
        }

        private fun unescapeXml(value: String): String = value
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'")
            .replace(Regex("<[^>]{1,120}>"), "")
            .trim()

        /** Rounds to one decimal, collapsing NaN into a dash. */
        fun round1(value: Double): String =
            if (value.isNaN()) "-" else String.format(Locale.US, "%.1f", value)

        /** WMO 4677 weather-code to short description. */
        fun weatherDescription(code: Int): String = when (code) {
            0 -> "clear sky"
            1 -> "mainly clear"
            2 -> "partly cloudy"
            3 -> "overcast"
            45, 48 -> "fog"
            51, 53, 55 -> "light drizzle"
            56, 57 -> "freezing drizzle"
            61 -> "light rain"
            63 -> "rain"
            65 -> "heavy rain"
            66, 67 -> "freezing rain"
            71 -> "light snow"
            73 -> "snow"
            75 -> "heavy snow"
            77 -> "snow grains"
            80, 81, 82 -> "rain showers"
            85, 86 -> "snow showers"
            95 -> "thunderstorm"
            96, 99 -> "thunderstorm with hail"
            else -> "unknown conditions"
        }

        fun volumeIndexFor(maximum: Int, percent: Int): Int =
            (maximum * percent + 50) / 100
    }
}