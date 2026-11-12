package app.cogwheel.conduit

import android.content.Intent
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class AssistantLaunchTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val cacheDir: File by lazy { temp.newFolder("cache") }

    @Test
    fun theOverlayTextBoxAsksForANewChatReadyToType() {
        val intent = Intent()
            .putExtra(AssistantLaunchAction.EXTRA_START_NEW_CHAT, true)
            .putExtra(AssistantLaunchAction.EXTRA_FOCUS_COMPOSER, true)

        val action = AssistantLaunchAction.take(intent, cacheDir)

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

        assertEquals("startVoiceCall", AssistantLaunchAction.take(intent, cacheDir)?.method)
        assertFalse(intent.hasExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL))
        assertNull(AssistantLaunchAction.take(intent, cacheDir))
    }

    @Test
    fun reopeningFromRecentsDoesNotReplayTheAssistantRequest() {
        val intent = Intent()
            .putExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL, true)
            .addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)

        assertNull(AssistantLaunchAction.take(intent, cacheDir))
        assertFalse(intent.hasExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL))
    }

    @Test
    fun anOrdinaryLaunchAsksForNothing() {
        assertNull(AssistantLaunchAction.take(Intent(Intent.ACTION_MAIN), cacheDir))
    }

    @Test
    fun aScreenshotTheAssistantSessionCachedIsPassedOn() {
        val screenshot = File(cacheDir, "assistant_screenshot_1.png").apply {
            writeText("png")
        }

        val action = take(screenshot.path)

        assertEquals("analyzeScreenshot", action?.method)
        assertEquals(screenshot.canonicalPath, action?.arguments)
    }

    @Test
    fun aScreenshotPathOutsideTheCacheIsDropped() {
        val elsewhere = temp.newFolder("files")
        File(elsewhere, "assistant_screenshot_1.png").writeText("png")
        File(cacheDir, "nested").mkdir()
        File(cacheDir, "nested/assistant_screenshot_1.png").writeText("png")
        File(cacheDir, "app.db").writeText("db")
        val link = File(cacheDir, "assistant_screenshot_link.png")
        Files.createSymbolicLink(
            link.toPath(),
            File(elsewhere, "assistant_screenshot_1.png").toPath()
        )

        for (path in listOf(
            File(elsewhere, "assistant_screenshot_1.png").path,
            "${cacheDir.path}/../files/assistant_screenshot_1.png",
            File(cacheDir, "nested/assistant_screenshot_1.png").path,
            File(cacheDir, "app.db").path,
            link.path,
            File(cacheDir, "assistant_screenshot_missing.png").path,
            "assistant_screenshot_1.png"
        )) {
            assertNull(path, take(path))
        }
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

    private fun take(screenshotPath: String) = AssistantLaunchAction.take(
        Intent().putExtra(AssistantLaunchAction.EXTRA_SCREENSHOT_PATH, screenshotPath),
        cacheDir
    )
}
