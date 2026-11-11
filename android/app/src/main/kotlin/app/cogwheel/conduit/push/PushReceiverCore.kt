package app.cogwheel.conduit.push

/** Where the receiver's decisions go. Android in production, fakes in tests. */
interface PushDelivery {
    /** Runs [block] on the main thread, returning once it ran. */
    fun runOnMain(block: () -> Unit)

    /** Main thread. True while Conduit is in the foreground with its Flutter engine attached. */
    fun canForwardToApp(): Boolean

    /** Main thread. Hands the push to Dart; [done] gets false when Dart did not take it. */
    fun forwardToApp(sid: String, scope: String, payloadJson: String, done: (Boolean) -> Unit)

    /** Main thread. Posts the system notification. */
    fun post(scope: String, payload: PushPayload, content: PushNotificationContent)

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
 * 4. In the foreground, Dart decides (banner or nothing).
 * 5. Otherwise claim the dedup key and post, unless something already
 *    showed this message.
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

        val content = when (val decision = PushPresenter.decide(scope, payload, config.config())) {
            is PushDecision.Drop -> return delivery.dropped(decision.reason)
            is PushDecision.Show -> decision.content
        }

        delivery.runOnMain {
            if (delivery.canForwardToApp()) {
                delivery.forwardToApp(sid, scope, payload.json) { taken ->
                    if (!taken) postOnce(scope, payload, content)
                }
            } else {
                postOnce(scope, payload, content)
            }
        }
    }

    private fun postOnce(scope: String, payload: PushPayload, content: PushNotificationContent) {
        if (ledger.claim(payload.appDedupKey(scope), null)) {
            delivery.post(scope, payload, content)
        } else {
            delivery.dropped("already shown")
        }
    }
}
