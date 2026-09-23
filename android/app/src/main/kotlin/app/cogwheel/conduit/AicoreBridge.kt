package app.cogwheel.conduit

import android.app.Activity
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
class AicoreBridge(
    private val appContext: Context,
    messenger: BinaryMessenger,
    activityProvider: () -> Activity? = { null },
) : AicoreHostApi {
    private val flutterApi = AicoreFlutterApi(messenger)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val runs = mutableMapOf<String, Job>()
    private val actionExecutor by lazy { DeviceActionExecutor(appContext) }

    /**
     * Approval gate for state-changing device actions. The default fails
     * closed (no activity, no dialog, no approval), so only the foreground
     * activity wires a real gate.
     */
    private val approval: DeviceActionApproval = ActivityActionApproval(activityProvider)
    @Volatile
    private var webSearchApiKey: String? = null
    @Volatile
    private var model: GenerativeModel? = null

    /** Context token limit as reported by the loaded model, read once. */
    @Volatile
    private var cachedTokenLimit: Int? = null

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
        // Track the whole run lifecycle synchronously: startInternal suspends
        // in checkStatus before any inference work, and a cancel() that lands
        // during that window must still reach this job. Replacing a run with
        // the same id also cancels the old job instead of leaking it.
        runs.remove(request.runId)?.cancel()
        val job = scope.launch {
            try {
                startInternal(request)
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
            if (runs[request.runId] === job) runs.remove(request.runId)
        }
    }

    private suspend fun startInternal(request: PlatformAicoreCompletionRequest) {
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
        if (toolRoundsRemaining <= 0) {
            // The tool budget is exhausted; do not execute another action.
            emitContent(
                runId,
                "I've reached the limit of device actions for this request.",
            )
            return
        }
        var result: String
        var followUpDeviceTools = deviceTools &&
            call.name != DeviceActions.WEB_SEARCH &&
            call.name != DeviceActions.WEB_LOOKUP
        if (DeviceActions.requiresConfirmation(call.name)) {
            // State-changing actions never run on parsed model output alone:
            // the user approves (or declines) each one. A declined action is
            // narrated, and the follow-up turn loses the tool schema so the
            // model cannot simply retry the same call.
            val approved = approval.awaitApproval(
                DeviceActionConfirmation(
                    title = DeviceActionPrompts.describe(call.name, call.args),
                    message = DeviceActionPrompts.CONFIRMATION_MESSAGE,
                ),
            )
            if (approved) {
                Log.i(TAG, "tool-confirm: ${call.name} approved")
                result = actionExecutor.execute(call.name, call.args)
            } else {
                Log.i(TAG, "tool-confirm: ${call.name} denied")
                result = DECLINED_RESULT
                followUpDeviceTools = false
            }
        } else {
            result = actionExecutor.execute(call.name, call.args)
        }
        Log.i(TAG, "tool-exec: ${call.name} args=${call.args} result=$result")
        emitToolCall(
            runId,
            JSONObject()
                .put("name", call.name)
                .put("args", call.args)
                .put("result", result)
                .toString(),
        )
        val assistantTurn =
            PlatformAicoreMessage(role = ROLE_ASSISTANT, content = fullText.trim())
        val fittedResult = fitToolResultToTokenBudget(
            generativeModel = generativeModel,
            systemText = systemText,
            baseTurns = turns + assistantTurn,
            result = result,
            reserveTokens = maxOutputTokens?.toInt()?.takeIf { it > 0 }
                ?: OUTPUT_TOKEN_RESERVE,
        )
        // Untrusted tool output (web results carry remote page content) must
        // not arm another tool round: the follow-up turn drops the device-tool
        // schema unless the previous action's narration was locally produced.
        runConversationTurn(
            runId = runId,
            generativeModel = generativeModel,
            systemText = systemText,
            turns = turns + assistantTurn + toolResultMessage(fittedResult),
            deviceTools = followUpDeviceTools,
            toolRoundsRemaining = toolRoundsRemaining - 1,
            temperature = temperature,
            topK = topK,
            seed = seed,
            maxOutputTokens = maxOutputTokens,
        )
    }

    /** The follow-up user turn that carries a tool result into the model. */
    private fun toolResultMessage(result: String) = PlatformAicoreMessage(
        role = ROLE_USER,
        content = "Tool result: $result. Reply to the user in one or two sentences.",
    )

    /** Token count of a whole prompt; null when the API is unavailable. */
    private suspend fun countPromptTokens(
        generativeModel: GenerativeModel,
        systemText: String,
        turns: List<PlatformAicoreMessage>,
    ): Int? = try {
        generativeModel
            .countTokens(
                buildRequest(
                    prompt = buildPrompt(turns),
                    systemText = systemText,
                    temperature = null,
                    topK = null,
                    seed = null,
                    maxOutputTokens = null,
                ),
            )
            .totalTokens
            .takeIf { it > 0 }
    } catch (_: Throwable) {
        null
    }

    /**
     * Caps a tool result so the follow-up turn fits the model's context
     * window. An absolute character cap applies first; beyond that the
     * result is trimmed proportionally, measured with the model's own
     * countTokens against getTokenLimit — Nano's web results (near-full
     * page text from Ollama) can dwarf the small on-device window and fail
     * with "Input text length exceeds the limit". Both measurements are
     * best-effort: when either is unavailable, the character caps still
     * bound the prompt.
     */
    private suspend fun fitToolResultToTokenBudget(
        generativeModel: GenerativeModel,
        systemText: String,
        baseTurns: List<PlatformAicoreMessage>,
        result: String,
        reserveTokens: Int,
    ): String {
        var text = result
        if (text.length > MAX_TOOL_RESULT_CHARS) {
            text = text.take(MAX_TOOL_RESULT_CHARS).trimEnd() + " …[truncated]"
        }
        if (text.length < TOKEN_GUARD_MIN_CHARS) return text
        val limit = cachedTokenLimit
            ?: try {
                generativeModel.getTokenLimit().takeIf { it > 0 }
                    ?.also { cachedTokenLimit = it }
            } catch (_: Throwable) {
                null
            }
            ?: DEFAULT_TOKEN_LIMIT
        return try {
            val baseTokens = countPromptTokens(generativeModel, systemText, baseTurns)
                ?: return text
            // getTokenLimit covers input AND output, so the whole follow-up
            // prompt (base turns plus the tool message) must fit under
            // limit - reserve. baseTokens is only used to attribute the
            // tool-text token share, not subtracted from the budget.
            val budget = limit - reserveTokens
            var tokens = countPromptTokens(
                generativeModel,
                systemText,
                baseTurns + toolResultMessage(text),
            ) ?: return text
            var attempts = 0
            while (tokens > budget && attempts < 4) {
                val resultTokens = (tokens - baseTokens).coerceAtLeast(1)
                val overshoot = tokens - budget
                val cut = (overshoot * (text.length.toDouble() / resultTokens) * 1.1)
                    .toInt() + 48
                if (cut >= text.length - 48) {
                    return TOOL_RESULT_OVERFLOW_FALLBACK
                }
                text = text.removeSuffix(" …[truncated]").trimEnd()
                    .dropLast(cut) + " …[truncated]"
                tokens = countPromptTokens(
                    generativeModel,
                    systemText,
                    baseTurns + toolResultMessage(text),
                ) ?: return text
                attempts++
            }
            if (attempts > 0) {
                Log.i(
                    TAG,
                    "tool-result fitted: ${result.length} -> ${text.length} chars " +
                        "($tokens/$budget tool tokens)",
                )
            }
            text
        } catch (_: Throwable) {
            text
        }
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
                            // Keep buffering while the reply could still be
                            // a tool-call (starts with a brace or fence, or
                            // is too short to judge). Prose past the buffer
                            // window switches to live streaming.
                            val trimmed = buffered.toString().trimStart()
                            if (!trimmed.startsWith("{") && !trimmed.startsWith("```")) {
                                if (trimmed.length >= TOOL_CALL_PREFIX_LIMIT &&
                                    !trimmed.contains('{') &&
                                    !trimmed.contains('`')
                                ) {
                                    streamingLive = true
                                    emitContent(runId, buffered.toString())
                                    emittedCharacters += buffered.length
                                }
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
                // Abort the turn: buffered text from a failed stream must
                // not reach tool parsing or execution. The run-level
                // handler emits the single error event; its finally emits
                // the terminal event.
                throw error
            }
        }
        if (!streamingLive) {
            val full = buffered.toString()
            Log.i(
                TAG,
                "tool-detect: parsed=${DeviceActionParser.parse(full) != null} " +
                    "text=${full.take(120).replace("\n", " ")}",
            )
            if (DeviceActionParser.parse(full) == null && full.isNotBlank()) {
                // It never was a tool-call; surface what the model wrote.
                emitContent(runId, full)
            }
            return full
        }
        return ""
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

    override fun setWebSearchKey(apiKey: String) {
        val effective = apiKey.takeIf { it.isNotBlank() }
        webSearchApiKey = effective
        actionExecutor.webSearchApiKey = effective
        Log.i(TAG, "web-search key pushed: ${effective != null}")
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

        /** Narrated to the model when the user declines a device action. */
        private const val DECLINED_RESULT =
            "The user declined this action. Nothing was changed; do not attempt it again."

        /** Absolute cap on tool narration injected into a follow-up turn. */
        private const val MAX_TOOL_RESULT_CHARS = 4_500

        /** Token headroom left for the model's answer in a follow-up turn. */
        private const val OUTPUT_TOKEN_RESERVE = 1_200

        /** Tool results below this length skip token-count trimming. */
        private const val TOKEN_GUARD_MIN_CHARS = 1_000

        /** Fallback window when getTokenLimit is unavailable (Nano ~8K). */
        private const val DEFAULT_TOKEN_LIMIT = 8_192

        private const val TOOL_RESULT_OVERFLOW_FALLBACK =
            "The tool result was too large to fit this model's context window. " +
                "Answer briefly from what you know and offer to search a narrower topic."

        /**
         * How many characters of a reply are buffered before concluding it
         * is prose and switching to live streaming. Small enough to stay
         * imperceptible; large enough to cover Nano's usual intro sentence
         * before a tool-call.
         */
        private const val TOOL_CALL_PREFIX_LIMIT = 60

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
                "- flashlight {\"on\":true|false} (on=false turns it off)\n" +
                "- set_volume {\"stream\":\"media\"|\"ring\"|\"alarm\"|\"notification\"," +
                "\"volumePercent\":0-100}\n" +
                "- open_settings {\"screen\":\"wifi\"|\"bluetooth\"|\"sound\"|\"display\"|" +
                "\"airplane\"|\"battery\"|\"date\"|\"security\"|\"storage\"|\"apps\"|" +
                "\"hotspot\"|\"notifications\"|\"home\"|\"vpn\"}\n" +
                "- dial {\"number\"?}\n" +
                "- calendar_event {\"title\",\"date\":\"yyyy-MM-dd\",\"time\":\"HH:mm\"?," +
                "\"durationMinutes\"?,\"description\"?}\n" +
                "- play_media {\"query\"}\n" +
                "- open_app {\"appName\"}\n" +
                "- compose_sms {\"to\"?,\"body\"}\n" +
                "- share_text {\"text\"}\n" +
                "- get_weather {\"location\"?,\"days\"?} — omit location for the user's " +
                "local area (uses the device location if available), 1-3 days\n" +
                "- web_search {\"query\",\"maxResults\"?} — search the live web and " +
                    "answer from the results in this chat\n" +
                "For anything else, answer normally. Never invent other tools."
    }
}