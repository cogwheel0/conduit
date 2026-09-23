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
    const val WEB_LOOKUP = "web_lookup"

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
        WEB_LOOKUP,
    )

    /**
     * Actions that silently change device state without opening any
     * user-visible surface. The bridge requires explicit user approval before
     * executing these, so parsed model output — including untrusted retrieved
     * content replayed in chat history — can never act without a human in the
     * loop. Every other action opens a surface the user can see and back out
     * of, or only reads data.
     */
    val confirmationRequired = setOf(SET_ALARM, SET_TIMER, FLASHLIGHT, SET_VOLUME)

    fun requiresConfirmation(name: String): Boolean = name in confirmationRequired
}

/**
 * Parses a model completion into a device-action tool call, or returns null
 * when the text is a normal answer. Accepted shapes, in order:
 *
 * 1. A whole-reply JSON object (optionally fenced or prose-wrapped).
 * 2. The native Gemma function-call syntax that Gemma-derived models
 *    (including Gemini Nano) emit with control tokens around
 *    `call:name{args}`.
 *
 * Gemma call names are resolved leniently: the captured text before the
 * brace must contain a whitelisted tool name, so schema text that the model
 * parrots verbatim still resolves. The resolved call must name a whitelisted
 * tool, so ordinary prose or code samples can never trigger an action.
 */
object DeviceActionParser {
    data class ToolCall(val name: String, val args: JSONObject)

    private const val MAX_EMBEDDED_JSON_LENGTH = 8_192

    /** Matches the Gemma call syntax with an optional control-token prefix. */
    private val GEMMA_CALL_PATTERN = Regex(
        "(?:<ctrl\\d+>|\\s)*call:([^{}]{1,64}?)\\s*\\{([^}]*)\\}",
        options = setOf(RegexOption.IGNORE_CASE),
    )

    fun parse(text: String?): ToolCall? {
        if (text.isNullOrBlank()) return null
        val json = text.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        parseObject(json)?.let { return it }
        // Small models often wrap the call in prose ("I'll search: {...}").
        // Extract the first balanced JSON object and try that alone.
        extractEmbeddedJson(text)?.let { embedded ->
            parseObject(embedded)?.let { return it }
        }
        return parseGemmaCall(text)
    }

    private fun parseObject(json: String): ToolCall? {
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

    /**
     * Finds the first balanced `{...}` object in [text], respecting string
     * escapes, so a prose-wrapped tool-call can still be recovered.
     */
    fun extractEmbeddedJson(text: String): String? {
        if (text.length > MAX_EMBEDDED_JSON_LENGTH) return null
        val start = text.indexOf('{')
        if (start < 0) return null
        var depth = 0
        var inString = false
        var escaped = false
        for (index in start until text.length) {
            val char = text[index]
            when {
                escaped -> escaped = false
                char == '\\' && inString -> escaped = true
                char == '"' -> inString = !inString
                !inString && char == '{' -> depth++
                !inString && char == '}' -> {
                    depth--
                    if (depth == 0) return text.substring(start, index + 1)
                }
            }
        }
        return null
    }

    /**
     * Parses the native Gemma function-call syntax, e.g. control tokens
     * followed by `call:web_search{query:"..."}`. The captured name may be
     * decorated (schema text the model copied); any whitelisted tool name
     * inside it resolves the call. Args are lenient: unquoted keys, quoted
     * or bare values, comma or semicolon separators.
     */
    fun parseGemmaCall(text: String): ToolCall? {
        val match = GEMMA_CALL_PATTERN.find(text) ?: return null
        val name = resolveToolName(match.groupValues[1]) ?: return null
        val rawArgs = match.groupValues[2].trim()
        val args = if (rawArgs.isEmpty()) JSONObject() else parseLenientArgs(rawArgs)
        return ToolCall(name = name, args = args)
    }

    /** Maps decorated tool-name text onto a whitelisted tool, if any. */
    private fun resolveToolName(captured: String): String? {
        val normalized = captured.lowercase()
        for (name in DeviceActions.names.sortedByDescending { it.length }) {
            if (normalized.contains(name)) return name
        }
        return null
    }

    private fun parseLenientArgs(raw: String): JSONObject {
        val args = JSONObject()
        for (pair in splitTopLevel(raw)) {
            val separator = pair.indexOfFirst { it == ':' || it == '=' }
            if (separator <= 0) continue
            val key = pair.substring(0, separator).trim().removeSurrounding("\"")
            if (key.isEmpty()) continue
            val value = pair.substring(separator + 1).trim()
            when {
                value.equals("true", ignoreCase = true) -> args.put(key, true)
                value.equals("false", ignoreCase = true) -> args.put(key, false)
                value.toIntOrNull() != null -> args.put(key, value.toInt())
                value.toDoubleOrNull() != null -> args.put(key, value.toDouble())
                value.startsWith("\"") -> args.put(key, value.removeSurrounding("\""))
                value.startsWith("'") -> args.put(key, value.removeSurrounding("'"))
                else -> args.put(key, value)
            }
        }
        return args
    }

    /** Splits arg pairs on commas/semicolons outside of quoted values. */
    private fun splitTopLevel(raw: String): List<String> {
        val parts = mutableListOf<String>()
        val current = StringBuilder()
        var activeQuote: Char? = null
        var escaped = false
        for (char in raw) {
            when {
                escaped -> {
                    current.append(char)
                    escaped = false
                }
                activeQuote != null && char == '\\' -> {
                    current.append(char)
                    escaped = true
                }
                char == activeQuote -> {
                    activeQuote = null
                    current.append(char)
                }
                activeQuote == null && (char == '"' || char == '\'') -> {
                    activeQuote = char
                    current.append(char)
                }
                activeQuote == null && (char == ',' || char == ';') -> {
                    if (current.isNotBlank()) parts.add(current.toString().trim())
                    current.clear()
                }
                else -> current.append(char)
            }
        }
        if (current.isNotBlank()) parts.add(current.toString().trim())
        return parts
    }
}