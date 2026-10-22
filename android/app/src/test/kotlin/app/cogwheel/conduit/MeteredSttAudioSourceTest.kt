package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MeteredSttAudioSourceTest {
    @Test
    fun silenceAndNoiseFloorHaveNoActivity() {
        assertEquals(0.0, MeteredSttAudioSource.levelFromPcm(ShortArray(512), 512), 0.0)
        assertEquals(0.0, MeteredSttAudioSource.levelFromPcm(ShortArray(512) { 100 }, 512), 0.0)
    }

    @Test
    fun originalGainUsesRmsRatherThanPeakAndSaturates() {
        assertEquals(0.761842, MeteredSttAudioSource.levelFromPcm(ShortArray(512) { 3277 }, 512), 0.0001)
        val quiet = MeteredSttAudioSource.levelFromPcm(ShortArray(512) { 1000 }, 512)
        val loud = MeteredSttAudioSource.levelFromPcm(ShortArray(512) { 3000 }, 512)
        assertTrue(loud > quiet)
        assertEquals(1.0, MeteredSttAudioSource.levelFromPcm(ShortArray(512) { Short.MAX_VALUE }, 512), 0.0)
    }
}
