package app.cogwheel.conduit

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class AssistantLaunchTest {
    @Test
    fun theOverlayTextBoxAsksForANewChatReadyToType() {
        val intent = Intent()
            .putExtra(AssistantLaunchAction.EXTRA_START_NEW_CHAT, true)
            .putExtra(AssistantLaunchAction.EXTRA_FOCUS_COMPOSER, true)

        val action = AssistantLaunchAction.take(intent)

        assertEquals("startNewChat", action?.method)
        assertEquals(mapOf("focusComposer" to true), action?.arguments)
        assertEquals(
            mapOf(
                "method" to "startNewChat",
                "arguments" to mapOf("focusComposer" to true)
            ),
            action?.toChannelValue()
        )
    }

    @Test
    fun aRequestIsTakenOnceSoARecreatedActivityDoesNotRepeatIt() {
        val intent = Intent()
            .putExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL, true)

        assertEquals("startVoiceCall", AssistantLaunchAction.take(intent)?.method)
        assertFalse(intent.hasExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL))
        assertNull(AssistantLaunchAction.take(intent))
    }

    @Test
    fun reopeningFromRecentsDoesNotReplayTheAssistantRequest() {
        val intent = Intent()
            .putExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL, true)
            .addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)

        assertNull(AssistantLaunchAction.take(intent))
        assertFalse(intent.hasExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL))
    }

    @Test
    fun anOrdinaryLaunchAsksForNothing() {
        assertNull(AssistantLaunchAction.take(Intent(Intent.ACTION_MAIN)))
    }

    @Test
    fun aColdStartRequestWaitsUntilDartAsksForIt() {
        val queue = AssistantLaunchQueue()
        val call = AssistantLaunchAction("startVoiceCall", null)

        assertNull(queue.offer(call))
        assertSame(call, queue.startListening())
        assertNull(queue.startListening())
    }

    @Test
    fun onlyTheLatestRequestIsHeld() {
        val queue = AssistantLaunchQueue()
        queue.offer(AssistantLaunchAction("startVoiceCall", null))
        val newChat = AssistantLaunchAction("startNewChat", null)
        queue.offer(newChat)

        assertSame(newChat, queue.startListening())
    }

    @Test
    fun requestsGoStraightToDartOnceItListens() {
        val queue = AssistantLaunchQueue()
        queue.startListening()
        val call = AssistantLaunchAction("startVoiceCall", null)

        assertSame(call, queue.offer(call))
    }

    @Test
    fun aNewEngineWaitsForItsOwnDartHandler() {
        val queue = AssistantLaunchQueue()
        queue.startListening()
        queue.reset()
        val call = AssistantLaunchAction("startVoiceCall", null)

        assertNull(queue.offer(call))
        assertSame(call, queue.startListening())
    }
}
