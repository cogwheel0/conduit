package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class RealtimePlaybackQueueTest {
    @Test
    fun pausedPlaybackKeepsWhatIsQueuedUntilResumed() {
        val queue = RealtimePlaybackQueue()
        queue.enqueue("resp-1", "speech-1", 0, ShortArray(2400) { 1 })
        assertNotNull(queue.next(480))

        queue.paused = true
        assertNull(queue.next(480))
        assertEquals(1920, queue.queued)

        queue.paused = false
        val piece = queue.next(480)
        assertNotNull(piece)
        assertEquals("speech-1", piece!!.itemId)
        assertEquals(1440, queue.queued)
    }

    @Test
    fun aNewCallStartsUnpaused() {
        val queue = RealtimePlaybackQueue()
        queue.paused = true
        queue.reset()

        queue.enqueue("resp-1", "speech-1", 0, ShortArray(1920) { 1 })
        assertNotNull(queue.next(480))
    }
}
