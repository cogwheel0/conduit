package app.cogwheel.conduit

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The Quick Settings tiles, which are only a way in to the app's own launches.
 *
 * Runs at 33 so the tap goes through `startActivityAndCollapse(Intent)`, which
 * Robolectric can observe. The Android 14+ PendingIntent overload is the one
 * that ran in the device checks (Android 17), where both tiles were tapped in
 * the shade.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class AssistantTileServiceTest {
    private fun startedActivity() =
        shadowOf(RuntimeEnvironment.getApplication()).nextStartedActivity

    @Test
    fun tappingTheAskTileOpensANewChatWithTheComposerReady() {
        Robolectric.setupService(AskTileService::class.java).onClick()

        val launch = startedActivity()
        assertNotNull(launch)
        assertEquals(MainActivity::class.java.name, launch!!.component?.className)
        assertTrue(launch.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        assertTrue(launch.flags and Intent.FLAG_ACTIVITY_SINGLE_TOP != 0)
        assertTrue(launch.flags and Intent.FLAG_ACTIVITY_CLEAR_TOP != 0)

        val action = AssistantLaunchAction.take(launch, RuntimeEnvironment.getApplication().cacheDir)
        assertEquals("startNewChat", action?.method)
        assertEquals(mapOf("focusComposer" to true), action?.arguments)
    }

    @Test
    fun tappingTheVoiceTileStartsAVoiceCall() {
        Robolectric.setupService(VoiceTileService::class.java).onClick()

        val launch = startedActivity()
        assertNotNull(launch)
        assertEquals(MainActivity::class.java.name, launch!!.component?.className)
        val action = AssistantLaunchAction.take(launch, RuntimeEnvironment.getApplication().cacheDir)
        assertEquals("startVoiceCall", action?.method)
    }

    @Test
    fun aTileOnALockedPhoneOpensAfterTheUnlock() {
        val tile = Robolectric.setupService(AskTileService::class.java)
        shadowOf(tile).setLocked(true)

        tile.onClick()

        // unlockAndRun is what carries the launch past the keyguard; without it
        // a tap on the lock screen collapses the shade onto nothing. Robolectric
        // runs its callback at once and clears the lock, so the lock state is
        // what tells it apart from a launch that skipped the unlock.
        assertEquals(false, tile.isLocked)
        assertNotNull(startedActivity())
    }

    @Test
    fun theTilesAskForTheirOwnLaunchOnly() {
        val ask = Robolectric.setupService(AskTileService::class.java).askLaunchIntent()
        val voice = Robolectric.setupService(VoiceTileService::class.java).voiceLaunchIntent()

        // A tile carrying both extras would open whichever the reader checks
        // first, which is how the assistant's extras are read.
        assertTrue(ask.getBooleanExtra(AssistantLaunchAction.EXTRA_START_NEW_CHAT, false))
        assertEquals(false, ask.getBooleanExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL, false))
        assertTrue(voice.getBooleanExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL, false))
        assertEquals(
            false,
            voice.getBooleanExtra(AssistantLaunchAction.EXTRA_START_NEW_CHAT, false),
        )
    }
}
