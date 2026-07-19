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
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import android.util.Log
import android.webkit.CookieManager
import android.webkit.MimeTypeMap
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

internal fun cookieValuesFromHeader(cookieHeader: String?): Map<String, String> {
    if (cookieHeader.isNullOrBlank()) return emptyMap()
    val values = linkedMapOf<String, String>()
    cookieHeader.split(";").forEach { cookie ->
        val parts = cookie.trim().split("=", limit = 2)
        val name = parts.firstOrNull()?.trim().orEmpty()
        if (parts.size == 2 && name.isNotEmpty()) {
            // Cookie headers are ordered with longer paths first. Keep that
            // first, more-specific value when the same name appears again.
            values.putIfAbsent(name, parts[1].trim())
        }
    }
    return values
}

internal fun validatedPendingSharePayload(
    id: String?,
    text: String?,
    filePaths: List<String>
): Map<String, Any>? {
    val normalizedId = id?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val normalizedText = text?.trim()?.takeIf { it.isNotEmpty() }
    val normalizedPaths = filePaths.mapNotNull { it.trim().takeIf(String::isNotEmpty) }
    if (normalizedText == null && normalizedPaths.isEmpty()) return null

    return hashMapOf<String, Any>(
        "id" to normalizedId,
        "filePaths" to ArrayList(normalizedPaths)
    ).apply {
        if (normalizedText != null) this["text"] = normalizedText
    }
}

internal fun isCanonicalDirectChild(filePath: String, rootPath: String): Boolean {
    return try {
        File(filePath).canonicalFile.parentFile == File(rootPath).canonicalFile
    } catch (_: Exception) {
        false
    }
}

internal enum class PendingShareFinalization {
    COMMITTED,
    FAILED,
    SUPERSEDED
}

internal data class PendingSharePayloadSelection(
    val raw: String,
    val backlogIndex: Int?
)

internal data class PendingSharePayloadAcknowledgement(
    val queue: PendingSharePayloadQueue,
    val acknowledged: Boolean
)

internal data class PendingSharePayloadAdmission(
    val queue: PendingSharePayloadQueue,
    val admitted: Boolean
)

internal const val MAX_PENDING_SHARE_PAYLOAD_RECORDS = 32
internal const val MAX_PENDING_SHARE_STAGED_BYTES = 256L * 1024L * 1024L
internal const val MAX_SHARED_IMAGE_BYTES = 20L * 1024L * 1024L
internal const val MAX_SHARED_GENERIC_FILE_BYTES = 100L * 1024L * 1024L
internal const val INTERRUPTED_SHARE_IMPORT_MESSAGE =
    "Shared content import was interrupted. Please share the files again."

internal data class PendingShareImportStatusState(
    val id: String,
    val expectedFileCount: Int,
    val isInProgress: Boolean,
    val errors: List<String>
)

internal fun canonicalShareImportId(id: String?): String? {
    val trimmed = id?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    return try {
        UUID.fromString(trimmed).toString()
    } catch (_: IllegalArgumentException) {
        null
    }
}

internal fun shareImportStagingFilePrefix(id: String?): String? =
    canonicalShareImportId(id)?.let { "$it-" }

internal fun interruptedShareImportStatus(
    status: PendingShareImportStatusState?
): PendingShareImportStatusState? {
    if (status?.isInProgress != true) return null
    val canonicalId = canonicalShareImportId(status.id) ?: return null
    return status.copy(
        id = canonicalId,
        isInProgress = false,
        errors = (status.errors + INTERRUPTED_SHARE_IMPORT_MESSAGE).distinct()
    )
}

/**
 * Copies an untrusted provider stream without ever writing past [maximumBytes].
 * A rejected or failed copy removes the partial destination before returning.
 * `null` means the stream exceeded the limit; I/O failures are rethrown after
 * the same cleanup attempt.
 */
internal fun copySharedStreamToFileWithinLimit(
    input: InputStream,
    destination: File,
    maximumBytes: Long
): Long? {
    require(maximumBytes >= 0L)
    var copiedBytes = 0L
    var exceededLimit = false
    try {
        FileOutputStream(destination).use { output ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val bytesRead = input.read(buffer)
                if (bytesRead == -1) break
                if (bytesRead == 0) continue
                if (bytesRead.toLong() > maximumBytes - copiedBytes) {
                    exceededLimit = true
                    break
                }
                output.write(buffer, 0, bytesRead)
                copiedBytes += bytesRead.toLong()
            }
        }
        if (exceededLimit) {
            if (!destination.delete() && destination.exists()) {
                throw IOException("Could not remove rejected shared file")
            }
            return null
        }
        return copiedBytes
    } catch (error: Exception) {
        if (destination.exists() && !destination.delete()) {
            error.addSuppressed(IOException("Could not remove partial shared file"))
        }
        throw error
    }
}

/** Returns the unused byte budget across exact, regular direct children. */
internal fun remainingSharedStagingBytes(
    stagingRoot: File,
    maximumBytes: Long,
    noFollowRegularFileSize: (File) -> Long?
): Long? {
    require(maximumBytes >= 0L)
    if (!stagingRoot.exists()) return maximumBytes
    val children = stagingRoot.listFiles() ?: return null
    var usedBytes = 0L
    return try {
        for (candidate in children) {
            if (!isCanonicalDirectChild(candidate.path, stagingRoot.path)) continue
            val size = noFollowRegularFileSize(candidate) ?: continue
            if (size < 0L) return null
            if (size > maximumBytes - usedBytes) return 0L
            usedBytes += size
        }
        maximumBytes - usedBytes
    } catch (_: Exception) {
        null
    }
}

