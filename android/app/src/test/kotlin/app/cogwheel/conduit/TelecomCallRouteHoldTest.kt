package app.cogwheel.conduit

import android.os.Looper
import android.telecom.CallAudioState.ROUTE_EARPIECE
import android.telecom.CallAudioState.ROUTE_SPEAKER
import android.telecom.CallAudioState.ROUTE_WIRED_OR_EARPIECE
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Drives the bridge's route request against a call whose focus switch throws
 * the request away, as Telecom does while a call becomes active (the app's own
 * route calls are refused then, so the dropped request leaves the call on the
 * earpiece over a speaker button that says otherwise).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class TelecomCallRouteHoldTest {
    /** A call whose route moves only when Telecom takes a request. */
    private class FakeCall(
        override val supportedRoutes: Int = ROUTE_EARPIECE or ROUTE_SPEAKER,
    ) : TelecomCall {
        /** The route Telecom reports for the call. */
        override var audioRoute: Int? = ROUTE_EARPIECE

        /** The route the phone is playing now, as AudioManager reports it. */
        var playing: Int = ROUTE_EARPIECE

        /** Whether Telecom takes a request at all; a refusing phone never moves. */
        var applies = true

        /** Requests Telecom throws away, as a following focus switch does. */
        var droppedRequests = 0

        val requests = mutableListOf<Int>()

        override fun setAudioRoute(route: Int) {
            requests += route
            // Telecom goes on reporting the route it accepted, which is why
            // the bridge has to trust the read-back instead.
            audioRoute = route
            if (droppedRequests > 0) {
                droppedRequests -= 1
                return
            }
            if (applies) playing = route
        }
    }

    private class Answer : MethodChannel.Result {
        var answered = false
        var value: Any? = null

        override fun success(result: Any?) {
            answered = true
            value = result
        }

        override fun error(code: String, message: String?, details: Any?) =
            throw AssertionError("$code: $message")

        override fun notImplemented() = throw AssertionError("not implemented")
    }

    private fun bridge(call: FakeCall): TelecomCallBridge {
        return TelecomCallBridge(
            RuntimeEnvironment.getApplication(),
            loudspeaker = { call.playing == ROUTE_SPEAKER },
            callLookup = { call },
        )
    }

    private fun route(
        bridge: TelecomCallBridge,
        speaker: Boolean,
        callId: String = "call-1",
    ): Answer {
        val answer = Answer()
        bridge.onMethodCall(
            MethodCall(
                "routeAudio",
                hashMapOf("callId" to callId, "speaker" to speaker),
            ),
            answer,
        )
        return answer
    }

    private fun idle(millis: Long) =
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis))

    private fun loudspeaker(answer: Answer) = (answer.value as Map<*, *>)["loudspeaker"]

    @Test
    fun answersWhenTheRouteLandsAndKeepsAskingUntilItDoes() {
        val call = FakeCall()
        call.droppedRequests = 1
        val answer = route(bridge(call), speaker = true)

        // The caller reads the route back itself as soon as this answers, and
        // reverts the speaker button when the two disagree: answering before
        // Telecom has had its chance would undo the press.
        assertEquals(false, answer.answered)

        idle(1_500)
        assertEquals(true, answer.answered)
        assertEquals(true, loudspeaker(answer))
        // The first ask is dropped by the focus switch; the re-ask lands it.
        assertEquals(listOf(ROUTE_SPEAKER, ROUTE_SPEAKER), call.requests)
        assertEquals(ROUTE_SPEAKER, call.playing)
    }

    @Test
    fun answersWithTheRealRouteWhenThePhoneWillNotMove() {
        val call = FakeCall()
        call.applies = false
        val answer = route(bridge(call), speaker = true)

        // The answer waits out the confirm window so the caller's own
        // read-back agrees with it, and no longer: a caller that serializes
        // route changes must not wait out the whole hold.
        idle(800)
        assertEquals(false, answer.answered)
        idle(250)
        assertEquals(true, answer.answered)
        assertEquals(false, loudspeaker(answer))
        assertEquals(ROUTE_EARPIECE, call.playing)
        // One ask to begin with, then at most one per interval for the hold.
        assertTrue(call.requests.size <= 1 + 6)
        assertTrue(call.requests.all { it == ROUTE_SPEAKER })
    }

    @Test
    fun holdingOnKeepsAskingAfterTheAnswer() {
        val call = FakeCall()
        // The phone only moves on a re-ask that comes after the answer.
        call.droppedRequests = 3
        val answer = route(bridge(call), speaker = true)

        idle(1_000)
        assertEquals(true, answer.answered)
        assertEquals(false, loudspeaker(answer))

        // The hold is still working after the answer went out.
        idle(2_000)
        assertEquals(ROUTE_SPEAKER, call.playing)
        assertEquals(true, call.requests.size > 2)
    }

    @Test
    fun aLaterPressTakesTheRouteOver() {
        val call = FakeCall()
        call.applies = false
        val bridge = bridge(call)
        val first = route(bridge, speaker = true)
        idle(100)
        route(bridge, speaker = false)
        val afterSecondPress = call.requests.size

        idle(3_000)
        // The wait for the speaker let go instead of re-asking over the press
        // that followed it, and it still answered its caller.
        assertEquals(afterSecondPress, call.requests.size)
        assertEquals(true, first.answered)
        assertEquals(ROUTE_WIRED_OR_EARPIECE, call.audioRoute)
    }

    @Test
    fun aSpeakerPressDuringAHoldAsksImmediately() {
        val call = FakeCall()
        // The phone never moves, so the hold keeps running, and Telecom goes
        // on reporting the speaker route it already accepted.
        call.applies = false
        val bridge = bridge(call)
        route(bridge, speaker = true)
        idle(100)
        val before = call.requests.size

        route(bridge, speaker = true)

        // The reported route is already speaker, which is also what a dropped
        // re-ask leaves behind. Waiting out the 400 ms re-ask can miss the
        // 900 ms window the caller gives the press.
        assertEquals(before + 1, call.requests.size)
        assertEquals(ROUTE_SPEAKER, call.requests.last())
    }

    @Test
    fun anEarpiecePressDuringALaggingHoldAsksImmediately() {
        val call = FakeCall()
        call.applies = false
        val bridge = bridge(call)
        route(bridge, speaker = true)
        idle(100)
        // The speaker asks are in flight, and Telecom's report has not caught up.
        call.audioRoute = ROUTE_EARPIECE
        val before = call.requests.size

        route(bridge, speaker = false)

        // The report is already off the speaker, so the hold keeps that
        // earpiece route. It still has to be asked now: the speaker requests
        // already in flight would otherwise be the last word.
        assertEquals(before + 1, call.requests.size)
        assertEquals(ROUTE_EARPIECE, call.requests.last())
    }

    @Test
    fun aPressAsksImmediatelyWhenTelecomReportsARouteThePhoneIsNotPlaying() {
        val call = FakeCall()
        // No hold is running, and Telecom reports the speaker it accepted and
        // then dropped while the phone still plays the earpiece.
        call.audioRoute = ROUTE_SPEAKER
        val answer = route(bridge(call), speaker = true)

        // The read-back disagrees, so the press asks with it rather than on
        // the re-ask 400 ms later, which can miss the caller's 900 ms window.
        assertEquals(listOf(ROUTE_SPEAKER), call.requests)
        assertEquals(true, answer.answered)
        assertEquals(true, loudspeaker(answer))
    }

    @Test
    fun aLookupStillPollingLeavesTheRouteToTheLaterPress() {
        val call = FakeCall()
        var created = false
        val bridge = TelecomCallBridge(
            RuntimeEnvironment.getApplication(),
            loudspeaker = { call.playing == ROUTE_SPEAKER },
            callLookup = { if (created) call else null },
        )
        // Telecom has not created the connection yet, so this press polls.
        val first = route(bridge, speaker = true)
        // The connection arrives, and an earpiece press finds it first.
        created = true
        val second = route(bridge, speaker = false)
        assertEquals(true, second.answered)
        assertEquals(false, loudspeaker(second))

        idle(200)
        // The first press's next poll finds the call too. It answers with
        // where the phone is and leaves the later press's route alone.
        assertEquals(true, first.answered)
        assertEquals(false, loudspeaker(first))
        assertEquals(emptyList<Int>(), call.requests)
        assertEquals(ROUTE_EARPIECE, call.playing)
    }

    @Test
    fun disposingStopsTheHoldAndAnswersTheCaller() {
        val call = FakeCall()
        call.applies = false
        val bridge = bridge(call)
        val answer = route(bridge, speaker = true)
        idle(100)
        assertEquals(false, answer.answered)

        bridge.dispose()
        val afterDispose = call.requests.size

        // The caller's route queue is serialized behind this answer, so a
        // disposed bridge must still give it one.
        assertEquals(true, answer.answered)
        idle(3_000)
        assertEquals(afterDispose, call.requests.size)
    }

    @Test
    fun disposingAnswersACallerStillWaitingForTheConnection() {
        val bridge = TelecomCallBridge(
            RuntimeEnvironment.getApplication(),
            loudspeaker = { false },
            callLookup = { null },
        )
        val answer = Answer()
        bridge.onMethodCall(
            MethodCall("awaitConnection", hashMapOf("callId" to "late-call")),
            answer,
        )
        idle(100)
        // Telecom has not created the connection yet.
        assertEquals(false, answer.answered)

        bridge.dispose()

        // The caller waits on this before marking the call connected, so a
        // dispose that stayed silent would leave the call dialing into the
        // two-minute teardown of #846 — and hold its route queue meanwhile.
        assertEquals(true, answer.answered)
        assertEquals(false, answer.value)
    }

    @Test
    fun aCallTelecomDoesNotHostIsTheCallersToRoute() {
        val bridge = TelecomCallBridge(
            RuntimeEnvironment.getApplication(),
            loudspeaker = { false },
            callLookup = { null },
        )

        val answer = route(bridge, speaker = true, callId = "no-call")

        idle(1_200)
        // No Telecom call means the caller's own route requests are the ones
        // that count, so the answer says so rather than claiming a route.
        assertTrue(answer.answered)
        assertEquals(null, answer.value)
    }
}
