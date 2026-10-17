package app.loom.messenger

import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith

/** Run on a clean test device: notification channel choices belong to the user. */
@RunWith(AndroidJUnit4::class)
class CallNotificationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var activity: MainActivity
    private lateinit var manager: NotificationManager

    @Before
    fun setUp() {
        if (Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.executeShellCommand(
                "pm grant ${instrumentation.targetContext.packageName} android.permission.POST_NOTIFICATIONS",
            ).let { descriptor ->
                android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() }
            }
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity {
            activity = it
            manager = it.getSystemService(NotificationManager::class.java)
        }
    }

    @After
    fun tearDown() {
        if (::scenario.isInitialized) scenario.close()
    }

    private fun invoke(method: String, args: Map<String, Any?>? = null) {
        val bridge = MainActivity::class.java.getDeclaredMethod(
            "handleCallMethod", MethodCall::class.java, MethodChannel.Result::class.java,
        ).apply { isAccessible = true }
        var failure: String? = null
        instrumentation.runOnMainSync {
            bridge.invoke(activity, MethodCall(method, args), object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) { failure = code }
                override fun notImplemented() { failure = "not_implemented" }
            })
        }
        assertNull(failure)
    }

    private fun incoming(id: String, video: Boolean, expiry: Long) = mapOf<String, Any?>(
        "callId" to id, "callerName" to "Test caller", "callerAddress" to "",
        "video" to video, "expiresAt" to expiry,
    )

    @Test
    fun callVibrationPermissionIsGrantedInInstalledApp() {
        assertEquals(android.content.pm.PackageManager.PERMISSION_GRANTED,
            instrumentation.targetContext.checkSelfPermission(android.Manifest.permission.VIBRATE))
    }

    @Test
    fun incomingRingtoneChannelAndCancellation() {
        if (Build.VERSION.SDK_INT < 26) return
        for (video in listOf(false, true)) {
            val id = "native-notification-test-$video"
            try {
                invoke("showIncoming", incoming(id, video, System.currentTimeMillis() + 30_000L))
                val notification = manager.activeNotifications.single {
                    it.id == MainActivity.notificationId(id)
                }.notification
                val channel = manager.getNotificationChannel(notification.channelId)
                assertEquals(NotificationManager.IMPORTANCE_HIGH, channel.importance)
                assertEquals(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE), channel.sound)
                assertEquals(AudioAttributes.USAGE_NOTIFICATION_RINGTONE, channel.audioAttributes.usage)
                assertTrue(channel.shouldVibrate())
                assertTrue(notification.flags and Notification.FLAG_INSISTENT != 0)
                assertFalse(notification.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
                assertTrue(notification.timeoutAfter in 1L..30_000L)
                assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
                assertEquals("Incoming Loom call", notification.publicVersion.extras.getString(Notification.EXTRA_TITLE))
                if (Build.VERSION.SDK_INT >= 31) {
                    assertEquals("android.app.Notification\$CallStyle", notification.extras.getString(Notification.EXTRA_TEMPLATE))
                }
                // Peer-name hydration updates the same notification, without
                // creating another audible incoming alert.
                invoke("showIncoming", incoming(id, video, System.currentTimeMillis() + 20_000L))
                assertEquals(1, manager.activeNotifications.count { it.id == MainActivity.notificationId(id) })
                val updated = manager.activeNotifications.single { it.id == MainActivity.notificationId(id) }.notification
                assertTrue(updated.flags and Notification.FLAG_INSISTENT != 0)
                assertFalse(updated.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
            } finally {
                invoke("clearIncoming", mapOf("callId" to id))
            }
            assertFalse(manager.activeNotifications.any { it.id == MainActivity.notificationId(id) })
        }
    }

    @Test
    fun expiredOfferDoesNotRingAndPendingPermissionCannotResurrectIt() {
        val id = "native-expired-call-test"
        invoke("showIncoming", incoming(id, false, System.currentTimeMillis() - 1L))
        assertFalse(manager.activeNotifications.any { it.id == MainActivity.notificationId(id) })
        assertNull(MainActivity::class.java.getDeclaredField("pendingIncomingNotification")
            .apply { isAccessible = true }.get(activity))
    }

    @Test
    fun incomingNotificationExpiresWithoutDartTimer() {
        if (Build.VERSION.SDK_INT < 26) return
        val id = "native-expiring-call-test"
        try {
            invoke("showIncoming", incoming(id, false, System.currentTimeMillis() + 500L))
            Thread.sleep(1_500L)
            assertFalse(manager.activeNotifications.any { it.id == MainActivity.notificationId(id) })
        } finally {
            invoke("clearIncoming", mapOf("callId" to id))
        }
    }

    @Test
    fun notificationActionCancelsRingingBeforeDartUnlock() {
        val id = "native-call-action-test"
        try {
            invoke("showIncoming", incoming(id, true, System.currentTimeMillis() + 30_000L))
            val deliver = MainActivity::class.java.getDeclaredMethod("deliverAction", Intent::class.java)
                .apply { isAccessible = true }
            instrumentation.runOnMainSync {
                deliver.invoke(activity, Intent().apply {
                    putExtra(MainActivity.EXTRA_CALL_ACTION, "decline")
                    putExtra(MainActivity.EXTRA_CALL_ID, id)
                })
            }
            assertFalse(manager.activeNotifications.any { it.id == MainActivity.notificationId(id) })
        } finally {
            invoke("clearIncoming", mapOf("callId" to id))
        }
    }

    @Test
    fun ringbackIsIdempotentAndStoppedByCallTeardown() {
        val ringbackField = MainActivity::class.java.getDeclaredField("ringback")
            .apply { isAccessible = true }
        val toneField = CallRingback::class.java.getDeclaredField("tone")
            .apply { isAccessible = true }
        try {
            invoke("setRingback", mapOf("playing" to true))
            val owner = ringbackField.get(activity)
            val first = toneField.get(owner)
            assertNotNull(first)
            invoke("setRingback", mapOf("playing" to true))
            assertSame(first, toneField.get(owner))
            invoke("stopOngoing")
            assertNull(toneField.get(owner))
            invoke("setRingback", mapOf("playing" to false))
            assertNull(toneField.get(owner))
        } finally {
            invoke("setRingback", mapOf("playing" to false))
        }
    }
    @Test
    fun mediaPlaybackRestoresMusicRouteAndRefusesToChangeAnActiveCall() {
        val audio = activity.getSystemService(android.media.AudioManager::class.java)
        val ongoing = MainActivity::class.java.getDeclaredField("ongoingCall").apply { isAccessible = true }
        try {
            instrumentation.runOnMainSync { audio.mode = android.media.AudioManager.MODE_IN_COMMUNICATION }
            invoke("prepareMediaPlayback")
            assertEquals(android.media.AudioManager.MODE_NORMAL, audio.mode)
            assertEquals(android.media.AudioManager.STREAM_MUSIC, activity.volumeControlStream)
            var error: String? = null
            instrumentation.runOnMainSync {
                ongoing.setBoolean(activity, true)
                audio.mode = android.media.AudioManager.MODE_IN_COMMUNICATION
                val method = MainActivity::class.java.getDeclaredMethod("handleCallMethod", MethodCall::class.java, MethodChannel.Result::class.java).apply { isAccessible = true }
                method.invoke(activity, MethodCall("prepareMediaPlayback", null), object : MethodChannel.Result {
                    override fun success(result: Any?) { fail("Active call route was reset") }
                    override fun error(code: String, message: String?, details: Any?) { error = code }
                    override fun notImplemented() { fail("Media route missing") }
                })
            }
            assertEquals("call_active", error)
            assertEquals(android.media.AudioManager.MODE_IN_COMMUNICATION, audio.mode)
        } finally {
            instrumentation.runOnMainSync { ongoing.setBoolean(activity, false); audio.mode = android.media.AudioManager.MODE_NORMAL }
        }
    }

    @Test
    fun receivedMessageUsesNotificationSoundAndNeverExposesPlaintext() {
        val bridge = MainActivity::class.java.getDeclaredField("messageNotifications").apply { isAccessible = true }.get(activity) as LoomMessageNotifications
        val id = "native-message-notification-test"
        val result = object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(code: String, message: String?, details: Any?) { fail(code) }
            override fun notImplemented() { fail("Notification bridge missing") }
        }
        try {
            instrumentation.runOnMainSync {
                bridge.handle(MethodCall("showMessage", mapOf("conversationId" to id, "title" to "Test friend", "body" to "secret plaintext")), result)
            }
            val notification = manager.activeNotifications.single { it.tag == "loom.message.$id" }.notification
            assertEquals("New encrypted message", notification.extras.getString(Notification.EXTRA_TEXT))
            assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
            assertEquals("Loom", notification.publicVersion.extras.getString(Notification.EXTRA_TITLE))
            if (Build.VERSION.SDK_INT >= 26) {
                val channel = manager.getNotificationChannel(notification.channelId)
                assertEquals(NotificationManager.IMPORTANCE_HIGH, channel.importance)
                assertEquals(android.provider.Settings.System.DEFAULT_NOTIFICATION_URI, channel.sound)
                assertEquals(AudioAttributes.USAGE_NOTIFICATION, channel.audioAttributes.usage)
            }
        } finally {
            instrumentation.runOnMainSync { bridge.handle(MethodCall("clearMessage", id), result) }
        }
        assertFalse(manager.activeNotifications.any { it.tag == "loom.message.$id" })
    }

}
