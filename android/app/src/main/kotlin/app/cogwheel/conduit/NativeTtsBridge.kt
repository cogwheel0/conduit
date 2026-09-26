package app.cogwheel.conduit

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.util.Log
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
        val volume: Float,
        val voiceCall: Boolean
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
    private var appliedVoiceCallRouting: Boolean? = null
    private val callAudioKeepAlive = SilentCallAudioKeepAlive()
    private val releaseCallAudioKeepAliveTask = Runnable { callAudioKeepAlive.stop() }

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
                    volume = floatArgument(call, "volume", 1.0f, 0.0f, 1.0f),
                    voiceCall = call.argument<Boolean>("voiceCall") == true
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
        releaseCallAudioKeepAliveNow()
        tts?.shutdown()
        tts = null
        initState = InitState.NOT_STARTED
        appliedVoiceCallRouting = null
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
                releaseCallAudioKeepAliveNow()
                tts?.shutdown()
                tts = null
                initState = InitState.NOT_STARTED
            }
            InitState.NOT_STARTED -> Unit
        }

        initState = InitState.INITIALIZING
        // A fresh engine starts on its default routing, so the next utterance
        // has to set the attributes again rather than trust the cached value.
        appliedVoiceCallRouting = null
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
                    // The next sentence of the answer usually follows at once.
                    releaseCallAudioKeepAliveSoon()
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
                    releaseCallAudioKeepAliveNow()
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
                    releaseCallAudioKeepAliveNow()
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

        applyAudioRouting(engine, request.voiceCall)
        engine.setSpeechRate(request.rate)
        engine.setPitch(request.pitch)

        val text = request.text.substring(baseOffset.coerceIn(0, request.text.length))
        if (text.isBlank()) {
            if (request.voiceCall) {
                releaseCallAudioKeepAliveSoon()
            } else {
                releaseCallAudioKeepAliveNow()
            }
            emit(mapOf("type" to "complete"))
            return true
        }

        // Started before the engine so Conduit is already active on the call
        // route when the engine's speech begins.
        if (request.voiceCall) {
            holdCallAudioKeepAlive()
        } else {
            releaseCallAudioKeepAliveNow()
        }

        val utteranceId = UUID.randomUUID().toString()
        activeUtterance = ActiveUtterance(utteranceId, request, baseOffset)
        lastProgressStart = baseOffset
        if (isResume) {
            resumeUtteranceIds.add(utteranceId)
        }

        val params = Bundle().apply {
            putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, request.volume)
            // Audio attributes win over the stream param on engines that honour
            // them, but older ones only read the stream, so send both.
            putInt(
                TextToSpeech.Engine.KEY_PARAM_STREAM,
                if (request.voiceCall) {
                    AudioManager.STREAM_VOICE_CALL
                } else {
                    AudioManager.STREAM_MUSIC
                }
            )
        }
        val started = engine.speak(text, TextToSpeech.QUEUE_FLUSH, params, utteranceId) ==
            TextToSpeech.SUCCESS
        if (!started && activeUtterance?.id == utteranceId) {
            activeUtterance = null
            resumeUtteranceIds.remove(utteranceId)
        }
        if (!started) {
            releaseCallAudioKeepAliveNow()
        }
        return started
    }

    // See SilentCallAudioKeepAlive for why a voice call needs this.
    private fun holdCallAudioKeepAlive() {
        mainHandler.removeCallbacks(releaseCallAudioKeepAliveTask)
        callAudioKeepAlive.start()
    }

    // Answers are spoken a sentence at a time, and the next sentence can wait on
    // the model. Stopping between sentences would drop the call route and bring
    // it back for every one, so the keep-alive outlives the last utterance by a
    // short grace and the next voice-call utterance picks it back up.
    private fun releaseCallAudioKeepAliveSoon() {
        mainHandler.removeCallbacks(releaseCallAudioKeepAliveTask)
        if (!callAudioKeepAlive.isRunning) return
        mainHandler.postDelayed(releaseCallAudioKeepAliveTask, CALL_AUDIO_KEEP_ALIVE_GRACE_MS)
    }

    private fun releaseCallAudioKeepAliveNow() {
        mainHandler.removeCallbacks(releaseCallAudioKeepAliveTask)
        callAudioKeepAlive.stop()
    }

    // Puts the engine on the voice-communication stream for the duration of a
    // voice call. Without this the engine speaks as USAGE_MEDIA while the call
    // holds audio focus as USAGE_VOICE_COMMUNICATION in MODE_IN_COMMUNICATION.
    // The two are routed separately, so setCommunicationDevice() never moves
    // device TTS to the call's speakerphone choice, and the media stream goes
    // quiet once the app is backgrounded during the call.
    private fun applyAudioRouting(engine: TextToSpeech, voiceCall: Boolean) {
        if (appliedVoiceCallRouting == voiceCall) return
        val attributes = AudioAttributes.Builder()
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .setUsage(
                if (voiceCall) {
                    AudioAttributes.USAGE_VOICE_COMMUNICATION
                } else {
                    AudioAttributes.USAGE_MEDIA
                }
            )
            .build()
        engine.setAudioAttributes(attributes)
        appliedVoiceCallRouting = voiceCall
    }

    private fun stopInternal(emitCancel: Boolean): Boolean {
        releaseCallAudioKeepAliveNow()
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
            releaseCallAudioKeepAliveSoon()
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

        // Long enough to bridge the wait for the next sentence of a streamed
        // answer, short enough that the track does not linger once the call
        // has gone back to listening.
        private const val CALL_AUDIO_KEEP_ALIVE_GRACE_MS = 5_000L
    }
}

