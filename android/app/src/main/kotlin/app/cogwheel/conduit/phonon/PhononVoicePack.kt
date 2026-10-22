package app.cogwheel.conduit.phonon

import android.content.Context
import java.io.File
import java.security.MessageDigest

/** Only this pinned English q8 checkpoint and exact Zoey conditioning are accepted. */
internal object PhononVoicePack {
    const val VOICE = "NbpkqMVS3CJeq2j8"
    const val VOICE_ID = "phonon:31m-en:$VOICE"
    private const val REVISION = "31m-en-92741c5b-zoey-0ee17205-v1"
    internal val hashes = linkedMapOf(
        "model.q8.gguf" to "a7d9aad2cd6dc66473f24a08bc6d2939030ef4d751ef82349361fbef3272dbae",
        "config.json" to "b5d0f88353638370d94035b7d73d7d6577c0554d78f8d7ecfd40490aae39ae85",
        "tokenizer.json" to "691a00068fa7b989f2f3e5ae5daa2d1a5bb319f2d5360deafcfb19a8bb6e7936",
        "voices/$VOICE.safetensors" to "97c7f8c253413574406ab80dd23f49c3ebb2517163b00a9bf86b9c4cf43e7e23",
    )

    fun install(context: Context): File {
        // Downloadable/model data must never enter Android backups.
        val parent = File(context.noBackupFilesDir, "phonon").apply { mkdirs() }
        val installed = File(parent, REVISION)
        if (verified(installed)) return installed
        val staging = File(parent, "$REVISION.staging")
        staging.deleteRecursively()
        staging.mkdirs()
        try {
            for ((path, hash) in hashes) {
                val target = File(staging, path)
                target.parentFile!!.mkdirs()
                context.assets.open("phonon/$path").use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                check(sha256(target) == hash) { "Zoey voice pack failed integrity verification" }
            }
            if (installed.exists()) check(installed.deleteRecursively())
            check(staging.renameTo(installed)) { "Unable to install Zoey voice pack" }
            return installed
        } catch (error: Throwable) {
            staging.deleteRecursively()
            throw error
        }
    }

    private fun verified(dir: File): Boolean = hashes.all { (path, hash) ->
        val file = File(dir, path)
        file.isFile && sha256(file) == hash
    }

    internal fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
