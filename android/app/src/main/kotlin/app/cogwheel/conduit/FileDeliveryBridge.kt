package app.cogwheel.conduit

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.Locale
import java.util.concurrent.Executors

/** Original files leave private cache only after an explicit Save/Open action. */
class FileDeliveryBridge(private val activity: Activity) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var pendingSave: Pair<File, MethodChannel.Result>? = null

    fun setup(engine: FlutterEngine) {
        executor.execute { cleanExports() }
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "app.cogwheel.conduit/file_delivery")
        channel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "save" -> {
                        val file = source(call.argument<String>("path"))
                        val name = safeName(call.argument<String>("name"))
                        // MediaStore uses its MIME map when preserving extensions
                        // in duplicate names. Use Android's canonical alias (for
                        // example audio/x-wav), rather than an unknown alias.
                        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(
                            name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                        ) ?: call.argument<String>("mime") ?: "application/octet-stream"
                        if (Build.VERSION.SDK_INT >= 29) {
                            executor.execute {
                                try {
                                    val uri = saveDownload(file, name, mime)
                                    main.post { result.success(uri.toString()) }
                                } catch (error: Exception) {
                                    main.post { result.error("SAVE_FAILED", "Could not save the file to Downloads.", null) }
                                }
                            }
                        } else {
                            if (pendingSave != null) throw IOException("Another save is in progress")
                            pendingSave = file to result
                            try {
                                activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = mime
                                    putExtra(Intent.EXTRA_TITLE, name)
                                }, SAVE_REQUEST)
                            } catch (error: Exception) { pendingSave = null; throw error }
                        }
                    }
                    "open" -> {
                        val file = source(call.argument<String>("path"))
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        val name = safeName(call.argument<String>("name") ?: file.name)
                        executor.execute {
                            var export: File? = null
                            try {
                                cleanExports()
                                val folder = File(activity.cacheDir, "hermes-media/exports/${UUID.randomUUID()}")
                                folder.mkdirs()
                                export = folder
                                val snapshot = file.copyTo(File(folder, name))
                                main.post {
                                    try {
                                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.media-files", snapshot)
                                        val intent = Intent(Intent.ACTION_VIEW).apply {
                                            setDataAndType(uri, mime)
                                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                            clipData = android.content.ClipData.newRawUri("File", uri)
                                        }
                                        activity.startActivity(Intent.createChooser(intent, "Open with"))
                                        result.success(null)
                                    } catch (error: Exception) {
                                        result.error("OPEN_FAILED", "Install a compatible app to open this file.", null)
                                    }
                                }
                            } catch (error: Exception) {
                                export?.deleteRecursively()
                                main.post { result.error("OPEN_FAILED", "Could not prepare the file for another app.", null) }
                            }
                        }
                    }
                    "openSaved" -> {
                        val uri = Uri.parse(call.argument<String>("uri") ?: throw IOException("Missing download"))
                        require(uri.scheme == "content")
                        activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, call.argument<String>("mime") ?: "application/octet-stream")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            clipData = android.content.ClipData.newRawUri("File", uri)
                        }, "Open with"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("FILE_ACTION_FAILED", "Could not open or save this file. Check that a compatible app is installed and try again.", null)
            }
        }
    }

    private fun source(path: String?): File {
        val file = File(path ?: throw IOException("Missing file")).canonicalFile
        val root = File(activity.cacheDir, "hermes-media").canonicalFile
        require(file.path.startsWith(root.path + File.separator) && file.isFile && file.length() <= 256L * 1024 * 1024)
        return file
    }

    private fun safeName(name: String?): String = (name ?: "download")
        .replace(Regex("[\\\\/\\p{Cntrl}]"), "_").take(180).ifBlank { "download" }

    private fun cleanExports() {
        val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        File(activity.cacheDir, "hermes-media/exports").listFiles()?.forEach {
            if (it.lastModified() < cutoff) it.deleteRecursively()
        }
    }

    @androidx.annotation.RequiresApi(29)
    private fun saveDownload(file: File, name: String, mime: String): Uri {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Downloads unavailable")
        try {
            resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
                ?: throw IOException("Cannot write Downloads")
            val published = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            if (resolver.update(uri, published, null, null) != 1) throw IOException("Cannot publish download")
            return uri
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SAVE_REQUEST) return false
        val (file, result) = pendingSave ?: return true
        pendingSave = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        executor.execute {
            try {
                activity.contentResolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
                    ?: throw IOException("Cannot write file")
                main.post { result.success(uri.toString()) }
            } catch (error: Exception) {
                // ACTION_CREATE_DOCUMENT created this document for this save.
                // Do not leave a corrupt partial copy after a failed transfer.
                try { android.provider.DocumentsContract.deleteDocument(activity.contentResolver, uri) } catch (_: Exception) { }
                main.post { result.error("SAVE_FAILED", "Could not save the file.", null) }
            }
        }
        return true
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingSave?.second?.success(null)
        pendingSave = null
        executor.shutdown()
    }

    companion object { const val SAVE_REQUEST = 4197 }
}
