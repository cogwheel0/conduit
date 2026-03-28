package app.cogwheel.qonduit

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Entry point for Android's text selection context menu (ACTION_PROCESS_TEXT).
 * This activity immediately forwards the selected text to the app via an
 * ACTION_SEND intent targeted at MainActivity so the existing share handler
 * pipeline (share_handler) processes it uniformly.
 */
class ProcessTextActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val text = intent?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString() ?: ""

        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            // Route directly to our MainActivity so share_handler sees it
            setClass(this@ProcessTextActivity, MainActivity::class.java)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

        startActivity(sendIntent)
        finish()
    }
}

