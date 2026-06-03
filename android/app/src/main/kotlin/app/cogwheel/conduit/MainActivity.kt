package app.cogwheel.conduit

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private lateinit var backgroundStreamingHandler: BackgroundStreamingHandler

    override fun onCreate(savedInstanceState: Bundle?) {
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
    private val SHARE_CHANNEL = "conduit/share_receiver"
    private var methodChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private var initialSharePayload: Map<String, Any?>? = null
    private var pendingSharePayload: Map<String, Any?>? = null
    private var initialSharePayloadRequested = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val shareCopyExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val maxSharedFileCount = 6
    private val maxSharedFileBytes = 20L * 1024L * 1024L
    private val maxSharedPayloadBytes = maxSharedFileCount * maxSharedFileBytes

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize background streaming handler
        backgroundStreamingHandler = BackgroundStreamingHandler(this)
        backgroundStreamingHandler.setup(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ASSISTANT_CHANNEL)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedPayload" -> {
                    initialSharePayloadRequested = true
                    val payload = initialSharePayload ?: pendingSharePayload
                    result.success(payload)
                }
                "resetInitialSharedPayload" -> {
                    initialSharePayload = null
                    pendingSharePayload = null
                    result.success(null)
                }
                "ackSharedPayload" -> {
                    val ackId = (call.arguments as? Map<*, *>)?.get("id") as? String
                    if (matchesSharePayload(initialSharePayload, ackId)) {
                        initialSharePayload = null
                    }
                    if (matchesSharePayload(pendingSharePayload, ackId)) {
                        pendingSharePayload = null
                    }
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
        handleIntent(intent, initial = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent, initial = false)
    }

    private fun handleIntent(intent: Intent, initial: Boolean = false) {
        Log.d("MainActivity", "handleIntent called")
        Log.d("MainActivity", "Intent extras: ${intent.extras?.keySet()}")

        handleShareIntent(intent, initial)

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

    private fun handleShareIntent(intent: Intent, initial: Boolean) {
        if (initial && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
            return
        }

        if (!isShareIntent(intent)) {
            return
        }

        val shareIntent = Intent(intent)
        shareCopyExecutor.execute {
            val payload = sharePayloadFromIntent(shareIntent) ?: return@execute
            mainHandler.post {
                if (initial) {
                    if (initialSharePayloadRequested) {
                        deliverSharePayload(payload)
                    } else {
                        initialSharePayload = payload
                    }
                } else {
                    deliverSharePayload(payload)
                }
            }
        }
    }

    private fun deliverSharePayload(payload: Map<String, Any?>) {
        val channel = shareChannel
        if (channel == null) {
            pendingSharePayload = payload
            return
        }

        channel.invokeMethod("sharedPayload", payload, object : MethodChannel.Result {
            override fun success(result: Any?) = Unit

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                pendingSharePayload = payload
            }

            override fun notImplemented() {
                pendingSharePayload = payload
            }
        })
    }

    private fun sharePayloadFromIntent(intent: Intent): Map<String, Any?>? {
        val action = intent.action
        if (!isShareIntent(intent)) {
            return null
        }

        val filePaths = mutableListOf<String>()
        val stagingBudget = ShareStagingBudget()
        when (action) {
            Intent.ACTION_SEND -> streamUriFromIntent(intent)?.let { uri ->
                copyUriToCache(uri, intent.type, stagingBudget)?.let(filePaths::add)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = streamUrisFromIntent(intent)
                if (uris.size > maxSharedFileCount) {
                    Log.w(
                        "MainActivity",
                        "Received ${uris.size} shared URIs; only staging first $maxSharedFileCount"
                    )
                }
                uris.take(maxSharedFileCount).forEach { uri ->
                    copyUriToCache(uri, intent.type, stagingBudget)?.let(filePaths::add)
                }
            }
        }

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

        if (text == null && filePaths.isEmpty()) {
            return null
        }

        val payload = mutableMapOf<String, Any?>(
            "id" to UUID.randomUUID().toString(),
            "filePaths" to filePaths,
        )
        if (text != null) {
            payload["text"] = text
        }
        return payload
    }

    private fun matchesSharePayload(payload: Map<String, Any?>?, id: String?): Boolean {
        if (payload == null) {
            return false
        }
        return id == null || payload["id"] == id
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
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                ?: emptyList()
        }
    }

    private fun copyUriToCache(
        uri: Uri,
        intentMimeType: String?,
        stagingBudget: ShareStagingBudget
    ): String? {
        val resolver = contentResolver
        val mimeType = resolver.getType(uri) ?: intentMimeType
        val fileName = uniqueCacheFileName(displayNameForUri(resolver, uri), mimeType)
        val directory = File(cacheDir, "shared-intents").apply { mkdirs() }
        val destination = File(directory, fileName)
        if (stagingBudget.fileCount >= maxSharedFileCount) {
            Log.w("MainActivity", "Rejected shared URI after file count cap: $uri")
            return null
        }

        val declaredSize = sizeForUri(resolver, uri)
        if (declaredSize != null && declaredSize > maxSharedFileBytes) {
            Log.w(
                "MainActivity",
                "Rejected oversized shared URI before copy: $uri ($declaredSize bytes)"
            )
            return null
        }
        if (
            declaredSize != null &&
            stagingBudget.totalBytes + declaredSize > maxSharedPayloadBytes
        ) {
            Log.w(
                "MainActivity",
                "Rejected shared URI before copy because payload would exceed " +
                    "$maxSharedPayloadBytes bytes: $uri"
            )
            return null
        }

        var copiedBytes = 0L
        return try {
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val bytesRead = input.read(buffer)
                        if (bytesRead == -1) break

                        copiedBytes += bytesRead.toLong()
                        if (copiedBytes > maxSharedFileBytes) {
                            throw SharedFileTooLargeException(copiedBytes)
                        }
                        if (stagingBudget.totalBytes + copiedBytes > maxSharedPayloadBytes) {
                            throw SharedPayloadTooLargeException(
                                stagingBudget.totalBytes + copiedBytes
                            )
                        }

                        output.write(buffer, 0, bytesRead)
                    }
                }
            } ?: return null
            stagingBudget.fileCount += 1
            stagingBudget.totalBytes += copiedBytes
            destination.absolutePath
        } catch (error: SharedFileTooLargeException) {
            destination.delete()
            Log.w(
                "MainActivity",
                "Rejected oversized shared URI during copy: $uri (${error.sizeBytes} bytes)"
            )
            null
        } catch (error: SharedPayloadTooLargeException) {
            destination.delete()
            Log.w(
                "MainActivity",
                "Rejected shared URI during copy because payload reached " +
                    "${error.sizeBytes} bytes"
            )
            null
        } catch (error: Exception) {
            destination.delete()
            Log.w("MainActivity", "Failed to copy shared URI: $uri", error)
            null
        }
    }

    private fun sizeForUri(resolver: ContentResolver, uri: Uri): Long? {
        return try {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (index == -1 || cursor.isNull(index)) {
                        null
                    } else {
                        cursor.getLong(index).takeIf { it >= 0L }
                    }
                }
        } catch (_: Exception) {
            null
        }
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

    private fun uniqueCacheFileName(displayName: String?, mimeType: String?): String {
        val sanitizedName = sanitizeFileName(displayName)
            ?: "shared-${System.currentTimeMillis()}"
        val withExtension = ensureFileExtension(sanitizedName, mimeType)
        return "${UUID.randomUUID()}-$withExtension"
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

    private class SharedFileTooLargeException(val sizeBytes: Long) : Exception()
    private class SharedPayloadTooLargeException(val sizeBytes: Long) : Exception()
    private data class ShareStagingBudget(var fileCount: Int = 0, var totalBytes: Long = 0L)
    
    override fun onDestroy() {
        super.onDestroy()
        if (::backgroundStreamingHandler.isInitialized) {
            backgroundStreamingHandler.cleanup()
        }
        shareCopyExecutor.shutdown()
    }
}
