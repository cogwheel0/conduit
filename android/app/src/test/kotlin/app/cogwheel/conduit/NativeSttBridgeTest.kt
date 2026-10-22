package app.cogwheel.conduit

import android.content.Intent
import android.content.pm.ResolveInfo
import android.content.pm.ServiceInfo
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import java.io.File
import java.util.Locale
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
import org.robolectric.shadows.ShadowLooper
import org.robolectric.shadows.ShadowSpeechRecognizer
import kotlinx.coroutines.CoroutineScope

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class NativeSttBridgeTest {
    private lateinit var bridge: NativeSttBridge
    private lateinit var previousLocale: Locale
    private val events = mutableListOf<Map<*, *>>()
    private val audioSources = mutableListOf<FakeAudioSource>()
    private val callCapturePolicies = mutableListOf<Boolean>()
    private var audioStartFailure: Throwable? = null

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
        bridge = NativeSttBridge(Robolectric.buildActivity(MainActivity::class.java).get()) { level, error, voiceCall ->
            callCapturePolicies.add(voiceCall)
            FakeAudioSource(level, error, audioStartFailure).also { audioSources.add(it) }
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
        bridge.dispose()
        ShadowLooper.idleMainLooper()
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
    fun microphoneLevelsAreForwardedOnlyDuringActiveCapture() {
        start("en-US")
        val listenerField = NativeSttBridge::class.java.getDeclaredField("platformRecognitionListener")
        listenerField.isAccessible = true
        val listener = listenerField.get(bridge) as android.speech.RecognitionListener
        listener.onRmsChanged(5.5f)
        ShadowLooper.idleMainLooper()
        assertEquals(0.5, events.last { it["type"] == "level" }["level"])
        bridge.onMethodCall(MethodCall("stop", null), IgnoreResult())
        ShadowLooper.idleMainLooper()
        val levelsBefore = events.count { it["type"] == "level" }
        listener.onRmsChanged(10f)
        ShadowLooper.idleMainLooper()
        assertEquals(levelsBefore, events.count { it["type"] == "level" })
    }

    @Test
    @Config(sdk = [34])
    fun onDeviceRecognizerReceivesSharedPcmAudioForAnIndependentMeter() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start(null))
        assertTrue("The meter and built-in transcriber must share microphone samples",
            shadow.lastRecognizerIntent.hasExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE))
        assertEquals(16000, shadow.lastRecognizerIntent.getIntExtra(
            RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 0))
        assertEquals(RecognizerIntent.EXTRA_AUDIO_SOURCE,
            shadow.lastRecognizerIntent.getStringExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION))
        val audio = audioSources.single()
        assertEquals(1, audio.starts)
        audio.emitLevel(0.7)
        ShadowLooper.idleMainLooper()
        assertEquals(0.7, events.last { it["type"] == "level" }["level"])
        // Late, coarse transcriber updates must not overwrite the PCM meter.
        platformListener().onRmsChanged(1f)
        assertEquals(1, events.count { it["type"] == "level" })
        bridge.onMethodCall(MethodCall("stop", null), IgnoreResult())
        ShadowLooper.idleMainLooper()
        assertTrue(audio.closed)
        audio.emitLevel(0.9)
        ShadowLooper.idleMainLooper()
        assertEquals(1, events.count { it["type"] == "level" })
    }

    @Test
    @Config(sdk = [34])
    fun audioSegmentsKeepOneMicrophoneAndAccumulateBuiltInTranscripts() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        val recognizer = start(null)
        val audio = audioSources.single()
        val listener = platformListener()
        listener.onSegmentResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("first phrase"))
        })
        listener.onSegmentResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("second phrase"))
        })
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofMillis(350))
        assertSame(recognizer, ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        assertEquals(1, audioSources.size)
        assertFalse(audio.closed)
        assertEquals("first phrase second phrase", events.last { it["type"] == "result" }["text"])
        listener.onEndOfSegmentedSession()
        ShadowLooper.idleMainLooper()
        assertTrue(audio.closed)
        assertEquals(1, events.count { it["type"] == "done" })
        audio.emitLevel(1.0)
        ShadowLooper.idleMainLooper()
        assertFalse(events.any { it["type"] == "level" })
    }

    @Test
    @Config(sdk = [34])
    fun continuousCallsUseCommunicationCaptureAndEmitIndividualSegments() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        bridge.onMethodCall(MethodCall("start", mapOf(
            "allowOnlineFallback" to false,
            "voiceCall" to true,
            "accumulateResults" to false
        )), IgnoreResult())
        ShadowLooper.idleMainLooper()
        assertEquals(listOf(true), callCapturePolicies)
        val audio = audioSources.single()
        for (phrase in listOf("first question", "second question")) {
            platformListener().onSegmentResults(Bundle().apply {
                putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf(phrase))
            })
        }
        ShadowLooper.idleMainLooper()
        assertEquals(listOf("first question", "second question"),
            events.filter { it["type"] == "result" && it["final"] == true }.map { it["text"] })
        assertEquals(1, audioSources.size)
        assertEquals(1, audio.starts)
        assertFalse(audio.closed)
        bridge.onMethodCall(MethodCall("stop", null), IgnoreResult())
        ShadowLooper.idleMainLooper()
        assertTrue(audio.closed)
    }

    @Test
    @Config(sdk = [34])
    fun pcmReadFailureClosesCaptureAndStopsMeterEvents() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        start(null)
        val audio = audioSources.single()
        audio.emitError(IllegalStateException("Microphone read failed"))
        ShadowLooper.idleMainLooper()
        assertTrue(audio.closed)
        assertEquals("MICROPHONE_ERROR", events.single { it["type"] == "error" }["code"])
        assertEquals(1, events.count { it["type"] == "done" })
        audio.emitLevel(1.0)
        ShadowLooper.idleMainLooper()
        assertFalse(events.any { it["type"] == "level" })
    }

    @Test
    @Config(sdk = [34])
    fun pcmStartupFailureReleasesTheAudioAndRecognizer() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        audioStartFailure = IllegalStateException("Microphone initialization failed")
        val result = IgnoreResult()
        bridge.onMethodCall(MethodCall("start", mapOf("allowOnlineFallback" to false)), result)
        ShadowLooper.idleMainLooper()
        assertEquals(false, (result.value as Map<*, *>)["available"])
        assertTrue(audioSources.single().closed)
        assertTrue(Shadow.extract<ShadowSpeechRecognizer>(ShadowSpeechRecognizer.getLatestSpeechRecognizer()).isDestroyed)
    }

    @Test
    @Config(sdk = [32])
    fun olderOnDeviceRecognizersKeepTheirNativeMicrophone() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(start(null))
        assertFalse(shadow.lastRecognizerIntent.hasExtra("android.speech.extra.AUDIO_SOURCE"))
        assertTrue(audioSources.isEmpty())
        platformListener().onRmsChanged(5.5f)
        ShadowLooper.idleMainLooper()
        assertEquals(0.5, events.single { it["type"] == "level" }["level"])
    }

    @Test
    @Config(sdk = [34])
    fun onDeviceMicrophoneStartsWithoutWaitingForOptionalLanguageSupport() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        val result = IgnoreResult()
        bridge.onMethodCall(MethodCall("start", mapOf(
            "localeId" to null,
            "allowOnlineFallback" to false
        )), result)
        // A recognizer may never answer the optional language-switch query.
        // That must not delay access to the phone's built-in microphone/STT.
        val deadline = System.nanoTime() + Duration.ofMillis(250).toNanos()
        while (result.value == null && System.nanoTime() < deadline) {
            ShadowLooper.idleMainLooper()
            Thread.sleep(1)
        }
        assertEquals("On-device capture must start before the language-support timeout", true,
            (result.value as? Map<*, *>)?.get("available"))
        assertEquals("android_speech", (result.value as Map<*, *>)["engine"])
        ShadowLooper.idleMainLooper()
        val shadow = Shadow.extract<ShadowSpeechRecognizer>(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        assertTrue(shadow.lastRecognizerIntent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false))
        // Robolectric's on-device shadow does not expose the bound listener.
        val listener = platformListener()
        audioSources.single().emitLevel(0.5)
        listener.onPartialResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("test phrase"))
        })
        ShadowLooper.idleMainLooper()
        assertTrue(events.any { it["type"] == "level" })
        assertTrue(events.any { it["type"] == "result" && it["final"] == false })
    }

    private fun platformListener(): android.speech.RecognitionListener {
        val field = NativeSttBridge::class.java.getDeclaredField("platformRecognitionListener")
        field.isAccessible = true
        return field.get(bridge) as android.speech.RecognitionListener
    }

    private class FakeAudioSource(
        val emitLevel: (Double) -> Unit,
        val emitError: (Throwable) -> Unit,
        private val startFailure: Throwable?
    ) : SttAudioSource {
        private val file = File.createTempFile("stt-meter-test-", ".pcm", RuntimeEnvironment.getApplication().cacheDir)
        override val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        var closed = false
        var starts = 0
        override fun start(scope: CoroutineScope) {
            starts += 1
            startFailure?.let { throw it }
        }
        override fun close() {
            if (closed) return
            closed = true
            descriptor.close()
            file.delete()
        }
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

    private fun start(localeId: String?, support: RecognitionSupport? = null): SpeechRecognizer {
        if (support != null) {
            val locales = IgnoreResult()
            bridge.onMethodCall(MethodCall("getLocales", mapOf("deviceLocaleId" to "en-IN")), locales)
            val deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos()
            while (locales.value == null && System.nanoTime() < deadline) {
                ShadowLooper.idleMainLooper()
                Shadow.extract<ShadowSpeechRecognizer>(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
                    .triggerSupportResult(support)
                Thread.sleep(1)
            }
            assertTrue("Language support should be cached before capture", locales.value != null)
        }
        val result = IgnoreResult()
        bridge.onMethodCall(MethodCall("start", mapOf(
            "localeId" to localeId,
            "allowOnlineFallback" to false
        )), result)
        // Startup briefly crosses Dispatchers.IO before binding the system
        // recognizer. Drain the main looper until that callback returns.
        val deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos()
        while (result.value == null && System.nanoTime() < deadline) {
            ShadowLooper.idleMainLooper()
            Thread.sleep(1)
        }
        ShadowLooper.idleMainLooper()
        assertEquals(result.value.toString(), true, (result.value as? Map<*, *>)?.get("available"))
        return ShadowSpeechRecognizer.getLatestSpeechRecognizer()
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
