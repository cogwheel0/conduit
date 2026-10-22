package app.cogwheel.conduit

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.util.Log
import android.os.ParcelFileDescriptor
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sqrt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

internal interface SttAudioSource : Closeable {
    val descriptor: ParcelFileDescriptor
    fun start(scope: CoroutineScope)
}

/** One microphone stream supplies both recognition and the local visual meter. */
internal class MeteredSttAudioSource(
    private val onLevel: (Double) -> Unit,
    private val onError: (Throwable) -> Unit,
    private val voiceCall: Boolean = false
) : SttAudioSource {
    private val closed = AtomicBoolean(false)
    private val pipe = ParcelFileDescriptor.createPipe()
    override val descriptor: ParcelFileDescriptor get() = pipe[0]
    private val output = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
    private var recorder: AudioRecord? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var job: Job? = null

    override fun start(scope: CoroutineScope) {
        val minimum = AudioRecord.getMinBufferSize(
            16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        check(minimum > 0) { "Microphone format unavailable" }
        val capture = AudioRecord.Builder()
            .setAudioSource(if (voiceCall) MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(16000)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build())
            .setBufferSizeInBytes(max(minimum, 4096))
            .build()
        recorder = capture
        check(capture.state == AudioRecord.STATE_INITIALIZED) { "Microphone initialization failed" }
        if (voiceCall) {
            if (AcousticEchoCanceler.isAvailable()) {
                echoCanceler = AcousticEchoCanceler.create(capture.audioSessionId)?.also { it.enabled = true }
            }
            Log.i("ConduitCallCapture", "prepared aec=${echoCanceler?.enabled == true}")
        }
        capture.startRecording()
        if (voiceCall) Log.i("ConduitCallCapture", "started")
        job = scope.launch(Dispatchers.IO) {
            val samples = ShortArray(512)
            val bytes = ByteArray(1024)
            try {
                while (!closed.get()) {
                    val count = capture.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING)
                    if (closed.get()) break
                    check(count > 0) { "Microphone read failed: $count" }
                    onLevel(levelFromPcm(samples, count))
                    for (i in 0 until count) {
                        bytes[i * 2] = (samples[i].toInt() and 0xff).toByte()
                        bytes[i * 2 + 1] = (samples[i].toInt() shr 8).toByte()
                    }
                    output.write(bytes, 0, count * 2)
                }
            } catch (error: Throwable) {
                if (!closed.get()) onError(error)
            } finally {
                runCatching { echoCanceler?.release() }; echoCanceler = null
                runCatching { capture.release() }
                close()
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        // Closing both ends also unblocks a writer if recognition stopped
        // reading. Stopping capture unblocks its blocking microphone read.
        runCatching { recorder?.stop() }
        runCatching { output.close() }
        runCatching { pipe[0].close() }
        job?.cancel()
        if (job == null) {
            runCatching { echoCanceler?.release() }; echoCanceler = null
            runCatching { recorder?.release() }
        }
        if (voiceCall) Log.i("ConduitCallCapture", "stopped")
    }

    companion object {
        /** The original Contour preview gain and noise floor, without ±25%. */
        internal fun levelFromPcm(samples: ShortArray, count: Int): Double {
            if (count <= 0) return 0.0
            var sum = 0.0
            for (i in 0 until count) {
                val sample = samples[i] / 32768.0
                sum += sample * sample
            }
            return (max(0.0, sqrt(sum / count) - 0.006) * 7).pow(0.65).coerceIn(0.0, 1.0)
        }
    }
}
