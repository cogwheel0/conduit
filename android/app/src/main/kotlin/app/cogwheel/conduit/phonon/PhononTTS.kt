// Adapted from gradium-ai/xn-ptts commit 49b9033e; MIT OR Apache-2.0.
// Phonon text to speech for Android: a Kotlin wrapper over libptts_ffi.so (see README.md), called
// through JNA. Copy this file into your app and change the package to yours.
package app.cogwheel.conduit.phonon

import com.sun.jna.Callback
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.Structure

/**
 * A loaded model. Loading is the slow part, so keep one around and reuse it, and [close] it when
 * done: nothing else frees the model.
 *
 * Every call blocks, so make them off the main thread, and from one thread at a time.
 *
 * @param modelDir a checkpoint folder: `tokenizer.json`, the weights and the voices.
 * @param lang how to normalize text: `en`, `fr`, `de`, `es`, `pt`, or `none` to read it as written.
 */
class PhononTTS(modelDir: String, lang: String) : AutoCloseable {
    private var handle: Pointer? =
        lib.ptts_new(modelDir, 0, lang) ?: throw IllegalStateException(lib.ptts_last_error(null))

    private var onAudio: (FloatArray) -> Boolean = { true }

    // What onAudio threw. JNA would log it and hand native code `false`, which reads as "stop", so
    // speak() would return as if nothing went wrong: keep it, stop, and rethrow it from speak().
    private var thrown: Throwable? = null

    // A field rather than a local, so the callback outlives every call that hands it to native code.
    private val onFrame = Lib.FrameFn { pcm, n, _ ->
        try {
            onAudio(pcm.getFloatArray(0, n.toInt()))
        } catch (t: Throwable) {
            thrown = t
            false
        }
    }

    /** The voices this checkpoint ships, sorted. */
    val voices: List<String>
        get() = names(lib.ptts_voices(open()))

    /** The languages the model was trained for, as its config lists them. */
    val languages: List<String>
        get() = names(lib.ptts_languages(open()))

    private fun names(block: Pointer): List<String> {
        val names = mutableListOf<String>()
        var offset = 0L
        while (true) {
            val name = block.getString(offset, "UTF-8")
            if (name.isEmpty()) return names
            names += name
            offset += name.toByteArray(Charsets.UTF_8).size + 1
        }
    }

    /** Speak in [name], one of [voices], from now on. */
    fun setVoice(name: String) = check(lib.ptts_set_voice(open(), name))

    /** Normalize text as [lang] (en, fr, de, es, pt or none) from now on, with no reload. */
    fun setLanguage(lang: String) = check(lib.ptts_set_language(open(), lang))

    /**
     * Speak [text], handing [onAudio] each piece of audio as soon as it is made: 24 kHz mono
     * floats in [-1, 1]. Return false from [onAudio] to stop early. Returns once all the audio
     * has been handed over, with the utterance's timings. What [onAudio] throws, [speak] rethrows.
     * [onAudio] must not call back into this object.
     */
    fun speak(text: String, onAudio: (FloatArray) -> Boolean): Result {
        this.onAudio = onAudio
        thrown = null
        val out = Result()
        val ok = lib.ptts_speak(open(), text, onFrame, null, out)
        thrown?.let {
            thrown = null
            throw it
        }
        check(ok)
        return out
    }

    override fun close() {
        handle?.let { lib.ptts_free(it) }
        handle = null
    }

    private fun open() = handle ?: throw IllegalStateException("PhononTTS is closed")

    private fun check(ok: Byte) {
        if (ok.toInt() == 0) throw IllegalStateException(lib.ptts_last_error(handle))
    }

    /** One utterance's timings: `PttsResult` in ptts.h, whose `size_t` is a `Long` on 64 bits. */
    @Structure.FieldOrder("frames", "samples", "ttfaMs", "totalMs")
    class Result : Structure() {
        @JvmField var frames: Int = 0
        @JvmField var samples: Long = 0
        @JvmField var ttfaMs: Double = 0.0
        @JvmField var totalMs: Double = 0.0
    }

    /** ptts.h. A C `bool` return is one byte, which JNA's `Boolean` (four) would misread. */
    @Suppress("FunctionName")
    private interface Lib : Library {
        fun ptts_new(dir: String, unit: Int, lang: String): Pointer?
        fun ptts_speak(h: Pointer, text: String, cb: FrameFn, user: Pointer?, out: Result): Byte
        fun ptts_voices(h: Pointer): Pointer
        fun ptts_set_voice(h: Pointer, name: String): Byte
        fun ptts_set_language(h: Pointer, lang: String): Byte
        fun ptts_languages(h: Pointer): Pointer
        fun ptts_last_error(h: Pointer?): String?
        fun ptts_free(h: Pointer)

        /** `PttsFrameFn`. `n` is a `size_t`, 64 bits on both ABIs `build.sh` makes. */
        fun interface FrameFn : Callback {
            fun invoke(pcm: Pointer, n: Long, user: Pointer?): Boolean
        }
    }

    private companion object {
        val lib: Lib = Native.load("ptts_ffi", Lib::class.java)
    }
}
