package app.cogwheel.conduit

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer as AndroidSpeechRecognizer
import android.util.Log
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.audio.AudioSource
import com.google.mlkit.genai.speechrecognition.SpeechRecognition
import com.google.mlkit.genai.speechrecognition.SpeechRecognizer as MlKitSpeechRecognizer
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerResponse
import com.google.mlkit.genai.speechrecognition.speechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.speechRecognizerRequest
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class NativeSttBridge(private val activity: MainActivity) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var eventSink: EventChannel.EventSink? = null
    @Volatile
    private var activeMlKitRecognizer: MlKitSpeechRecognizer? = null
    private var activePlatformRecognizer: AndroidSpeechRecognizer? = null
    private var recognitionJob: kotlinx.coroutines.Job? = null
    private var platformRestartJob: kotlinx.coroutines.Job? = null
    private var platformStopRequested = false
    private var platformEmitPartialResults = true
    private var platformAccumulateResults = true
    private var platformAllowOnlineFallback = true
    private var platformLocaleId: String? = null
    private var platformCommittedText = ""
    @Volatile
    private var recognitionGeneration = 0

    fun setup(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler(this)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkAvailability" -> {
                val localeId = call.argument<String>("localeId")
                scope.launch {
                    result.success(checkAvailability(localeId))
                }
            }
            "getLocales" -> {
                val deviceLocaleId = call.argument<String>("deviceLocaleId")
                result.success(localesPayload(deviceLocaleId))
            }
            "start" -> {
                val localeId = call.argument<String>("localeId")
                val emitPartialResults = call.argument<Boolean>("emitPartialResults") ?: true
                val accumulateResults = call.argument<Boolean>("accumulateResults") ?: true
                val allowOnlineFallback = call.argument<Boolean>("allowOnlineFallback") ?: true
                scope.launch {
                    start(
                        localeId,
                        emitPartialResults,
                        accumulateResults,
                        allowOnlineFallback,
                        result
                    )
                }
            }
            "stop" -> {
                scope.launch {
                    recognitionGeneration += 1
                    stopInternal(emitDone = false, awaitCompletion = true)
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        recognitionGeneration += 1
        scope.launch {
            stopInternal(emitDone = false, awaitCompletion = false)
        }
    }

    fun dispose() {
        recognitionGeneration += 1
        scope.launch {
            stopInternal(emitDone = false, awaitCompletion = false)
            scope.cancel()
        }
    }

    private suspend fun checkAvailability(localeId: String?): Map<String, Any?> {
        val mlKitAvailability = checkMlKitAvailability(localeId)
        if (mlKitAvailability["available"] == true) {
            return mlKitAvailability
        }

        return if (AndroidSpeechRecognizer.isRecognitionAvailable(activity.applicationContext)) {
            available("android_speech")
        } else {
            unavailable(mlKitAvailability["reason"] as? String ?: "Android speech recognition unavailable")
        }
    }

    private suspend fun checkMlKitAvailability(localeId: String?): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return unavailable("Android 12/API 31 is required for ML Kit microphone input")
        }

        return withContext(Dispatchers.IO) {
            val advanced = createRecognizer(localeId, SpeechRecognizerOptions.Mode.MODE_ADVANCED)
            try {
                val advancedStatus = advanced.checkStatus()
                if (isUsableStatus(advancedStatus)) {
                    return@withContext available("mlkit_advanced")
                }
            } catch (error: Throwable) {
                Log.w(TAG, "Advanced ML Kit STT status check failed", error)
            } finally {
                advanced.close()
            }

            val basic = createRecognizer(localeId, SpeechRecognizerOptions.Mode.MODE_BASIC)
            try {
                val basicStatus = basic.checkStatus()
                if (isUsableStatus(basicStatus)) {
                    available("mlkit_basic")
                } else {
                    unavailable("ML Kit speech recognition unavailable: $basicStatus")
                }
            } catch (error: Throwable) {
                unavailable(error.message ?: "ML Kit speech recognition unavailable")
            } finally {
                basic.close()
            }
        }
    }

    private suspend fun start(
        localeId: String?,
        emitPartialResults: Boolean,
        accumulateResults: Boolean,
        allowOnlineFallback: Boolean,
        result: MethodChannel.Result
    ) {
        val generation = recognitionGeneration + 1
        recognitionGeneration = generation
        stopInternal(emitDone = false, awaitCompletion = false)
        val prepared = try {
            withContext(Dispatchers.IO) {
                prepareRecognizer(localeId, generation)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (!isCurrentGeneration(generation)) {
                result.success(unavailable("Speech recognition start was cancelled"))
                return
            }
            Log.w(TAG, "ML Kit STT startup failed", error)
            null
        }
        if (!isCurrentGeneration(generation)) {
            prepared?.first?.close()
            result.success(unavailable("Speech recognition start was cancelled"))
            return
        }
        if (prepared == null) {
            if (AndroidSpeechRecognizer.isRecognitionAvailable(activity.applicationContext)) {
                startPlatformRecognizer(
                    localeId,
                    emitPartialResults,
                    accumulateResults,
                    allowOnlineFallback
                )
                result.success(available("android_speech"))
            } else {
                result.success(unavailable("Speech recognition is not available"))
            }
            return
        }

        val (recognizer, engineName) = prepared
        activeMlKitRecognizer = recognizer
        emitStatus("listening", engineName)
        recognitionJob = scope.launch(Dispatchers.IO) {
            var committedText = ""
            var doneEmitted = false
            try {
                val request = speechRecognizerRequest {
                    audioSource = AudioSource.fromMic()
                }
                recognizer.startRecognition(request).collect { response ->
                    if (!isCurrentGeneration(generation)) return@collect
                    when (response) {
                        is SpeechRecognizerResponse.PartialTextResponse -> {
                            if (emitPartialResults) {
                                val text = if (accumulateResults) {
                                    mergeText(committedText, response.text)
                                } else {
                                    response.text.trim()
                                }
                                emitResult(text, false, engineName)
                            }
                        }
                        is SpeechRecognizerResponse.FinalTextResponse -> {
                            val text = if (accumulateResults) {
                                committedText = mergeText(committedText, response.text)
                                committedText
                            } else {
                                response.text.trim()
                            }
                            emitResult(text, true, engineName)
                        }
                        is SpeechRecognizerResponse.ErrorResponse -> {
                            emitError(
                                "MLKIT_ERROR_${response.e.errorCode}",
                                response.e.message ?: "ML Kit speech recognition failed",
                                engineName
                            )
                        }
                        is SpeechRecognizerResponse.CompletedResponse -> {
                            doneEmitted = true
                            emitDone(engineName)
                        }
                    }
                }
                if (!doneEmitted) {
                    emitDone(engineName)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                emitError("MLKIT_ERROR", error.message ?: error.toString(), engineName)
            } finally {
                if (activeMlKitRecognizer === recognizer) {
                    activeMlKitRecognizer = null
                    runCatching { recognizer.close() }
                }
            }
        }
        result.success(available(engineName))
    }

    private suspend fun prepareRecognizer(
        localeId: String?,
        generation: Int
    ): Pair<MlKitSpeechRecognizer, String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return null
        }

        val advanced = createRecognizer(localeId, SpeechRecognizerOptions.Mode.MODE_ADVANCED)
        if (!isCurrentGeneration(generation)) {
            advanced.close()
            return null
        }
        if (ensureReady(advanced, "mlkit_advanced", generation)) {
            return advanced to "mlkit_advanced"
        }
        advanced.close()

        val basic = createRecognizer(localeId, SpeechRecognizerOptions.Mode.MODE_BASIC)
        if (!isCurrentGeneration(generation)) {
            basic.close()
            return null
        }
        if (ensureReady(basic, "mlkit_basic", generation)) {
            return basic to "mlkit_basic"
        }
        basic.close()
        return null
    }

    private fun createRecognizer(localeId: String?, mode: Int): MlKitSpeechRecognizer {
        val locale = parseLocale(localeId)
        val options = speechRecognizerOptions {
            this.locale = locale
            preferredMode = mode
        }
        return SpeechRecognition.getClient(options)
    }

    private suspend fun ensureReady(
        recognizer: MlKitSpeechRecognizer,
        engineName: String,
        generation: Int
    ): Boolean {
        if (!isCurrentGeneration(generation)) {
            return false
        }
        return when (val status = recognizer.checkStatus()) {
            FeatureStatus.AVAILABLE -> true
            FeatureStatus.DOWNLOADABLE, FeatureStatus.DOWNLOADING -> {
                if (isCurrentGeneration(generation)) {
                    emitStatus("downloading", engineName)
                }
                var ready = false
                try {
                    coroutineScope {
                        val downloadJob = launch {
                            recognizer.download().collect { downloadStatus ->
                                if (!isCurrentGeneration(generation)) {
                                    throw CancellationException("Stale recognition generation")
                                }
                                when (downloadStatus) {
                                    is DownloadStatus.DownloadStarted -> {
                                        emitStatus("downloading", engineName)
                                    }
                                    is DownloadStatus.DownloadCompleted -> {
                                        ready = true
                                        emitStatus("downloaded", engineName)
                                    }
                                    is DownloadStatus.DownloadProgress -> {
                                        emit(
                                            mapOf(
                                                "type" to "status",
                                                "message" to "downloading",
                                                "engine" to engineName,
                                                "bytesDownloaded" to downloadStatus.totalBytesDownloaded
                                            )
                                        )
                                    }
                                    is DownloadStatus.DownloadFailed -> {
                                        emitError(
                                            "MLKIT_DOWNLOAD_${downloadStatus.e.errorCode}",
                                            downloadStatus.e.message ?: "ML Kit speech model download failed",
                                            engineName
                                        )
                                    }
                                }
                            }
                        }
                        val staleGenerationJob = launch {
                            while (downloadJob.isActive && isCurrentGeneration(generation)) {
                                delay(STALE_GENERATION_CHECK_MS)
                            }
                            if (downloadJob.isActive) {
                                downloadJob.cancel(
                                    CancellationException("Stale recognition generation")
                                )
                            }
                        }
                        try {
                            downloadJob.join()
                        } finally {
                            staleGenerationJob.cancel()
                        }
                    }
                    if (!isCurrentGeneration(generation)) {
                        return false
                    }
                } catch (error: CancellationException) {
                    if (!isCurrentGeneration(generation)) {
                        return false
                    }
                    throw error
                }
                ready || recognizer.checkStatus() == FeatureStatus.AVAILABLE
            }
            else -> {
                Log.i(TAG, "ML Kit STT $engineName status unavailable: $status")
                false
            }
        }
    }

    private fun isCurrentGeneration(generation: Int): Boolean {
        return recognitionGeneration == generation
    }

    private fun startPlatformRecognizer(
        localeId: String?,
        emitPartialResults: Boolean,
        accumulateResults: Boolean,
        allowOnlineFallback: Boolean
    ) {
        platformStopRequested = false
        platformEmitPartialResults = emitPartialResults
        platformAccumulateResults = accumulateResults
        platformAllowOnlineFallback = allowOnlineFallback
        platformLocaleId = localeId
        platformCommittedText = ""
        activePlatformRecognizer = AndroidSpeechRecognizer.createSpeechRecognizer(
            activity.applicationContext
        ).also { recognizer ->
            recognizer.setRecognitionListener(platformRecognitionListener)
            recognizer.startListening(platformRecognizerIntent())
        }
        emitStatus("listening", "android_speech")
    }

    private val platformRecognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            emitStatus("listening", "android_speech")
        }

        override fun onBeginningOfSpeech() {}

        override fun onRmsChanged(rmsdB: Float) {}

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {}

        override fun onPartialResults(partialResults: Bundle?) {
            if (!platformEmitPartialResults) return
            val text = firstRecognitionText(partialResults) ?: return
            val emitted = if (platformAccumulateResults) {
                mergeText(platformCommittedText, text)
            } else {
                text.trim()
            }
            emitResult(emitted, false, "android_speech")
        }

        override fun onResults(results: Bundle?) {
            val text = firstRecognitionText(results)
            if (text != null) {
                val emitted = if (platformAccumulateResults) {
                    platformCommittedText = mergeText(platformCommittedText, text)
                    platformCommittedText
                } else {
                    text.trim()
                }
                emitResult(emitted, true, "android_speech")
            }
            restartPlatformRecognizerIfActive()
        }

        override fun onError(error: Int) {
            if (platformStopRequested || activePlatformRecognizer == null) {
                emitDone("android_speech")
                return
            }
            if (isRestartablePlatformError(error)) {
                restartPlatformRecognizerIfActive(delayMs = 300L)
                return
            }
            emitError(
                "ANDROID_SPEECH_$error",
                platformSpeechErrorMessage(error),
                "android_speech"
            )
            emitDone("android_speech")
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun restartPlatformRecognizerIfActive(delayMs: Long = 200L) {
        val recognizer = activePlatformRecognizer ?: return
        if (platformStopRequested) {
            emitDone("android_speech")
            return
        }

        platformRestartJob?.cancel()
        platformRestartJob = scope.launch {
            if (delayMs > 0) {
                kotlinx.coroutines.delay(delayMs)
            }
            if (platformStopRequested || activePlatformRecognizer !== recognizer) {
                return@launch
            }
            runCatching { recognizer.startListening(platformRecognizerIntent()) }
        }
    }

    private fun platformRecognizerIntent(): Intent {
        val locale = parseLocale(platformLocaleId)
        return Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale.toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, locale.toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, false)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, platformEmitPartialResults)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, !platformAllowOnlineFallback)
        }
    }

    private fun firstRecognitionText(results: Bundle?): String? {
        val matches = results?.getStringArrayList(AndroidSpeechRecognizer.RESULTS_RECOGNITION)
        return matches?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun isRestartablePlatformError(error: Int): Boolean {
        return error == AndroidSpeechRecognizer.ERROR_NO_MATCH ||
            error == AndroidSpeechRecognizer.ERROR_SPEECH_TIMEOUT ||
            error == AndroidSpeechRecognizer.ERROR_RECOGNIZER_BUSY
    }

    private fun platformSpeechErrorMessage(error: Int): String {
        return when (error) {
            AndroidSpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
            AndroidSpeechRecognizer.ERROR_CLIENT -> "Speech recognition client error"
            AndroidSpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                "Speech recognition permission was not granted"
            AndroidSpeechRecognizer.ERROR_NETWORK -> "Speech recognition network error"
            AndroidSpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition network timeout"
            AndroidSpeechRecognizer.ERROR_NO_MATCH -> "No speech was recognized"
            AndroidSpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognizer is busy"
            AndroidSpeechRecognizer.ERROR_SERVER -> "Speech recognition server error"
            AndroidSpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech input"
            else -> "Android speech recognition failed"
        }
    }

    private suspend fun stopInternal(emitDone: Boolean, awaitCompletion: Boolean) {
        val platformRecognizer = activePlatformRecognizer
        activePlatformRecognizer = null
        platformStopRequested = true
        platformRestartJob?.cancel()
        platformRestartJob = null
        if (platformRecognizer != null) {
            withContext(Dispatchers.Main.immediate) {
                runCatching { platformRecognizer.cancel() }
                runCatching { platformRecognizer.destroy() }
            }
        }

        val recognizer = activeMlKitRecognizer
        val job = recognitionJob
        activeMlKitRecognizer = null
        if (recognizer != null) {
            withContext(Dispatchers.IO) {
                runCatching { recognizer.stopRecognition() }
            }
        }
        if (awaitCompletion && job != null) {
            val completed = withTimeoutOrNull(STOP_GRACE_PERIOD_MS) {
                job.join()
                true
            } ?: false
            if (!completed) {
                job.cancelAndJoin()
            }
        } else {
            job?.cancelAndJoin()
        }
        recognitionJob = null
        recognizer?.close()
        if (emitDone) {
            emitDone(if (platformRecognizer != null) "android_speech" else "mlkit")
        }
    }

    private fun localesPayload(deviceLocaleId: String?): Map<String, Any?> {
        val systemLocale = parseLocale(deviceLocaleId)
        val locales = Locale.getAvailableLocales()
            .filter { it.language.isNotBlank() }
            .distinctBy { localeIdentifier(it) }
            .sortedBy { localeIdentifier(it) }
            .map { localePayload(it) }
        return mapOf(
            "systemLocale" to localeIdentifier(systemLocale),
            "locales" to locales
        )
    }

    private fun localePayload(locale: Locale): Map<String, Any?> {
        val identifier = localeIdentifier(locale)
        val displayName = locale.getDisplayName(locale).takeIf { it.isNotBlank() }
            ?: locale.getDisplayName().takeIf { it.isNotBlank() }
            ?: identifier
        return mapOf(
            "localeId" to identifier,
            "name" to displayName
        )
    }

    private fun localeIdentifier(locale: Locale): String {
        val tag = locale.toLanguageTag()
        return if (tag.isNullOrBlank() || tag == "und") {
            locale.toString().replace('_', '-')
        } else {
            tag
        }
    }

    private fun parseLocale(localeId: String?): Locale {
        val normalized = localeId
            ?.takeIf { it.isNotBlank() }
            ?.replace('_', '-')
        return if (normalized == null) Locale.getDefault() else Locale.forLanguageTag(normalized)
    }

    private fun isUsableStatus(status: Int): Boolean {
        return status == FeatureStatus.AVAILABLE ||
            status == FeatureStatus.DOWNLOADABLE ||
            status == FeatureStatus.DOWNLOADING
    }

    private fun mergeText(committed: String, next: String): String {
        val trimmedNext = next.trim()
        if (trimmedNext.isEmpty()) return committed
        if (committed.isBlank()) return trimmedNext
        if (committed == trimmedNext || committed.endsWith(trimmedNext)) return committed
        if (trimmedNext.startsWith(committed)) return trimmedNext
        return "$committed $trimmedNext".trim()
    }

    private fun available(engine: String): Map<String, Any?> {
        return mapOf("available" to true, "engine" to engine)
    }

    private fun unavailable(reason: String): Map<String, Any?> {
        return mapOf("available" to false, "reason" to reason)
    }

    private fun emitStatus(message: String, engine: String) {
        emit(mapOf("type" to "status", "message" to message, "engine" to engine))
    }

    private fun emitResult(text: String, isFinal: Boolean, engine: String) {
        emit(mapOf("type" to "result", "text" to text, "final" to isFinal, "engine" to engine))
    }

    private fun emitError(code: String, message: String, engine: String) {
        emit(mapOf("type" to "error", "code" to code, "message" to message, "engine" to engine))
    }

    private fun emitDone(engine: String) {
        emit(mapOf("type" to "done", "engine" to engine))
    }

    private fun emit(event: Map<String, Any?>) {
        activity.runOnUiThread {
            eventSink?.success(event)
        }
    }

    companion object {
        private const val TAG = "NativeSttBridge"
        private const val METHOD_CHANNEL = "app.cogwheel.conduit/native_stt"
        private const val EVENT_CHANNEL = "app.cogwheel.conduit/native_stt/events"
        private const val STOP_GRACE_PERIOD_MS = 1500L
        private const val STALE_GENERATION_CHECK_MS = 50L
    }
}
