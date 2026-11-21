package app.cogwheel.conduit

import android.content.Intent
import android.content.pm.ResolveInfo
import android.content.pm.ServiceInfo
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.system.ErrnoException
import android.system.OsConstants
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import java.util.Locale
import java.util.concurrent.Semaphore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowAudioEffect
import org.robolectric.shadows.ShadowAudioRecord
import org.robolectric.shadows.ShadowLog
import org.robolectric.shadows.ShadowLooper
import org.robolectric.shadows.ShadowSpeechRecognizer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class NativeSttBridgeTest {
    private lateinit var bridge: NativeSttBridge
    private lateinit var previousLocale: Locale
    private val events = mutableListOf<Map<*, *>>()
    private var pipeFactory: () -> NativePcmPipe = { NativePcmPipe.create() }
    private val pipes = mutableListOf<NativePcmPipe>()
    private var gate: ChunkGate? = null

    @Before
    fun setUp() {
        previousLocale = Locale.getDefault()
        Locale.setDefault(Locale.forLanguageTag("en-IN"))
        shadowOf(RuntimeEnvironment.getApplication().packageManager).addResolveInfoForIntent(
            Intent(RecognitionService.SERVICE_INTERFACE),
            ResolveInfo().apply {
                serviceInfo = ServiceInfo().apply {
                    packageName = "test.speech"
                    name = "RecognitionService"
                }
            }
        )
        bridge = NativeSttBridge(Robolectric.buildActivity(MainActivity::class.java).get()) {
            pipeFactory().also(pipes::add)
        }
        bridge.onListen(null, object : EventChannel.EventSink {
            override fun success(event: Any?) { events.add(event as Map<*, *>) }
            override fun error(code: String, message: String?, details: Any?) {
                throw AssertionError("Unexpected channel failure: $code $message")
            }
            override fun endOfStream() {}
        })
    }

    @After
    fun tearDown() {
        // A held microphone read would keep the source from stopping.
        gate?.open()
        bridge.dispose()
        ShadowLooper.idleMainLooper()
        ShadowAudioRecord.clearSource()
        Locale.setDefault(previousLocale)
    }

    @Test
    fun unsupportedRegionalLanguageRecoversWithoutEnablingOnlineRecognition() {
        val recognizer = start("en-IN")
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(recognizer)
        shadow.triggerOnError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(350))

        assertSame(recognizer, ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        assertEquals("en", shadow.lastRecognizerIntent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertTrue(shadow.lastRecognizerIntent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false))
        assertFalse(events.any { it["type"] == "error" || it["type"] == "done" })

        shadow.triggerOnPartialResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("hello"))
        })
        assertEquals("hello", events.last { it["type"] == "result" }["text"])
    }

    @Test
    fun automaticRecognitionDoesNotForceTheSystemRegionalLocale() {
        val recognizer = start(null)
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(recognizer)
        assertFalse(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertFalse(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE))
    }

    @Test
    @Config(sdk = [34])
    fun unsupportedLanguageRetriesAreBounded() {
        val support = RecognitionSupport.Builder()
            .setInstalledOnDeviceLanguages(listOf("en-IN", "en-GB", "en-US", "pl-PL"))
            .build()
        // Automatic language switching selects the platform recognizer. Its
        // support response leaves more candidates than the two-retry budget.
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start(null, support))
        assertTrue(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH))

        val initialIntent = shadow.lastRecognizerIntent
        shadow.triggerOnError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(200))
        assertSame(initialIntent, shadow.lastRecognizerIntent)
        assertFalse(events.any { it["type"] == "error" || it["type"] == "done" })
        shadow.triggerSupportResult(support)
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(350))
        assertFalse(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertFalse(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH))

        shadow.triggerOnError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(350))
        assertEquals("en-IN", shadow.lastRecognizerIntent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertFalse(events.any { it["type"] == "error" || it["type"] == "done" })

        val finalAttempt = shadow.lastRecognizerIntent
        shadow.triggerOnError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(350))

        assertSame(finalAttempt, shadow.lastRecognizerIntent)
        assertEquals(1, events.count { it["type"] == "error" })
        assertEquals("ANDROID_SPEECH_12", events.single { it["type"] == "error" }["code"])
        assertEquals(1, events.count { it["type"] == "done" })
    }

    @Test
    fun stoppingDuringLanguageRecoveryDoesNotRestartTheMicrophone() {
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start("en-IN"))
        val initialIntent = shadow.lastRecognizerIntent
        shadow.triggerOnError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
        bridge.onMethodCall(MethodCall("stop", null), IgnoreResult())
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofSeconds(1))

        assertTrue(shadow.isDestroyed)
        assertSame(initialIntent, shadow.lastRecognizerIntent)
        assertFalse(events.any { it["type"] == "error" })
    }

    @Test
    @Config(sdk = [34])
    fun stoppingBeforeLanguageSupportReplyDoesNotRestartTheMicrophone() {
        val support = RecognitionSupport.Builder()
            .setInstalledOnDeviceLanguages(listOf("en-IN", "pl-PL"))
            .build()
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start(null, support))
        val initialIntent = shadow.lastRecognizerIntent
        shadow.triggerOnError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(200))
        assertSame(initialIntent, shadow.lastRecognizerIntent)

        bridge.onMethodCall(MethodCall("stop", null), IgnoreResult())
        shadow.triggerSupportResult(support)
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofSeconds(1))

        assertTrue(shadow.isDestroyed)
        assertSame(initialIntent, shadow.lastRecognizerIntent)
        assertFalse(events.any { it["type"] == "error" })
    }

    @Test
    @Config(sdk = [33])
    fun aCallFeedsTheRecognizerItsOwnMicrophone() {
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start("en-US", inCall = true))

        // The platform recognizer's own microphone has no echo canceller, so
        // on the loudspeaker it hears the assistant and barges in on it (#900).
        assertTrue(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE))
        // Nothing asked to keep the audio, so none of it goes to Dart.
        ShadowLooper.idleMainLooper()
        assertFalse(events.any { it["type"] == "audio" })
    }

    @Test
    @Config(sdk = [33])
    fun aCallRecognizerThatLeavesItsAudioUnreadListensThroughItsOwnMicrophone() {
        // Android lets a recognition service ignore EXTRA_AUDIO_SOURCE and
        // open its own microphone, so nothing reads the call's pipe.
        val unread = UnreadPipe(capacity = 4 * CHUNK_BYTES)
        pipeFactory = { unread }
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start("en-US", inCall = true))
        assertTrue(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE))

        // The call stops feeding the pipe instead of failing recognition.
        idleUntil { unread.outputClosed }
        assertFalse(events.any { it["type"] == "error" || it["type"] == "done" })
        assertTrue(FELL_BACK in bridgeLogs())

        // The next request, after this utterance, opens the recognizer's own
        // microphone, and the call carries on.
        shadow.triggerOnResults(recognized("hello there"))
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(250))
        assertFalse(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE))
        assertEquals("hello there", events.last { it["type"] == "result" }["text"])
        assertFalse(events.any { it["type"] == "error" || it["type"] == "done" })

        // A later call goes straight to the recognizer's microphone.
        val next = Shadow.extract<ShadowSpeechRecognizer>(start("en-US", inCall = true))
        assertFalse(next.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE))
        assertEquals(1, pipes.size)
        assertTrue("Call microphone: the recognizer's own, since it left the call microphone unread" in bridgeLogs())
    }

    @Test
    @Config(sdk = [33])
    fun aCallRecognizerThatPausesBetweenUtterancesKeepsTheCallMicrophone() {
        val gate = ChunkGate().also { source -> gate = source; ShadowAudioRecord.setSourceProvider { source } }
        val unread = UnreadPipe(capacity = 4 * CHUNK_BYTES)
        pipeFactory = { unread }
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start("en-US", inCall = true))

        // The recognizer stops reading at its endpoint. The pipe fills, and
        // all but the last chunk of the unread allowance is dropped.
        val gap = 4 + NativeDictationAudioSource.UNREAD_LIMIT_BYTES / CHUNK_BYTES - 1
        gate.release(gap)
        idleUntil { unread.writes == gap }
        shadow.triggerOnResults(recognized("first answer"))
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(250))

        // Its next request reads the backlog, then pauses as long again.
        unread.read()
        gate.release(gap)
        idleUntil { unread.writes == 2 * gap }

        // The fallback logs on the main thread as soon as it is reported.
        assertFalse(FELL_BACK in bridgeLogs())
        assertTrue(shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE))
        assertFalse(events.any { it["type"] == "error" || it["type"] == "done" })
    }

    @Test
    @Config(sdk = [33])
    fun dictationThatKeepsItsRecordingStillFailsWhenTheRecognizerStopsReading() {
        // Recovery needs every chunk, so a stalled recognizer is reported.
        val unread = UnreadPipe(capacity = 4 * CHUNK_BYTES)
        pipeFactory = { unread }
        start("en-US", emitAudio = true)

        idleUntil { events.any { it["type"] == "error" } }
        assertEquals("AUDIO_PRESERVATION_FAILED", events.single { it["type"] == "error" }["code"])
    }

    // Robolectric only tracks audio effects up to Android 10.
    @Test
    @Config(sdk = [29])
    fun aCallRecordsThroughTheEchoCanceller() = runBlocking {
        ShadowAudioEffect.addEffect(
            AudioEffect.Descriptor(
                AudioEffect.EFFECT_TYPE_AEC.toString(),
                "00000000-0000-0000-0000-00000000ec00",
                AudioEffect.EFFECT_INSERT,
                "Echo canceller",
                "Test",
            )
        )

        val call = NativeDictationAudioSource.create(voiceCall = true, onAudio = null, onFailure = {})
        val effect = ShadowAudioEffect.getAudioEffects().single()
        assertTrue(effect is AcousticEchoCanceler && effect.enabled)
        call.stop()
        call.closeDescriptor()
        assertTrue(ShadowAudioEffect.getAudioEffects().isEmpty())

        val dictation = NativeDictationAudioSource.create(voiceCall = false, onAudio = null, onFailure = {})
        assertTrue(ShadowAudioEffect.getAudioEffects().isEmpty())
        dictation.stop()
        dictation.closeDescriptor()

        // A device report says whether the call got the echo canceller.
        assertEquals(
            listOf("Call microphone: VOICE_COMMUNICATION, echo canceller enabled"),
            callMicrophoneLogs(),
        )
    }

    @Test
    @Config(sdk = [29])
    fun aCallOnAPhoneWithoutAnEchoCancellerLogsIt() = runBlocking {
        val call = NativeDictationAudioSource.create(voiceCall = true, onAudio = null, onFailure = {})
        call.stop()
        call.closeDescriptor()

        assertEquals(
            listOf("Call microphone: VOICE_COMMUNICATION, no echo canceller on this device"),
            callMicrophoneLogs(),
        )
    }

    private fun bridgeLogs() = ShadowLog.getLogsForTag("NativeSttBridge").map { it.msg }

    private fun callMicrophoneLogs() =
        ShadowLog.getLogsForTag("NativeDictationAudio").map { it.msg }.filter { it.startsWith("Call microphone") }

    private fun start(
        localeId: String?,
        support: RecognitionSupport? = null,
        inCall: Boolean = false,
        emitAudio: Boolean = false,
    ): SpeechRecognizer {
        val result = IgnoreResult()
        bridge.onMethodCall(MethodCall("start", mapOf(
            "localeId" to localeId,
            "allowOnlineFallback" to false,
            "preserveAudioSession" to inCall,
            "emitAudio" to emitAudio,
        )), result)
        // Startup briefly crosses Dispatchers.IO before binding the system
        // recognizer. Drain the main looper until that callback returns.
        val deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos()
        while (result.value == null && System.nanoTime() < deadline) {
            ShadowLooper.idleMainLooper()
            if (support != null) {
                Shadow.extract<ShadowSpeechRecognizer>(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
                    .triggerSupportResult(support)
            }
            Thread.sleep(1)
        }
        ShadowLooper.idleMainLooper()
        assertEquals(result.value.toString(), true, (result.value as? Map<*, *>)?.get("available"))
        return ShadowSpeechRecognizer.getLatestSpeechRecognizer()
    }

    @Test
    fun savedRecordingRejectsIncompletePcmBeforeOpeningRecognition() {
        val result = RecordingResult()
        bridge.onMethodCall(MethodCall("transcribeRecording", mapOf(
            "pcm" to byteArrayOf(1),
            "requestId" to "recording-a"
        )), result)
        assertEquals("INVALID_AUDIO", result.errorCode)
        assertTrue(events.isEmpty())
    }

    @Test
    fun savedRecordingCannotReplaceLiveDictation() {
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start(null))
        val result = RecordingResult()
        bridge.onMethodCall(MethodCall("transcribeRecording", mapOf(
            "pcm" to byteArrayOf(1, 0),
            "requestId" to "recording-a"
        )), result)
        assertEquals("BUSY", result.errorCode)
        assertFalse(shadow.isDestroyed)
    }

    @Test
    fun cancellingRetiredRecordingDoesNotStopLiveDictation() {
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start(null))
        bridge.onMethodCall(MethodCall("cancelRecordingTranscription", mapOf(
            "requestId" to "retired-recording"
        )), IgnoreResult())
        ShadowLooper.idleMainLooper()
        assertFalse(shadow.isDestroyed)
        shadow.triggerOnPartialResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("four tiles"))
        })
        assertEquals("four tiles", events.last { it["type"] == "result" }["text"])
    }

    /** Drains the main looper while background capture catches up. */
    private fun idleUntil(condition: () -> Boolean) {
        val deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos()
        while (!condition() && System.nanoTime() < deadline) {
            ShadowLooper.idleMainLooper()
            Thread.sleep(1)
        }
        ShadowLooper.idleMainLooper()
        assertTrue("Timed out waiting for capture", condition())
    }

    private fun recognized(text: String) = Bundle().apply {
        putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf(text))
    }

    /** Hands the recorder one chunk per permit. */
    private class ChunkGate : ShadowAudioRecord.AudioRecordSource {
        private val permits = Semaphore(0)
        private var opened = false

        fun release(chunks: Int) = permits.release(chunks)

        @Synchronized
        fun open() {
            if (!opened) permits.release(Int.MAX_VALUE / 2)
            opened = true
        }

        override fun readInByteArray(
            audioData: ByteArray,
            offsetInBytes: Int,
            sizeInBytes: Int,
            isBlocking: Boolean,
        ): Int {
            permits.acquireUninterruptibly()
            return sizeInBytes
        }
    }

    /** A recognizer's pipe that holds [capacity] bytes and is read only on [read]. */
    private class UnreadPipe(private val capacity: Int) : NativePcmPipe {
        private val pipe = ParcelFileDescriptor.createPipe()
        override val input: ParcelFileDescriptor = pipe[0]
        private var queued = 0
        @Volatile var writes = 0
            private set
        @Volatile var outputClosed = false
            private set

        @Synchronized
        override fun write(bytes: ByteArray, offset: Int, count: Int): Int {
            writes += 1
            if (queued + count > capacity) throw ErrnoException("write", OsConstants.EAGAIN)
            queued += count
            return count
        }

        @Synchronized
        fun read() { queued = 0 }

        override fun closeOutput() {
            outputClosed = true
            runCatching { pipe[1].close() }
        }
    }

    private companion object {
        const val CHUNK_BYTES = 640 // 20 ms of mono PCM16 at 16 kHz.
        const val FELL_BACK = "Call microphone: the recognizer left it unread, so it listens through its own"
    }

    private class RecordingResult : MethodChannel.Result {
        var errorCode: String? = null
        override fun success(result: Any?) { throw AssertionError("Unexpected success") }
        override fun error(code: String, message: String?, details: Any?) { errorCode = code }
        override fun notImplemented() { throw AssertionError("Method was not implemented") }
    }

    private class IgnoreResult : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) {
            throw AssertionError("Unexpected method failure: $code $message")
        }
        override fun notImplemented() { throw AssertionError("Method was not implemented") }
    }
}
