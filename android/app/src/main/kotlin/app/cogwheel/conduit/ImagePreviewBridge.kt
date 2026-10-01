package app.cogwheel.conduit

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

class ImagePreviewFileProvider : FileProvider()

/** Grants a receiving app read access to one staged image, never a server URL. */
class ImagePreviewBridge(private val activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "app.cogwheel.conduit/image_preview").setMethodCallHandler { call, result ->
            if (call.method != "open") {
                result.notImplemented()
            } else {
                try {
                    val path = call.argument<String>("path") ?: error("Missing path")
                    val file = File(path).canonicalFile
                    val root = File(activity.cacheDir, "image_previews").canonicalFile
                    require(file.path.startsWith(root.path + File.separator) && file.isFile)
                    val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
                    require(mime != null && mime.startsWith("image/"))
                    val uri = FileProvider.getUriForFile(activity, activity.packageName + ".image_previews", file)
                    val view = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mime)
                        clipData = ClipData.newRawUri("image", uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    if (view.resolveActivity(activity.packageManager) == null) {
                        result.error("unavailable", "No image viewer is installed", null)
                    } else {
                        activity.startActivity(Intent.createChooser(view, null))
                        result.success(null)
                    }
                } catch (_: ActivityNotFoundException) {
                    result.error("unavailable", "No image viewer is installed", null)
                } catch (_: Exception) {
                    result.error("unavailable", "Cannot open this image", null)
                }
            }
        }
    }
}