/**
 * Deletes only regular direct children whose name is owned by [importId].
 * Returning false leaves the durable in-progress status intact for retry.
 */
internal fun cleanupInterruptedShareImportFiles(
    stagingRoot: File,
    importId: String,
    isRegularFileNoFollow: (File) -> Boolean,
    deleteFile: (File) -> Boolean = File::delete
): Boolean {
    val importPrefix = shareImportStagingFilePrefix(importId) ?: return false
    if (!stagingRoot.exists()) return true
    val children = stagingRoot.listFiles() ?: return false
    var cleaned = true
    for (candidate in children) {
        if (!candidate.name.startsWith(importPrefix)) continue
        try {
            if (!isCanonicalDirectChild(candidate.path, stagingRoot.path) ||
                !isRegularFileNoFollow(candidate) ||
                !deleteFile(candidate)
            ) {
                cleaned = false
            }
        } catch (_: Exception) {
            cleaned = false
        }
    }
    return cleaned
}

/**
 * Immutable policy model for durable native share payloads.
 *
 * A completed payload stays in FIFO order until Dart acknowledges its exact
 * ID. Starting a newer import retires the current payload into the backlog;
 * it never grants permission to discard the older payload or its files.
 */
internal data class PendingSharePayloadQueue(
    val backlog: List<String> = emptyList(),
    val current: String? = null
) {
    fun retireCurrent(
        replacementId: String? = null,
        idForRaw: (String) -> String?
    ): PendingSharePayloadQueue {
        val raw = current ?: return this
        val currentId = idForRaw(raw)
        if (replacementId != null && currentId == replacementId) {
            return copy(current = null)
        }
        val alreadyQueued = backlog.any { queued ->
            queued == raw || (currentId != null && idForRaw(queued) == currentId)
        }
        return PendingSharePayloadQueue(
            backlog = if (alreadyQueued) backlog else backlog + raw,
            current = null
        )
    }

    fun withCurrent(raw: String?): PendingSharePayloadQueue = copy(current = raw)

    /**
     * Admits a completed payload only while both durable queue budgets hold.
     * Existing records are never evicted to make room for a newer share.
     */
    fun admitCurrent(
        raw: String?,
        replacementId: String? = null,
        idForRaw: (String) -> String?,
        stagedBytesForRaw: (String) -> Long?,
        maxRecords: Int = MAX_PENDING_SHARE_PAYLOAD_RECORDS,
        maxStagedBytes: Long = MAX_PENDING_SHARE_STAGED_BYTES
    ): PendingSharePayloadAdmission {
        require(maxRecords > 0)
        require(maxStagedBytes >= 0L)

        val retired = retireCurrent(
            replacementId = replacementId,
            idForRaw = idForRaw
        )
        if (raw == null) {
            return PendingSharePayloadAdmission(retired, true)
        }

        val candidate = retired.withCurrent(raw)
        val records = candidate.backlog + listOfNotNull(candidate.current)
        if (records.size > maxRecords) {
            return PendingSharePayloadAdmission(retired, false)
        }

        var totalBytes = 0L
        for (record in records) {
            val recordBytes = stagedBytesForRaw(record)
                ?.takeIf { it >= 0L }
                ?: return PendingSharePayloadAdmission(retired, false)
            if (recordBytes > maxStagedBytes - totalBytes) {
                return PendingSharePayloadAdmission(retired, false)
            }
            totalBytes += recordBytes
        }
        return PendingSharePayloadAdmission(candidate, true)
    }

    fun peek(): PendingSharePayloadSelection? {
        return if (backlog.isNotEmpty()) {
            PendingSharePayloadSelection(backlog.first(), 0)
        } else {
            current?.let { PendingSharePayloadSelection(it, null) }
        }
    }

    fun removing(selection: PendingSharePayloadSelection): PendingSharePayloadQueue {
        val index = selection.backlogIndex
        if (index == null) {
            return if (current == selection.raw) copy(current = null) else this
        }
        if (backlog.getOrNull(index) != selection.raw) return this
        return copy(backlog = backlog.toMutableList().apply { removeAt(index) })
    }

    fun acknowledge(
        expectedId: String,
        idForRaw: (String) -> String?
    ): PendingSharePayloadAcknowledgement {
        val selection = peek()
            ?: return PendingSharePayloadAcknowledgement(this, false)
        val acknowledged = idForRaw(selection.raw) == expectedId
        return PendingSharePayloadAcknowledgement(
            queue = if (acknowledged) removing(selection) else this,
            acknowledged = acknowledged
        )
    }

    val hasRecords: Boolean
        get() = backlog.isNotEmpty() || current != null
}

/**
 * Serializes share-import ownership changes with their durable mutations.
 *
 * URI staging happens on background threads while new Android intents arrive
 * on the activity thread. Keeping the final current-id check inside the same
 * monitor as the durable state write prevents an older import from
 * publishing its payload after a newer import has taken ownership.
 */
internal class PendingShareImportCoordinator {
    private val monitor = Any()
    private var activeImportId: String? = null

