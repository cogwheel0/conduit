package app.cogwheel.conduit

import android.os.Build
import android.util.Log
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.GenerateContentRequest
import com.google.mlkit.genai.prompt.GenerateContentResponse
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Exposes Gemini Nano inside Android's AICore system service to Conduit's
 * Dart layer over the generated AicoreHostApi/AicoreFlutterApi bindings.
 *
 * The ML Kit GenAI Prompt API binds to AICore, so every call below can fail
 * with a binding or download error on devices without the service. Status
 * probes are the only path that may run before a download; inference waits
 * for [FeatureStatus.AVAILABLE] and reports failures as stream error events
 * instead of throwing across the channel.
 */
class AicoreBridge(messenger: BinaryMessenger) : AicoreHostApi {
    private val flutterApi = AicoreFlutterApi(messenger)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val runs = mutableMapOf<String, Job>()
    @Volatile
    private var model: GenerativeModel? = null

    fun setup(flutterEngine: FlutterEngine) {
        AicoreHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    fun dispose() {
        runs.values.forEach { it.cancel() }
        runs.clear()
        try {
            model?.close()
        } catch (_: Exception) {
        }
        model = null
        scope.cancel()
    }

    private fun obtainModel(): GenerativeModel {
        val existing = model
        if (existing != null) return existing
        val created = Generation.getClient()
        model = created
        return created
    }

    override fun getStatus(callback: (Result<PlatformAicoreStatus>) -> Unit) {
        scope.launch {
            callback(Result.success(runCatching { statusInternal() }.getOrElse { error ->
                Log.w(TAG, "AICore status probe failed", error)
                PlatformAicoreStatus(
                    status = PlatformAicoreStatusKind.UNAVAILABLE,
                    message = friendlyStatusMessage(error),
                )
            }))
        }
    }

    private suspend fun statusInternal(): PlatformAicoreStatus {
        if (Build.VERSION.SDK_INT < MIN_SUPPORTED_SDK) {
            return PlatformAicoreStatus(
                status = PlatformAicoreStatusKind.UNAVAILABLE,
                message = "Gemini Nano requires Android 8.0 or newer.",
            )
        }
        val generativeModel = obtainModel()
        val featureStatus = generativeModel.checkStatus()
        val status = when (featureStatus) {
            FeatureStatus.AVAILABLE -> PlatformAicoreStatusKind.AVAILABLE
            FeatureStatus.DOWNLOADABLE -> PlatformAicoreStatusKind.DOWNLOADABLE
            FeatureStatus.DOWNLOADING -> PlatformAicoreStatusKind.DOWNLOADING
            else -> PlatformAicoreStatusKind.UNAVAILABLE
        }
        val tokenLimit = runCatching { generativeModel.getTokenLimit() }
            .getOrNull()
            ?.takeIf { it > 0 }
            ?.let { it.toLong() }
        if (status == PlatformAicoreStatusKind.UNAVAILABLE) {
            // A successful token-limit probe proves the AICore service binding
            // itself works, which isolates a feature-level refusal from a
            // failed bind when diagnosing devices that do have Gemini Nano.
            val binding = runCatching { generativeModel.getTokenLimit() }
            val detail = binding.exceptionOrNull()?.let { error ->
                " Binding to the AICore service failed: ${friendlyReason(error)}"
            } ?: "."
            return PlatformAicoreStatus(
                status = status,
                message = "Gemini Nano is installed but the prompt feature is not available$detail",
            )
        }
        return PlatformAicoreStatus(status = status, tokenLimit = tokenLimit)
    }

    override fun downloadModel(callback: (Result<Boolean>) -> Unit) {
        scope.launch {
            callback(Result.success(runCatching { downloadInternal() }.getOrElse { error ->
                if (error is CancellationException) throw error
                Log.w(TAG, "AICore model download failed", error)
                false
            }))
        }
    }

    private suspend fun downloadInternal(): Boolean {
        if (Build.VERSION.SDK_INT < MIN_SUPPORTED_SDK) return false
        val generativeModel = obtainModel()
        if (generativeModel.checkStatus() == FeatureStatus.AVAILABLE) return true
        val downloads: Flow<DownloadStatus> = generativeModel.download()
        var completed = false
        // AICore downloads are multi-hundred-megabyte system downloads; bound
        // the wait so a stalled transfer cannot hold the status UI forever.
        withTimeoutOrNull(DOWNLOAD_TIMEOUT_MILLIS) {
            // Progress callbacks can be frequent; keep them off the main
            // thread. Event emission hops back to Main in the emit helpers.
            withContext(Dispatchers.Default) {
                downloads.collect { status ->
                    when (status) {
                        is DownloadStatus.DownloadCompleted -> completed = true
                        is DownloadStatus.DownloadFailed -> throw status.e
                        else -> Unit
                    }
                }
            }
        } ?: return false
        return completed && generativeModel.checkStatus() == FeatureStatus.AVAILABLE
    }

    override fun start(request: PlatformAicoreCompletionRequest) {
        scope.launch {
            startInternal(request)
        }
    }

    private suspend fun startInternal(request: PlatformAicoreCompletionRequest) {
        try {
            Log.i(
                TAG,
                "start: runId=${request.runId.take(8)} turns=${request.messages.size}",
            )
            val generativeModel = obtainModel()
            if (Build.VERSION.SDK_INT < MIN_SUPPORTED_SDK) {
                throw IllegalStateException("Gemini Nano requires Android 8.0 or newer.")
            }
            if (generativeModel.checkStatus() != FeatureStatus.AVAILABLE) {
                throw IllegalStateException(
                    "Gemini Nano is not ready on this device. Check the connection settings."
                )
            }
            Log.i(TAG, "start: checkStatus ok")

            val systemText = request.messages
                .filter { it.role == ROLE_SYSTEM }
                .joinToString("\n\n") { it.content }
                .trim()
            val turns = request.messages.filter { it.role != ROLE_SYSTEM }
            val prompt = buildPrompt(turns)
            if (prompt.isEmpty()) {
                throw IllegalArgumentException("The request contained no message content.")
            }

            val builder = generateContentRequest(TextPart(prompt)) {
                request.temperature?.let { temperature = it.toFloat() }
                request.topK?.let { topK = it.toInt() }
                request.seed?.let { seed = it.toInt() }
                request.maxOutputTokens?.let { maxOutputTokens = it.toInt() }
                if (systemText.isNotEmpty()) {
                    systemInstruction = SystemInstruction(systemText)
                }
            }
            val job = scope.launch {
                runStreaming(request.runId, generativeModel, builder)
            }
            runs[request.runId] = job
            job.invokeOnCompletion {
                runs.remove(request.runId)
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            Log.w(TAG, "AICore inference failed to start", error)
            emitError(request.runId, friendlyInferenceMessage(error))
        }
    }

    /**
     * Gemini Nano receives a flat prompt: a single user turn plus an optional
     * system instruction. Multi-turn history is rendered as an explicit
     * transcript ending in an assistant cue, which keeps speaker turns
     * unambiguous without relying on undocumented turn semantics.
     */
    private fun buildPrompt(turns: List<PlatformAicoreMessage>): String {
        if (turns.isEmpty()) return ""
        if (turns.size == 1 && turns[0].role == ROLE_USER) {
            return turns[0].content
        }
        return turns.joinToString(separator = "\n\n") { message ->
            val speaker = if (message.role == ROLE_USER) "User" else "Assistant"
            "$speaker: ${message.content}"
        } + "\n\nAssistant:"
    }

    private suspend fun runStreaming(
        runId: String,
        generativeModel: GenerativeModel,
        request: GenerateContentRequest,
    ) {
        val startedAt = android.os.SystemClock.elapsedRealtime()
        var firstChunkAt = -1L
        var chunkCount = 0
        var emittedCharacters = 0
        try {
            val stream = generativeModel.generateContentStream(request)
            // Nano on the TPU emits chunks faster than the UI thread should
            // spend on channel encoding, so collect on a worker dispatcher;
            // each emit hops to Main for the platform channel send.
            withContext(Dispatchers.Default) {
                stream.collect { chunk: GenerateContentResponse ->
                    val text = chunk.candidates.firstOrNull()?.text
                    if (!text.isNullOrEmpty()) {
                        if (firstChunkAt < 0L) {
                            firstChunkAt =
                                android.os.SystemClock.elapsedRealtime() - startedAt
                            Log.i(TAG, "first chunk after ${firstChunkAt}ms")
                        }
                        chunkCount++
                        emittedCharacters += text.length
                        emitContent(runId, text)
                    }
                }
            }
            Log.i(
                TAG,
                "stream done: chunks=$chunkCount firstChunk=${firstChunkAt}ms " +
                    "total=${android.os.SystemClock.elapsedRealtime() - startedAt}ms " +
                    "chars=$emittedCharacters",
            )
            emitDone(runId)
        } catch (error: Throwable) {
            if (error is CancellationException) {
                Log.i(
                    TAG,
                    "stream cancelled: chunks=$chunkCount " +
                        "firstChunk=${firstChunkAt}ms " +
                        "elapsed=${android.os.SystemClock.elapsedRealtime() - startedAt}ms",
                )
                emitDone(runId)
            } else {
                Log.w(TAG, "AICore inference failed", error)
                emitError(runId, friendlyInferenceMessage(error))
            }
        }
    }

    override fun cancel(runId: String) {
        runs.remove(runId)?.cancel()
    }

    private fun emitContent(runId: String, text: String) {
        scope.launch {
            flutterApi.onEvent(
                PlatformAicoreStreamEvent(
                    runId = runId,
                    kind = PlatformAicoreEventKind.CONTENT,
                    content = text,
                )
            ) { _ -> }
        }
    }

    private fun emitError(runId: String, message: String) {
        scope.launch {
            flutterApi.onEvent(
                PlatformAicoreStreamEvent(
                    runId = runId,
                    kind = PlatformAicoreEventKind.ERROR,
                    content = message,
                )
            ) { _ -> }
        }
    }

    private fun emitDone(runId: String) {
        scope.launch {
            flutterApi.onEvent(
                PlatformAicoreStreamEvent(
                    runId = runId,
                    kind = PlatformAicoreEventKind.DONE,
                )
            ) { _ -> }
        }
    }

    private fun friendlyReason(error: Throwable): String {
        val message = error.message?.takeIf { it.isNotBlank() }
        val name = error.javaClass.simpleName
        return if (message != null) "$name: $message" else name
    }

    private fun friendlyStatusMessage(error: Throwable): String {
        val detail = friendlyReason(error).let { ": $it" }
        return "Gemini Nano is not available on this device$detail"
    }

    private fun friendlyInferenceMessage(error: Throwable): String {
        val detail = friendlyReason(error).let { ": $it" }
        return "Gemini Nano inference failed$detail"
    }

    companion object {
        private const val TAG = "AicoreBridge"
        private const val MIN_SUPPORTED_SDK = Build.VERSION_CODES.O
        private const val DOWNLOAD_TIMEOUT_MILLIS = 30L * 60L * 1000L
        private const val ROLE_SYSTEM = "system"
        private const val ROLE_USER = "user"
    }
}