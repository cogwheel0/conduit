package app.cogwheel.conduit

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow

/**
 * The order a locked tile launches in, and the overload it launches through.
 *
 * Every test runs on both sides of the Android 14 split: below 34 the tile
 * starts the activity with the Intent overload, and from 34 it hands the system
 * a PendingIntent instead. The other tile tests assert the end state, which a
 * launch made before the unlock also produces: Robolectric runs
 * `unlockAndRun`'s callback straight away, so an activity started either side of
 * it looks the same afterwards. This test drives that callback by hand —
 * [RecordingTileServiceShadow.unlock] is what the system does once the user
 * unlocks — and records what happened in which order.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33, 34], shadows = [RecordingTileServiceShadow::class])
class AssistantTileLaunchOrderTest {
    private val android14 = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

    /** Which overload this Android version is expected to launch through. */
    private val expectedKind = if (android14) LaunchKind.PENDING_INTENT else LaunchKind.INTENT

    @Test
    fun aLockedTileLaunchesNothingUntilTheUnlockRuns() {
        val tile = Robolectric.setupService(AskTileService::class.java)
        val shadow = Shadow.extract<RecordingTileServiceShadow>(tile)
        shadow.locked = true

        tile.onClick()

        // The lock is up, so the tap may only ask for an unlock.
        assertEquals(listOf(Event.UNLOCK), shadow.events)
        assertEquals(0, shadow.launches.size)

        // What the system does once the user unlocks.
        shadow.unlock()

        assertEquals(listOf(Event.UNLOCK, Event.LAUNCH), shadow.events)
        val launch = shadow.launches.single()
        assertEquals(expectedKind, launch.kind)
        assertEquals(MainActivity::class.java.name, launch.intent.component?.className)
        val action = AssistantLaunchAction.take(launch.intent, RuntimeEnvironment.getApplication().cacheDir)
        assertEquals("startNewChat", action?.method)
        // The composer, not just the chat: the tile is for asking something.
        assertEquals(mapOf("focusComposer" to true), action?.arguments)
    }

    @Test
    fun aLockedVoiceTileDefersTheSameWay() {
        val tile = Robolectric.setupService(VoiceTileService::class.java)
        val shadow = Shadow.extract<RecordingTileServiceShadow>(tile)
        shadow.locked = true

        tile.onClick()
        assertEquals(listOf(Event.UNLOCK), shadow.events)

        shadow.unlock()
        assertEquals(listOf(Event.UNLOCK, Event.LAUNCH), shadow.events)
        val launch = shadow.launches.single()
        assertEquals(expectedKind, launch.kind)
        assertEquals("startVoiceCall", AssistantLaunchAction.take(launch.intent, RuntimeEnvironment.getApplication().cacheDir)?.method)
    }

    @Test
    fun anUnlockedTileLaunchesWithoutAskingForAnUnlock() {
        val tile = Robolectric.setupService(AskTileService::class.java)
        val shadow = Shadow.extract<RecordingTileServiceShadow>(tile)
        shadow.locked = false

        tile.onClick()

        assertEquals(listOf(Event.LAUNCH), shadow.events)
        assertEquals(expectedKind, shadow.launches.single().kind)
    }

    @Test
    fun android14LaunchesThroughAnImmutableActivityPendingIntent() {
        assumeTrue("the PendingIntent overload arrives in 34", android14)

        val tile = Robolectric.setupService(AskTileService::class.java)
        val shadow = Shadow.extract<RecordingTileServiceShadow>(tile)
        shadow.locked = false

        tile.onClick()

        val launch = shadow.launches.single()
        assertEquals(LaunchKind.PENDING_INTENT, launch.kind)
        assertEquals(true, launch.isActivityIntent)
        // Immutable because nothing fills anything into the intent, and updated
        // so a re-tap reuses the same PendingIntent instead of piling up.
        assertTrue(launch.flags and PendingIntent.FLAG_IMMUTABLE != 0)
        assertTrue(launch.flags and PendingIntent.FLAG_UPDATE_CURRENT != 0)
    }

    @Test
    fun theSecondTapAsksForTheSameLaunch() {
        assumeTrue("the PendingIntent overload arrives in 34", android14)

        val tile = Robolectric.setupService(AskTileService::class.java)
        val shadow = Shadow.extract<RecordingTileServiceShadow>(tile)

        tile.onClick()
        tile.onClick()

        val launches = shadow.launches
        assertEquals(2, launches.size)
        // FLAG_UPDATE_CURRENT plus one request code per tile means a re-tap
        // asks the system for the same launch instead of adding another.
        assertEquals(launches[0].requestCode, launches[1].requestCode)
        assertTrue(launches[0].intent.filterEquals(launches[1].intent))
    }

    @Test
    fun theTwoTilesUseTheirOwnPendingIntents() {
        assumeTrue("request codes only separate PendingIntents", android14)

        val askTile = Robolectric.setupService(AskTileService::class.java)
        val askShadow = Shadow.extract<RecordingTileServiceShadow>(askTile)
        askTile.onClick()

        val voiceTile = Robolectric.setupService(VoiceTileService::class.java)
        val voiceShadow = Shadow.extract<RecordingTileServiceShadow>(voiceTile)
        voiceTile.onClick()

        val ask = askShadow.launches.single()
        val voice = voiceShadow.launches.single()
        // Two intents that differ only in extras compare equal, so the request
        // code is the only thing keeping one tile's launch from replacing the
        // other's.
        assertNotEquals(ask.requestCode, voice.requestCode)
        assertEquals(ask.intent.component, voice.intent.component)
        assertNotEquals(
            ask.intent.getBooleanExtra(AssistantLaunchAction.EXTRA_START_NEW_CHAT, false),
            voice.intent.getBooleanExtra(AssistantLaunchAction.EXTRA_START_NEW_CHAT, false),
        )
    }
}

