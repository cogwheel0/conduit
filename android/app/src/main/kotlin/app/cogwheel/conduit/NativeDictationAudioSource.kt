package app.cogwheel.conduit

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One microphone feeds both recovery and recognition. A stalled recognizer
 * fails explicitly instead of blocking capture behind a full input pipe. */
internal class NativeDictationAudioSource private constructor(
    private val recorder: AudioRecord,
    private val echoCanceler: AcousticEchoCanceler?,
    private val pipe: NativePcmPipe,
    private val onAudio: ((ByteArray) -> Unit)?,
    private val onFailure: () -> Unit,
) {
    val descriptor: ParcelFileDescriptor get() = pipe.input
    private val stopping = AtomicBoolean(false)
    private val stopped = CompletableDeferred<Unit>()
    private var job: Job? = null

    /** Requires microphone permission; delivers mono 16 kHz PCM16 before recognition writes. */
    @SuppressLint("MissingPermission")
    fun start(scope: CoroutineScope) {
        check(!stopping.get())
        recorder.startRecording()
        check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING)
        job = scope.launch(Dispatchers.IO) {
            val buffer = ByteArray(640) // 20 ms, mono PCM16 at 16 kHz.
            try {
                while (!stopping.get()) {
                    val count = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                    if (stopping.get()) break
                    check(count > 0 && count % 2 == 0)
                    onAudio?.invoke(buffer.copyOf(count))
                    var offset = 0
                    while (offset < count) {
                        offset += pipe.write(buffer, offset, count - offset)
                    }
                }
            } catch (_: Exception) {
                if (!stopping.get()) onFailure()
            } finally {
                pipe.closeOutput()
            }
        }
    }

    /** Non-cancellable shutdown shared by concurrent callers; the input descriptor stays owned. */
    suspend fun stop() = withContext(NonCancellable + Dispatchers.IO) {
        if (!stopping.compareAndSet(false, true)) {
            stopped.await()
            return@withContext
        }
        try {
            runCatching { recorder.stop() }
            job?.join()
        } finally {
            try {
                recorder.release()
                echoCanceler?.let { runCatching { it.release() } }
                pipe.closeOutput()
            } finally {
                stopped.complete(Unit)
            }
        }
    }

    fun closeDescriptor() {
        runCatching { descriptor.close() }
    }

    companion object {
        /**
         * Allocates an unstarted recorder; the caller owns stop and descriptor
         * closure. [onAudio], when given, receives every chunk as well.
         *
         * In a [voiceCall] the assistant answers out loud, often on the
         * loudspeaker, so the microphone is the voice-communication source
         * with the platform's echo canceller, which takes the call's own
         * output back out. A phone that cannot open that source records as
         * dictation does.
         */
        @SuppressLint("MissingPermission")
        fun create(
            voiceCall: Boolean,
            onAudio: ((ByteArray) -> Unit)?,
            onFailure: () -> Unit,
        ): NativeDictationAudioSource {
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(16000)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0)
            val sources = if (voiceCall) {
                listOf(MediaRecorder.AudioSource.VOICE_COMMUNICATION, MediaRecorder.AudioSource.VOICE_RECOGNITION)
            } else {
                listOf(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            }
            val recorder = sources.firstNotNullOfOrNull { source ->
                openRecorder(source, format, maxOf(minimum, 5120))
            }
            checkNotNull(recorder)
            var echoCanceler: AcousticEchoCanceler? = null
            try {
                if (recorder.audioSource == MediaRecorder.AudioSource.VOICE_COMMUNICATION &&
                    AcousticEchoCanceler.isAvailable()
                ) {
                    echoCanceler = runCatching {
                        AcousticEchoCanceler.create(recorder.audioSessionId)?.apply { enabled = true }
                    }.getOrNull()
                }
                return NativeDictationAudioSource(recorder, echoCanceler, NativePcmPipe.create(), onAudio, onFailure)
            } catch (error: Exception) {
                recorder.release()
                echoCanceler?.release()
                throw error
            }
        }

        @SuppressLint("MissingPermission")
        private fun openRecorder(source: Int, format: AudioFormat, bufferSize: Int): AudioRecord? {
            val recorder = runCatching {
                AudioRecord.Builder()
                    .setAudioSource(source)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(bufferSize)
                    .build()
            }.getOrNull() ?: return null
            if (recorder.state == AudioRecord.STATE_INITIALIZED) return recorder
            recorder.release()
            return null
        }
    }
}

/** Nonblocking writes keep cancellation independent of an ASR reader. */
internal class NativePcmPipe private constructor(
    val input: ParcelFileDescriptor,
    private val output: ParcelFileDescriptor,
) {
    fun write(bytes: ByteArray, offset: Int, count: Int): Int =
        Os.write(output.fileDescriptor, bytes, offset, count)

    fun closeOutput() { runCatching { output.close() } }
    fun close() {
        closeOutput()
        runCatching { input.close() }
    }

    companion object {
        fun create(): NativePcmPipe {
            val pipe = ParcelFileDescriptor.createPipe()
            try {
                val flags = Os.fcntlInt(pipe[1].fileDescriptor, OsConstants.F_GETFL, 0)
                Os.fcntlInt(pipe[1].fileDescriptor, OsConstants.F_SETFL, flags or OsConstants.O_NONBLOCK)
                return NativePcmPipe(pipe[0], pipe[1])
            } catch (error: Exception) {
                pipe.forEach { runCatching { it.close() } }
                throw error
            }
        }
    }
}
