package app.cogwheel.conduit

import android.os.Looper
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class UserCertificatesBridgeTest {
    private val syntheticPem =
        "-----BEGIN CERTIFICATE-----\nc3ludGhldGlj\n-----END CERTIFICATE-----\n"

    @Test
    fun theStoreIsReadOnTheExecutorAndTheReplyComesBackOnTheMainThread() {
        val queued = mutableListOf<Runnable>()
        var readOnMainThread: Boolean? = null
        val bridge = UserCertificatesBridge(
            executor = Executor { queued.add(it) },
            readCertificates = {
                readOnMainThread = Looper.myLooper() == Looper.getMainLooper()
                listOf(syntheticPem)
            },
        )
        var reply: Result<List<String>>? = null
        var repliedOnMainThread: Boolean? = null

        bridge.userCaCertificates { result ->
            reply = result
            repliedOnMainThread = Looper.myLooper() == Looper.getMainLooper()
        }
        assertEquals(null, readOnMainThread)
        assertEquals(1, queued.size)

        val worker = Thread(queued.single())
        worker.start()
        worker.join()
        shadowOf(Looper.getMainLooper()).idle()

        assertFalse(readOnMainThread!!)
        assertTrue(repliedOnMainThread!!)
        assertEquals(listOf(syntheticPem), reply!!.getOrThrow())
    }

    @Test
    fun aFailedReadRepliesWithTheFailure() {
        val bridge = UserCertificatesBridge(
            executor = Executor { it.run() },
            readCertificates = { throw IllegalStateException("store unavailable") },
        )
        var reply: Result<List<String>>? = null

        bridge.userCaCertificates { reply = it }
        shadowOf(Looper.getMainLooper()).idle()

        assertTrue(reply!!.isFailure)
    }
}