/**
 * Keeps a silent voice-communication track playing in Conduit's own process
 * while device TTS speaks during a voice call (issue #716).
 *
 * The TTS engine renders speech in its own process, so none of that audio
 * counts as Conduit's. Since Android 12, AudioService keeps an app as the
 * MODE_IN_COMMUNICATION owner, and applies its setCommunicationDevice() or
 * speakerphone choice, only while that app's own uid has voice-communication
 * playback or capture running; a few seconds without either and the mode
 * falls back to normal and the call's route stops applying. A server STT call
 * keeps its recorder running, which is enough. With the platform recognizer,
 * which also runs in another process, nothing of Conduit's is active, so the
 * engine's speech played from the earpiece whatever the speaker button said,
 * and the route read-back refused the speaker when the button was pressed.
 *
 * Looping a short static buffer of silence keeps the uid active: no thread,
 * nothing audible, one small buffer. It only matters on Android 12 and newer,
 * so older versions skip it, and failing to create the track only costs the
 * route fix: speech carries on as before.
 */
private class SilentCallAudioKeepAlive {
    private var track: AudioTrack? = null

    val isRunning: Boolean
        get() = track != null

    fun start() {
        if (track != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val created = try {
            createTrack()
        } catch (error: Exception) {
            Log.w(TAG, "Unable to create the call audio keep-alive track", error)
            null
        } ?: return
        try {
            created.play()
            track = created
        } catch (error: Exception) {
            Log.w(TAG, "Unable to start the call audio keep-alive track", error)
            created.release()
        }
    }

    fun stop() {
        val current = track ?: return
        track = null
        try {
            current.stop()
        } catch (error: IllegalStateException) {
            Log.w(TAG, "Unable to stop the call audio keep-alive track", error)
        }
        current.release()
    }

    private fun createTrack(): AudioTrack? {
        val created = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(FRAMES * BYTES_PER_FRAME)
            .build()
        // A static track only becomes playable once its data is written, and
        // loop points can only be set after that.
        val written = created.write(ShortArray(FRAMES), 0, FRAMES)
        if (written != FRAMES ||
            created.state != AudioTrack.STATE_INITIALIZED ||
            created.setLoopPoints(0, FRAMES, -1) != AudioTrack.SUCCESS
        ) {
            Log.w(TAG, "Call audio keep-alive track did not initialize (written=$written)")
            created.release()
            return null
        }
        return created
    }

    private companion object {
        const val TAG = "NativeTtsBridge"
        const val SAMPLE_RATE = 16_000
        const val BYTES_PER_FRAME = 2

        // Half a second of silence, looped for as long as the call speaks.
        const val FRAMES = SAMPLE_RATE / 2
    }
}
