package app.cogwheel.conduit.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PushPresenterTest {
    private val strings = mapOf(
        PushDisplayConfig.FALLBACK_TITLE to "Conduit",
        PushDisplayConfig.FALLBACK_BODY to "Nouvelle notification",
        PushDisplayConfig.REPLY_TITLE to "Nouvelle réponse",
        PushDisplayConfig.REPLY_FAILED_TITLE to "Échec",
        PushDisplayConfig.REPLY_FAILED_BODY to "La réponse a échoué.",
        PushDisplayConfig.CHANNEL_TITLE to "Canal",
        PushDisplayConfig.CRON_TITLE to "Tâche planifiée",
        PushDisplayConfig.TEST_TITLE to "Test réussi",
        PushDisplayConfig.TEST_BODY to "Chiffré de bout en bout.",
    )
    private val config = PushDisplayConfig.DEFAULT.copy(
        scopeLabels = mapOf("owui:acct-1" to "Work", "owui:acct-2" to "Home"),
        strings = strings,
    )

    private fun case(name: String): Pair<String, PushPayload> {
        val case = PushVectors.cases().first { it.getString("name") == name }
        return case.getString("scope") to PushPayload.parse(case.bytes("plaintext"))!!
    }

    private fun show(name: String, config: PushDisplayConfig = this.config): PushNotificationContent {
        val (scope, payload) = case(name)
        val decision = PushPresenter.decide(scope, payload, config)
        assertTrue("$name: $decision", decision is PushDecision.Show)
        return (decision as PushDecision.Show).content
    }

    private fun drop(name: String, config: PushDisplayConfig): String {
        val (scope, payload) = case(name)
        val decision = PushPresenter.decide(scope, payload, config)
        assertTrue("$name: $decision", decision is PushDecision.Drop)
        return (decision as PushDecision.Drop).reason
    }

    @Test
    fun aReplyShowsItsTitleBodyTagAndGroup() {
        val content = show("owui_reply")
        assertEquals("Trip ideas", content.title)
        assertEquals("Here are three routes along the coast:", content.body)
        assertEquals("owui:acct-1|chat:4f1c2a7e:b9d0e3f1", content.tag)
        assertEquals("owui:acct-1|chat:4f1c2a7e", content.group)
        assertEquals(1_760_000_000_000L, content.timestampMillis)
        assertNull(content.subtitle)
        assertFalse(content.silent)
        assertEquals("Conduit", content.publicTitle)
        assertEquals("Nouvelle notification", content.publicBody)
    }

    @Test
    fun theTagMatchesTheAppDedupKey() {
        PushVectors.cases().forEach { case ->
            val payload = PushPayload.parse(case.bytes("plaintext"))!!
            val decision = PushPresenter.decide(case.getString("scope"), payload, config)
            assertEquals(case.getString("app_dedup_key"), (decision as PushDecision.Show).content.tag)
        }
    }

    @Test
    fun aFailedReplyWithoutPreviewUsesTheLocalizedBody() {
        val content = show("owui_reply_failed")
        assertEquals("Trip ideas", content.title)
        assertEquals("La réponse a échoué.", content.body)
    }

    @Test
    fun aChannelMessageLeadsWithItsAuthor() {
        val content = show("owui_channel_unicode")
        assertEquals("Zoë 🦊 (#général)", content.title)
        assertTrue(content.body.startsWith("Réunion"))
        assertEquals("owui:acct-2|channel:ch-9", content.group)
    }

    @Test
    fun aTestPushUsesTheTestStrings() {
        val content = show("test")
        assertEquals("Test réussi", content.title)
        assertEquals("Chiffré de bout en bout.", content.body)
        assertNull(content.group)
    }

    @Test
    fun emptyTitlesFallBackPerKind() {
        val scope = "hermes:c"
        fun titleOf(kind: String) = (PushPresenter.decide(
            scope,
            PushPayload.parse("""{"v":1,"k":"$kind","dk":"x"}""".toByteArray())!!,
            config,
        ) as PushDecision.Show).content.title
        assertEquals("Nouvelle réponse", titleOf("reply"))
        assertEquals("Échec", titleOf("reply_failed"))
        assertEquals("Canal", titleOf("channel"))
        assertEquals("Tâche planifiée", titleOf("cron"))
    }

    @Test
    fun missingStringsFallBackToEnglish() {
        val content = show("owui_reply_failed", PushDisplayConfig.DEFAULT)
        assertEquals("The response could not be completed.", content.body)
        assertEquals("New notification", content.publicBody)
    }

    @Test
    fun theScopeLabelShowsOnlyWhenAsked() {
        assertNull(show("owui_reply").subtitle)
        assertEquals("Work", show("owui_reply", config.copy(showScopeLabel = true)).subtitle)
        assertNull(show("hermes_reply", config.copy(showScopeLabel = true)).subtitle)
    }

    @Test
    fun soundOffPostsSilently() {
        assertTrue(show("owui_reply", config.copy(sound = false)).silent)
    }

    @Test
    fun theMasterSwitchKindsAndScopesDrop() {
        drop("owui_reply", config.copy(enabled = false))
        drop("hermes_cron", config.copy(enabledKinds = PushPayload.KINDS - PushPayload.KIND_CRON))
        show("hermes_reply", config.copy(enabledKinds = PushPayload.KINDS - PushPayload.KIND_CRON))
        drop("owui_channel_unicode", config.copy(disabledScopes = setOf("owui:acct-2")))
        show("owui_reply", config.copy(disabledScopes = setOf("owui:acct-2")))
        drop("test", config.copy(enabledKinds = emptySet()))
    }
}