/** How a tile handed its launch to the system. */
enum class LaunchKind {
    INTENT,
    PENDING_INTENT,
}

/** What a tile did, in order. */
enum class Event {
    UNLOCK,
    LAUNCH,
}

/** A launch a tile made, as the shadow saw it. */
data class RecordedLaunch(
    val kind: LaunchKind,
    val intent: Intent,
    val requestCode: Int? = null,
    val flags: Int = 0,
    val isActivityIntent: Boolean = false,
)

/**
 * A [TileService] shadow that keeps the unlock callback instead of running it,
 * and records launches with the overload they came through, so a test can tell
 * a deferred launch from an immediate one and 34's PendingIntent from the older
 * Intent.
 *
 * The stock shadow runs the callback at once and its `unlockAndRun` is final,
 * so it cannot be subclassed into an observable one.
 */
@Implements(TileService::class)
class RecordingTileServiceShadow {
    val events = mutableListOf<Event>()
    val launches = mutableListOf<RecordedLaunch>()

    var locked: Boolean = false

    private var pending: Runnable? = null

    @Implementation
    protected fun isLocked(): Boolean = locked

    @Implementation
    protected fun unlockAndRun(runnable: Runnable) {
        events += Event.UNLOCK
        pending = runnable
    }

    @Implementation
    protected fun startActivityAndCollapse(intent: Intent) {
        events += Event.LAUNCH
        launches += RecordedLaunch(LaunchKind.INTENT, intent)
    }

    @Implementation(minSdk = Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    protected fun startActivityAndCollapse(pendingIntent: PendingIntent) {
        val recorded = shadowOf(pendingIntent)
        events += Event.LAUNCH
        launches += RecordedLaunch(
            kind = LaunchKind.PENDING_INTENT,
            intent = recorded.savedIntent,
            requestCode = recorded.requestCode,
            flags = recorded.flags,
            isActivityIntent = recorded.isActivityIntent,
        )
    }

    /** Runs the callback the unlock would run, as the system does afterwards. */
    fun unlock() {
        val runnable = pending
        pending = null
        runnable?.run()
    }
}
