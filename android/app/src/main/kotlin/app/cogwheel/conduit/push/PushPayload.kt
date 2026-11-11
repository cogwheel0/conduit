package app.cogwheel.conduit.push

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

/**
 * A decrypted `cp/1` notification payload (docs/push/PROTOCOL.md section 2).
 *
 * [json] is the plaintext exactly as received; it is what Dart and the tap
 * intent get, so fields this class ignores still reach the app.
 */
data class PushPayload(
    val kind: String,
    val source: String,
    val ids: Map<String, String>,
    val title: String,
    val body: String,
    val author: String?,
    val timestamp: Long,
    val dedupKey: String,
    val group: String?,
    val nonce: String?,
    val json: String,
) {
    /** The app-wide dedup key: the subscription's scope, `|`, then `dk`. */
    fun appDedupKey(scope: String): String = "$scope|$dedupKey"

    companion object {
        const val VERSION = 1
        const val KIND_REPLY = "reply"
        const val KIND_REPLY_FAILED = "reply_failed"
        const val KIND_CHANNEL = "channel"
        const val KIND_CRON = "cron"
        const val KIND_TEST = "test"
        val KINDS = setOf(KIND_REPLY, KIND_REPLY_FAILED, KIND_CHANNEL, KIND_CRON, KIND_TEST)

        /**
         * Parses a decrypted plaintext. Returns null for anything a device
         * must drop: invalid UTF-8, not a JSON object, `v` other than 1, an
         * unknown `k`, or a missing `dk`. Unknown keys are ignored.
         */
        fun parse(plaintext: ByteArray): PushPayload? {
            val text = decodeUtf8(plaintext) ?: return null
            val root = try {
                JSONTokener(text).nextValue() as? JSONObject
            } catch (_: JSONException) {
                null
            } ?: return null

            val version = root.opt("v") as? Number ?: return null
            if (version.toDouble() != VERSION.toDouble()) return null
            val kind = root.opt("k") as? String ?: return null
            if (kind !in KINDS) return null
            val dedupKey = (root.opt("dk") as? String)?.takeIf { it.isNotEmpty() } ?: return null

            val ids = linkedMapOf<String, String>()
            (root.opt("ids") as? JSONObject)?.let { object_ ->
                object_.keys().forEach { key ->
                    (object_.opt(key) as? String)?.let { ids[key] = it }
                }
            }
            return PushPayload(
                kind = kind,
                source = root.opt("src") as? String ?: "",
                ids = ids,
                title = root.opt("t") as? String ?: "",
                body = root.opt("b") as? String ?: "",
                author = (root.opt("a") as? String)?.takeIf { it.isNotEmpty() },
                timestamp = (root.opt("ts") as? Number)?.toLong() ?: 0L,
                dedupKey = dedupKey,
                group = (root.opt("g") as? String)?.takeIf { it.isNotEmpty() },
                nonce = (root.opt("n") as? String)?.takeIf { it.isNotEmpty() },
                json = text,
            )
        }

        private fun decodeUtf8(bytes: ByteArray): String? = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }
}
