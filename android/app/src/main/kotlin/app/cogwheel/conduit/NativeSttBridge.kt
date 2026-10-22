package app.cogwheel.conduit

import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
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

class NativeSttBridge internal constructor(
    private val activity: MainActivity,
    private val audioSourceFactory: ((Double) -> Unit, (Throwable) -> Unit, Boolean) -> SttAudioSource =
        { onLevel, onError, voiceCall -> MeteredSttAudioSource(onLevel, onError, voiceCall) }
) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var eventSink: EventChannel.EventSink? = null
    @Volatile
    private var activeMlKitRecognizer: MlKitSpeechRecognizer? = null
    private var activePlatformRecognizer: AndroidSpeechRecognizer? = null
    private var recognitionJob: kotlinx.coroutines.Job? = null
    @Volatile
    private var meteredAudioSource: SttAudioSource? = null
    private var platformRestartJob: kotlinx.coroutines.Job? = null
    private var voiceCallCapture = false
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
    private var platformCaptureStartedAt = 0L
    private val languageSwitchSupport = mutableMapOf<Boolean, List<String>>()
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
                val voiceCall = call.argument<Boolean>("voiceCall") ?: false
                scope.launch {
                    start(
                        localeId,
                        emitPartialResults,
                        accumulateResults,
                        allowOnlineFallback,
                        voiceCall,
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

    private suspend fun checkAvailability(
        localeId: String?,
        allowOnlineFallback: Boolean
    ): Map<String, Any?> {
        if (platformRecognizerAvailable(allowOnlineFallback)) {
            val automatic = NativeSttLanguagePolicy.usesPlatformLanguageSwitch(localeId, Build.VERSION.SDK_INT) &&
                NativeSttLanguagePolicy.hasMultipleLanguages(languageSwitchSupport[allowOnlineFallback].orEmpty())
            return available(if (automatic) "android_speech_auto" else "android_speech")
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
        voiceCall: Boolean,
        result: MethodChannel.Result
    ) {
        val generation = recognitionGeneration + 1
        recognitionGeneration = generation
        stopInternal(emitDone = false, awaitCompletion = false)
        voiceCallCapture = voiceCall
        val usePlatformCapture = platformRecognizerAvailable(allowOnlineFallback) &&
            (!voiceCall || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && usesSystemOnDeviceRecognizer(allowOnlineFallback)))
        val languageSwitch = platformLanguageSwitch(localeId, allowOnlineFallback)
        val usePlatformLanguageSwitch = languageSwitch != null
        // Use the phone's recognizer directly. ML Kit preparation/downloads
        // are a fallback only for devices without a platform recognizer.
        val prepared = if (usePlatformCapture) {
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
            if (usePlatformCapture) {
                try {
                    startPlatformRecognizer(
                        localeId,
                        emitPartialResults,
                        accumulateResults,
                        allowOnlineFallback,
                        languageSwitch
                    )
                    val engineName = if (usePlatformLanguageSwitch) {
                        "android_speech_auto"
                    } else {
                        "android_speech"
                    }
                    result.success(available(engineName))
                } catch (error: Throwable) {
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
        val audio = audioSourceFactory(
            { level ->
                activity.runOnUiThread {
                    if (isCurrentGeneration(generation) && activeMlKitRecognizer === recognizer) {
                        emit(mapOf("type" to "level", "level" to level, "engine" to engineName))
                    }
                }
            },
            { error ->
                activity.runOnUiThread {
                    if (isCurrentGeneration(generation) && activeMlKitRecognizer === recognizer) {
                        emitError("MICROPHONE_ERROR", error.message ?: "Microphone capture failed", engineName)
                        emitDone(engineName)
                    }
                }
            },
            voiceCallCapture
        )
        try {
            audio.start(scope)
        } catch (error: Throwable) {
            audio.close()
            recognizer.close()
            result.success(unavailable(error.message ?: "Microphone capture failed"))
            return
        }
        meteredAudioSource = audio
        activeMlKitRecognizer = recognizer
        emitStatus("listening", engineName)
        recognitionJob = scope.launch(Dispatchers.IO) {
            var committedText = ""
            var doneEmitted = false
            try {
                val request = speechRecognizerRequest {
                    audioSource = AudioSource.fromPfd(audio.descriptor)
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
                audio.close()
                if (meteredAudioSource === audio) meteredAudioSource = null
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
        // Keep one recognizer for the whole capture session. Rebinding after
        // destroying a recognizer can drop the system service connection.
        val recognizer = languageSwitch?.recognizer
            ?: createPlatformRecognizer(allowOnlineFallback)
        platformCaptureStartedAt = SystemClock.elapsedRealtime()
        activePlatformRecognizer = recognizer
        try {
            // Android 13+ accepts our PCM stream. The same 32 ms frames drive
            // the meter and the system's on-device transcriber; no second mic.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                usesSystemOnDeviceRecognizer(allowOnlineFallback)) {
                val generation = recognitionGeneration
                val audio = audioSourceFactory(
                    { level -> activity.runOnUiThread {
                        if (isCurrentGeneration(generation) &&
                            activePlatformRecognizer === recognizer && !platformStopRequested) {
                            emit(mapOf("type" to "level", "level" to level, "engine" to platformEngineName))
                        }
                    } },
                    { error -> activity.runOnUiThread {
                        if (isCurrentGeneration(generation) &&
                            activePlatformRecognizer === recognizer && !platformStopRequested) {
                            meteredAudioSource?.close()
                            meteredAudioSource = null
                            platformStopRequested = true
                            emitError("MICROPHONE_ERROR", error.message ?: "Microphone capture failed", platformEngineName)
                            emitDone(platformEngineName)
                        }
                    } },
                    voiceCallCapture
                )
                meteredAudioSource = audio
                audio.start(scope)
            }
            recognizer.setRecognitionListener(platformRecognitionListener)
            recognizer.startListening(platformRecognizerIntent())
        } catch (error: Throwable) {
            meteredAudioSource?.close()
            meteredAudioSource = null
            activePlatformRecognizer = null
            platformStopRequested = true
            runCatching { recognizer.destroy() }
            throw error
        }
        // Diagnostic metadata only; never log audio or recognized words.
        Log.i(TAG, "Capture started engine=$platformEngineName onDevice=${usesSystemOnDeviceRecognizer(allowOnlineFallback)}")
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
            recognitionAvailable = AndroidSpeechRecognizer.isRecognitionAvailable(context),
            onDeviceRecognitionAvailable = systemOnDeviceRecognitionAvailable()
        )
    }

    private val platformRecognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            if (platformStopRequested || activePlatformRecognizer == null) return
            Log.i(TAG, "Capture ready after ${SystemClock.elapsedRealtime() - platformCaptureStartedAt}ms")
            emitStatus("listening", platformEngineName)
        }

        override fun onBeginningOfSpeech() {}

        override fun onRmsChanged(rmsdB: Float) {
            if (platformStopRequested || activePlatformRecognizer == null || !rmsdB.isFinite() ||
                meteredAudioSource != null) return
            // Android reports recognizer-relative dB rather than PCM amplitude.
            val level = ((rmsdB - 1f) / 9f).coerceIn(0f, 1f).toDouble()
            emit(mapOf("type" to "level", "level" to level, "engine" to platformEngineName))
        }

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
            emitPlatformResult(results)
            restartPlatformRecognizerIfActive()
        }

        override fun onSegmentResults(segmentResults: Bundle) {
            emitPlatformResult(segmentResults)
        }

        override fun onEndOfSegmentedSession() {
            if (platformStopRequested) return
            platformStopRequested = true
            meteredAudioSource?.close()
            meteredAudioSource = null
            emitDone(platformEngineName)
        }

        private fun emitPlatformResult(results: Bundle?) {
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
        meteredAudioSource?.close()
        meteredAudioSource = null
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
                meteredAudioSource?.let { audio ->
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, audio.descriptor)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
                    putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
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
    private fun platformLanguageSwitch(
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
        // Optional capability discovery belongs to the language picker. Never
        // wait for its support callback while the user is already speaking.
        val languages = languageSwitchSupport[allowOnlineFallback]
            ?.takeIf { NativeSttLanguagePolicy.hasMultipleLanguages(it) }
            ?: return null
        val recognizer = try {
            createPlatformRecognizer(allowOnlineFallback)
        } catch (error: Throwable) {
            Log.w(TAG, "Unable to create Android recognizer for language switching", error)
            return null
        }
        return PlatformLanguageSwitch(recognizer, languages)
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
        meteredAudioSource?.close()
        meteredAudioSource = null
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

    private suspend fun localesPayload(deviceLocaleId: String?): Map<String, Any?> {
        val systemLocale = parseLocale(deviceLocaleId)
        val supportedLanguages = platformRecognitionLanguages(
            allowOnlineFallback = false,
            requestLanguageSwitch = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
        ).orEmpty()
        languageSwitchSupport[false] = supportedLanguages
        val installedLocales = supportedLanguages
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
