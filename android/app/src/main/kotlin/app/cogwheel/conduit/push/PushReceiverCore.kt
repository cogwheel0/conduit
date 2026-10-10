package app.cogwheel.conduit.push

/** Where the receiver's decisions go. Android in production, fakes in tests. */
interface PushDelivery {
    /** Runs [block] on the main thread, returning once it ran. */
    fun runOnMain(block: () -> Unit)

    /**
     * Main thread. True while Conduit is resumed with its Flutter engine
     * attached, the same test Dart uses for "in the foreground".
     */
    fun canForwardToApp(): Boolean

    /** Main thread. Hands the push to Dart; [done] gets false when Dart did not take it. */
    fun forwardToApp(sid: String, scope: String, payloadJson: String, done: (Boolean) -> Unit)

    /** Main thread. Posts the system notification; false when it could not, say without permission. */
    fun post(scope: String, payload: PushPayload, content: PushNotificationContent): Boolean

    fun testReceived(sid: String, nonce: String)

    fun dropped(reason: String)
}

/**
 * Turns an encrypted push into a notification, for FCM and UnifiedPush alike
 * (docs/push/PROTOCOL.md section 7):
 *
 * 1. Find the subscription by sid. Unknown sids are dropped.
 * 2. Decrypt and parse `cp/1`. Anything malformed is dropped.
 * 3. Drop it if the user turned push, this kind or this account off.
 * 4. Claim the dedup key, unless something already showed this message.
 * 5. In the foreground, Dart decides (banner or nothing); it routes the push
 *    as already claimed. Otherwise, or when Dart does not take it, post.
 *
 * Removing an account and changing settings happen on the main thread, so
 * steps 1 and 3 run again there, right before claiming and before posting.
 * A claim whose notification was not shown is given back.
 */
class PushReceiverCore(
    private val subscriptions: (String) -> PushSubscriptionRecord?,
    private val config: PushConfigStore,
    private val ledger: PushLedger,
    private val delivery: PushDelivery,
) {
    fun handle(sid: String, body: ByteArray) {
        val subscription = subscriptions(sid) ?: return delivery.dropped("unknown subscription")
        val plaintext = try {
            PushCrypto.decrypt(body, subscription.privateKey, subscription.publicKeyBytes, subscription.authBytes)
        } catch (error: PushDecryptException) {
            return delivery.dropped("undecryptable: ${error.message}")
        } catch (error: IllegalArgumentException) {
            return delivery.dropped("corrupt subscription")
        }
        val payload = PushPayload.parse(plaintext) ?: return delivery.dropped("invalid payload")
        val scope = subscription.scope

        if (payload.kind == PushPayload.KIND_TEST) {
            payload.nonce?.let { nonce ->
                config.recordNonce(sid, nonce)
                delivery.testReceived(sid, nonce)
            }
        }

        if (currentContent(sid, scope, payload) == null) return

        val key = payload.appDedupKey(scope)
        delivery.runOnMain {
            // The account may have gone, or its settings changed, since.
            val content = currentContent(sid, scope, payload) ?: return@runOnMain
            if (!ledger.claim(key, null)) {
                delivery.dropped("already shown")
                return@runOnMain
            }
            if (delivery.canForwardToApp()) {
                delivery.forwardToApp(sid, scope, payload.json) { taken ->
                    if (taken) return@forwardToApp
                    // And again: Dart may have taken a while to answer.
                    val latest = currentContent(sid, scope, payload)
                    if (latest == null) ledger.release(key) else post(key, scope, payload, latest)
                }
            } else {
                post(key, scope, payload, content)
            }
        }
    }

    /** Main thread. Gives the claim on [key] back when nothing was posted. */
    private fun post(key: String, scope: String, payload: PushPayload, content: PushNotificationContent) {
        if (delivery.post(scope, payload, content)) return
        delivery.dropped("not posted")
        ledger.release(key)
    }

    /**
     * What to show for [payload], or null, reported as dropped, when the
     * subscription is gone or the settings turn it away.
     */
    private fun currentContent(sid: String, scope: String, payload: PushPayload): PushNotificationContent? {
        if (subscriptions(sid)?.scope != scope) {
            delivery.dropped("subscription removed")
            return null
        }
        return when (val decision = PushPresenter.decide(scope, payload, config.config())) {
            is PushDecision.Drop -> {
                delivery.dropped(decision.reason)
                null
            }
            is PushDecision.Show -> decision.content
        }
    }
}
