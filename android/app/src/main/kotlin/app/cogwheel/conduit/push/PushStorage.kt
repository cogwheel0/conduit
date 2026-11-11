package app.cogwheel.conduit.push

import android.content.SharedPreferences
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/**
 * A small file replaced atomically: the new bytes go to a sibling file that
 * is synced and renamed over the old one, so a crash leaves either version.
 */
internal class AtomicBytesFile(private val file: File) {
    private val scratch = File(file.path + ".new")

    fun readOrNull(): ByteArray? = if (file.isFile) file.readBytes() else null

    fun write(bytes: ByteArray) {
        file.parentFile?.mkdirs()
        FileOutputStream(scratch).use { output ->
            output.write(bytes)
            output.fd.sync()
        }
        if (!scratch.renameTo(file)) {
            scratch.delete()
            throw IOException("Could not replace ${file.name}")
        }
    }
}

/** String preferences, so the push stores run in plain JVM tests. */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
}

internal class SharedPreferencesStore(private val prefs: SharedPreferences) : KeyValueStore {
    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(key: String, value: String?) {
        prefs.edit().apply {
            if (value == null) remove(key) else putString(key, value)
        }.apply()
    }
}
