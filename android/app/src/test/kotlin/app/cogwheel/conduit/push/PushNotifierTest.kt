package app.cogwheel.conduit.push

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import app.cogwheel.conduit.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The Android side of posting, tapping and cancelling. Unit tests run without
 * the app's resources, so the channel is created here the way Dart does.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class PushNotifierTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val notifier = PushNotifier(context)

    @Before
    fun createChannel() {
        manager.createNotificationChannel(
            NotificationChannel(PushNotifier.CHANNEL_ID, "Nachrichten", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    private fun content(scope: String, dk: String) = PushNotificationContent(
        tag = PushPresenter.tag(scope, dk),
        group = "$scope|chat:c",
        title = "Trip ideas",
        body = "Three routes",
        subtitle = "Work",
        silent = false,
        publicTitle = "Conduit",
        publicBody = "New notification",
        timestampMillis = 1_760_000_000_000L,
    )

    @Test
    fun anExistingChannelIsLeftAlone() {
        PushNotifier.ensureChannel(context)
        assertEquals("Nachrichten", manager.getNotificationChannel(PushNotifier.CHANNEL_ID).name)
    }

    @Test
    fun aPostedPushCarriesItsTagGroupTextAndTap() {
        val payload = """{"v":1,"k":"reply","dk":"chat:c:m"}"""
        assertTrue(notifier.post("owui:a", payload, content("owui:a", "chat:c:m")))

        val posted = shadowOf(manager).allNotifications.single()
        val extras = posted.extras
        assertEquals("Trip ideas", extras.getString(Notification.EXTRA_TITLE))
        assertEquals("Three routes", extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals("Work", extras.getCharSequence(Notification.EXTRA_SUB_TEXT).toString())
        assertEquals("owui:a|chat:c", posted.group)
        assertEquals(PushNotifier.CHANNEL_ID, posted.channelId)
        assertEquals(NotificationCompat.CATEGORY_MESSAGE, posted.category)
        assertEquals("Conduit", posted.publicVersion.extras.getString(Notification.EXTRA_TITLE))
        assertNotNull(shadowOf(manager).getNotification("owui:a|chat:c:m", PushNotifier.NOTIFICATION_ID))

        val tapIntent = shadowOf(posted.contentIntent).savedIntent
        assertEquals(PushTaps.ACTION, tapIntent.action)
        assertEquals(MainActivity::class.java.name, tapIntent.component?.className)
        assertTrue(shadowOf(posted.contentIntent).isActivityIntent)
        assertTrue(shadowOf(posted.contentIntent).isImmutable)

        val tap = PushTaps.read(context, tapIntent)!!
        assertEquals("owui:a", tap.scope)
        assertEquals(payload, tap.payloadJson)
    }

    @Test
    fun aRepeatReplacesTheNotification() {
        notifier.post("owui:a", "{}", content("owui:a", "chat:c:m"))
        notifier.post("owui:a", "{}", content("owui:a", "chat:c:m"))
        assertEquals(1, shadowOf(manager).allNotifications.size)
    }

    @Test
    fun aForgedTapIsIgnored() {
        val forged = Intent(context, MainActivity::class.java).apply {
            action = PushTaps.ACTION
            putExtra(PushTaps.EXTRA_SCOPE, "owui:a")
            putExtra(PushTaps.EXTRA_PAYLOAD, "{}")
        }
        assertNull(PushTaps.read(context, forged))
    }

    private fun plain() = NotificationCompat.Builder(context, PushNotifier.CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_notify_chat)
        .build()

    @Test
    fun cancelScopeRemovesThatScopeOnly() {
        notifier.post("owui:a", "{}", content("owui:a", "chat:c:1"))
        notifier.post("owui:ab", "{}", content("owui:ab", "chat:c:2"))
        notifier.post("hermes:x", "{}", content("hermes:x", "hermes:s:t"))
        // The app's own, as flutter_local_notifications posts it: tagged with
        // its dedup key, under the id it claimed.
        manager.notify("owui:a|chat:c:3", 41, plain())
        // Untagged ones belong to other features, such as the voice call,
        // even under an id the app also claimed.
        manager.notify(41, plain())
        manager.notify(2001, plain())

        notifier.cancelScope("owui:a", listOf("owui:a|chat:c:3" to 41, "owui:ab|chat:c:2" to 7))

        val left = shadowOf(manager).activeNotifications.map { it.tag to it.id }
        assertEquals(
            setOf<Pair<String?, Int>>(
                "owui:ab|chat:c:2" to PushNotifier.NOTIFICATION_ID,
                "hermes:x|hermes:s:t" to PushNotifier.NOTIFICATION_ID,
                null to 41,
                null to 2001,
            ),
            left.toSet(),
        )
    }
}
