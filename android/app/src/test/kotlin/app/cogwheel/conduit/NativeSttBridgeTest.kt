package app.cogwheel.conduit

import android.content.Intent
import android.content.pm.ResolveInfo
import android.content.pm.ServiceInfo
import android.os.Bundle
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class NativeSttBridgeTest {
    private lateinit var bridge: NativeSttBridge
    private lateinit var previousLocale: Locale
    private val events = mutableListOf<Map<*, *>>()

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
        bridge = NativeSttBridge(Robolectric.buildActivity(MainActivity::class.java).get())
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

    private class IgnoreResult : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) {
            throw AssertionError("Unexpected method failure: $code $message")
        }
        override fun notImplemented() { throw AssertionError("Method was not implemented") }
    }
}
