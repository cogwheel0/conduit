package app.cogwheel.conduit

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The realtime voice's playback queue, mirroring Open WebUI's
 * `realtime-audio.js` worklet: speech is queued per item and starts once
 * 80 ms are buffered or its response has ended. Callers hold the bridge's lock.
 */
internal class RealtimePlaybackQueue {
    class Piece(
        val responseId: String,
        val itemId: String,
        val contentIndex: Int,
        val samples: ShortArray,
    )

    private class Chunk(
        val responseId: String,
        val itemId: String,
        val contentIndex: Int,
        val samples: ShortArray,
        var offset: Int = 0,
    )

    private val chunks = ArrayDeque<Chunk>()
    private val ended = HashSet<String>()
    private var playing = false
    var queued = 0
        private set
    var received = 0
        private set

    fun enqueue(responseId: String, itemId: String, contentIndex: Int, samples: ShortArray) {
        if (samples.isEmpty()) return
        chunks.addLast(Chunk(responseId, itemId, contentIndex, samples))
        queued += samples.size
        received += samples.size
    }

    fun endResponse(responseId: String) {
        ended.add(responseId)
    }

    /** Up to [max] samples of one item, or null while nothing is to play. */
    fun next(max: Int): Piece? {
        val first = chunks.firstOrNull()
        if (!playing && (queued >= PREBUFFER_SAMPLES || (first != null && first.responseId in ended))) {
            playing = true
        }
        if (!playing || first == null) {
            if (queued == 0) playing = false
            return null
        }
        val count = min(max, first.samples.size - first.offset)
        val piece = first.samples.copyOfRange(first.offset, first.offset + count)
        first.offset += count
        queued -= count
        if (first.offset == first.samples.size) chunks.removeFirst()
        if (queued == 0) playing = false
        return Piece(first.responseId, first.itemId, first.contentIndex, piece)
    }

    fun clear() {
        chunks.clear()
        ended.clear()
        queued = 0
        playing = false
    }

    fun reset() {
        clear()
        received = 0
    }

    companion object {
        private const val PREBUFFER_SAMPLES = 1920
    }
}

/**
 * Captures the microphone and plays a realtime voice at 24 kHz on one audio
 * session with the platform's echo canceller, so the voice is not heard back
 * through the microphone. The call's coordinator owns the audio mode; this
 * only runs the stream inside it.
 *
 * How much of an item was heard comes from the track's play position, which
 * already accounts for its buffer, so the reported output latency is zero.
 */
class RealtimeAudioBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private class Segment(
        val responseId: String,
        val itemId: String,
        val contentIndex: Int,
        val start: Long,
        val end: Long,
    )

    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val playback = RealtimePlaybackQueue()
    private val segments = ArrayList<Segment>()
    private var events: EventChannel.EventSink? = null

    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var effects = listOf<android.media.audiofx.AudioEffect>()
    private var captureThread: Thread? = null
    private var playbackThread: Thread? = null
    @Volatile private var running = false

    // Which start the worker threads belong to; an older call's late worker
    // stops and sends nothing.
    @Volatile private var callGeneration = 0
    @Volatile private var captureEnabled = false
    private var decimate = false

    // Guarded by [lock].
    private var written = 0L
    private var clearId = 0
    private var writtenSinceReport = 0
    private var outputEnergy = 0.0
    private var outputSamples = 0
    private var inputEnergy = 0.0
    private var inputSamples = 0

    private val reportTask = object : Runnable {
        override fun run() {
            if (!running) return
            sendReport()
            main.postDelayed(this, REPORT_INTERVAL_MS)
        }
    }

    fun setup(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        stop()
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> try {
                start()
                result.success(null)
            } catch (error: Exception) {
                stop()
                result.error("realtime_audio_start_failed", error.message, null)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            "setCaptureEnabled" -> {
                captureEnabled = call.argument<Boolean>("enabled") ?: false
                result.success(null)
            }
            "enqueue" -> {
                val responseId = call.argument<String>("responseId")
                val itemId = call.argument<String>("itemId")
                val contentIndex = call.argument<Int>("contentIndex")
                val pcm = call.argument<ByteArray>("pcm")
                if (responseId != null && itemId != null && contentIndex != null && pcm != null) {
                    val samples = ShortArray(pcm.size / 2)
                    ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
                    synchronized(lock) { playback.enqueue(responseId, itemId, contentIndex, samples) }
                }
                result.success(null)
            }
            "endResponse" -> {
                call.argument<String>("responseId")?.let { id ->
                    synchronized(lock) { playback.endResponse(id) }
                }
                result.success(null)
            }
            "clear" -> result.success(clear(call.argument<Int>("clearId") ?: 0))
            else -> result.notImplemented()
        }
    }

    @SuppressLint("MissingPermission") // The call asked for the microphone first.
    private fun start() {
        stop()
        val recorder = openRecord(SAMPLE_RATE) ?: openRecord(SAMPLE_RATE * 2)?.also { decimate = true }
            ?: throw IllegalStateException("The microphone is unavailable.")
        record = recorder
        val session = recorder.audioSessionId
        effects = listOfNotNull(
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(session) else null,
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(session) else null,
            if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(session) else null,
        ).onEach { it.enabled = true }

        val minOut = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val player = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(max(minOut, FRAME_SAMPLES * 2 * 2))
            .setSessionId(session)
            .build()
        track = player

        val current = ++callGeneration
        running = true
        player.play()
        recorder.startRecording()
        captureThread = Thread({ captureLoop(current, recorder) }, "realtime-capture")
            .apply { start() }
        playbackThread = Thread({ playbackLoop(current, player) }, "realtime-playback")
            .apply { start() }
        main.postDelayed(reportTask, REPORT_INTERVAL_MS)
    }

    @SuppressLint("MissingPermission")
    private fun openRecord(rate: Int): AudioRecord? {
        val minIn = AudioRecord.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minIn <= 0) return null
        val candidate = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            max(minIn, FRAME_SAMPLES * 2 * 4 * (rate / SAMPLE_RATE)),
        )
        if (candidate.state == AudioRecord.STATE_INITIALIZED) return candidate
        candidate.release()
        return null
    }

    private fun stop() {
        running = false
        callGeneration++
        main.removeCallbacks(reportTask)
        // Stopping the recorder releases a read still blocked in it, so the
        // capture thread can end before the recorder is released.
        record?.let {
            try { it.stop() } catch (_: IllegalStateException) {}
        }
        captureThread?.join(THREAD_JOIN_MS)
        playbackThread?.join(THREAD_JOIN_MS)
        captureThread = null
        playbackThread = null
        record?.release()
        record = null
        effects.forEach { it.release() }
        effects = emptyList()
        track?.let {
            try { it.stop() } catch (_: IllegalStateException) {}
            it.release()
        }
        track = null
        decimate = false
        captureEnabled = false
        synchronized(lock) {
            playback.reset()
            segments.clear()
            written = 0
            clearId = 0
            writtenSinceReport = 0
            outputEnergy = 0.0
            outputSamples = 0
            inputEnergy = 0.0
            inputSamples = 0
        }
    }

    private fun captureLoop(current: Int, recorder: AudioRecord) {
        val read = ShortArray(if (decimate) FRAME_SAMPLES * 2 else FRAME_SAMPLES)
        while (running && callGeneration == current) {
            val count = recorder.read(read, 0, read.size)
            if (callGeneration != current) return
            if (count < 0) {
                fail(current, "The microphone stopped.")
                return
            }
            if (!captureEnabled || count == 0) continue
            // A 48 kHz microphone is brought down to 24 kHz by averaging pairs.
            val frame = if (decimate) {
                ShortArray(count / 2) { ((read[it * 2] + read[it * 2 + 1]) / 2).toShort() }
            } else {
                read.copyOf(count)
            }
            var energy = 0.0
            for (sample in frame) {
                val value = sample / 32768.0
                energy += value * value
            }
            synchronized(lock) {
                inputEnergy += energy
                inputSamples += frame.size
            }
            val bytes = ByteArray(frame.size * 2)
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(frame)
            main.post {
                if (callGeneration == current) events?.success(mapOf("type" to "frame", "pcm" to bytes))
            }
        }
    }

    private fun playbackLoop(current: Int, player: AudioTrack) {
        while (running && callGeneration == current) {
            // Taken with its clear generation, so a clear right after drops it.
            val (piece, generation) = synchronized(lock) {
                playback.next(PLAYBACK_CHUNK_SAMPLES) to clearId
            }
            if (piece == null) {
                Thread.sleep(IDLE_SLEEP_MS)
                continue
            }
            var offset = 0
            while (running && callGeneration == current && offset < piece.samples.size) {
                val count = synchronized(lock) {
                    // A clear meanwhile dropped this piece.
                    if (clearId != generation) return@synchronized -2
                    val count = player.write(
                        piece.samples,
                        offset,
                        piece.samples.size - offset,
                        AudioTrack.WRITE_NON_BLOCKING,
                    )
                    if (count > 0) {
                        segments.add(
                            Segment(piece.responseId, piece.itemId, piece.contentIndex, written, written + count),
                        )
                        written += count
                        writtenSinceReport += count
                        for (index in offset until offset + count) {
                            val value = piece.samples[index] / 32768.0
                            outputEnergy += value * value
                        }
                        outputSamples += count
                    }
                    count
                }
                if (count == -2) break
                if (count < 0) {
                    fail(current, "The call audio stopped.")
                    return
                }
                offset += count
                if (count == 0) Thread.sleep(WRITE_RETRY_MS)
            }
        }
    }

    /** Drops queued speech and returns how much of each item was played. */
    private fun clear(id: Int): List<Map<String, Any>> {
        val player = track
        synchronized(lock) {
            clearId = id
            val played = player?.playbackHeadPosition?.toLong() ?: written
            val rendered = LinkedHashMap<String, MutableMap<String, Any>>()
            for (segment in segments) {
                val heard = min(segment.end, played) - segment.start
                if (heard <= 0) continue
                val key = "${segment.itemId}:${segment.contentIndex}"
                val entry = rendered.getOrPut(key) {
                    mutableMapOf(
                        "responseId" to segment.responseId,
                        "itemId" to segment.itemId,
                        "contentIndex" to segment.contentIndex,
                        "samples" to 0,
                    )
                }
                entry["samples"] = (entry["samples"] as Int) + heard.toInt()
            }
            playback.clear()
            segments.clear()
            written = 0
            writtenSinceReport = 0
            outputEnergy = 0.0
            outputSamples = 0
            player?.let {
                try {
                    it.pause()
                    it.flush()
                    it.play()
                } catch (_: IllegalStateException) {}
            }
            return rendered.values.toList()
        }
    }

    private fun sendReport() {
        val player = track
        val report = synchronized(lock) {
            val played = player?.playbackHeadPosition?.toLong() ?: written
            val report = mapOf(
                "type" to "report",
                "clearId" to clearId,
                "playbackActive" to (writtenSinceReport > 0),
                // Speech still in the track's buffer is still to be heard.
                "queued" to playback.queued + max(0L, written - played).toInt(),
                "received" to playback.received,
                "inputLevel" to if (inputSamples > 0) sqrt(inputEnergy / inputSamples) else 0.0,
                "outputLevel" to if (outputSamples > 0) sqrt(outputEnergy / outputSamples) else 0.0,
                "outputLatencyMs" to 0,
            )
            writtenSinceReport = 0
            outputEnergy = 0.0
            outputSamples = 0
            inputEnergy = 0.0
            inputSamples = 0
            report
        }
        events?.success(report)
    }

    private fun fail(current: Int, message: String) {
        main.post {
            if (callGeneration == current) {
                events?.success(mapOf("type" to "failure", "message" to message))
            }
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "app.cogwheel.conduit/realtime_audio"
        private const val EVENT_CHANNEL = "app.cogwheel.conduit/realtime_audio/events"
        private const val SAMPLE_RATE = 24000
        private const val FRAME_SAMPLES = 960
        private const val PLAYBACK_CHUNK_SAMPLES = 480
        private const val REPORT_INTERVAL_MS = 100L
        private const val THREAD_JOIN_MS = 1000L
        private const val IDLE_SLEEP_MS = 10L
        private const val WRITE_RETRY_MS = 5L
    }
}
