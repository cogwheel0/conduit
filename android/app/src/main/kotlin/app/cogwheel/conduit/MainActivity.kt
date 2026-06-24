package app.cogwheel.conduit

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.os.Bundle
import android.os.Parcelable
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.CookieManager
import android.webkit.MimeTypeMap
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private lateinit var backgroundStreamingHandler: BackgroundStreamingHandler
    private lateinit var nativeSttBridge: NativeSttBridge
    private lateinit var nativeTtsBridge: NativeTtsBridge

    override fun onCreate(savedInstanceState: Bundle?) {
        sanitizeLaunchIntent(intent)?.let { setIntent(it) }
        super.onCreate(savedInstanceState)

        // Enable edge-to-edge display for all Android versions
        // This is the official way to enable edge-to-edge that works with Android 15+
        WindowCompat.setDecorFitsSystemWindows(window, false)

        // Configure system bar appearance for edge-to-edge
        val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
        windowInsetsController.isAppearanceLightStatusBars = false
        windowInsetsController.isAppearanceLightNavigationBars = false
    }
    
    private val ASSISTANT_CHANNEL = "app.cogwheel.conduit/assistant"
    private val SHARE_TEXT_CHANNEL = "conduit/share_receiver_text"
    private val HOME_WIDGET_LAUNCH_ACTION = "es.antonborri.home_widget.action.LAUNCH"
    private val SHARE_TEXT_PREFS_NAME = "conduit_share_receiver_text"
    private val PENDING_MULTIPLE_SHARE_TEXT_KEY = "pending_multiple_share_text"
    private val PENDING_STAGED_SHARE_PAYLOAD_KEY = "pending_staged_share_payload"
    private val PENDING_SHARE_IMPORT_STATUS_KEY = "pending_share_import_status"
    private val SHARE_STAGING_DIRECTORY_NAME = "conduit-shared-intents"
    private val maxSharedFileCount = 6
    private val maxSharedImageBytes = 20L * 1024L * 1024L
    private var methodChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    @Volatile
    private var pendingStagedShareInProgress = false
    @Volatile
    private var activeShareImportId: String? = null

    private data class PendingSharedUri(
        val uri: Uri,
        val mimeType: String?,
        val ordinal: Int
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize background streaming handler
        backgroundStreamingHandler = BackgroundStreamingHandler(this)
        backgroundStreamingHandler.setup(flutterEngine)
        nativeSttBridge = NativeSttBridge(this)
        nativeSttBridge.setup(flutterEngine)
        nativeTtsBridge = NativeTtsBridge(this)
        nativeTtsBridge.setup(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ASSISTANT_CHANNEL)
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_TEXT_CHANNEL
        )
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingMultipleShareText" -> {
                    result.success(takePendingMultipleShareText())
                }
                "hasPendingStagedSharePayload" -> {
                    result.success(hasPendingStagedSharePayload())
                }
                "takePendingStagedSharePayload" -> {
                    result.success(takePendingStagedSharePayload())
                }
                "takePendingShareImportPayload" -> {
                    result.success(takePendingStagedSharePayload())
                }
                "pendingShareImportStatus" -> {
                    result.success(pendingShareImportStatus())
                }
                "clearShareImportStatus" -> {
                    val id = call.argument<String>("id")
                    clearShareImportStatus(id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        
        // Setup cookie manager channel for WebView cookie access
        val cookieChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.conduit.app/cookies"
        )
        
        cookieChannel.setMethodCallHandler { call, result ->
            if (call.method == "getCookies") {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("INVALID_ARGS", "Invalid URL", null)
                    return@setMethodCallHandler
                }
                
                // Get cookies from Android's CookieManager (shared with WebView)
                val cookieManager = CookieManager.getInstance()
                val cookieString = cookieManager.getCookie(url)
                
                val cookieMap = mutableMapOf<String, String>()
                if (cookieString != null) {
                    // Parse cookie string: "name1=value1; name2=value2"
                    cookieString.split(";").forEach { cookie ->
                        val parts = cookie.trim().split("=", limit = 2)
                        if (parts.size == 2) {
                            cookieMap[parts[0].trim()] = parts[1].trim()
                        }
                    }
                }
                
                result.success(cookieMap)
            } else {
                result.notImplemented()
            }
        }
        
        // Check if started with context
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        val sanitizedIntent = sanitizeLaunchIntent(intent) ?: intent
        setIntent(sanitizedIntent)
        super.onNewIntent(sanitizedIntent)
        handleIntent(sanitizedIntent)
    }

    private fun sanitizeLaunchIntent(intent: Intent?): Intent? {
        return sanitizeShareIntent(sanitizeHistoryHomeWidgetIntent(intent))
    }

    private fun sanitizeHistoryHomeWidgetIntent(intent: Intent?): Intent? {
        if (intent == null || intent.action != HOME_WIDGET_LAUNCH_ACTION) {
            return intent
        }
        if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0) {
            return intent
        }

        return Intent(intent).apply {
            action = Intent.ACTION_MAIN
            data = null
        }
    }

    private fun sanitizeShareIntent(intent: Intent?): Intent? {
        if (intent == null || !isShareIntent(intent)) {
            return intent
        }

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

        return when (intent.action) {
            Intent.ACTION_SEND -> sanitizeSingleShareIntent(intent, text)
            Intent.ACTION_SEND_MULTIPLE -> sanitizeMultipleShareIntent(intent, text)
            else -> intent
        }
    }

    private fun sanitizeSingleShareIntent(intent: Intent, text: String?): Intent {
        val uri = streamUriFromIntent(intent)
        if (uri == null) {
            storePendingMultipleShareText(null)
            return intent
        }
        val mimeType = mimeTypeAt(intent, 0)
        if (!sharedUriWithinLimits(uri, mimeType)) {
            Log.w("MainActivity", "Rejected oversized shared image URI: $uri")
            storePendingMultipleShareText(null)
            val importId = UUID.randomUUID().toString()
            beginShareImport(importId)
            storePendingShareImportStatus(
                id = importId,
                expectedFileCount = 1,
                isInProgress = false,
                errors = listOf(shareRejectionMessage(uri, mimeType))
            )
            notifyStagedSharePayloadReady()
            return textOnlyShareIntent(intent, text)
        }
        storePendingMultipleShareText(null)
        stageSharedUrisAsync(listOf(PendingSharedUri(uri, mimeType, 0)), text)
        return textOnlyShareIntent(intent, null)
    }

    private fun sanitizeMultipleShareIntent(intent: Intent, text: String?): Intent {
        val originalUris = streamUrisFromIntent(intent)
        if (originalUris.isEmpty()) {
            storePendingMultipleShareText(null)
            return intent
        }

        val pendingUris = ArrayList<PendingSharedUri>()
        val importErrors = ArrayList<String>()
        originalUris.forEachIndexed { index, uri ->
            if (pendingUris.size >= maxSharedFileCount) {
                Log.w("MainActivity", "Rejected shared URI beyond count cap: $uri")
                importErrors.add("Only the first $maxSharedFileCount shared attachments were imported.")
                return@forEachIndexed
            }
            val mimeType = mimeTypeAt(intent, index)
            if (sharedUriWithinLimits(uri, mimeType)) {
                pendingUris.add(PendingSharedUri(uri, mimeType, index))
            } else {
                Log.w("MainActivity", "Rejected oversized shared image URI: $uri")
                importErrors.add(shareRejectionMessage(uri, mimeType))
            }
        }

        if (pendingUris.isEmpty()) {
            storePendingMultipleShareText(null)
            if (importErrors.isNotEmpty()) {
                val importId = UUID.randomUUID().toString()
                beginShareImport(importId)
                storePendingShareImportStatus(
                    id = importId,
                    expectedFileCount = originalUris.size.coerceAtMost(maxSharedFileCount),
                    isInProgress = false,
                    errors = importErrors
                )
                notifyStagedSharePayloadReady()
            }
            return textOnlyShareIntent(intent, text)
        }

        storePendingMultipleShareText(null)
        stageSharedUrisAsync(pendingUris, text, importErrors)
        return textOnlyShareIntent(intent, null)
    }

    private fun textOnlyShareIntent(intent: Intent, text: String?): Intent {
        return Intent(intent).apply {
            removeExtra(Intent.EXTRA_STREAM)
            removeExtra(Intent.EXTRA_MIME_TYPES)
            clipData = null
            type = if (text == null) null else "text/plain"
            if (text == null) {
                action = Intent.ACTION_MAIN
                removeExtra(Intent.EXTRA_TEXT)
                data = null
            } else {
                action = Intent.ACTION_SEND
                putExtra(Intent.EXTRA_TEXT, text)
            }
        }
    }

    private fun stageSharedUri(uri: Uri, intentMimeType: String?, ordinal: Int): Uri? {
        val resolver = contentResolver
        val mimeType = resolver.getType(uri) ?: intentMimeType
        val displayName = displayNameForUri(resolver, uri)
        val maxBytes = if (sharedUriIsImage(mimeType, displayName)) maxSharedImageBytes else null
        val stagingDirectory = File(cacheDir, SHARE_STAGING_DIRECTORY_NAME).apply {
            if (!exists()) {
                mkdirs()
            }
        }
        if (!stagingDirectory.isDirectory) {
            return null
        }

        val destination = File(
            stagingDirectory,
            uniqueStagingFileName(displayName, mimeType, ordinal)
        )
        var copiedBytes = 0L
        return try {
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val bytesRead = input.read(buffer)
                        if (bytesRead == -1) break

                        copiedBytes += bytesRead.toLong()
                        if (maxBytes != null && copiedBytes > maxBytes) {
                            destination.delete()
                            Log.w(
                                "MainActivity",
                                "Rejected shared image URI during staging because it exceeded " +
                                    "$maxBytes bytes: $uri"
                            )
                            return null
                        }
                        output.write(buffer, 0, bytesRead)
                    }
                }
            } ?: return null
            Uri.fromFile(destination)
        } catch (error: Exception) {
            destination.delete()
            Log.w("MainActivity", "Failed to stage shared URI: $uri", error)
            null
        }
    }

    private fun stageSharedUrisAsync(
        uris: List<PendingSharedUri>,
        text: String?,
        initialErrors: List<String> = emptyList()
    ) {
        val importId = UUID.randomUUID().toString()
        beginShareImport(importId)
        storePendingShareImportStatus(
            id = importId,
            expectedFileCount = uris.size,
            isInProgress = true,
            errors = initialErrors
        )
        pendingStagedShareInProgress = true
        notifyStagedSharePayloadReady()
        Thread {
            val stagedPaths = ArrayList<String>()
            val errors = ArrayList(initialErrors)
            try {
                uris.forEach { pending ->
                    if (!sharedUriWithinLimits(pending.uri, pending.mimeType)) {
                        Log.w("MainActivity", "Rejected oversized shared image URI: ${pending.uri}")
                        errors.add(shareRejectionMessage(pending.uri, pending.mimeType))
                        return@forEach
                    }

                    val stagedUri = stageSharedUri(pending.uri, pending.mimeType, pending.ordinal)
                    val stagedPath = stagedUri?.path
                    if (!stagedPath.isNullOrEmpty()) {
                        stagedPaths.add(stagedPath)
                    } else {
                        Log.w("MainActivity", "Failed to stage accepted shared URI: ${pending.uri}")
                        errors.add("Could not import ${displayNameForUri(contentResolver, pending.uri) ?: "shared file"}.")
                    }
                }
                if (isCurrentShareImport(importId)) {
                    storePendingStagedSharePayload(importId, text, stagedPaths)
                    storePendingShareImportStatus(
                        id = importId,
                        expectedFileCount = uris.size,
                        isInProgress = false,
                        errors = errors
                    )
                } else {
                    deleteStagedPaths(stagedPaths)
                }
            } finally {
                if (isCurrentShareImport(importId)) {
                    pendingStagedShareInProgress = false
                    notifyStagedSharePayloadReady()
                }
            }
        }.start()
    }

    private fun notifyStagedSharePayloadReady() {
        runOnUiThread {
            shareChannel?.invokeMethod("stagedSharePayloadReady", null)
        }
    }

    private fun beginShareImport(id: String) {
        activeShareImportId = id
        pendingStagedShareInProgress = false
        getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(PENDING_STAGED_SHARE_PAYLOAD_KEY)
            .apply()
    }

    private fun isCurrentShareImport(id: String): Boolean {
        return activeShareImportId == id
    }

    private fun deleteStagedPaths(paths: List<String>) {
        paths.forEach { path ->
            try {
                File(path).delete()
            } catch (_: Exception) {
            }
        }
    }

    private fun sharedUriWithinLimits(uri: Uri, intentMimeType: String?): Boolean {
        val resolver = contentResolver
        val mimeType = resolver.getType(uri) ?: intentMimeType
        if (!sharedUriIsImage(mimeType, displayNameForUri(resolver, uri))) {
            return true
        }

        val sizeBytes = sharedUriSizeBytes(resolver, uri)
        return sizeBytes == null || sizeBytes <= maxSharedImageBytes
    }

    private fun shareRejectionMessage(uri: Uri, intentMimeType: String?): String {
        val displayName = displayNameForUri(contentResolver, uri) ?: "shared image"
        val mimeType = contentResolver.getType(uri) ?: intentMimeType
        return if (sharedUriIsImage(mimeType, displayName)) {
            "$displayName is larger than the 20 MB image limit."
        } else {
            "Could not import $displayName."
        }
    }

    private fun sharedUriSizeBytes(resolver: ContentResolver, uri: Uri): Long? {
        if (uri.scheme == ContentResolver.SCHEME_FILE) {
            return uri.path?.let { File(it).length().takeIf { size -> size >= 0L } }
        }

        try {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (!cursor.moveToFirst()) {
                        return@use null
                    }
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        return cursor.getLong(sizeIndex).takeIf { it >= 0L }
                    }
                }
        } catch (error: Exception) {
            Log.w("MainActivity", "Failed to query shared URI size: $uri", error)
        }

        return try {
            resolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.length.takeIf { it >= 0L }
            }
        } catch (error: Exception) {
            Log.w("MainActivity", "Failed to open shared URI descriptor: $uri", error)
            null
        }
    }

    private fun isShareIntent(intent: Intent): Boolean {
        val action = intent.action
        return action == Intent.ACTION_SEND || action == Intent.ACTION_SEND_MULTIPLE
    }

    @Suppress("DEPRECATION")
    private fun streamUriFromIntent(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    @Suppress("DEPRECATION")
    private fun streamUrisFromIntent(intent: Intent): List<Uri> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                ?: emptyList()
        } else {
            intent.getParcelableArrayListExtra<Parcelable>(Intent.EXTRA_STREAM)
                ?.filterIsInstance<Uri>()
                ?: emptyList()
        }
    }

    private fun mimeTypeAt(intent: Intent, index: Int): String? {
        return intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)
            ?.getOrNull(index)
            ?: intent.type
    }

    private fun displayNameForUri(resolver: ContentResolver, uri: Uri): String? {
        return try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index == -1) null else cursor.getString(index)
                }
        } catch (_: Exception) {
            null
        } ?: uri.lastPathSegment
    }

    private fun sharedUriIsImage(mimeType: String?, displayName: String?): Boolean {
        return isImageMimeType(mimeType) || isImageFileName(displayName)
    }

    private fun isImageMimeType(mimeType: String?): Boolean {
        return mimeType?.lowercase()?.startsWith("image/") == true
    }

    private fun isImageFileName(fileName: String?): Boolean {
        val extension = fileName
            ?.substringAfterLast('.', missingDelimiterValue = "")
            ?.lowercase()
            ?: return false
        return extension in setOf(
            "jpg",
            "jpeg",
            "png",
            "gif",
            "webp",
            "heic",
            "heif",
            "dng",
            "raw",
            "cr2",
            "nef",
            "arw",
            "orf",
            "rw2",
            "bmp"
        )
    }

    private fun uniqueStagingFileName(
        displayName: String?,
        mimeType: String?,
        ordinal: Int
    ): String {
        val sanitizedName = sanitizeFileName(displayName) ?: "shared-file"
        val fileName = ensureFileExtension(sanitizedName, mimeType)
        return "${UUID.randomUUID()}-$ordinal-$fileName"
    }

    private fun ensureFileExtension(fileName: String, mimeType: String?): String {
        if (fileName.substringAfterLast('.', missingDelimiterValue = "").isNotEmpty()) {
            return fileName
        }

        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
        return if (extension.isNullOrEmpty()) fileName else "$fileName.$extension"
    }

    private fun sanitizeFileName(fileName: String?): String? {
        val trimmed = fileName?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return trimmed.replace(Regex("[/\\\\:?%*|\"<>\\p{Cntrl}]"), "-")
    }

    private fun storePendingStagedSharePayload(
        id: String,
        text: String?,
        filePaths: List<String>
    ) {
        val trimmed = text?.trim()?.takeIf { it.isNotEmpty() }
        val prefs = getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
        if (trimmed == null && filePaths.isEmpty()) {
            prefs.edit().remove(PENDING_STAGED_SHARE_PAYLOAD_KEY).apply()
            return
        }

        val payload = JSONObject()
            .put("id", id)
            .put("filePaths", JSONArray(filePaths))
        if (trimmed != null) {
            payload.put("text", trimmed)
        }

        prefs.edit()
            .putString(PENDING_STAGED_SHARE_PAYLOAD_KEY, payload.toString())
            .apply()
    }

    private fun storePendingShareImportStatus(
        id: String,
        expectedFileCount: Int,
        isInProgress: Boolean,
        errors: List<String> = emptyList()
    ) {
        val payload = JSONObject()
            .put("id", id)
            .put("expectedFileCount", expectedFileCount)
            .put("isInProgress", isInProgress)
            .put("errors", JSONArray(errors.distinct()))

        getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PENDING_SHARE_IMPORT_STATUS_KEY, payload.toString())
            .apply()
    }

    private fun pendingShareImportStatus(): Map<String, Any>? {
        val prefs = getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(PENDING_SHARE_IMPORT_STATUS_KEY, null)
            ?: return null

        return try {
            val json = JSONObject(raw)
            val errors = ArrayList<String>()
            val rawErrors = json.optJSONArray("errors")
            if (rawErrors != null) {
                for (index in 0 until rawErrors.length()) {
                    rawErrors.optString(index).takeIf { it.isNotEmpty() }?.let(errors::add)
                }
            }

            hashMapOf(
                "id" to json.optString("id"),
                "expectedFileCount" to json.optInt("expectedFileCount", 0),
                "isInProgress" to json.optBoolean("isInProgress", pendingStagedShareInProgress),
                "errors" to errors
            )
        } catch (error: Exception) {
            Log.w("MainActivity", "Failed to parse pending share import status", error)
            null
        }
    }

    private fun clearShareImportStatus(id: String?) {
        val prefs = getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
        if (id != null) {
            val raw = prefs.getString(PENDING_SHARE_IMPORT_STATUS_KEY, null)
            val currentId = try {
                raw?.let { JSONObject(it).optString("id").takeIf { value -> value.isNotEmpty() } }
            } catch (_: Exception) {
                null
            }
            if (currentId != null && currentId != id) {
                return
            }
        }

        prefs.edit().remove(PENDING_SHARE_IMPORT_STATUS_KEY).apply()
    }

    private fun hasPendingStagedSharePayload(): Boolean {
        if (pendingStagedShareInProgress) return true
        val prefs = getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.contains(PENDING_STAGED_SHARE_PAYLOAD_KEY)
    }

    private fun takePendingStagedSharePayload(): Map<String, Any>? {
        val prefs = getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(PENDING_STAGED_SHARE_PAYLOAD_KEY, null)
            ?: return null
        prefs.edit().remove(PENDING_STAGED_SHARE_PAYLOAD_KEY).apply()

        return try {
            val json = JSONObject(raw)
            val payload = HashMap<String, Any>()
            val filePaths = ArrayList<String>()
            val files = json.optJSONArray("filePaths")
            if (files != null) {
                for (index in 0 until files.length()) {
                    files.optString(index).takeIf { it.isNotEmpty() }?.let(filePaths::add)
                }
            }
            json.optString("id").takeIf { it.isNotEmpty() }?.let { payload["id"] = it }
            json.optString("text").takeIf { it.isNotEmpty() }?.let { payload["text"] = it }
            payload["filePaths"] = filePaths
            payload
        } catch (error: Exception) {
            Log.w("MainActivity", "Failed to parse pending staged share payload", error)
            null
        }
    }

    private fun storePendingMultipleShareText(text: String?) {
        val editor = getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE).edit()
        val trimmed = text?.trim()?.takeIf { it.isNotEmpty() }
        if (trimmed == null) {
            editor.remove(PENDING_MULTIPLE_SHARE_TEXT_KEY)
        } else {
            editor.putString(PENDING_MULTIPLE_SHARE_TEXT_KEY, trimmed)
        }
        editor.apply()
    }

    private fun takePendingMultipleShareText(): String? {
        val prefs = getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
        val text = prefs.getString(PENDING_MULTIPLE_SHARE_TEXT_KEY, null)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        prefs.edit().remove(PENDING_MULTIPLE_SHARE_TEXT_KEY).apply()
        return if (intent?.action in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            text
        } else {
            null
        }
    }

    private fun handleIntent(intent: Intent) {
        Log.d("MainActivity", "handleIntent called")
        Log.d("MainActivity", "Intent extras: ${intent.extras?.keySet()}")

        val screenContext = intent.getStringExtra("screen_context")
        val screenshotPath = intent.getStringExtra("screenshot_path")
        val startVoiceCall = intent.getBooleanExtra("start_voice_call", false)
        val startNewChat = intent.getBooleanExtra("start_new_chat", false)

        Log.d("MainActivity", "screenContext: $screenContext")
        Log.d("MainActivity", "screenshotPath: $screenshotPath")
        Log.d("MainActivity", "startVoiceCall: $startVoiceCall")
        Log.d("MainActivity", "startNewChat: $startNewChat")
        Log.d("MainActivity", "methodChannel: $methodChannel")

        if (startVoiceCall) {
            Log.d("MainActivity", "Invoking startVoiceCall")
            methodChannel?.invokeMethod("startVoiceCall", null)
        } else if (startNewChat) {
            Log.d("MainActivity", "Invoking startNewChat")
            methodChannel?.invokeMethod("startNewChat", null)
        } else if (screenContext != null) {
            Log.d("MainActivity", "Invoking analyzeScreen")
            methodChannel?.invokeMethod("analyzeScreen", screenContext)
        } else if (screenshotPath != null) {
            Log.d("MainActivity", "Invoking analyzeScreenshot with path: $screenshotPath")
            methodChannel?.invokeMethod("analyzeScreenshot", screenshotPath)
        } else {
            Log.d("MainActivity", "No screen context or screenshot path found")
        }
    }
    
    override fun onDestroy() {
        if (::nativeSttBridge.isInitialized) {
            nativeSttBridge.dispose()
        }
        if (::nativeTtsBridge.isInitialized) {
            nativeTtsBridge.dispose()
        }
        if (::backgroundStreamingHandler.isInitialized) {
            backgroundStreamingHandler.cleanup()
        }
        super.onDestroy()
    }
}
