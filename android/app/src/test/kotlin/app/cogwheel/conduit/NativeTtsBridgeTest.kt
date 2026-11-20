package app.cogwheel.conduit

import android.speech.tts.TextToSpeech
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import org.robolectric.shadows.ShadowTextToSpeech

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class NativeTtsBridgeTest {
    private lateinit var bridge: NativeTtsBridge

    @Before
    fun setUp() {
        bridge = NativeTtsBridge(Robolectric.buildActivity(MainActivity::class.java).get())
        val available = Answer()
        bridge.onMethodCall(MethodCall("isAvailable", null), available)
        shadowOf(ShadowTextToSpeech.getLastTextToSpeechInstance())
            .onInitListener
            .onInit(TextToSpeech.SUCCESS)
        ShadowLooper.idleMainLooper()
        assertEquals(true, available.value)
    }

    @After
    fun tearDown() {
        bridge.dispose()
        ShadowLooper.idleMainLooper()
        ShadowTextToSpeech.reset()
    }

    @Test
    fun rendersAskedForTogetherWaitTheirTurnAndAStalledEngineFailsThem() {
        val first = Answer()
        val second = Answer()
        synthesize("A paper kite.", first)
        synthesize("A paper boat.", second)
        ShadowLooper.idleMainLooper()
        assertNull(first.error)
        assertNull(second.error)

        // The engine never answers: it is reported, not waited on for a minute.
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofSeconds(19))
        assertNull(first.error)
        ShadowLooper.getShadowMainLooper().idleFor(Duration.ofSeconds(2))
        assertEquals("SYNTHESIS_STALLED", first.error)
        assertEquals("SYNTHESIS_STALLED", second.error)
    }

    private fun synthesize(text: String, answer: Answer) {
        bridge.onMethodCall(
            MethodCall("synthesize", mapOf("text" to text, "rate" to 0.5, "pitch" to 1.0)),
            answer
        )
    }
}

private class Answer : MethodChannel.Result {
    var value: Any? = null
    var error: String? = null

    override fun success(result: Any?) {
        value = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        error = errorCode
    }

    override fun notImplemented() {
        error = "notImplemented"
    }
}
