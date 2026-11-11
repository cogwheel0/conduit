package app.cogwheel.conduit

import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.system.ErrnoException
import android.system.OsConstants
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
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
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.isActive

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
    private var platformLanguageSwitchLanguages: List<String>? = null
    private var platformLanguageFallbacks: List<String?>? = null
    private val platformFailedLocaleIds = mutableSetOf<String?>()
    private var platformEngineName = "android_speech"
    private var platformCommittedText = ""
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pcmSource: NativeDictationAudioSource? = null
    private var pcmGeneration: Int? = null
    private var pendingStarts = 0
    private var recordingTranscriptionId: String? = null
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
                val allowOnlineFallback =
                    call.argument<Boolean>("allowOnlineFallback") ?: true
                scope.launch {
                    result.success(checkAvailability(localeId, allowOnlineFallback))
                }
            }
            "getLocales" -> {
                val deviceLocaleId = call.argument<String>("deviceLocaleId")
                scope.launch {
                    result.success(localesPayload(deviceLocaleId))
                }
            }
            "start" -> {
                val localeId = call.argument<String>("localeId")
                val emitPartialResults = call.argument<Boolean>("emitPartialResults") ?: true
                val accumulateResults = call.argument<Boolean>("accumulateResults") ?: true
                val allowOnlineFallback = call.argument<Boolean>("allowOnlineFallback") ?: true
                val emitAudio = call.argument<Boolean>("emitAudio") ?: false
                scope.launch {
                    pendingStarts += 1
                    try { start(
                        localeId,
                        emitPartialResults,
                        accumulateResults,
                        allowOnlineFallback,
                        emitAudio,
                        result
                    ) } finally { pendingStarts -= 1 }
                }
            }
            "transcribeRecording" -> {
                val pcm = call.argument<ByteArray>("pcm")
                val id = call.argument<String>("requestId")
                if (pcm == null || pcm.isEmpty() || pcm.size % 2 != 0 || pcm.size > 32000 * 600 || id == null) {
                    result.error("INVALID_AUDIO", "Invalid recording audio", null)
                } else {
                    transcribeRecording(pcm, call.argument<String>("localeId"), id, result)
                }
            }
            "cancelRecordingTranscription" -> {
                val id = call.argument<String>("requestId")
                scope.launch {
                    if (id != null && recordingTranscriptionId == id) {
                        recognitionGeneration += 1
                        stopInternal(emitDone = false, awaitCompletion = false)
                    }
                    result.success(null)
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

    private suspend fun checkAvailability(
        localeId: String?,
        allowOnlineFallback: Boolean
    ): Map<String, Any?> {
        val languageSwitch = platformLanguageSwitch(localeId, allowOnlineFallback)
        if (languageSwitch != null) {
            runCatching { languageSwitch.recognizer.destroy() }
            return available("android_speech_auto")
        }

        val mlKitAvailability = checkMlKitAvailability(localeId)
        if (mlKitAvailability["available"] == true) {
            return mlKitAvailability
        }

        return if (platformRecognizerAvailable(allowOnlineFallback)) {
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
        emitAudio: Boolean,
        result: MethodChannel.Result
    ) {
        val generation = recognitionGeneration + 1
        recognitionGeneration = generation
        stopInternal(emitDone = false, awaitCompletion = false)
        val languageSwitch = platformLanguageSwitch(localeId, allowOnlineFallback)
        val usePlatformLanguageSwitch = languageSwitch != null
        val prepared = if (usePlatformLanguageSwitch) {
            null
        } else {
            try {
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
        }
        if (!isCurrentGeneration(generation)) {
            prepared?.first?.close()
            languageSwitch?.let { runCatching { it.recognizer.destroy() } }
            result.success(unavailable("Speech recognition start was cancelled"))
            return
        }
        if (prepared == null) {
            if (platformRecognizerAvailable(allowOnlineFallback)) {
                try {
                    if (emitAudio && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val source = createPcmSource(generation)
                        if (!isCurrentGeneration(generation)) {
                            source.stop()
                            source.closeDescriptor()
                            result.success(unavailable("Speech recognition start was cancelled"))
                            return
                        }
                        pcmSource = source
                        pcmGeneration = generation
                    }
                    startPlatformRecognizer(
                        localeId,
                        emitPartialResults,
                        accumulateResults,
                        allowOnlineFallback,
                        languageSwitch
                    )
                    pcmSource?.start(scope)
                    val engineName = if (usePlatformLanguageSwitch) {
                        "android_speech_auto"
                    } else {
                        "android_speech"
                    }
                    result.success(available(engineName) + ("audioRecoverySupported" to (pcmSource != null)))
                } catch (error: Throwable) {
                    retirePcmSource(pcmSource)
                    Log.w(TAG, "Android speech recognition startup failed", error)
                    languageSwitch?.recognizer?.takeIf { it !== activePlatformRecognizer }
                        ?.let { runCatching { it.destroy() } }
                    result.success(
                        unavailable(error.message ?: "Speech recognition failed to start")
                    )
                }
            } else {
                languageSwitch?.let { runCatching { it.recognizer.destroy() } }
                result.success(unavailable("Speech recognition is not available"))
            }
            return
        }

        val (recognizer, engineName) = prepared
        val source = try {
            if (emitAudio) createPcmSource(generation) else null
        } catch (error: Exception) {
            recognizer.close()
            result.success(unavailable("Unable to preserve microphone audio"))
            return
        }
        if (!isCurrentGeneration(generation)) {
            retirePcmSource(source)
            recognizer.close()
            result.success(unavailable("Speech recognition start was cancelled"))
            return
        }
        pcmSource = source
        pcmGeneration = if (source == null) null else generation
        activeMlKitRecognizer = recognizer
        emitStatus("listening", engineName)
        recognitionJob = scope.launch(Dispatchers.IO) {
            var committedText = ""
            var doneEmitted = false
            try {
                source?.start(scope)
                val request = speechRecognizerRequest {
                    audioSource = source?.let { AudioSource.fromPfd(it.descriptor) } ?: AudioSource.fromMic()
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
                retirePcmSource(source)
                if (activeMlKitRecognizer === recognizer) {
                    activeMlKitRecognizer = null
                    runCatching { recognizer.close() }
                }
            }
        }
        result.success(available(engineName) + ("audioRecoverySupported" to (source != null)))
    }

    /** Prefers advanced recognition; only a current generation receives ownership. */
    private suspend fun prepareRecognizer(
        localeId: String?,
        generation: Int
    ): Pair<MlKitSpeechRecognizer, String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return null
        }

        suspend fun prepare(mode: Int, engine: String): Pair<MlKitSpeechRecognizer, String>? {
            if (!isCurrentGeneration(generation)) return null
            val recognizer = createRecognizer(localeId, mode)
            var transferred = false
            try {
                if (ensureReady(recognizer, engine, generation)) {
                    transferred = true
                    return recognizer to engine
                }
                return null
            } finally {
                if (!transferred) recognizer.close()
            }
        }
        return prepare(SpeechRecognizerOptions.Mode.MODE_ADVANCED, "mlkit_advanced")
            ?: prepare(SpeechRecognizerOptions.Mode.MODE_BASIC, "mlkit_basic")
    }

    /** Transcribes validated PCM exclusively, with a duration-based deadline and one reply. */
    private fun transcribeRecording(pcm: ByteArray, localeId: String?, id: String, result: MethodChannel.Result) {
        if (pendingStarts > 0 || recordingTranscriptionId != null ||
            activeMlKitRecognizer != null || activePlatformRecognizer != null || recognitionJob?.isActive == true) {
            result.error("BUSY", "Speech recognition is already in progress", null)
            return
        }
        val generation = ++recognitionGeneration
        recordingTranscriptionId = id
        recognitionJob = scope.launch(Dispatchers.IO) {
            var recognizer: MlKitSpeechRecognizer? = null
            var registered = false
            var answered = false
            suspend fun answer(text: String? = null, error: String? = null) {
                withContext(NonCancellable + Dispatchers.Main.immediate) {
                    if (!answered) {
                        answered = true
                        if (error == null) result.success(text)
                        else result.error("TRANSCRIPTION_FAILED", error, null)
                    }
                }
            }
            try {
                val prepared = prepareRecognizer(localeId, generation)
                    ?: error("On-device transcription is unavailable for this device or language")
                val client = prepared.first
                recognizer = client
                withContext(Dispatchers.Main.immediate) {
                    if (!isCurrentGeneration(generation)) throw CancellationException()
                    activeMlKitRecognizer = client
                    registered = true
                }
                val text = withTimeout(pcm.size * 1000L / 32000 + 30000L) {
                    transcribePcm(client, pcm)
                }
                if (!isCurrentGeneration(generation)) throw CancellationException()
                check(text.isNotBlank()) { "No speech was recognized" }
                answer(text = text)
            } catch (_: CancellationException) {
                answer(error = "Recording transcription was cancelled")
            } catch (_: Exception) {
                answer(error = "On-device recording transcription failed")
            } finally {
                val ownsClient = withContext(NonCancellable + Dispatchers.Main.immediate) {
                    if (recordingTranscriptionId == id) recordingTranscriptionId = null
                    if (recognizer != null && activeMlKitRecognizer === recognizer) {
                        activeMlKitRecognizer = null
                        recognitionJob = null
                        true
                    } else !registered
                }
                if (ownsClient) runCatching { recognizer?.close() }
            }
        }
    }

    /** Feeds mono 16 kHz PCM16 through a paced nonblocking pipe, closing it on every exit.
     * Recognition that ends before all input is submitted fails instead of returning partial text. */
    private suspend fun transcribePcm(recognizer: MlKitSpeechRecognizer, pcm: ByteArray): String = coroutineScope {
        val pipe = NativePcmPipe.create()
        val submitted = CompletableDeferred<Unit>()
        val writer = launch(Dispatchers.IO) {
            try {
                var offset = 0
                while (offset < pcm.size) {
                    val count = minOf(640, pcm.size - offset)
                    try {
                        val written = pipe.write(pcm, offset, count)
                        offset += written
                        delay(written * 1000L / 32000)
                    } catch (error: ErrnoException) {
                        if (error.errno != OsConstants.EAGAIN) throw error
                        delay(10)
                    }
                }
                submitted.complete(Unit)
            } catch (error: Exception) {
                if (isActive) throw error
            } finally {
                pipe.closeOutput()
            }
        }
        try {
            val segments = mutableListOf<String>()
            val request = speechRecognizerRequest { audioSource = AudioSource.fromPfd(pipe.input) }
            recognizer.startRecognition(request).collect { response ->
                when (response) {
                    is SpeechRecognizerResponse.FinalTextResponse -> segments.add(response.text.trim())
                    is SpeechRecognizerResponse.ErrorResponse -> error("On-device transcription failed")
                    else -> Unit
                }
            }
            check(submitted.isCompleted) { "Recognition ended before the recording was consumed" }
            segments.filter { it.isNotEmpty() }.joinToString(" ")
        } finally {
            withContext(NonCancellable) {
                writer.cancel()
                pipe.close()
                writer.join()
            }
        }
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
        allowOnlineFallback: Boolean,
        languageSwitch: PlatformLanguageSwitch?
    ) {
        platformStopRequested = false
        platformEmitPartialResults = emitPartialResults
        platformAccumulateResults = accumulateResults
        platformAllowOnlineFallback = allowOnlineFallback
        platformLocaleId = localeId?.takeIf { it.isNotBlank() }
            ?.let { parseLocale(it).toLanguageTag() }
        platformLanguageSwitchLanguages = languageSwitch?.languages
        platformLanguageFallbacks = null
        platformFailedLocaleIds.clear()
        platformEngineName = if (languageSwitch == null) {
            "android_speech"
        } else {
            "android_speech_auto"
        }
        platformCommittedText = ""
        // Listen on the recognizer that answered the support check. Destroying
        // it and binding a fresh one makes system_server drop the recognition
        // service connection, so the new recognizer fails with
        // ERROR_SERVER_DISCONNECTED before it hears anything.
        val recognizer = languageSwitch?.recognizer
            ?: createPlatformRecognizer(allowOnlineFallback)
        activePlatformRecognizer = recognizer.also {
            it.setRecognitionListener(platformRecognitionListener)
            it.startListening(platformRecognizerIntent())
        }
        emitStatus("listening", platformEngineName)
    }

    private fun createPlatformRecognizer(allowOnlineFallback: Boolean): AndroidSpeechRecognizer {
        val context = activity.applicationContext
        return if (usesSystemOnDeviceRecognizer(allowOnlineFallback)) {
            AndroidSpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            AndroidSpeechRecognizer.createSpeechRecognizer(context)
        }
    }

    private fun systemOnDeviceRecognitionAvailable(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            AndroidSpeechRecognizer.isOnDeviceRecognitionAvailable(activity.applicationContext)
    }

    private fun usesSystemOnDeviceRecognizer(allowOnlineFallback: Boolean): Boolean {
        return NativeSttLanguagePolicy.usesSystemOnDeviceRecognizer(
            allowOnlineFallback = allowOnlineFallback,
            sdkInt = Build.VERSION.SDK_INT,
            onDeviceRecognitionAvailable = systemOnDeviceRecognitionAvailable()
        )
    }

    private fun platformRecognizerAvailable(allowOnlineFallback: Boolean): Boolean {
        val context = activity.applicationContext
        return NativeSttLanguagePolicy.platformRecognizerAvailable(
            allowOnlineFallback = allowOnlineFallback,
            sdkInt = Build.VERSION.SDK_INT,
            recognitionAvailable = otherRecognizerInstalled(context),
            onDeviceRecognitionAvailable = systemOnDeviceRecognitionAvailable()
        )
    }

    private val platformRecognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            emitStatus("listening", platformEngineName)
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
            emitResult(emitted, false, platformEngineName)
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
                emitResult(emitted, true, platformEngineName)
            }
            restartPlatformRecognizerIfActive()
        }

        override fun onError(error: Int) {
            if (platformStopRequested || activePlatformRecognizer == null) {
                emitDone(platformEngineName)
                return
            }
            if (isRestartablePlatformError(error)) {
                restartPlatformRecognizerIfActive(delayMs = 300L)
                return
            }
            if (error == AndroidSpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED &&
                recoverUnsupportedPlatformLanguage()
            ) return
            finishPlatformError(error)
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun finishPlatformError(error: Int) {
        platformStopRequested = true
        platformRestartJob?.cancel()
        platformRestartJob = null
        emitError("ANDROID_SPEECH_$error", platformSpeechErrorMessage(error), platformEngineName)
        emitDone(platformEngineName)
    }

    private fun recoverUnsupportedPlatformLanguage(): Boolean {
        val recognizer = activePlatformRecognizer ?: return false
        val generation = recognitionGeneration
        // A rejected switching request has not yet tried the engine's default
        // single-language request, even though both use a null locale.
        if (platformLanguageSwitchLanguages == null) {
            platformFailedLocaleIds.add(platformLocaleId)
        }
        platformRestartJob?.cancel()
        platformRestartJob = scope.launch {
            if (platformLanguageFallbacks == null) {
                // Reuse the active recognizer for the support check. Rebinding
                // the recognition service can disconnect it (issue #762).
                val supported = platformRecognitionLanguages(
                    allowOnlineFallback = platformAllowOnlineFallback,
                    requestLanguageSwitch = false,
                    recognizer = recognizer
                )
                if (!isCurrentGeneration(generation) || platformStopRequested ||
                    activePlatformRecognizer !== recognizer
                ) return@launch
                platformLanguageFallbacks = NativeSttLanguagePolicy.fallbackLocaleIds(
                    localeId = platformLocaleId,
                    systemLocaleId = Locale.getDefault().toLanguageTag(),
                    supportedLocaleIds = supported
                ).filterNot { it in platformFailedLocaleIds }.take(2)
            }
            val remaining = platformLanguageFallbacks.orEmpty()
                .filterNot { it in platformFailedLocaleIds }
            if (remaining.isEmpty()) {
                finishPlatformError(AndroidSpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
                return@launch
            }
            platformLanguageSwitchLanguages = null
            platformLocaleId = remaining.first()
            platformFailedLocaleIds.add(platformLocaleId)
            platformEngineName = "android_speech"
            delay(300L)
            if (!isCurrentGeneration(generation) || platformStopRequested ||
                activePlatformRecognizer !== recognizer
            ) return@launch
            try {
                recognizer.startListening(platformRecognizerIntent())
            } catch (error: Throwable) {
                Log.w(TAG, "Android speech language recovery failed", error)
                finishPlatformError(AndroidSpeechRecognizer.ERROR_CLIENT)
            }
        }
        return true
    }

    private fun restartPlatformRecognizerIfActive(delayMs: Long = 200L) {
        val recognizer = activePlatformRecognizer ?: return
        if (platformStopRequested) {
            emitDone(platformEngineName)
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
        val languageSwitchLanguages = platformLanguageSwitchLanguages
        return Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            if (languageSwitchLanguages != null) {
                putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_DETECTION, true)
                putExtra(
                    RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH,
                    RecognizerIntent.LANGUAGE_SWITCH_BALANCED
                )
                putStringArrayListExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_SWITCH_ALLOWED_LANGUAGES,
                    ArrayList(languageSwitchLanguages)
                )
            } else if (platformLocaleId != null) {
                val locale = platformLocaleId
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            }
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, platformEmitPartialResults)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, !platformAllowOnlineFallback)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pcmSource?.let { source ->
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, source.descriptor)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
                }
            }
        }
    }

    /** A multi-language recognizer whose support check already succeeded. */
    private class PlatformLanguageSwitch(
        val recognizer: AndroidSpeechRecognizer,
        val languages: List<String>
    )

    /**
     * Resolves automatic language switching. The caller owns the returned
     * recognizer and must listen on it or destroy it.
     */
    private suspend fun platformLanguageSwitch(
        localeId: String?,
        allowOnlineFallback: Boolean
    ): PlatformLanguageSwitch? {
        if (!NativeSttLanguagePolicy.usesPlatformLanguageSwitch(localeId, Build.VERSION.SDK_INT)) {
            return null
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            !platformRecognizerAvailable(allowOnlineFallback)
        ) {
            return null
        }
        return withContext(Dispatchers.Main.immediate) {
            val recognizer = try {
                createPlatformRecognizer(allowOnlineFallback)
            } catch (error: Throwable) {
                Log.w(TAG, "Unable to create Android recognizer for language switching", error)
                return@withContext null
            }
            // Destroy on every exit that does not hand the recognizer to the
            // caller, including cancellation before the support check runs.
            var ownershipTransferred = false
            try {
                val languages = platformRecognitionLanguages(
                    allowOnlineFallback = allowOnlineFallback,
                    requestLanguageSwitch = true,
                    recognizer = recognizer
                )?.takeIf { NativeSttLanguagePolicy.hasMultipleLanguages(it) }
                    ?: return@withContext null
                ownershipTransferred = true
                PlatformLanguageSwitch(recognizer, languages)
            } finally {
                if (!ownershipTransferred) {
                    runCatching { recognizer.destroy() }
                }
            }
        }
    }

    /**
     * Lists recognition languages. When [recognizer] is supplied the caller
     * owns it; otherwise a temporary recognizer is created and destroyed.
     */
    private suspend fun platformRecognitionLanguages(
        allowOnlineFallback: Boolean,
        requestLanguageSwitch: Boolean,
        recognizer: AndroidSpeechRecognizer? = null
    ): List<String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return null
        }
        if (!platformRecognizerAvailable(allowOnlineFallback)) {
            return null
        }

        return withContext(Dispatchers.Main.immediate) {
            val checkRecognizer = recognizer ?: try {
                createPlatformRecognizer(allowOnlineFallback)
            } catch (error: Throwable) {
                Log.w(TAG, "Unable to create Android recognizer for language support", error)
                return@withContext null
            }
            try {
                val supportResult = CompletableDeferred<RecognitionSupport?>()
                val supportIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(
                        RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                        RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                    )
                    if (requestLanguageSwitch && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_DETECTION, true)
                        putExtra(
                            RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH,
                            RecognizerIntent.LANGUAGE_SWITCH_BALANCED
                        )
                    }
                    putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, !allowOnlineFallback)
                }
                checkRecognizer.checkRecognitionSupport(
                    supportIntent,
                    activity.mainExecutor,
                    object : RecognitionSupportCallback {
                        override fun onSupportResult(recognitionSupport: RecognitionSupport) {
                            supportResult.complete(recognitionSupport)
                        }

                        override fun onError(error: Int) {
                            Log.i(TAG, "Android language-switch support check failed: $error")
                            supportResult.complete(null)
                        }
                    }
                )
                val support = withTimeoutOrNull(PLATFORM_SUPPORT_CHECK_TIMEOUT_MS) {
                    supportResult.await()
                } ?: return@withContext null
                val usableLanguages = buildList {
                    addAll(support.installedOnDeviceLanguages)
                    if (allowOnlineFallback) {
                        addAll(support.onlineLanguages)
                    }
                }
                NativeSttLanguagePolicy.normalizeLocaleIds(usableLanguages)
                    .takeIf { it.isNotEmpty() }
            } catch (error: Throwable) {
                Log.w(TAG, "Android language-switch support check failed", error)
                null
            } finally {
                if (recognizer == null) {
                    runCatching { checkRecognizer.destroy() }
                }
            }
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
            AndroidSpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ->
                "The speech recognizer does not support this language. Choose another speech language or STT mode."
            AndroidSpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE ->
                "The speech language is not downloaded. Download it in your speech recognition settings or choose another STT mode."
            else -> "Android speech recognition failed"
        }
    }

    private suspend fun stopInternal(emitDone: Boolean, awaitCompletion: Boolean) {
        val source = pcmSource
        source?.stop()
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
        retirePcmSource(source)
        if (emitDone) {
            emitDone(if (platformRecognizer != null) "android_speech" else "mlkit")
        }
    }

    /** Allocates off-main, gates delivery by generation, and retires cancelled allocations. */
    private suspend fun createPcmSource(generation: Int): NativeDictationAudioSource {
        var allocated: NativeDictationAudioSource? = null
        try {
            return withContext(Dispatchers.IO) {
                NativeDictationAudioSource.create(
                    onAudio = { bytes ->
                        mainHandler.post {
                            if (pcmGeneration == generation) {
                                eventSink?.success(mapOf("type" to "audio", "pcm" to bytes))
                            }
                        }
                    },
                    onFailure = {
                        scope.launch {
                            if (pcmGeneration == generation) {
                                pcmSource?.stop()
                                if (pcmGeneration == generation) {
                                    emitError("AUDIO_PRESERVATION_FAILED", "Unable to preserve dictation audio", "android_audio")
                                }
                            }
                        }
                    },
                ).also { allocated = it }
            }
        } catch (error: Throwable) {
            // withContext can be cancelled after allocation but before delivery.
            withContext(NonCancellable) {
                allocated?.stop()
                allocated?.closeDescriptor()
            }
            throw error
        }
    }

    /** Stops without cancellation and drains admitted main-thread events before closing input. */
    private suspend fun retirePcmSource(source: NativeDictationAudioSource?) {
        if (source == null) return
        withContext(NonCancellable) {
            source.stop()
            // Drain admitted PCM events before the stop reply detaches Dart.
            suspendCoroutine<Unit> { continuation ->
                mainHandler.post {
                    if (pcmSource === source) {
                        pcmSource = null
                        pcmGeneration = null
                    }
                    source.closeDescriptor()
                    continuation.resume(Unit)
                }
            }
        }
    }

    private suspend fun localesPayload(deviceLocaleId: String?): Map<String, Any?> {
        val systemLocale = parseLocale(deviceLocaleId)
        val installedLocales = platformRecognitionLanguages(
            allowOnlineFallback = false,
            requestLanguageSwitch = false
        ).orEmpty()
            .map(Locale::forLanguageTag)
            .filter { it.language.isNotBlank() }
        val candidateLocales = installedLocales.ifEmpty {
            Locale.getAvailableLocales().toList()
        }
        val locales = candidateLocales
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
        private const val PLATFORM_SUPPORT_CHECK_TIMEOUT_MS = 1200L
    }
}
