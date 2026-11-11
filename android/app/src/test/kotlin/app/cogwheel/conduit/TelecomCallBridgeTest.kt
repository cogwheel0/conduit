package app.cogwheel.conduit

import android.telecom.CallAudioState.ROUTE_BLUETOOTH
import android.telecom.CallAudioState.ROUTE_EARPIECE
import android.telecom.CallAudioState.ROUTE_SPEAKER
import android.telecom.CallAudioState.ROUTE_WIRED_HEADSET
import android.telecom.CallAudioState.ROUTE_WIRED_OR_EARPIECE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TelecomCallBridgeTest {
    private val earpieceAndSpeaker = ROUTE_EARPIECE or ROUTE_SPEAKER

    @Test
    fun asksForTheLoudspeakerUnlessTheCallIsAlreadyThere() {
        assertEquals(ROUTE_SPEAKER, telecomAudioRouteFor(true, ROUTE_EARPIECE, earpieceAndSpeaker))
        // Telecom has not sent the call's audio state yet.
        assertEquals(ROUTE_SPEAKER, telecomAudioRouteFor(true, null, 0))
        assertNull(telecomAudioRouteFor(true, ROUTE_SPEAKER, earpieceAndSpeaker))
    }

    @Test
    fun leavesACallAlreadyOffTheLoudspeakerWhereTelecomPutIt() {
        assertNull(telecomAudioRouteFor(false, ROUTE_EARPIECE, earpieceAndSpeaker))
        assertNull(
            telecomAudioRouteFor(false, ROUTE_WIRED_HEADSET, ROUTE_WIRED_HEADSET or ROUTE_SPEAKER),
        )
        assertNull(
            telecomAudioRouteFor(false, ROUTE_BLUETOOTH, earpieceAndSpeaker or ROUTE_BLUETOOTH),
        )
        assertNull(telecomAudioRouteFor(false, null, 0))
    }

    @Test
    fun leavesTheLoudspeakerForBluetoothWhenTelecomHasIt() {
        assertEquals(
            ROUTE_BLUETOOTH,
            telecomAudioRouteFor(false, ROUTE_SPEAKER, earpieceAndSpeaker or ROUTE_BLUETOOTH),
        )
        assertEquals(
            ROUTE_WIRED_OR_EARPIECE,
            telecomAudioRouteFor(false, ROUTE_SPEAKER, earpieceAndSpeaker),
        )
    }
}