    fun begin(
        id: String,
        onBeforeOwnershipLock: () -> Unit = {},
        durableBegin: () -> Boolean
    ): Boolean {
        // Test-visible admission boundary: a waiter can prove it reached the
        // ownership monitor while another durable transition still holds it.
        onBeforeOwnershipLock()
        return synchronized(monitor) {
            // The source URI grant is not itself durable. Keep an in-flight import
            // as the sole owner; callers preserve a newer original Intent when
            // this returns false, allowing Flutter's share plugin to consume it.
            if (activeImportId != null) return@synchronized false
            durableBegin().also { began ->
                if (began) activeImportId = id
            }
        }
    }

    fun finalizeIfCurrent(
        id: String,
        durableFinalize: () -> Boolean
    ): PendingShareFinalization = synchronized(monitor) {
        if (activeImportId != id) {
            PendingShareFinalization.SUPERSEDED
        } else if (durableFinalize()) {
            PendingShareFinalization.COMMITTED
        } else {
            PendingShareFinalization.FAILED
        }
    }

    fun runIfCurrent(id: String, action: () -> Unit): Boolean = synchronized(monitor) {
        if (activeImportId != id) return@synchronized false
        action()
        true
    }

    fun finishIfCurrent(id: String, action: () -> Unit): Boolean = synchronized(monitor) {
        if (activeImportId != id) return@synchronized false
        try {
            action()
        } finally {
            activeImportId = null
        }
        true
    }

    /**
     * Runs restart recovery only when this process has no live import worker.
     * Activity recreation shares this coordinator and therefore cannot reclaim
     * files from the process-wide worker that still owns them.
     */
    fun reconcileIfIdle(action: () -> Boolean): Boolean = synchronized(monitor) {
        if (activeImportId != null) return@synchronized false
        action()
    }

    fun <T> locked(action: () -> T): T = synchronized(monitor, action)
}

/** Process-wide import ownership survives FlutterActivity recreation. */
internal object PendingShareImportRuntime {
    val coordinator = PendingShareImportCoordinator()
    val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "conduit-share-import")
    }

    @Volatile
    var isImportInProgress: Boolean = false
}

private data class PendingShareDurableState(
    val queue: PendingSharePayloadQueue = PendingSharePayloadQueue(),
    val status: String? = null
)

class MainActivity : FlutterActivity() {
    private lateinit var backgroundStreamingHandler: BackgroundStreamingHandler
    private lateinit var nativeSttBridge: NativeSttBridge
    private lateinit var nativeTtsBridge: NativeTtsBridge

