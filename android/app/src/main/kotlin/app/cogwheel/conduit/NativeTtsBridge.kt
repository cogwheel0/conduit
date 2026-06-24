package app.cogwheel.conduit

import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.UUID

class NativeTtsBridge(private val activity: MainActivity) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private enum class InitState {
        NOT_STARTED,
        INITIALIZING,
        READY,
        FAILED
    }

    private data class SpeakRequest(
        val text: String,
        val voiceIdentifier: String?,
        val rate: Float,
        val pitch: Float,
        val volume: Float
    )

    private data class ActiveUtterance(
        val id: String,
        val request: SpeakRequest,
        val baseOffset: Int
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingInitCallbacks = mutableListOf<(Boolean) -> Unit>()
    private var eventSink: EventChannel.EventSink? = null
    private var tts: TextToSpeech? = null
    private var initState = InitState.NOT_STARTED
    private var activeUtterance: ActiveUtterance? = null
    private var pausedRequest: SpeakRequest? = null
    private var pausedOffset = 0
    private var lastProgressStart = 0
    private var suppressStopForUtteranceId: String? = null
    private val resumeUtteranceIds = mutableSetOf<String>()

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
            "isAvailable" -> ensureInitialized { available ->
                result.success(available)
            }
            "getVoices" -> ensureInitialized { available ->
                if (!available) {
                    result.success(emptyList<Map<String, Any?>>())
                    return@ensureInitialized
                }
                result.success(voicesPayload())
            }
            "speak" -> ensureInitialized { available ->
                if (!available) {
                    result.success(false)
                    return@ensureInitialized
                }
                val text = call.argument<String>("text")?.trim()
                if (text.isNullOrEmpty()) {
                    result.success(false)
                    return@ensureInitialized
                }
                val request = SpeakRequest(
                    text = text,
                    voiceIdentifier = call.argument<String>("voiceIdentifier")
                        ?.trim()
                        ?.takeIf { it.isNotEmpty() },
                    rate = floatArgument(call, "rate", 0.5f, 0.1f, 3.0f),
                    pitch = floatArgument(call, "pitch", 1.0f, 0.1f, 2.0f),
                    volume = floatArgument(call, "volume", 1.0f, 0.0f, 1.0f)
                )
                result.success(speakRequest(request, baseOffset = 0, isResume = false))
            }
            "stop" -> {
                val stopped = stopInternal(emitCancel = true)
                result.success(stopped)
            }
            "pause" -> {
                result.success(pauseInternal())
            }
            "resume" -> {
                result.success(resumeInternal())
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        stopInternal(emitCancel = false)
        tts?.shutdown()
        tts = null
        initState = InitState.NOT_STARTED
        pendingInitCallbacks.clear()
    }

    private fun ensureInitialized(callback: (Boolean) -> Unit) {
        when (initState) {
            InitState.READY -> {
                callback(true)
                return
            }
            InitState.INITIALIZING -> {
                pendingInitCallbacks.add(callback)
                return
            }
            InitState.FAILED -> {
                tts?.shutdown()
                tts = null
                initState = InitState.NOT_STARTED
            }
            InitState.NOT_STARTED -> Unit
        }

        initState = InitState.INITIALIZING
        pendingInitCallbacks.add(callback)
        tts = TextToSpeech(activity.applicationContext) { status ->
            mainHandler.post {
                val ready = status == TextToSpeech.SUCCESS
                initState = if (ready) InitState.READY else InitState.FAILED
                if (ready) {
                    tts?.setOnUtteranceProgressListener(progressListener)
                }
                val callbacks = pendingInitCallbacks.toList()
                pendingInitCallbacks.clear()
                callbacks.forEach { it(ready) }
            }
        }
    }

    private val progressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String) {
            mainHandler.post {
                if (resumeUtteranceIds.remove(utteranceId)) {
                    emit(mapOf("type" to "continue"))
                } else {
                    emit(mapOf("type" to "start"))
                }
            }
        }

        override fun onDone(utteranceId: String) {
            mainHandler.post {
                if (activeUtterance?.id == utteranceId) {
                    activeUtterance = null
                    pausedRequest = null
                    pausedOffset = 0
                    lastProgressStart = 0
                    emit(mapOf("type" to "complete"))
                }
            }
        }

        @Deprecated("Deprecated in Android framework")
        override fun onError(utteranceId: String) {
            onError(utteranceId, TextToSpeech.ERROR)
        }

        override fun onError(utteranceId: String, errorCode: Int) {
            mainHandler.post {
                if (activeUtterance?.id == utteranceId) {
                    activeUtterance = null
                    pausedRequest = null
                    pausedOffset = 0
                    lastProgressStart = 0
                    resumeUtteranceIds.remove(utteranceId)
                    emit(
                        mapOf(
                            "type" to "error",
                            "message" to "Android TTS failed with code $errorCode"
                        )
                    )
                }
            }
        }

        override fun onStop(utteranceId: String, interrupted: Boolean) {
            mainHandler.post {
                if (suppressStopForUtteranceId == utteranceId) {
                    suppressStopForUtteranceId = null
                    return@post
                }
                if (activeUtterance?.id == utteranceId) {
                    activeUtterance = null
                    emit(mapOf("type" to "cancel"))
                }
            }
        }

        override fun onRangeStart(
            utteranceId: String,
            start: Int,
            end: Int,
            frame: Int
        ) {
            mainHandler.post {
                val active = activeUtterance ?: return@post
                if (active.id != utteranceId) return@post
                val absoluteStart = active.baseOffset + start
                val absoluteEnd = active.baseOffset + end
                lastProgressStart = absoluteStart.coerceAtLeast(0)
                emit(
                    mapOf(
                        "type" to "progress",
                        "start" to absoluteStart,
                        "end" to absoluteEnd
                    )
                )
            }
        }
    }

    private fun speakRequest(request: SpeakRequest, baseOffset: Int, isResume: Boolean): Boolean {
        val engine = tts ?: return false
        activeUtterance?.id?.let { suppressStopForUtteranceId = it }
        engine.stop()

        request.voiceIdentifier?.let { requested ->
            resolveVoice(engine, requested)?.let { engine.voice = it }
                ?: parseLocale(requested)?.let { engine.language = it }
        }

        engine.setSpeechRate(request.rate)
        engine.setPitch(request.pitch)

        val text = request.text.substring(baseOffset.coerceIn(0, request.text.length))
        if (text.isBlank()) {
            emit(mapOf("type" to "complete"))
            return true
        }

        val utteranceId = UUID.randomUUID().toString()
        activeUtterance = ActiveUtterance(utteranceId, request, baseOffset)
        lastProgressStart = baseOffset
        if (isResume) {
            resumeUtteranceIds.add(utteranceId)
        }

        val params = Bundle().apply {
            putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, request.volume)
        }
        val started = engine.speak(text, TextToSpeech.QUEUE_FLUSH, params, utteranceId) ==
            TextToSpeech.SUCCESS
        if (!started && activeUtterance?.id == utteranceId) {
            activeUtterance = null
            resumeUtteranceIds.remove(utteranceId)
        }
        return started
    }

    private fun stopInternal(emitCancel: Boolean): Boolean {
        val engine = tts ?: return false
        activeUtterance = null
        pausedRequest = null
        pausedOffset = 0
        lastProgressStart = 0
        suppressStopForUtteranceId = null
        resumeUtteranceIds.clear()
        val stopped = engine.stop() != TextToSpeech.ERROR
        if (emitCancel && stopped) {
            emit(mapOf("type" to "cancel"))
        }
        return stopped
    }

    private fun pauseInternal(): Boolean {
        val engine = tts ?: return false
        val active = activeUtterance ?: return false
        pausedRequest = active.request
        pausedOffset = lastProgressStart.coerceIn(0, active.request.text.length)
        suppressStopForUtteranceId = active.id
        val stopped = engine.stop() != TextToSpeech.ERROR
        if (stopped) {
            activeUtterance = null
            emit(mapOf("type" to "pause"))
        }
        return stopped
    }

    private fun resumeInternal(): Boolean {
        val request = pausedRequest ?: return false
        val offset = pausedOffset.coerceIn(0, request.text.length)
        pausedRequest = null
        pausedOffset = 0
        return speakRequest(request, baseOffset = offset, isResume = true)
    }

    private fun voicesPayload(): List<Map<String, Any?>> {
        val voices = tts?.voices ?: return emptyList()
        return voices
            .sortedWith(compareBy<Voice> { it.locale.toLanguageTag() }.thenBy { it.name })
            .map { voice ->
                mapOf(
                    "id" to voice.name,
                    "identifier" to voice.name,
                    "name" to voice.name,
                    "locale" to voice.locale.toLanguageTag(),
                    "language" to voice.locale.toLanguageTag(),
                    "quality" to voice.quality,
                    "qualityName" to qualityName(voice.quality),
                    "latency" to voice.latency,
                    "requiresNetwork" to voice.isNetworkConnectionRequired,
                    "features" to voice.features?.toList().orEmpty()
                )
            }
    }

    private fun resolveVoice(engine: TextToSpeech, requested: String): Voice? {
        val normalized = requested.trim()
        if (normalized.isEmpty()) return null
        return engine.voices?.firstOrNull { voice ->
            voice.name.equals(normalized, ignoreCase = true) ||
                voice.locale.toLanguageTag().equals(normalized, ignoreCase = true) ||
                voice.locale.toString().equals(normalized, ignoreCase = true)
        }
    }

    private fun parseLocale(value: String): Locale? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return null
        val locale = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            Locale.forLanguageTag(trimmed.replace('_', '-'))
        } else {
            Locale(trimmed)
        }
        return if (locale.language.isNullOrEmpty()) null else locale
    }

    private fun floatArgument(
        call: MethodCall,
        key: String,
        fallback: Float,
        min: Float,
        max: Float
    ): Float {
        val value = when (val raw = call.argument<Any>(key)) {
            is Number -> raw.toFloat()
            is String -> raw.toFloatOrNull()
            else -> null
        } ?: fallback
        return value.coerceIn(min, max)
    }

    private fun qualityName(quality: Int): String {
        return when (quality) {
            Voice.QUALITY_VERY_LOW -> "Very Low"
            Voice.QUALITY_LOW -> "Low"
            Voice.QUALITY_NORMAL -> "Normal"
            Voice.QUALITY_HIGH -> "High"
            Voice.QUALITY_VERY_HIGH -> "Very High"
            else -> "Unknown"
        }
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "app.cogwheel.conduit/native_android_tts"
        private const val EVENT_CHANNEL = "app.cogwheel.conduit/native_android_tts/events"
    }
}
