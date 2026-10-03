package app.cogwheel.conduit

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Saves chat images into the shared Pictures collection.
 *
 * Android 10 and later let apps add their own media through MediaStore
 * without a storage permission, so saving is only offered there. Older
 * versions keep the share sheet.
 */
class ImageGalleryBridge(context: Context) : ImageGalleryHostApi {
    private val appContext = context.applicationContext
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null

    fun setup(flutterEngine: FlutterEngine) {
        engine = flutterEngine
        ImageGalleryHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    fun dispose() {
        engine?.let { ImageGalleryHostApi.setUp(it.dartExecutor.binaryMessenger, null) }
        engine = null
        executor.shutdown()
    }

    override fun canSaveImages(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    override fun saveImage(
        path: String,
        mimeType: String,
        displayName: String,
        callback: (Result<Unit>) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            callback(Result.failure(FlutterError("UNSUPPORTED", "Saving images needs Android 10 or later", null)))
            return
        }
        executor.execute {
            val result = runCatching { insertImage(File(path), mimeType, displayName) }
                .recoverCatching { error ->
                    throw FlutterError("SAVE_FAILED", error.message ?: error.javaClass.simpleName, null)
                }
            mainHandler.post { callback(result) }
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun insertImage(source: File, mimeType: String, displayName: String) {
        if (!source.isFile) throw IOException("Image file is missing")
        val resolver = appContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Conduit")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: throw IOException("MediaStore insert failed")
        try {
            val output = resolver.openOutputStream(uri) ?: throw IOException("MediaStore output unavailable")
            output.use { stream -> source.inputStream().use { it.copyTo(stream) } }
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }
}