    override fun onCreate(savedInstanceState: Bundle?) {
        reconcileInterruptedShareImportIfNeeded()
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
    private val PENDING_STAGED_SHARE_BACKLOG_KEY = "pending_staged_share_backlog"
    private val PENDING_SHARE_IMPORT_STATUS_KEY = "pending_share_import_status"
    private val PENDING_SHARE_STATE_FILE_NAME = "pending-share-state-v1.json"
    private val SHARE_STAGING_DIRECTORY_NAME = "conduit-shared-intents"
    private val maxSharedFileCount = 6
    private var methodChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private var pendingStagedShareInProgress: Boolean
        get() = PendingShareImportRuntime.isImportInProgress
        set(value) {
            PendingShareImportRuntime.isImportInProgress = value
        }
    private val pendingShareImports: PendingShareImportCoordinator
        get() = PendingShareImportRuntime.coordinator
    private val pendingShareStateFile: AtomicFile by lazy {
        AtomicFile(File(noBackupFilesDir, PENDING_SHARE_STATE_FILE_NAME))
    }

    private data class PendingSharedUri(
        val uri: Uri,
        val mimeType: String?,
        val ordinal: Int
    )

    private data class ParsedPendingSharePayload(
        val payload: Map<String, Any>?,
        val candidateFilePaths: List<String>
    )

    private sealed interface SharedUriStageOutcome {
        data class Staged(val path: String, val copiedBytes: Long) : SharedUriStageOutcome
        data object LimitExceeded : SharedUriStageOutcome
        data object Failed : SharedUriStageOutcome
    }

    private enum class StagedShareFinalization {
        PAYLOAD_COMMITTED,
        FAILURE_COMMITTED,
        PERSISTENCE_FAILED,
        SUPERSEDED
    }

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
                "ackPendingShareImportPayload" -> {
                    val acknowledged =
                        ackPendingStagedSharePayload(call.argument<String>("id"))
                    result.success(acknowledged)
                    if (acknowledged && hasPendingStagedSharePayload()) {
                        notifyStagedSharePayloadReady()
                    }
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
                
                result.success(cookieValuesFromHeader(cookieString))
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
            Log.w("MainActivity", "Rejected oversized shared image URI")
            val importId = UUID.randomUUID().toString()
            if (beginShareImport(
                    id = importId,
                    expectedFileCount = 1,
                    isInProgress = false,
                    errors = listOf(shareRejectionMessage(uri, mimeType))
                )) {
                storePendingMultipleShareText(null)
                notifyStagedSharePayloadReady()
                return textOnlyShareIntent(intent, text)
            } else {
                Log.w("MainActivity", "Could not durably record rejected share")
                return intent
            }
        }
        if (!stageSharedUrisAsync(listOf(PendingSharedUri(uri, mimeType, 0)), text)) {
            return intent
        }
        storePendingMultipleShareText(null)
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
                Log.w("MainActivity", "Rejected shared URI beyond count cap")
                importErrors.add("Only the first $maxSharedFileCount shared attachments were imported.")
                return@forEachIndexed
            }
            val mimeType = mimeTypeAt(intent, index)
            if (sharedUriWithinLimits(uri, mimeType)) {
                pendingUris.add(PendingSharedUri(uri, mimeType, index))
            } else {
                Log.w("MainActivity", "Rejected oversized shared image URI")
                importErrors.add(shareRejectionMessage(uri, mimeType))
            }
        }

        if (pendingUris.isEmpty()) {
            if (importErrors.isNotEmpty()) {
                val importId = UUID.randomUUID().toString()
                if (beginShareImport(
                        id = importId,
                        expectedFileCount = originalUris.size.coerceAtMost(maxSharedFileCount),
                        isInProgress = false,
                        errors = importErrors
                    )) {
                    storePendingMultipleShareText(null)
                    notifyStagedSharePayloadReady()
                    return textOnlyShareIntent(intent, text)
                } else {
                    Log.w("MainActivity", "Could not durably record rejected share")
                }
            }
            return intent
        }

        if (!stageSharedUrisAsync(pendingUris, text, importErrors)) {
            return intent
        }
        storePendingMultipleShareText(null)
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

    private fun shareStagingDirectory(): File? {
        val stagingDirectory = File(cacheDir, SHARE_STAGING_DIRECTORY_NAME)
        try {
            if (!stagingDirectory.exists() && !stagingDirectory.mkdirs()) {
                return null
            }
            if (!isCanonicalDirectChild(stagingDirectory.path, cacheDir.path)) {
                return null
            }
            val mode = Os.lstat(stagingDirectory.absolutePath).st_mode
            return stagingDirectory.takeIf { OsConstants.S_ISDIR(mode) }
        } catch (error: Exception) {
            Log.w(
                "MainActivity",
                "Failed to inspect shared staging directory (${error.javaClass.simpleName})"
            )
            return null
        }
    }

    private fun remainingShareStagingBudgetBytes(): Long? {
        val stagingDirectory = shareStagingDirectory() ?: return null
        return remainingSharedStagingBytes(
            stagingRoot = stagingDirectory,
            maximumBytes = MAX_PENDING_SHARE_STAGED_BYTES
        ) { candidate ->
            val stat = Os.lstat(candidate.absolutePath)
            if (OsConstants.S_ISREG(stat.st_mode)) stat.st_size else null
        }
    }

    private fun stageSharedUri(
        uri: Uri,
        intentMimeType: String?,
        ordinal: Int,
        importId: String,
        maximumBytes: Long
    ): SharedUriStageOutcome {
        val resolver = contentResolver
        val mimeType = resolver.getType(uri) ?: intentMimeType
        val displayName = displayNameForUri(resolver, uri)
        val stagingDirectory = shareStagingDirectory()
            ?: return SharedUriStageOutcome.Failed

        val destination = File(
            stagingDirectory,
            uniqueStagingFileName(importId, displayName, mimeType, ordinal)
        )
        return try {
            val input = resolver.openInputStream(uri)
                ?: return SharedUriStageOutcome.Failed
            val copiedBytes = input.use {
                copySharedStreamToFileWithinLimit(it, destination, maximumBytes)
            }
            if (copiedBytes == null) {
                Log.w(
                    "MainActivity",
                    "Rejected shared URI during staging because it exceeded $maximumBytes bytes"
                )
                SharedUriStageOutcome.LimitExceeded
            } else {
                SharedUriStageOutcome.Staged(destination.path, copiedBytes)
            }
        } catch (error: Exception) {
            deleteOwnedStagedPaths(listOf(destination.path))
            Log.w(
                "MainActivity",
                "Failed to stage shared URI (${error.javaClass.simpleName})"
            )
            SharedUriStageOutcome.Failed
        }
    }

    private fun stageSharedUrisAsync(
        uris: List<PendingSharedUri>,
        text: String?,
        initialErrors: List<String> = emptyList()
    ): Boolean {
        val importId = UUID.randomUUID().toString()
        if (!beginShareImport(
                id = importId,
                expectedFileCount = uris.size,
                isInProgress = true,
                errors = initialErrors
            )) {
            Log.w("MainActivity", "Could not durably begin staged share import")
            return false
        }
        notifyStagedSharePayloadReady()
        PendingShareImportRuntime.executor.execute {
            val stagedPaths = ArrayList<String>()
            val errors = ArrayList(initialErrors)
            try {
                var remainingAggregateBytes = remainingShareStagingBudgetBytes()
                if (remainingAggregateBytes == null) {
                    errors.add("Could not inspect shared content storage. Please try again.")
                } else {
                    uris.forEach { pending ->
                        val perFileLimit = sharedUriMaximumBytes(
                            pending.uri,
                            pending.mimeType
                        )
                        val copyLimit = minOf(perFileLimit, remainingAggregateBytes!!)
                        val knownSize = sharedUriSizeBytes(contentResolver, pending.uri)
                        if (knownSize != null && knownSize > copyLimit) {
                            Log.w("MainActivity", "Rejected oversized shared URI")
                            errors.add(
                                if (knownSize > perFileLimit) {
                                    shareRejectionMessage(pending.uri, pending.mimeType)
                                } else {
                                    aggregateShareRejectionMessage()
                                }
                            )
                            return@forEach
                        }

                        when (val outcome = stageSharedUri(
                            uri = pending.uri,
                            intentMimeType = pending.mimeType,
                            ordinal = pending.ordinal,
                            importId = importId,
                            maximumBytes = copyLimit
                        )) {
                            is SharedUriStageOutcome.Staged -> {
                                stagedPaths.add(outcome.path)
                                remainingAggregateBytes =
                                    remainingAggregateBytes!! - outcome.copiedBytes
                            }
                            SharedUriStageOutcome.LimitExceeded -> {
                                errors.add(
                                    if (copyLimit < perFileLimit) {
                                        aggregateShareRejectionMessage()
                                    } else {
                                        shareRejectionMessage(pending.uri, pending.mimeType)
                                    }
                                )
                            }
                            SharedUriStageOutcome.Failed -> {
                                Log.w("MainActivity", "Failed to stage accepted shared URI")
                                errors.add(
                                    "Could not import ${displayNameForUri(contentResolver, pending.uri) ?: "shared file"}."
                                )
                            }
                        }
                    }
                }
                when (finalizePendingStagedSharePayload(
                        importId,
                        text,
                        stagedPaths,
                        expectedFileCount = uris.size,
                        errors = errors
                    )) {
                    StagedShareFinalization.PAYLOAD_COMMITTED -> Unit
                    StagedShareFinalization.FAILURE_COMMITTED -> {
                        deleteOwnedStagedPaths(stagedPaths)
                    }
                    StagedShareFinalization.PERSISTENCE_FAILED -> {
                        // Neither commit established a durable payload owner,
                        // so these process-owned copies cannot be recovered by
                        // the take/ack path and must not be orphaned.
                        deleteOwnedStagedPaths(stagedPaths)
                        Log.w(
                            "MainActivity",
                            "Staged share state could not be persisted"
                        )
                    }
                    StagedShareFinalization.SUPERSEDED -> {
                        deleteStagedPaths(stagedPaths)
                    }
                }
            } finally {
                val finishedCurrentImport = pendingShareImports.finishIfCurrent(importId) {
                    pendingStagedShareInProgress = false
                }
                if (finishedCurrentImport) {
                    notifyStagedSharePayloadReady()
                }
            }
        }
        return true
    }

    private fun notifyStagedSharePayloadReady() {
        runOnUiThread {
            shareChannel?.invokeMethod("stagedSharePayloadReady", null)
        }
    }

    /**
     * A process restart loses the URI grant and executor continuation, so an
     * in-progress durable status can no longer finish. Reclaim only files whose
     * exact UUID prefix belongs to that import, then atomically terminalize the
     * same status. The process-wide coordinator makes this a no-op during an
     * Activity recreation while its original worker is still alive.
     */
    private fun reconcileInterruptedShareImportIfNeeded() {
        var attempted = false
        var completed = false
        pendingShareImports.reconcileIfIdle reconciliation@{
            val state = pendingShareState() ?: return@reconciliation false
            val terminalStatus = interruptedShareImportStatus(
                parsePendingShareImportStatusState(state.status)
            ) ?: return@reconciliation true
            attempted = true

            val stagingDirectory = shareStagingDirectory()
                ?: return@reconciliation false
            val cleaned = cleanupInterruptedShareImportFiles(
                stagingRoot = stagingDirectory,
                importId = terminalStatus.id,
                isRegularFileNoFollow = { candidate ->
                    OsConstants.S_ISREG(Os.lstat(candidate.absolutePath).st_mode)
                }
            )
            if (!cleaned) return@reconciliation false

            completed = writePendingShareState(
                state.copy(
                    status = pendingShareImportStatusJson(
                        id = terminalStatus.id,
                        expectedFileCount = terminalStatus.expectedFileCount,
                        isInProgress = false,
                        errors = terminalStatus.errors
                    ).toString()
                )
            )
            if (completed) {
                pendingStagedShareInProgress = false
            }
            completed
        }
        if (attempted && !completed) {
            Log.w("MainActivity", "Interrupted shared content cleanup was deferred")
        }
    }

    private fun beginShareImport(
        id: String,
        expectedFileCount: Int,
        isInProgress: Boolean,
        errors: List<String> = emptyList()
    ): Boolean {
        val began = pendingShareImports.begin(id) durableBegin@{
            val existingState = pendingShareState()
                ?: return@durableBegin false
            val retiredQueue = existingState.queue.retireCurrent(
                replacementId = id,
                idForRaw = ::pendingSharePayloadId
            )
            // Queue ownership and import status are one AtomicFile generation;
            // a failed write leaves the complete previous state recoverable.
            val committed = writePendingShareState(
                existingState.copy(
                    queue = retiredQueue,
                    status = pendingShareImportStatusJson(
                        id = id,
                        expectedFileCount = expectedFileCount,
                        isInProgress = isInProgress,
                        errors = errors
                    ).toString()
                )
            )
            if (committed) {
                pendingStagedShareInProgress = isInProgress
            }
            committed
        }
        if (began && !isInProgress) {
            pendingShareImports.finishIfCurrent(id) {}
        }
        return began
    }

    private fun deleteStagedPaths(paths: List<String>) {
        paths.forEach { path ->
            try {
                File(path).delete()
            } catch (_: Exception) {
            }
        }
    }

    private fun deleteOwnedStagedPaths(paths: List<String>) {
        val stagingRoot = File(cacheDir, SHARE_STAGING_DIRECTORY_NAME)
        paths.forEach { candidatePath ->
            try {
                if (!isCanonicalDirectChild(candidatePath, stagingRoot.path)) {
                    return@forEach
                }
                val candidate = File(candidatePath)
                val mode = Os.lstat(candidate.absolutePath).st_mode
                if (!OsConstants.S_ISREG(mode)) return@forEach
                if (!candidate.delete()) {
                    Log.w("MainActivity", "Owned staged share cleanup was deferred")
                }
            } catch (error: Exception) {
                Log.w(
                    "MainActivity",
                    "Owned staged share cleanup failed (${error.javaClass.simpleName})"
                )
            }
        }
    }

    private fun sharedUriWithinLimits(uri: Uri, intentMimeType: String?): Boolean {
        val sizeBytes = sharedUriSizeBytes(contentResolver, uri)
        return sizeBytes == null ||
            sizeBytes <= sharedUriMaximumBytes(uri, intentMimeType)
    }

    private fun sharedUriMaximumBytes(uri: Uri, intentMimeType: String?): Long {
        val resolver = contentResolver
        val mimeType = resolver.getType(uri) ?: intentMimeType
        return if (sharedUriIsImage(mimeType, displayNameForUri(resolver, uri))) {
            MAX_SHARED_IMAGE_BYTES
        } else {
            MAX_SHARED_GENERIC_FILE_BYTES
        }
    }

    private fun shareRejectionMessage(uri: Uri, intentMimeType: String?): String {
        val displayName = displayNameForUri(contentResolver, uri) ?: "shared file"
        val mimeType = contentResolver.getType(uri) ?: intentMimeType
        return if (sharedUriIsImage(mimeType, displayName)) {
            "$displayName is larger than the 20 MB image limit."
        } else {
            "$displayName is larger than the 100 MB file limit."
        }
    }

    private fun aggregateShareRejectionMessage(): String =
        "Pending shared content is full. Finish importing older shared content and try again."

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
            Log.w(
                "MainActivity",
                "Failed to query shared URI size (${error.javaClass.simpleName})"
            )
        }

        return try {
            resolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.length.takeIf { it >= 0L }
            }
        } catch (error: Exception) {
            Log.w(
                "MainActivity",
                "Failed to open shared URI descriptor (${error.javaClass.simpleName})"
            )
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
        importId: String,
        displayName: String?,
        mimeType: String?,
        ordinal: Int
    ): String {
        val importPrefix = checkNotNull(shareImportStagingFilePrefix(importId))
        val sanitizedName = sanitizeFileName(displayName) ?: "shared-file"
        val fileName = ensureFileExtension(sanitizedName, mimeType)
        return "$importPrefix${UUID.randomUUID()}-$ordinal-$fileName"
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

    private fun pendingSharePayloadId(raw: String): String? {
        return parsePendingSharePayload(raw).payload?.get("id") as? String
    }

    private fun decodePendingSharePayloadBacklog(raw: String?): List<String>? {
        if (raw == null) return emptyList()
        return try {
            val array = JSONArray(raw)
            buildList(array.length()) {
                for (index in 0 until array.length()) {
                    val record = array.opt(index) as? String ?: return null
                    if (record.isEmpty()) return null
                    add(record)
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun encodePendingShareState(state: PendingShareDurableState): String {
        return JSONObject()
            .put("version", 1)
            .put("backlog", JSONArray(state.queue.backlog))
            .apply {
                state.queue.current?.let { put("current", it) }
                state.status?.let { put("status", it) }
            }
            .toString()
    }

    private fun decodePendingShareState(raw: String): PendingShareDurableState? {
        return try {
            val json = JSONObject(raw)
            if (json.optInt("version", -1) != 1) return null
            val backlogJson = json.optJSONArray("backlog") ?: JSONArray()
            val backlog = buildList(backlogJson.length()) {
                for (index in 0 until backlogJson.length()) {
                    val record = backlogJson.opt(index) as? String ?: return null
                    if (record.isEmpty()) return null
                    add(record)
                }
            }
            val currentValue = json.opt("current")
            val current = when (currentValue) {
                null, JSONObject.NULL -> null
                is String -> currentValue.takeIf { it.isNotEmpty() } ?: return null
                else -> return null
            }
            val statusValue = json.opt("status")
            val status = when (statusValue) {
                null, JSONObject.NULL -> null
                is String -> statusValue.takeIf { it.isNotEmpty() } ?: return null
                else -> return null
            }
            PendingShareDurableState(
                queue = PendingSharePayloadQueue(backlog = backlog, current = current),
                status = status
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun writePendingShareState(state: PendingShareDurableState): Boolean {
        var output: FileOutputStream? = null
        return try {
            val stream = pendingShareStateFile.startWrite()
            output = stream
            stream.write(
                encodePendingShareState(state).toByteArray(StandardCharsets.UTF_8)
            )
            pendingShareStateFile.finishWrite(stream)
            output = null
            true
        } catch (error: Exception) {
            output?.let { stream ->
                try {
                    pendingShareStateFile.failWrite(stream)
                } catch (_: Exception) {
                }
            }
            Log.w(
                "MainActivity",
                "Pending share state write failed (${error.javaClass.simpleName})"
            )
            false
        }
    }

    private fun migrateLegacyPendingShareState(): PendingShareDurableState? {
        val prefs = getSharedPreferences(SHARE_TEXT_PREFS_NAME, Context.MODE_PRIVATE)
        val hasLegacyState = prefs.contains(PENDING_STAGED_SHARE_BACKLOG_KEY) ||
            prefs.contains(PENDING_STAGED_SHARE_PAYLOAD_KEY) ||
            prefs.contains(PENDING_SHARE_IMPORT_STATUS_KEY)
        if (!hasLegacyState) return PendingShareDurableState()

        val backlog = decodePendingSharePayloadBacklog(
            prefs.getString(PENDING_STAGED_SHARE_BACKLOG_KEY, null)
        ) ?: return null
        val state = PendingShareDurableState(
            queue = PendingSharePayloadQueue(
                backlog = backlog,
                current = prefs.getString(PENDING_STAGED_SHARE_PAYLOAD_KEY, null)
            ),
            status = prefs.getString(PENDING_SHARE_IMPORT_STATUS_KEY, null)
        )
        if (!writePendingShareState(state)) return null

        // AtomicFile is canonical once published. A failed legacy cleanup is
        // harmless because future reads no longer consult SharedPreferences.
        if (!prefs.edit()
                .remove(PENDING_STAGED_SHARE_BACKLOG_KEY)
                .remove(PENDING_STAGED_SHARE_PAYLOAD_KEY)
                .remove(PENDING_SHARE_IMPORT_STATUS_KEY)
                .commit()
        ) {
            Log.w("MainActivity", "Legacy pending share state cleanup was deferred")
        }
        return state
    }

    private fun pendingShareState(): PendingShareDurableState? {
        return try {
            // Always let AtomicFile.openRead() restore an interrupted write's
            // backup before deciding that no canonical state exists.
            pendingShareStateFile.openRead().bufferedReader(StandardCharsets.UTF_8).use {
                decodePendingShareState(it.readText())
            }
        } catch (_: FileNotFoundException) {
            migrateLegacyPendingShareState()
        } catch (error: Exception) {
            Log.w(
                "MainActivity",
                "Pending share state read failed (${error.javaClass.simpleName})"
            )
            null
        }
    }

    private fun finalizePendingStagedSharePayload(
        id: String,
        text: String?,
        filePaths: List<String>,
        expectedFileCount: Int,
        errors: List<String>
    ): StagedShareFinalization {
        var payloadCommitted = false
        var failureCommitted = false
        val finalization = pendingShareImports.finalizeIfCurrent(id) {
            val trimmed = text?.trim()?.takeIf { it.isNotEmpty() }
            val existingState = pendingShareState()
                ?: return@finalizeIfCurrent false
            var rawPayload: String? = null
            if (trimmed != null || filePaths.isNotEmpty()) {
                rawPayload = JSONObject()
                    .put("id", id)
                    .put("filePaths", JSONArray(filePaths))
                    .apply {
                        if (trimmed != null) put("text", trimmed)
                    }
                    .toString()
            }
            val admission = existingState.queue.admitCurrent(
                raw = rawPayload,
                replacementId = id,
                idForRaw = ::pendingSharePayloadId,
                stagedBytesForRaw = ::pendingSharePayloadStagedBytes
            )
            if (!admission.admitted) {
                failureCommitted = writePendingShareState(
                    existingState.copy(
                        queue = admission.queue,
                        status = pendingShareImportStatusJson(
                            id = id,
                            expectedFileCount = expectedFileCount,
                            isInProgress = false,
                            errors = errors +
                                "Pending shared content is full. Finish importing older shared content and try again."
                        ).toString()
                    )
                )
                if (failureCommitted) pendingStagedShareInProgress = false
                return@finalizeIfCurrent failureCommitted
            }

            payloadCommitted = writePendingShareState(
                existingState.copy(
                    queue = admission.queue,
                    status = pendingShareImportStatusJson(
                        id = id,
                        expectedFileCount = expectedFileCount,
                        isInProgress = false,
                        errors = errors
                    ).toString()
                )
            )
            if (payloadCommitted) {
                pendingStagedShareInProgress = false
                return@finalizeIfCurrent true
            }

            failureCommitted = writePendingShareState(
                existingState.copy(
                    status = pendingShareImportStatusJson(
                        id = id,
                        expectedFileCount = expectedFileCount,
                        isInProgress = false,
                        errors = errors +
                            "Could not durably finish the shared content import."
                    ).toString()
                )
            )
            if (failureCommitted) {
                pendingStagedShareInProgress = false
            }
            failureCommitted
        }

        return when {
            finalization == PendingShareFinalization.SUPERSEDED -> {
                StagedShareFinalization.SUPERSEDED
            }
            payloadCommitted -> StagedShareFinalization.PAYLOAD_COMMITTED
            failureCommitted -> StagedShareFinalization.FAILURE_COMMITTED
            else -> StagedShareFinalization.PERSISTENCE_FAILED
        }
    }

    private fun pendingShareImportStatusJson(
        id: String,
        expectedFileCount: Int,
        isInProgress: Boolean,
        errors: List<String>
    ): JSONObject = JSONObject()
        .put("id", id)
        .put("expectedFileCount", expectedFileCount)
        .put("isInProgress", isInProgress)
        .put("errors", JSONArray(errors.distinct()))

    private fun parsePendingShareImportStatusState(
        raw: String?
    ): PendingShareImportStatusState? {
        if (raw == null) return null
        return try {
            val json = JSONObject(raw)
            val errors = ArrayList<String>()
            val rawErrors = json.optJSONArray("errors")
            if (rawErrors != null) {
                for (index in 0 until rawErrors.length()) {
                    rawErrors.optString(index)
                        .trim()
                        .takeIf { it.isNotEmpty() }
                        ?.let(errors::add)
                }
            }
            PendingShareImportStatusState(
                id = json.optString("id"),
                expectedFileCount = json.optInt("expectedFileCount", 0).coerceAtLeast(0),
                isInProgress = json.optBoolean("isInProgress", false),
                errors = errors
            )
        } catch (error: Exception) {
            Log.w(
                "MainActivity",
                "Failed to parse pending share import status (${error.javaClass.simpleName})"
            )
            null
        }
    }

    private fun pendingShareImportStatus(): Map<String, Any>? {
        return pendingShareImports.locked statusLock@{
            val status = parsePendingShareImportStatusState(
                pendingShareState()?.status
            ) ?: return@statusLock null

            hashMapOf(
                "id" to status.id,
                "expectedFileCount" to status.expectedFileCount,
                "isInProgress" to status.isInProgress,
                "errors" to ArrayList(status.errors)
            )
        }
    }

    private fun clearShareImportStatus(id: String?) {
        var writeFailed = false
        pendingShareImports.locked {
            val state = pendingShareState() ?: run {
                writeFailed = true
                return@locked
            }
            if (id != null) {
                val currentId = try {
                    state.status?.let {
                        JSONObject(it).optString("id").takeIf { value -> value.isNotEmpty() }
                    }
                } catch (_: Exception) {
                    null
                }
                if (currentId != null && currentId != id) {
                    return@locked
                }
            }

            if (!writePendingShareState(state.copy(status = null))) {
                writeFailed = true
            }
        }
        if (writeFailed) {
            Log.w("MainActivity", "Pending share import status cleanup was deferred")
        }
    }

    private fun hasPendingStagedSharePayload(): Boolean {
        return pendingShareImports.locked {
            if (pendingStagedShareInProgress) return@locked true
            val state = pendingShareState()
            state?.let { it.queue.hasRecords || it.status != null }
                ?: pendingShareStateFile.baseFile.exists()
        }
    }

    private fun parsePendingSharePayload(raw: String): ParsedPendingSharePayload {
        return try {
            val json = JSONObject(raw)
            val filePaths = ArrayList<String>()
            val files = json.optJSONArray("filePaths")
            if (files != null) {
                for (index in 0 until files.length()) {
                    (files.opt(index) as? String)
                        ?.trim()
                        ?.takeIf { it.isNotEmpty() }
                        ?.let(filePaths::add)
                }
            }
            val payload = validatedPendingSharePayload(
                id = json.opt("id") as? String,
                text = json.opt("text") as? String,
                filePaths = filePaths
            )
            ParsedPendingSharePayload(payload, filePaths)
        } catch (_: Exception) {
            ParsedPendingSharePayload(null, emptyList())
        }
    }

    private fun pendingSharePayloadStagedBytes(raw: String): Long? {
        val parsed = parsePendingSharePayload(raw)
        if (parsed.payload == null) return null
        val stagingRoot = File(cacheDir, SHARE_STAGING_DIRECTORY_NAME)
        var total = 0L
        for (path in parsed.candidateFilePaths) {
            if (!isCanonicalDirectChild(path, stagingRoot.path)) return null
            val size = try {
                val stat = Os.lstat(path)
                if (!OsConstants.S_ISREG(stat.st_mode)) return null
                stat.st_size
            } catch (_: Exception) {
                return null
            }
            if (size < 0L || size > Long.MAX_VALUE - total) return null
            total += size
        }
        return total
    }

    private fun takePendingStagedSharePayload(): Map<String, Any>? {
        val corruptOwnedPaths = ArrayList<String>()
        val payload: Map<String, Any>? = pendingShareImports.locked queueLock@{
            var state = pendingShareState() ?: return@queueLock null
            var queue = state.queue

            var resolvedPayload: Map<String, Any>? = null
            while (true) {
                val selection = queue.peek() ?: break
                val parsed = parsePendingSharePayload(selection.raw)
                if (parsed.payload != null) {
                    resolvedPayload = parsed.payload
                    break
                }

                val updatedQueue = queue.removing(selection)
                val updatedState = state.copy(
                    queue = updatedQueue,
                    status = if (selection.backlogIndex == null) null else state.status
                )
                if (!writePendingShareState(updatedState)) {
                    Log.w("MainActivity", "Malformed staged share payload cleanup was deferred")
                    return@queueLock null
                }
                corruptOwnedPaths.addAll(parsed.candidateFilePaths)
                state = updatedState
                queue = updatedQueue
            }
            resolvedPayload
        }
        deleteOwnedStagedPaths(corruptOwnedPaths)
        return payload
    }

    private fun ackPendingStagedSharePayload(id: String?): Boolean {
        val expectedId = id?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        return pendingShareImports.locked {
            val state = pendingShareState() ?: return@locked false
            val acknowledgement = state.queue.acknowledge(
                expectedId = expectedId,
                idForRaw = ::pendingSharePayloadId
            )
            if (!acknowledgement.acknowledged) return@locked false
            writePendingShareState(state.copy(queue = acknowledgement.queue))
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

        val screenContext = intent.getStringExtra("screen_context")
        val screenshotPath = intent.getStringExtra("screenshot_path")
        val startVoiceCall = intent.getBooleanExtra("start_voice_call", false)
        val startNewChat = intent.getBooleanExtra("start_new_chat", false)

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
            Log.d("MainActivity", "Invoking analyzeScreenshot")
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
