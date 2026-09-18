package app.cogwheel.conduit

import org.json.JSONObject

/**
 * The whitelisted on-device actions the bridge will execute for a model
 * tool-call. Kept deliberately small and fully user-visible: every action
 * either performs a benign device action (alarm, timer, torch, volume) or
 * opens a system surface the user can back out of.
 */
object DeviceActions {
    const val SET_ALARM = "set_alarm"
    const val SET_TIMER = "set_timer"
    const val FLASHLIGHT = "flashlight"
    const val SET_VOLUME = "set_volume"
    const val OPEN_SETTINGS = "open_settings"
    const val DIAL = "dial"
    const val CALENDAR_EVENT = "calendar_event"
    const val PLAY_MEDIA = "play_media"
    const val WEB_SEARCH = "web_search"
    const val OPEN_APP = "open_app"
    const val COMPOSE_SMS = "compose_sms"
    const val SHARE_TEXT = "share_text"
    const val GET_WEATHER = "get_weather"

    val names = setOf(
        SET_ALARM,
        SET_TIMER,
        FLASHLIGHT,
        SET_VOLUME,
        OPEN_SETTINGS,
        DIAL,
        CALENDAR_EVENT,
        PLAY_MEDIA,
        WEB_SEARCH,
        OPEN_APP,
        COMPOSE_SMS,
        SHARE_TEXT,
        GET_WEATHER,
    )
}

/**
 * Parses a model completion into a device-action tool call, or returns null
 * when the text is a normal answer. Deliberately strict: the whole reply
 * must be a single JSON object whose "tool" is on the whitelist, so prose or
 * code samples can never trigger an action.
 */
object DeviceActionParser {
    data class ToolCall(val name: String, val args: JSONObject)

    fun parse(text: String?): ToolCall? {
        if (text.isNullOrBlank()) return null
        val json = text.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        if (!json.startsWith("{")) return null
        val root = try {
            JSONObject(json)
        } catch (_: Exception) {
            return null
        }
        val tool = root.optString("tool").takeIf { it.isNotEmpty() } ?: return null
        if (tool !in DeviceActions.names) return null
        val args = root.optJSONObject("args") ?: JSONObject()
        return ToolCall(name = tool, args = args)
    }
}