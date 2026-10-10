package app.cogwheel.conduit.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PushConfigStoreTest {
    private val values = MemoryKeyValueStore()

    @Test
    fun defaultsUntilDartSendsAConfig() {
        val config = PushConfigStore(values).config()
        assertTrue(config.enabled)
        assertEquals(PushPayload.KINDS, config.enabledKinds)
        assertEquals("New notification", config.string(PushDisplayConfig.FALLBACK_BODY))
    }

    @Test
    fun theConfigSurvivesAReload() {
        val saved = PushDisplayConfig(
            enabled = false,
            sound = false,
            enabledKinds = setOf("reply", "test"),
            disabledScopes = setOf("hermes:x"),
            scopeLabels = mapOf("owui:a" to "Work · ünï"),
            showScopeLabel = true,
            strings = mapOf(PushDisplayConfig.TEST_TITLE to "Ça marche"),
        )
        PushConfigStore(values).save(saved)
        assertEquals(saved, PushConfigStore(values).config())
    }

    @Test
    fun aCorruptConfigFallsBackToDefaults() {
        values.putString("config", "{oops")
        assertEquals(PushDisplayConfig.DEFAULT, PushConfigStore(values).config())
    }

    @Test
    fun noncesAreTakenOncePerSid() {
        val store = PushConfigStore(values)
        store.recordNonce("s1", "a")
        store.recordNonce("s1", "b")
        store.recordNonce("s1", "a")
        store.recordNonce("s2", "c")
        assertEquals(listOf("b", "a"), PushConfigStore(values).takeNonces("s1"))
        assertTrue(store.takeNonces("s1").isEmpty())
        store.clearNonces("s2")
        assertTrue(store.takeNonces("s2").isEmpty())
    }

    @Test
    fun theOptInFlagAndTapTokenPersist() {
        val store = PushConfigStore(values)
        assertFalse(store.fcmOptedIn)
        store.fcmOptedIn = true
        assertTrue(PushConfigStore(values).fcmOptedIn)

        val token = store.tapToken()
        assertEquals(token, PushConfigStore(values).tapToken())
        assertNotEquals(token, PushConfigStore(MemoryKeyValueStore()).tapToken())
    }

    @Test
    fun releasingFcmWithdrawsTheOptIn() {
        val store = PushConfigStore(values)
        store.fcmOptedIn = true
        store.fcmOptedIn = false
        // Nothing is left that would start Firebase at the next launch.
        assertFalse(PushConfigStore(values).fcmOptedIn)
        assertEquals(null, values.getString("fcm_opted_in"))
    }
}
