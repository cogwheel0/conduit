package app.cogwheel.conduit

import android.Manifest
import android.os.Looper
import android.telecom.Connection
import android.telecom.TelecomManager
import com.hiennv.flutter_callkit_incoming.CallkitConnection
import com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowTelecomManager

/**
 * Drives flutter_callkit_incoming's real Android call flow with Telecom
 * creating the outgoing connection late, as it does on a device while it binds
 * the plugin's ConnectionService (issue #846).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class TelecomCallBridgeFlowTest {
    private object Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    private class Answer : MethodChannel.Result {
        var answered = false
        var value: Any? = null

        override fun success(result: Any?) {
            answered = true
            value = result
        }

        override fun error(code: String, message: String?, details: Any?) =
            throw AssertionError("$code: $message")

        override fun notImplemented() = throw AssertionError("not implemented")
    }

    private val app = RuntimeEnvironment.getApplication()
    private var delivered = 0

    /** Hands the plugin's broadcasts to its receiver, as the system would. */
    private fun deliverBroadcasts() {
        val intents = shadowOf(app).broadcastIntents
        while (delivered < intents.size) {
            CallkitIncomingBroadcastReceiver().onReceive(app, intents[delivered++])
        }
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun startCall(plugin: FlutterCallkitIncomingPlugin, id: String) {
        val params = hashMapOf<String, Any?>(
            "id" to id,
            "nameCaller" to "Model",
            "appName" to "Conduit",
            "handle" to "Conduit AI",
            "type" to 0,
            "duration" to 7200000,
        )
        plugin.onMethodCall(MethodCall("startCall", params), Answer())
        deliverBroadcasts()
    }

    private fun markConnected(plugin: FlutterCallkitIncomingPlugin, id: String) {
        plugin.onMethodCall(MethodCall("callConnected", hashMapOf("id" to id)), Answer())
        deliverBroadcasts()
    }

    private fun state(id: String): Int? = CallkitConnection.find(id)?.state

    @Test
    fun connectsTheCallOnlyOnceTelecomHasCreatedIt() {
        shadowOf(app).grantPermissions(Manifest.permission.MANAGE_OWN_CALLS, Manifest.permission.CALL_PHONE)
        val telecom = shadowOf(app.getSystemService(TelecomManager::class.java))
        telecom.setCallRequestMode(ShadowTelecomManager.CallRequestMode.MANUAL)
        FlutterCallkitIncomingPlugin.initSharedInstance(app, Messenger)
        val plugin = FlutterCallkitIncomingPlugin.getInstance()!!
        val bridge = TelecomCallBridge(app)

        // The plugin drops a connected signal that beats Telecom's connection,
        // and the call stays dialing once the connection does arrive.
        startCall(plugin, "early")
        markConnected(plugin, "early")
        telecom.allowOutgoingCall(telecom.allOutgoingCalls.last())
        assertEquals(Connection.STATE_DIALING, state("early"))

        // The bridge answers once Telecom has created the connection, and the
        // call goes active when connected after that.
        startCall(plugin, "waited")
        val waited = Answer()
        bridge.onMethodCall(MethodCall("awaitConnection", hashMapOf("callId" to "waited")), waited)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(500))
        assertFalse(waited.answered)

        telecom.allowOutgoingCall(telecom.allOutgoingCalls.last())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(100))
        assertEquals(true, waited.value)
        markConnected(plugin, "waited")
        assertEquals(Connection.STATE_ACTIVE, state("waited"))
    }

    @Test
    fun givesUpOnACallTelecomNeverCreates() {
        val bridge = TelecomCallBridge(app)
        val waited = Answer()
        bridge.onMethodCall(MethodCall("awaitConnection", hashMapOf("callId" to "missing")), waited)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(6))
        assertEquals(false, waited.value)

        // A call Telecom never hosted is the coordinator's own to route, and
        // the route request answers at once now the lookup has settled.
        val routed = Answer()
        bridge.onMethodCall(
            MethodCall("routeAudio", hashMapOf("callId" to "missing", "speaker" to true)),
            routed,
        )
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(true, routed.answered)
        assertNull(routed.value)
    }
}
