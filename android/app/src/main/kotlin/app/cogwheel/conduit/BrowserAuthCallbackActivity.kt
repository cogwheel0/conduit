package app.cogwheel.conduit

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Receives `conduit://oauth/callback` from a Custom Tab or the default
 * browser, hands it to the sign-in in progress, and returns to the app.
 *
 * A separate, invisible activity rather than [MainActivity]: the redirect
 * never reaches Flutter's deep links or [MainActivity]'s own intent
 * handling, and the relaunch carries no data. The redirect is delivered at
 * most once, and only to a sign-in waiting for exactly this redirect with
 * its state, so a superseded sign-in's cannot end a newer one; PKCE and the
 * state check in Dart cover a link another app forged.
 */
class BrowserAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity already delivered its redirect, if it could.
        if (savedInstanceState == null) {
            intent?.data?.toString()?.let { BrowserAuthSession.flows.deliver(it) }
        }
        // Back to the app, closing a Custom Tab above it.
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
            ),
        )
        finish()
    }
}
