package app.cogwheel.conduit.push

/** What a shown push looks like. Plain data, so the rules are unit-testable. */
data class PushNotificationContent(
    /** `scope|dk`: a repeat of the same message replaces the notification. */
    val tag: String,
    /** `scope|g`, so threads from different accounts never merge. */
    val group: String?,
    val title: String,
    val body: String,
    /** The account or connection name, when the user has several. */
    val subtitle: String?,
    val silent: Boolean,
    /** The lock-screen stand-in when the user hides sensitive content. */
    val publicTitle: String,
    val publicBody: String,
    val timestampMillis: Long?,
)

sealed class PushDecision {
    data class Drop(val reason: String) : PushDecision()
    data class Show(val content: PushNotificationContent) : PushDecision()
}

/** Decides whether and how a decrypted push is shown (PROTOCOL section 7). */
object PushPresenter {
    fun tag(scope: String, dedupKey: String): String = "$scope|$dedupKey"

    fun decide(scope: String, payload: PushPayload, config: PushDisplayConfig): PushDecision {
        if (!config.enabled) return PushDecision.Drop("push disabled")
        if (payload.kind !in config.enabledKinds) return PushDecision.Drop("kind ${payload.kind} disabled")
        if (scope in config.disabledScopes) return PushDecision.Drop("scope disabled")

        val isTest = payload.kind == PushPayload.KIND_TEST
        return PushDecision.Show(
            PushNotificationContent(
                tag = tag(scope, payload.dedupKey),
                group = payload.group?.let { "$scope|$it" },
                title = if (isTest) config.string(PushDisplayConfig.TEST_TITLE) else title(payload, config),
                body = if (isTest) config.string(PushDisplayConfig.TEST_BODY) else body(payload, config),
                subtitle = if (config.showScopeLabel) {
                    config.scopeLabels[scope]?.takeIf { it.isNotBlank() }
                } else {
                    null
                },
                silent = !config.sound,
                publicTitle = config.string(PushDisplayConfig.FALLBACK_TITLE),
                publicBody = config.string(PushDisplayConfig.FALLBACK_BODY),
                timestampMillis = payload.timestamp.takeIf { it > 0 }?.let { it * 1000 },
            )
        )
    }

    private fun title(payload: PushPayload, config: PushDisplayConfig): String {
        val title = payload.title.trim()
        val author = payload.author?.trim()?.takeIf { it.isNotEmpty() }
        if (payload.kind == PushPayload.KIND_CHANNEL && author != null) {
            // Matches the in-app channel notification: "Author (#channel)".
            return if (title.isEmpty()) author else "$author ($title)"
        }
        if (title.isNotEmpty()) return title
        return config.string(
            when (payload.kind) {
                PushPayload.KIND_REPLY -> PushDisplayConfig.REPLY_TITLE
                PushPayload.KIND_REPLY_FAILED -> PushDisplayConfig.REPLY_FAILED_TITLE
                PushPayload.KIND_CHANNEL -> PushDisplayConfig.CHANNEL_TITLE
                PushPayload.KIND_CRON -> PushDisplayConfig.CRON_TITLE
                else -> PushDisplayConfig.FALLBACK_TITLE
            }
        )
    }

    private fun body(payload: PushPayload, config: PushDisplayConfig): String {
        val body = payload.body.trim()
        if (body.isNotEmpty()) return body
        return if (payload.kind == PushPayload.KIND_REPLY_FAILED) {
            config.string(PushDisplayConfig.REPLY_FAILED_BODY)
        } else {
            ""
        }
    }
}
