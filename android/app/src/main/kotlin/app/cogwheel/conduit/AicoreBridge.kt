package app.cogwheel.conduit

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONObject
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
class AicoreBridge(private val appContext: Context, messenger: BinaryMessenger) : AicoreHostApi {
    private val flutterApi = AicoreFlutterApi(messenger)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val runs = mutableMapOf<String, Job>()
    private val actionExecutor by lazy { DeviceActionExecutor(appContext) }
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

            val systemText = listOfNotNull(
                request.messages
                    .filter { it.role == ROLE_SYSTEM }
                    .joinToString("\n\n") { it.content }
                    .trim()
                    .takeIf { it.isNotEmpty() },
                if (request.deviceTools) DEVICE_TOOL_SCHEMA else null,
            ).filterNotNull().joinToString("\n\n")
            val turns = request.messages.filter { it.role != ROLE_SYSTEM }
            if (turns.isEmpty()) {
                throw IllegalArgumentException("The request contained no message content.")
            }

            val job = scope.launch {
                try {
                    runConversationTurn(
                        runId = request.runId,
                        generativeModel = generativeModel,
                        systemText = systemText,
                        turns = turns,
                        deviceTools = request.deviceTools,
                        toolRoundsRemaining = MAX_TOOL_ROUNDS,
                        temperature = request.temperature,
                        topK = request.topK,
                        seed = request.seed,
                        maxOutputTokens = request.maxOutputTokens,
                    )
                } catch (error: Throwable) {
                    if (error is CancellationException) {
                        // Cancellation reaches Dart through its own cancel
                        // channel; still terminate the event stream.
                    } else {
                        Log.w(TAG, "AICore turn failed", error)
                        emitError(request.runId, friendlyInferenceMessage(error))
                    }
                } finally {
                    // The turn is only complete for listeners once the event
                    // stream reaches a terminal event, however many tool
                    // rounds ran before it.
                    emitDone(request.runId)
                }
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
     * One generation pass plus the device-action loop. A reply that is a
     * valid whitelisted tool-call is executed and the narration is appended
     * as a user turn before the model writes its user-facing answer; any
     * other reply streams straight to Dart.
     */
    private suspend fun runConversationTurn(
        runId: String,
        generativeModel: GenerativeModel,
        systemText: String,
        turns: List<PlatformAicoreMessage>,
        deviceTools: Boolean,
        toolRoundsRemaining: Int,
        temperature: Double? = null,
        topK: Long? = null,
        seed: Long? = null,
        maxOutputTokens: Long? = null,
    ) {
        val request = buildRequest(
            prompt = buildPrompt(turns),
            systemText = systemText,
            temperature = temperature,
            topK = topK,
            seed = seed,
            maxOutputTokens = maxOutputTokens,
        )
        val fullText = streamWithToolDetection(
            runId = runId,
            generativeModel = generativeModel,
            request = request,
            deviceTools = deviceTools,
        )
        if (!deviceTools) return
        val call = DeviceActionParser.parse(fullText) ?: return
        val result = actionExecutor.execute(call.name, call.args)
        emitToolCall(
            runId,
            JSONObject()
                .put("name", call.name)
                .put("args", call.args)
                .put("result", result)
                .toString(),
        )
        if (toolRoundsRemaining <= 0) {
            // The whitelist is exhausted; narrate the outcome directly.
            emitContent(runId, result)
            return
        }
        runConversationTurn(
            runId = runId,
            generativeModel = generativeModel,
            systemText = systemText,
            turns = turns +
                PlatformAicoreMessage(role = ROLE_ASSISTANT, content = fullText.trim()) +
                PlatformAicoreMessage(
                    role = ROLE_USER,
                    content = "Tool result: $result. Reply to the user in one or two sentences.",
                ),
            deviceTools = deviceTools,
            toolRoundsRemaining = toolRoundsRemaining - 1,
            temperature = temperature,
            topK = topK,
            seed = seed,
            maxOutputTokens = maxOutputTokens,
        )
    }

    /**
     * Streams a generation, buffering the reply while it still looks like a
     * tool-call (leading `{` or code fence) so the user never sees raw JSON.
     * Non-tool replies switch to live streaming after the first chunk.
     * Returns the complete reply text.
     */
    private suspend fun streamWithToolDetection(
        runId: String,
        generativeModel: GenerativeModel,
        request: GenerateContentRequest,
        deviceTools: Boolean,
    ): String {
        val startedAt = android.os.SystemClock.elapsedRealtime()
        var firstChunkAt = -1L
        var chunkCount = 0
        var emittedCharacters = 0
        val buffered = StringBuilder()
        var streamingLive = !deviceTools
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
                        if (streamingLive) {
                            emittedCharacters += text.length
                            emitContent(runId, text)
                        } else {
                            buffered.append(text)
                            // Buffer only while the reply could still be a
                            // tool-call; prose switches to live streaming.
                            if (!isPossibleToolCall(buffered.toString())) {
                                streamingLive = true
                                emitContent(runId, buffered.toString())
                                emittedCharacters += buffered.length
                            }
                        }
                    }
                }
            }
            Log.i(
                TAG,
                "stream done: chunks=$chunkCount firstChunk=${firstChunkAt}ms " +
                    "total=${android.os.SystemClock.elapsedRealtime() - startedAt}ms " +
                    "chars=$emittedCharacters",
            )
        } catch (error: Throwable) {
            if (error is CancellationException) {
                Log.i(
                    TAG,
                    "stream cancelled: chunks=$chunkCount " +
                        "firstChunk=${firstChunkAt}ms " +
                        "elapsed=${android.os.SystemClock.elapsedRealtime() - startedAt}ms",
                )
                throw error
            } else {
                Log.w(TAG, "AICore inference failed", error)
                emitError(runId, friendlyInferenceMessage(error))
                return buffered.toString()
            }
        }
        if (!streamingLive) {
            val full = buffered.toString()
            if (DeviceActionParser.parse(full) == null && full.isNotBlank()) {
                // It never was a tool-call; surface what the model wrote.
                emitContent(runId, full)
            }
            return full
        }
        return ""
    }

    private fun isPossibleToolCall(text: String): Boolean {
        val trimmed = text.trimStart()
        if (trimmed.startsWith("```")) return true
        return trimmed.startsWith("{")
    }

    private fun buildRequest(
        prompt: String,
        systemText: String,
        temperature: Double?,
        topK: Long?,
        seed: Long?,
        maxOutputTokens: Long?,
    ): GenerateContentRequest {
        return generateContentRequest(TextPart(prompt)) {
            temperature?.let { this.temperature = it.toFloat() }
            topK?.let { this.topK = it.toInt() }
            seed?.let { this.seed = it.toInt() }
            maxOutputTokens?.let { this.maxOutputTokens = it.toInt() }
            if (systemText.isNotEmpty()) {
                systemInstruction = SystemInstruction(systemText)
            }
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

    private fun emitToolCall(runId: String, payload: String) {
        scope.launch {
            flutterApi.onEvent(
                PlatformAicoreStreamEvent(
                    runId = runId,
                    kind = PlatformAicoreEventKind.TOOL,
                    toolCall = payload,
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
        private const val ROLE_ASSISTANT = "assistant"

        /** Bounded device-action chain per user request: tool → result → next. */
        private const val MAX_TOOL_ROUNDS = 2

        /**
         * Tool-call contract appended to the system instruction. The strict
         * whole-reply-JSON rule plus [DeviceActionParser]'s whitelist keep
         * prose or code from triggering actions.
         */
        private const val DEVICE_TOOL_SCHEMA =
            "DEVICE TOOLS: You can perform on-device actions. To use one, reply with ONLY " +
                "a JSON object and no other text: {\"tool\":\"<name>\",\"args\":{...}}. " +
                "Available tools:\n" +
                "- set_alarm {\"hour\":0-23,\"minute\":0-59,\"label\"?}\n" +
                "- set_timer {\"seconds\":1-86400,\"label\"?}\n" +
                "- flashlight {\"on\":true|false}\n" +
                "- set_volume {\"stream\":\"media\"|\"ring\"|\"alarm\"|\"notification\"," +
                "\"volumePercent\":0-100}\n" +
                "- open_settings {\"screen\":\"wifi\"|\"bluetooth\"|\"sound\"|\"display\"|" +
                "\"airplane\"|\"battery\"|\"date\"|\"security\"|\"storage\"|\"apps\"|" +
                "\"hotspot\"|\"notifications\"|\"home\"|\"vpn\"}\n" +
                "- dial {\"number\"?}\n" +
                "- calendar_event {\"title\",\"date\":\"yyyy-MM-dd\",\"time\":\"HH:mm\"?," +
                "\"durationMinutes\"?,\"description\"?}\n" +
                "- play_media {\"query\"}\n" +
                "- web_search {\"query\"}\n" +
                "- open_app {\"appName\"}\n" +
                "- compose_sms {\"to\"?,\"body\"}\n" +
                "- share_text {\"text\"}\n" +
                "For anything else, answer normally. Never invent other tools."
    }
}