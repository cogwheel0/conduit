package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Tests for the confirmation gate: which actions are gated, and what the
 * approval dialog shows for each. Lenient summaries must never crash on
 * missing or malformed arguments. */
class DeviceActionConfirmationTest {
    @Test
    fun silentStateChangesRequireConfirmation() {
        assertTrue(DeviceActions.requiresConfirmation(DeviceActions.SET_ALARM))
        assertTrue(DeviceActions.requiresConfirmation(DeviceActions.SET_TIMER))
        assertTrue(DeviceActions.requiresConfirmation(DeviceActions.FLASHLIGHT))
        assertTrue(DeviceActions.requiresConfirmation(DeviceActions.SET_VOLUME))
    }

    @Test
    fun visibleSurfacesAndReadonlyActionsStayUngated() {
        // These open a system surface the user can back out of (or only read
        // data), so no dialog gate is needed.
        val ungated = setOf(
            DeviceActions.OPEN_SETTINGS,
            DeviceActions.DIAL,
            DeviceActions.CALENDAR_EVENT,
            DeviceActions.PLAY_MEDIA,
            DeviceActions.WEB_SEARCH,
            DeviceActions.OPEN_APP,
            DeviceActions.COMPOSE_SMS,
            DeviceActions.SHARE_TEXT,
            DeviceActions.GET_WEATHER,
            DeviceActions.WEB_LOOKUP,
        )
        for (name in ungated) {
            assertFalse("expected no gate for $name", DeviceActions.requiresConfirmation(name))
        }
        assertFalse(DeviceActions.requiresConfirmation("factory_reset"))
        assertFalse(DeviceActions.requiresConfirmation(""))
    }

    @Test
    fun describesAlarmWithTime() {
        val description = DeviceActionPrompts.describe(
            DeviceActions.SET_ALARM,
            args("hour", 7, "minute", 30),
        )
        assertEquals("Set an alarm for 07:30", description)
    }

    @Test
    fun describesAlarmLenientlyWhenTimeIsMissingOrInvalid() {
        assertEquals("Set an alarm", DeviceActionPrompts.describe(DeviceActions.SET_ALARM, args()))
        assertEquals(
            "Set an alarm",
            DeviceActionPrompts.describe(DeviceActions.SET_ALARM, args("hour", 25, "minute", 0)),
        )
        assertEquals(
            "Set an alarm",
            DeviceActionPrompts.describe(DeviceActions.SET_ALARM, args("hour", 7, "minute", -1)),
        )
    }

    @Test
    fun describesTimerInHumanUnits() {
        assertEquals(
            "Start a 5 minute timer",
            DeviceActionPrompts.describe(DeviceActions.SET_TIMER, args("seconds", 300)),
        )
        assertEquals(
            "Start a 2 hour timer",
            DeviceActionPrompts.describe(DeviceActions.SET_TIMER, args("seconds", 7_200)),
        )
        assertEquals(
            "Start a timer for 1 min 30 s",
            DeviceActionPrompts.describe(DeviceActions.SET_TIMER, args("seconds", 90)),
        )
    }

    @Test
    fun describesTimerLenientlyWhenSecondsAreMissingOrInvalid() {
        assertEquals("Start a timer", DeviceActionPrompts.describe(DeviceActions.SET_TIMER, args()))
        assertEquals(
            "Start a timer",
            DeviceActionPrompts.describe(DeviceActions.SET_TIMER, args("seconds", -5)),
        )
        assertEquals(
            "Start a timer",
            DeviceActionPrompts.describe(DeviceActions.SET_TIMER, args("seconds", 200_000)),
        )
    }

    @Test
    fun describesFlashlightDirection() {
        assertEquals(
            "Turn the flashlight on",
            DeviceActionPrompts.describe(DeviceActions.FLASHLIGHT, args("on", true)),
        )
        assertEquals(
            "Turn the flashlight off",
            DeviceActionPrompts.describe(DeviceActions.FLASHLIGHT, args("on", false)),
        )
        assertEquals(
            "Toggle the flashlight",
            DeviceActionPrompts.describe(DeviceActions.FLASHLIGHT, args()),
        )
    }

    @Test
    fun describesVolumeWithStreamAndPercent() {
        assertEquals(
            "Set media volume to 40 percent",
            DeviceActionPrompts.describe(DeviceActions.SET_VOLUME, args("volumePercent", 40)),
        )
        assertEquals(
            "Set ringer volume to 80 percent",
            DeviceActionPrompts.describe(DeviceActions.SET_VOLUME, args("volumePercent", 80, "stream", "ring")),
        )
        assertEquals(
            "Set alarm volume to 10 percent",
            DeviceActionPrompts.describe(DeviceActions.SET_VOLUME, args("volumePercent", 10, "stream", "alarm")),
        )
        assertEquals(
            "Set notification volume to 5 percent",
            DeviceActionPrompts.describe(DeviceActions.SET_VOLUME, args("volumePercent", 5, "stream", "notification")),
        )
        // Unknown stream names fall back to media rather than leaking raw text.
        assertEquals(
            "Set media volume to 50 percent",
            DeviceActionPrompts.describe(DeviceActions.SET_VOLUME, args("volumePercent", 50, "stream", "weird")),
        )
    }

    @Test
    fun describesVolumeLenientlyWhenPercentIsMissingOrInvalid() {
        assertEquals(
            "Set the device volume",
            DeviceActionPrompts.describe(DeviceActions.SET_VOLUME, args()),
        )
        assertEquals(
            "Set the device volume",
            DeviceActionPrompts.describe(DeviceActions.SET_VOLUME, args("volumePercent", 150)),
        )
        assertEquals(
            "Set the device volume",
            DeviceActionPrompts.describe(DeviceActions.SET_VOLUME, args("volumePercent", -1)),
        )
    }

    @Test
    fun unknownActionStillProducesASummary() {
        // requiresConfirmation is whitelist-driven, so an unknown name is not
        // gated; describe() must still be total for it.
        assertEquals(
            "Perform the 'future_action' action",
            DeviceActionPrompts.describe("future_action", args()),
        )
    }

    @Test
    fun malformedArgsNeverCrashDescribe() {
        // An empty object is the lenient floor for every gated action.
        for (name in DeviceActions.confirmationRequired) {
            DeviceActionPrompts.describe(name, args())
        }
    }

    private fun args(vararg pairs: Any): org.json.JSONObject {
        val args = org.json.JSONObject()
        var index = 0
        while (index + 1 < pairs.size) {
            args.put(pairs[index].toString(), pairs[index + 1])
            index += 2
        }
        return args
    }
}