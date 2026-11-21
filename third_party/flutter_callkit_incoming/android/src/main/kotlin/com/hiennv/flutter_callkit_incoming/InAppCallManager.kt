package com.hiennv.flutter_callkit_incoming

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresApi

@RequiresApi(Build.VERSION_CODES.M)
class InAppCallManager(private val context: Context) {

    companion object {
        private const val ACCOUNT_ID = "flutter_callkit_incoming_in_app_call_account"
        private const val TAG = "InAppCallManager"
    }

    fun registerPhoneAccount() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        // Runs on the plugin-attach path, so anything thrown here crashes the host app
        // at startup. Telecom raises SecurityException without MANAGE_OWN_CALLS and
        // IllegalArgumentException on some OEM builds; neither is worth a crash.
        try {
            val telecomManager =
                context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
            val componentName = ComponentName(context, CallkitConnectionService::class.java)
            val handle = PhoneAccountHandle(componentName, ACCOUNT_ID)

            val phoneAccount = PhoneAccount.builder(handle, "Callkit Incoming In-App Call")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .build()

            telecomManager.registerPhoneAccount(phoneAccount)
            Log.d(TAG, "PhoneAccount registered.")
        } catch (e: Exception) {
            Log.e(TAG, "registerPhoneAccount failed — self-managed Telecom unavailable", e)
        }
    }

    fun unregisterPhoneAccount() {
        try {
            val telecomManager =
                context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
            val componentName = ComponentName(context, CallkitConnectionService::class.java)
            val handle = PhoneAccountHandle(componentName, ACCOUNT_ID)

            telecomManager.unregisterPhoneAccount(handle)
            Log.d(TAG, "PhoneAccount unregistered.")
        } catch (e: Exception) {
            Log.e(TAG, "unregisterPhoneAccount failed", e)
        }
    }

    fun getPhoneAccountHandle(): PhoneAccountHandle {
        return PhoneAccountHandle(
            ComponentName(context, CallkitConnectionService::class.java),
            ACCOUNT_ID
        )
    }
}
