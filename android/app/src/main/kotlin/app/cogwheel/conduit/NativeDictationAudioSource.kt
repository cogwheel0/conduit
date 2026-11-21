package app.cogwheel.conduit

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One microphone feeds both recovery and recognition. Capture never blocks
 * behind a full input pipe: a stalled recognizer fails explicitly, unless
 * the caller lets it leave audio unread. */
internal class NativeDictationAudioSource private constructor(
    private val recorder: AudioRecord,
    private val echoCanceler: AcousticEchoCanceler?,
    private val pipe: NativePcmPipe,
    private val onAudio: ((ByteArray) -> Unit)?,
    private val onUnread: (() -> Unit)?,
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
            // Audio dropped since the recognizer last took a chunk.
            var unread = 0
            var unreadReported = false
            try {
                while (!stopping.get()) {
                    val count = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                    if (stopping.get()) break
                    check(count > 0 && count % 2 == 0)
                    onAudio?.invoke(buffer.copyOf(count))
                    if (feed(buffer, count)) {
                        unread = 0
                        continue
                    }
                    val reportUnread = checkNotNull(onUnread) { "The recognizer stopped reading" }
                    unread += count
                    if (unread >= UNREAD_LIMIT_BYTES && !unreadReported) {
                        unreadReported = true
                        reportUnread()
                    }
                }
            } catch (_: Exception) {
                if (!stopping.get()) onFailure()
            } finally {
                pipe.closeOutput()
            }
        }
    }

    /** Writes [count] bytes, or returns false when the reader has left the
     * pipe full. A 20 ms chunk is below PIPE_BUF, so it is never split. */
    private fun feed(buffer: ByteArray, count: Int): Boolean {
        var offset = 0
        while (offset < count) {
            try {
                offset += pipe.write(buffer, offset, count - offset)
            } catch (error: ErrnoException) {
                if (error.errno != OsConstants.EAGAIN) throw error
                return false
            }
        }
        return true
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
        private const val TAG = "NativeDictationAudio"

        /** A second of audio, in mono PCM16 at 16 kHz. */
        const val UNREAD_LIMIT_BYTES = 32_000

        /**
         * Allocates an unstarted recorder; the caller owns stop and descriptor
         * closure. [onAudio], when given, receives every chunk as well.
         *
         * Without [onUnread], a recognizer that stops reading is a failure,
         * so a recovery recording is never cut short unnoticed. With it, a
         * full pipe drops audio until the recognizer reads again, and
         * [onUnread] runs once after [UNREAD_LIMIT_BYTES] go unread in a row.
         * The pipe itself holds about two seconds before that.
         *
         * In a [voiceCall] the assistant answers out loud, often on the
         * loudspeaker, so the microphone is the voice-communication source
         * with the platform's echo canceller, which takes the call's own
         * output back out. A phone that cannot open that source records as
         * dictation does. Each call microphone logs the source and echo
         * canceller it got.
         */
        @SuppressLint("MissingPermission")
        fun create(
            voiceCall: Boolean,
            onAudio: ((ByteArray) -> Unit)?,
            onFailure: () -> Unit,
            onUnread: (() -> Unit)? = null,
            createPipe: () -> NativePcmPipe = { NativePcmPipe.create() },
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
                if (voiceCall) {
                    if (recorder.audioSource != MediaRecorder.AudioSource.VOICE_COMMUNICATION) {
                        Log.w(TAG, "Call microphone: VOICE_COMMUNICATION would not open, recording VOICE_RECOGNITION without an echo canceller")
                    } else if (!AcousticEchoCanceler.isAvailable()) {
                        Log.w(TAG, "Call microphone: VOICE_COMMUNICATION, no echo canceller on this device")
                    } else {
                        val created = runCatching {
                            AcousticEchoCanceler.create(recorder.audioSessionId)?.apply { enabled = true }
                        }
                        echoCanceler = created.getOrNull()
                        val enabled = runCatching { echoCanceler?.enabled == true }.getOrDefault(false)
                        when {
                            enabled ->
                                Log.i(TAG, "Call microphone: VOICE_COMMUNICATION, echo canceller enabled")
                            echoCanceler != null ->
                                Log.w(TAG, "Call microphone: VOICE_COMMUNICATION, echo canceller would not enable")
                            else -> Log.w(
                                TAG,
                                "Call microphone: VOICE_COMMUNICATION, echo canceller could not be created",
                                created.exceptionOrNull(),
                            )
                        }
                    }
                }
                return NativeDictationAudioSource(recorder, echoCanceler, createPipe(), onAudio, onUnread, onFailure)
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

/** Carries PCM to a recognizer. Writes never block, so a reader that stops
 * cannot stall capture: a full pipe throws [android.system.ErrnoException]
 * with `EAGAIN`. */
internal interface NativePcmPipe {
    val input: ParcelFileDescriptor
    fun write(bytes: ByteArray, offset: Int, count: Int): Int
    fun closeOutput()
    fun close() {
        closeOutput()
        runCatching { input.close() }
    }

    companion object {
        fun create(): NativePcmPipe = OsPcmPipe.create()
    }
}

/** Nonblocking writes keep cancellation independent of an ASR reader. */
private class OsPcmPipe private constructor(
    override val input: ParcelFileDescriptor,
    private val output: ParcelFileDescriptor,
) : NativePcmPipe {
    override fun write(bytes: ByteArray, offset: Int, count: Int): Int =
        Os.write(output.fileDescriptor, bytes, offset, count)

    override fun closeOutput() { runCatching { output.close() } }

    companion object {
        fun create(): NativePcmPipe {
            val pipe = ParcelFileDescriptor.createPipe()
            try {
                val flags = Os.fcntlInt(pipe[1].fileDescriptor, OsConstants.F_GETFL, 0)
                Os.fcntlInt(pipe[1].fileDescriptor, OsConstants.F_SETFL, flags or OsConstants.O_NONBLOCK)
                return OsPcmPipe(pipe[0], pipe[1])
            } catch (error: Exception) {
                pipe.forEach { runCatching { it.close() } }
                throw error
            }
        }
    }
}
