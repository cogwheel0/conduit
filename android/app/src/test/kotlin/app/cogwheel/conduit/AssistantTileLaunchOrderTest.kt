package app.cogwheel.conduit

import android.content.Intent
import android.service.quicksettings.TileService
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow

/**
 * The order a locked tile launches in: nothing may reach the screen until the
 * unlock has run.
 *
 * The other tile tests assert the end state, which a launch made before the
 * unlock also produces: Robolectric runs `unlockAndRun`'s callback straight
 * away, so an activity started either side of it looks the same afterwards.
 * This test drives that callback by hand — [RecordingTileServiceShadow.unlock]
 * is what the system does once the user unlocks — and records what happened in
 * which order.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], shadows = [RecordingTileServiceShadow::class])
class AssistantTileLaunchOrderTest {
    @Test
    fun aLockedTileLaunchesNothingUntilTheUnlockRuns() {
        val tile = Robolectric.setupService(AskTileService::class.java)
        val shadow = Shadow.extract<RecordingTileServiceShadow>(tile)
        shadow.locked = true

        tile.onClick()

        // The lock is up, so the tap may only ask for an unlock.
        assertEquals(listOf("unlock"), shadow.events)
        assertEquals(0, shadow.launched.size)

        // What the system does once the user unlocks.
        shadow.unlock()

        assertEquals(listOf("unlock", "launch"), shadow.events)
        val launched = shadow.launched.single()
        assertEquals(MainActivity::class.java.name, launched.component?.className)
        assertEquals("startNewChat", AssistantLaunchAction.take(launched)?.method)
    }

    @Test
    fun aLockedVoiceTileDefersTheSameWay() {
        val tile = Robolectric.setupService(VoiceTileService::class.java)
        val shadow = Shadow.extract<RecordingTileServiceShadow>(tile)
        shadow.locked = true

        tile.onClick()
        assertEquals(listOf("unlock"), shadow.events)

        shadow.unlock()
        assertEquals(listOf("unlock", "launch"), shadow.events)
        assertEquals("startVoiceCall", AssistantLaunchAction.take(shadow.launched.single())?.method)
    }

    @Test
    fun anUnlockedTileLaunchesWithoutAskingForAnUnlock() {
        val tile = Robolectric.setupService(AskTileService::class.java)
        val shadow = Shadow.extract<RecordingTileServiceShadow>(tile)
        shadow.locked = false

        tile.onClick()

        assertEquals(listOf("launch"), shadow.events)
    }
}

/**
 * A [TileService] shadow that keeps the unlock callback instead of running it,
 * and records launches, so a test can tell a deferred launch from an immediate
 * one.
 *
 * The stock shadow runs the callback at once and its `unlockAndRun` is final,
 * so it cannot be subclassed into an observable one.
 */
@Implements(TileService::class)
class RecordingTileServiceShadow {
    val events = mutableListOf<String>()
    val launched = mutableListOf<Intent>()

    var locked: Boolean = false

    private var pending: Runnable? = null

    @Implementation
    protected fun isLocked(): Boolean = locked

    @Implementation
    protected fun unlockAndRun(runnable: Runnable) {
        events += "unlock"
        pending = runnable
    }

    @Implementation
    protected fun startActivityAndCollapse(intent: Intent) {
        events += "launch"
        launched += intent
    }

    /** Runs the callback the unlock would run, as the system does afterwards. */
    fun unlock() {
        val runnable = pending
        pending = null
        runnable?.run()
    }
}
