package app.cogwheel.conduit.push

import android.util.Log
import java.io.IOException
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * Which notifications this device already showed, by app-wide dedup key
 * (`scope|dk`). Pushes and the app's own socket notifications both claim a
 * key before they post, so a reply never notifies twice.
 *
 * Claims expire after [retentionMillis] (3 days, the longest push TTL).
 */
class PushLedger internal constructor(
    private val file: AtomicBytesFile?,
    private val clock: () -> Long = System::currentTimeMillis,
    private val retentionMillis: Long = RETENTION_MILLIS,
    private val maxEntries: Int = MAX_ENTRIES,
) {
    class Claim(val key: String, val claimedAtMillis: Long, val localNotificationId: String?)

    private var claims: LinkedHashMap<String, Claim>? = null

    /**
     * Records [key] as shown. Returns false when it was already claimed, by a
     * push or by the app. [localNotificationId] is the id of a notification
     * the app posted itself, so [claimsFor] can find it again.
     */
    @Synchronized
    fun claim(key: String, localNotificationId: String?): Boolean {
        val entries = load()
        val now = clock()
        prune(entries, now)
        if (entries.containsKey(key)) return false
        entries[key] = Claim(key, now, localNotificationId)
        while (entries.size > maxEntries) {
            entries.remove(entries.keys.first())
        }
        persist(entries)
        return true
    }

    /**
     * Gives back a push's claim on [key] when its notification was not shown
     * after all, so the message can still show later. A claim the app took
     * for its own notification stays.
     */
    @Synchronized
    fun release(key: String) {
        val entries = load()
        val claim = entries[key] ?: return
        if (claim.localNotificationId != null) return
        entries.remove(key)
        persist(entries)
    }

    /** Live claims whose key belongs to [scope]. */
    @Synchronized
    fun claimsFor(scope: String): List<Claim> {
        val entries = load()
        prune(entries, clock())
        val prefix = "$scope|"
        return entries.values.filter { it.key.startsWith(prefix) }
    }

    private fun prune(entries: LinkedHashMap<String, Claim>, now: Long) {
        // A clock that jumped backwards would otherwise pin entries forever.
        entries.values.removeAll { now - it.claimedAtMillis !in 0..retentionMillis }
    }

    private fun load(): LinkedHashMap<String, Claim> {
        claims?.let { return it }
        val loaded = LinkedHashMap<String, Claim>()
        try {
            file?.readOrNull()?.let { bytes ->
                val array = JSONObject(String(bytes, Charsets.UTF_8)).getJSONArray("claims")
                for (index in 0 until array.length()) {
                    val item = array.getJSONObject(index)
                    val key = item.getString("k")
                    loaded[key] = Claim(
                        key = key,
                        claimedAtMillis = item.getLong("t"),
                        localNotificationId = if (item.isNull("l")) null else item.optString("l"),
                    )
                }
            }
        } catch (error: JSONException) {
            Log.w(TAG, "Push ledger corrupt, starting empty", error)
            loaded.clear()
        } catch (error: IOException) {
            Log.w(TAG, "Push ledger unreadable, starting empty", error)
            loaded.clear()
        }
        claims = loaded
        return loaded
    }

    private fun persist(entries: LinkedHashMap<String, Claim>) {
        val target = file ?: return
        val array = JSONArray()
        entries.values.forEach { claim ->
            array.put(
                JSONObject()
                    .put("k", claim.key)
                    .put("t", claim.claimedAtMillis)
                    .put("l", claim.localNotificationId ?: JSONObject.NULL)
            )
        }
        try {
            target.write(JSONObject().put("v", 1).put("claims", array).toString().toByteArray(Charsets.UTF_8))
        } catch (error: IOException) {
            // The in-memory claim still dedupes for the life of the process.
            Log.w(TAG, "Could not persist push ledger", error)
        }
    }

    companion object {
        private const val TAG = "PushLedger"
        const val RETENTION_MILLIS = 3L * 24 * 60 * 60 * 1000
        const val MAX_ENTRIES = 2000
    }
}
