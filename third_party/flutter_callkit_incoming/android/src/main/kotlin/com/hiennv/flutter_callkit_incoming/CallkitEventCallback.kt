package com.hiennv.flutter_callkit_incoming

import android.os.Bundle

/**
 * Unified callback interface for handling call accept and decline events natively.
 * This allows other plugins or services to receive call events
 * even when the Flutter engine is terminated.
 */
interface CallkitEventCallback {
    
    /**
     * Called when a call is accepted or declined.
     * @param event The type of call event (ACCEPT, DECLINE, END)
     * @param callData Bundle containing call information (id, nameCaller, etc.)
     */
    fun onCallEvent(event: CallEvent, callData: Bundle)
    
    /**
     * Enum representing call events we handle
     */
    enum class CallEvent {
        ACCEPT,
        DECLINE,
        END
    }
}