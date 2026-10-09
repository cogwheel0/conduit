package app.cogwheel.conduit.push

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * The app's notification settings, mirrored from Dart (`PlatformPushConfig`)
 * so a push can be shown or dropped while the Flutter engine isn't running.
 */
data class PushDisplayConfig(
    val enabled: Boolean,
    val sound: Boolean,
    val enabledKinds: Set<String>,
    val disabledScopes: Set<String>,
    val scopeLabels: Map<String, String>,
    val showScopeLabel: Boolean,
    val strings: Map<String, String>,
) {
    /** A localized string from Dart, or the English default. */
    fun string(key: String): String =
        strings[key]?.takeIf { it.isNotBlank() } ?: DEFAULT_STRINGS[key].orEmpty()

    fun toJson(): String = JSONObject()
        .put("enabled", enabled)
        .put("sound", sound)
        .put("enabledKinds", JSONArray(enabledKinds.toList()))
        .put("disabledScopes", JSONArray(disabledScopes.toList()))
        .put("scopeLabels", JSONObject(scopeLabels))
        .put("showScopeLabel", showScopeLabel)
        .put("strings", JSONObject(strings))
        .toString()

    companion object {
        const val FALLBACK_TITLE = "fallbackTitle"
        const val FALLBACK_BODY = "fallbackBody"
        const val REPLY_TITLE = "replyTitle"
        const val REPLY_FAILED_TITLE = "replyFailedTitle"
        const val REPLY_FAILED_BODY = "replyFailedBody"
        const val CHANNEL_TITLE = "channelTitle"
        const val CRON_TITLE = "cronTitle"
        const val TEST_TITLE = "testTitle"
        const val TEST_BODY = "testBody"

        val DEFAULT_STRINGS = mapOf(
            FALLBACK_TITLE to "Conduit",
            FALLBACK_BODY to "New notification",
            REPLY_TITLE to "New reply",
            REPLY_FAILED_TITLE to "Reply failed",
            REPLY_FAILED_BODY to "The response could not be completed.",
            CHANNEL_TITLE to "New channel message",
            CRON_TITLE to "Scheduled task finished",
            TEST_TITLE to "Push notifications work",
            TEST_BODY to "This test notification was end-to-end encrypted.",
        )

        /**
         * Used until Dart sends a config. A subscription only exists after
         * the user turned push on, so show everything in English.
         */
        val DEFAULT = PushDisplayConfig(
            enabled = true,
            sound = true,
            enabledKinds = PushPayload.KINDS,
            disabledScopes = emptySet(),
            scopeLabels = emptyMap(),
            showScopeLabel = false,
            strings = emptyMap(),
        )

        fun fromJson(json: String): PushDisplayConfig? = try {
            val root = JSONObject(json)
            PushDisplayConfig(
                enabled = root.getBoolean("enabled"),
                sound = root.optBoolean("sound", true),
                enabledKinds = root.optJSONArray("enabledKinds").strings().toSet(),
                disabledScopes = root.optJSONArray("disabledScopes").strings().toSet(),
                scopeLabels = root.optJSONObject("scopeLabels").stringMap(),
                showScopeLabel = root.optBoolean("showScopeLabel", false),
                strings = root.optJSONObject("strings").stringMap(),
            )
        } catch (_: JSONException) {
            null
        }

        private fun JSONArray?.strings(): List<String> {
            if (this == null) return emptyList()
            return (0 until length()).mapNotNull { opt(it) as? String }
        }

        private fun JSONObject?.stringMap(): Map<String, String> {
            if (this == null) return emptyMap()
            val result = linkedMapOf<String, String>()
            keys().forEach { key -> (opt(key) as? String)?.let { result[key] = it } }
            return result
        }
    }
}

/**
 * Small push settings kept in preferences: the mirrored [PushDisplayConfig],
 * test nonces the receiver verified (per sid, until Dart takes them), the
 * FCM opt-in flag and the secret that marks Conduit's own tap intents.
 */
class PushConfigStore(private val store: KeyValueStore) {
    private var cached: PushDisplayConfig? = null

    @Synchronized
    fun config(): PushDisplayConfig {
        cached?.let { return it }
        val config = store.getString(KEY_CONFIG)?.let(PushDisplayConfig::fromJson)
            ?: PushDisplayConfig.DEFAULT
        cached = config
        return config
    }

    @Synchronized
    fun save(config: PushDisplayConfig) {
        store.putString(KEY_CONFIG, config.toJson())
        cached = config
    }

    @Synchronized
    fun recordNonce(sid: String, nonce: String) {
        val all = nonces()
        val list = all.optJSONArray(sid) ?: JSONArray()
        val values = (0 until list.length()).map { list.getString(it) }.filter { it != nonce }
        all.put(sid, JSONArray((values + nonce).takeLast(MAX_NONCES_PER_SID)))
        store.putString(KEY_NONCES, all.toString())
    }

    /** The nonces verified for [sid] since the last call, oldest first. */
    @Synchronized
    fun takeNonces(sid: String): List<String> {
        val all = nonces()
        val list = all.optJSONArray(sid) ?: return emptyList()
        all.remove(sid)
        store.putString(KEY_NONCES, all.toString())
        return (0 until list.length()).map { list.getString(it) }
    }

    @Synchronized
    fun clearNonces(sid: String) {
        val all = nonces()
        if (all.remove(sid) != null) store.putString(KEY_NONCES, all.toString())
    }

    var fcmOptedIn: Boolean
        @Synchronized get() = store.getString(KEY_FCM_OPTED_IN) == "true"
        @Synchronized set(value) = store.putString(KEY_FCM_OPTED_IN, if (value) "true" else null)

    /** A random per-install value carried by Conduit's own tap intents. */
    @Synchronized
    fun tapToken(): String {
        store.getString(KEY_TAP_TOKEN)?.let { return it }
        val token = Base64Url.encode(PushCrypto.randomBytes(16))
        store.putString(KEY_TAP_TOKEN, token)
        return token
    }

    private fun nonces(): JSONObject = try {
        store.getString(KEY_NONCES)?.let(::JSONObject) ?: JSONObject()
    } catch (_: JSONException) {
        JSONObject()
    }

    companion object {
        /** Kept out of device-to-device transfer by res/xml/data_extraction_rules.xml. */
        const val PREFS_NAME = "conduit_push"
        private const val KEY_CONFIG = "config"
        private const val KEY_NONCES = "verified_nonces"
        private const val KEY_FCM_OPTED_IN = "fcm_opted_in"
        private const val KEY_TAP_TOKEN = "tap_token"
        private const val MAX_NONCES_PER_SID = 16
    }
}
