package com.hiennv.flutter_callkit_incoming

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log

class TransparentActivity : Activity() {

    companion object {
        var isVisible: Boolean = false

        fun getIntent(context: Context, action: String, data: Bundle?): Intent {
            val intent = Intent(context, TransparentActivity::class.java)
            intent.action = action
            intent.putExtra("data", data)
            intent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
            intent.addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY)
            intent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return intent
        }
    }


    override fun onStart() {
        super.onStart()
        setVisible(false)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val action = intent.action
        if (action == null) {
            Log.w("TransparentActivity", "Intent action is null, finishing activity")
            finish()
            return
        }

        val data = intent.getBundleExtra("data")

        val broadcastIntent = CallkitIncomingBroadcastReceiver.getIntent(this, action, data)
        broadcastIntent.addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
        sendBroadcast(broadcastIntent)

        val activityIntent = AppUtils.getAppIntent(this, action, data)
        startActivity(activityIntent)

        finish()
        overridePendingTransition(0, 0)
    }
}
