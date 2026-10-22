package app.cogwheel.conduit.phonon

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.system.Os
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/** Native synthesis and bounded AudioTrack playback; never opens a microphone or another TTS engine. */
class PhononTtsBridge(private val context: Context) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    // The handle is used/freed only here. Stop reaches the callback out of band.
    private val synthesis = Executors.newSingleThreadExecutor()
    private val generation = AtomicLong()
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
    private val lock = Object()
    private var engine: PhononTTS? = null
    @Volatile private var ready = false
    @Volatile private var disposed = false
    private var sink: EventChannel.EventSink? = null
    private var track: AudioTrack? = null
    private var requestId: Long? = null
    private var paused = false

    fun setup(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, "$CHANNEL/events").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> prepare(result)
            "speak" -> {
                val id = call.argument<Number>("requestId")?.toLong()
                val voice = call.argument<String>("voiceIdentifier")
                val text = call.argument<String>("text")?.trim()
                if (!ready || disposed || id == null || text.isNullOrEmpty() || voice != PhononVoicePack.VOICE_ID) {
                    result.error("phonon_unavailable", "Phonon Zoey is unavailable. No other voice was used.", null)
                    return
                }
                stopOutput()
                val token = generation.incrementAndGet()
                synchronized(lock) { requestId = id; paused = false }
                val volume = (call.argument<Number>("volume")?.toFloat() ?: 1f).coerceIn(0f, 1f)
                val voiceCall = call.argument<Boolean>("voiceCall") == true
                synthesis.execute { speak(id, token, text, volume, voiceCall) }
                result.success(true)
            }
            "stop" -> { stopOutput(); result.success(true) }
            "pause" -> {
                synchronized(lock) {
                    paused = true
                    track?.pause()
                    requestId?.let { emit("pause", it, generation.get()) }
                }
                result.success(true)
            }
            "resume" -> {
                synchronized(lock) {
                    paused = false
                    track?.play()
                    requestId?.let { emit("continue", it, generation.get()) }
                    lock.notifyAll()
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        if (disposed || !Build.SUPPORTED_ABIS.contains("arm64-v8a")) {
            result.error("phonon_unsupported", "Phonon Zoey requires an ARM64 device.", null)
            return
        }
        synthesis.execute {
            try {
                if (engine == null) {
                    val start = SystemClock.elapsedRealtime()
                    val pack = PhononVoicePack.install(context)
                    Os.setenv("RAYON_NUM_THREADS", "2", true)
                    val loaded = PhononTTS(pack.path, "en")
                    try {
                        check(loaded.voices.contains(PhononVoicePack.VOICE)) { "Zoey is missing from the voice pack" }
                        loaded.setVoice(PhononVoicePack.VOICE)
                    } catch (error: Throwable) { loaded.close(); throw error }
                    engine = loaded
                    Log.i(TAG, "ready engine=phonon-31m-en-q8 voice=Zoey loadMs=${SystemClock.elapsedRealtime() - start}")
                }
                ready = !disposed
                main.post { result.success(ready) }
            } catch (error: Throwable) {
                ready = false
                Log.e(TAG, "prepare failed ${error.javaClass.simpleName}")
                main.post { result.error("phonon_load_failed", "Could not load Phonon Zoey. No other voice was used.", null) }
            }
        }
    }

    private fun current(token: Long) = !disposed && generation.get() == token

    private fun speak(id: Long, token: Long, text: String, volume: Float, voiceCall: Boolean) {
        if (!current(token)) return
        var output: AudioTrack? = null
        try {
            val minimum = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
            check(minimum > 0) { "Unsupported PCM output" }
            val player = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(if (voiceCall) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build())
                .setBufferSizeInBytes(maxOf(minimum, 1920 * 4 * 2))
                .setTransferMode(AudioTrack.MODE_STREAM).build()
            output = player
            synchronized(lock) {
                if (!current(token)) return
                check(player.state == AudioTrack.STATE_INITIALIZED) { "PCM output failed to initialize" }
                track = player
                player.setVolume(volume)
                if (!paused) player.play()
            }
            var written = 0L
            var started = false
            val start = SystemClock.elapsedRealtime()
            var firstPcmMs = -1L
            val timing = checkNotNull(engine).speak(text) { pcm ->
                if (firstPcmMs < 0) firstPcmMs = SystemClock.elapsedRealtime() - start
                var offset = 0
                while (offset < pcm.size && current(token)) {
                    synchronized(lock) {
                        while (paused && current(token)) lock.wait()
                        if (current(token)) {
                            // Nonblocking writes under the control lock prevent a write after stop's flush.
                            val count = player.write(pcm, offset, minOf(1920, pcm.size - offset), AudioTrack.WRITE_NON_BLOCKING)
                            check(count >= 0) { "PCM output write failed ($count)" }
                            if (count > 0) {
                                offset += count
                                written += count
                                if (!started) { started = true; emit("start", id, token) }
                            } else lock.wait(5)
                        }
                    }
                }
                current(token)
            }
            // Synthesis completion is not playback completion. Keep the microphone suspended until drained.
            var lastHead = 0L
            var lastProgress = SystemClock.elapsedRealtime()
            while (current(token)) {
                val done = synchronized(lock) {
                    while (paused && current(token)) { lock.wait(); lastProgress = SystemClock.elapsedRealtime() }
                    val head = player.playbackHeadPosition.toLong() and 0xffffffffL
                    if (head != lastHead) { lastHead = head; lastProgress = SystemClock.elapsedRealtime() }
                    check(SystemClock.elapsedRealtime() - lastProgress < 5000) { "PCM playback stalled" }
                    if (head < written && current(token)) lock.wait(5)
                    head >= written
                }
                if (done) break
            }
            if (current(token)) {
                check(written > 0) { "Phonon generated no audio" }
                Log.i(TAG, "played request=$id engine=phonon-31m-en-q8 voice=Zoey samples=$written firstPcmMs=$firstPcmMs nativeFrames=${timing.frames}")
                emit("complete", id, token)
            }
        } catch (error: Throwable) {
            if (current(token)) {
                Log.e(TAG, "playback failed request=$id ${error.javaClass.simpleName}")
                emit("error", id, token, "Phonon Zoey could not play this response. No other voice was used.")
            }
        } finally {
            if (!current(token)) Log.i(TAG, "cancelled request=$id producerQuiesced=true")
            synchronized(lock) {
                if (track === output) {
                    track = null
                    if (current(token)) { requestId = null; paused = false }
                }
                output?.let { player ->
                    try { player.pause(); player.flush() } catch (_: IllegalStateException) { }
                    player.release()
                }
                lock.notifyAll()
            }
        }
    }

    private fun emit(type: String, id: Long, token: Long, message: String? = null) {
        main.post {
            if (current(token)) sink?.success(mapOf("type" to type, "requestId" to id,
                "backend" to "phonon", "voice" to PhononVoicePack.VOICE_ID, "message" to message))
        }
    }

    private fun stopOutput() {
        generation.incrementAndGet()
        synchronized(lock) {
            val stopped = requestId
            requestId = null
            paused = false
            track?.let { try { it.pause(); it.flush() } catch (_: IllegalStateException) { } }
            lock.notifyAll()
            if (stopped != null) Log.i(TAG, "stopped request=$stopped outputFlushed=true")
        }
    }

    fun dispose() {
        disposed = true
        ready = false
        stopOutput()
        // Wait behind the running producer before freeing its handle. Never free on the UI thread.
        synthesis.execute { engine?.close(); engine = null }
        synthesis.shutdown()
        sink = null
    }

    companion object {
        private const val CHANNEL = "app.cogwheel.conduit/phonon_tts"
        private const val TAG = "ConduitPhonon"
        private const val RATE = 24000
    }
}
