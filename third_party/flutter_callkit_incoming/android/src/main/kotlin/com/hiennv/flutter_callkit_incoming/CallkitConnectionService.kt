package com.hiennv.flutter_callkit_incoming

import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * Self-managed Telecom [ConnectionService] — hosts in-app calls in the Android
 * Telecom framework.
 *
 * Registered via [InAppCallManager.registerPhoneAccount] with
 * [android.telecom.PhoneAccount.CAPABILITY_SELF_MANAGED]. Activated when the
 * plugin's incoming-call flow calls `telecomManager.addNewIncomingCall(...)` —
 * the OS then invokes [onCreateIncomingConnection] which returns a ringing
 * [CallkitConnection]. The Telecom layer grants the resulting call OS-level
 * privileges equivalent to a dialer app:
 *  - Keyguard bypass on the linked call Activity
 *  - Ringtone + vibration via Audio focus
 *  - Audio routing (Bluetooth / earpiece / speaker) via AudioManager call mode
 *  - Compatibility with strict OEMs (Samsung Knox, Xiaomi, Oppo) that block
 *    non-Telecom `showWhenLocked` Activities.
 *
 * Prior versions of this file were a stub with no overrides — the PhoneAccount
 * was registered but never used. Filling in the overrides + wiring
 * `addNewIncomingCall` in the BroadcastReceiver converts the plugin from an
 * "app that looks like a call" into a real first-party call.
 */
@RequiresApi(Build.VERSION_CODES.M)
class CallkitConnectionService : ConnectionService() {

    companion object {
        private const val TAG = "CallkitConnectionSvc"
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        val callBundle = extractCallBundle(request?.extras) ?: run {
            Log.w(TAG, "onCreateIncomingConnection: missing call bundle")
            return failed("Missing call data")
        }

        val data = Data.fromBundle(callBundle)
        val callId = data.id
        if (callId.isEmpty()) {
            Log.w(TAG, "onCreateIncomingConnection: empty call id")
            return failed("Empty call id")
        }

        Log.d(TAG, "onCreateIncomingConnection id=$callId caller=${data.nameCaller}")

        val connection = CallkitConnection(applicationContext, callId, callBundle).apply {
            if (data.nameCaller.isNotEmpty()) {
                setCallerDisplayName(data.nameCaller, TelecomManager.PRESENTATION_ALLOWED)
            }
            val handle = data.handle.ifEmpty { callId }
            setAddress(
                Uri.fromParts("tel", handle, null),
                TelecomManager.PRESENTATION_ALLOWED,
            )
            setRinging()
        }
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        super.onCreateIncomingConnectionFailed(connectionManagerPhoneAccount, request)
        Log.w(TAG, "onCreateIncomingConnectionFailed")
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        val callBundle = extractCallBundle(request?.extras) ?: run {
            Log.w(TAG, "onCreateOutgoingConnection: missing call bundle")
            return failed("Missing call data")
        }

        val data = Data.fromBundle(callBundle)
        val callId = data.id
        if (callId.isEmpty()) {
            Log.w(TAG, "onCreateOutgoingConnection: empty call id")
            return failed("Empty call id")
        }

        Log.d(TAG, "onCreateOutgoingConnection id=$callId callee=${data.nameCaller}")

        val connection = CallkitConnection(applicationContext, callId, callBundle).apply {
            if (data.nameCaller.isNotEmpty()) {
                setCallerDisplayName(data.nameCaller, TelecomManager.PRESENTATION_ALLOWED)
            }
            val handle = data.handle.ifEmpty { callId }
            setAddress(
                Uri.fromParts("tel", handle, null),
                TelecomManager.PRESENTATION_ALLOWED,
            )
            setDialing()
        }
        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        super.onCreateOutgoingConnectionFailed(connectionManagerPhoneAccount, request)
        Log.w(TAG, "onCreateOutgoingConnectionFailed")
    }

    private fun extractCallBundle(extras: Bundle?): Bundle? {
        if (extras == null) return null
        // Primary path — our helper nests the full plugin Data under the
        // dedicated key. Telecom also exposes the caller-supplied extras under
        // EXTRA_INCOMING_CALL_EXTRAS for the incoming path.
        extras.getBundle(CallkitConnection.EXTRA_CALL_BUNDLE)?.let { return it }
        extras.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS)?.let { inner ->
            inner.getBundle(CallkitConnection.EXTRA_CALL_BUNDLE)?.let { return it }
            if (inner.containsKey("id")) return inner
        }
        return if (extras.containsKey("id")) extras else null
    }

    private fun failed(reason: String): Connection {
        return Connection.createFailedConnection(
            DisconnectCause(DisconnectCause.ERROR, reason),
        )
    }
}
