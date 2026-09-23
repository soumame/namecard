package jp.namecard.nfctest

import android.app.Activity
import android.app.Application
import android.app.PendingIntent
import android.content.Intent
import android.nfc.NfcAdapter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.test.InstrumentationTestCase
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@Suppress("DEPRECATION")
class NfcDispatchTest : InstrumentationTestCase() {
    private class Lifecycle : Application.ActivityLifecycleCallbacks {
        val pauses = AtomicInteger()
        val resumes = AtomicInteger()
        val firstResume = CountDownLatch(1)
        val nextPause = CountDownLatch(1)
        val nextResume = CountDownLatch(1)
        override fun onActivityPaused(activity: Activity) {
            if (activity is MainActivity) { pauses.incrementAndGet(); nextPause.countDown() }
        }
        override fun onActivityResumed(activity: Activity) {
            if (activity is MainActivity) {
                if (resumes.incrementAndGet() > 1) nextResume.countDown()
                firstResume.countDown()
            }
        }
        override fun onActivityCreated(activity: Activity, state: Bundle?) {}
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    private fun withForegroundActivity(test: (MainActivity, Lifecycle) -> Unit) {
        val context = instrumentation.targetContext
        val app = context.applicationContext as Application
        val lifecycle = Lifecycle()
        instrumentation.runOnMainSync { app.registerActivityLifecycleCallbacks(lifecycle) }
        var activity: MainActivity? = null
        try {
            activity = instrumentation.startActivitySync(
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as MainActivity
            assertTrue("Activity did not resume; unlock the test device", lifecycle.firstResume.await(5, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            test(activity, lifecycle)
        } finally {
            instrumentation.runOnMainSync {
                app.unregisterActivityLifecycleCallbacks(lifecycle)
                activity?.finish()
            }
            instrumentation.waitForIdleSync()
        }
    }

    fun testLegacyActivityDeliveryPausesTheNfcOwner() = withForegroundActivity { activity, lifecycle ->
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val legacy = PendingIntent.getActivity(
            activity, 91,
            Intent(activity, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags,
        )
        try {
            legacy.send(activity, 0, Intent(NfcAdapter.ACTION_NDEF_DISCOVERED))
            assertTrue("Legacy NFC dispatch should reproduce onPause", lifecycle.nextPause.await(5, TimeUnit.SECONDS))
            assertTrue("Activity should resume after the intent", lifecycle.nextResume.await(5, TimeUnit.SECONDS))
        } finally {
            legacy.cancel()
        }
    }

    fun testFallbackNotificationsDoNotPauseOrResumeTheNfcOwner() = withForegroundActivity { activity, lifecycle ->
        val pending = NfcDispatchReceiver.pendingIntent(activity)
        assertFalse("Fallback must not launch the NFC Activity", pending.isActivity)
        val pausesBefore = lifecycle.pauses.get()
        val resumesBefore = lifecycle.resumes.get()
        val delivered = CountDownLatch(4)
        for (action in listOf(
            NfcAdapter.ACTION_NDEF_DISCOVERED,
            NfcAdapter.ACTION_TECH_DISCOVERED,
            NfcAdapter.ACTION_TAG_DISCOVERED,
            NfcAdapter.ACTION_NDEF_DISCOVERED,
        )) {
            pending.send(
                activity, 0, Intent(action),
                { _, _, _, _, _ -> delivered.countDown() }, Handler(Looper.getMainLooper()),
            )
        }
        assertTrue("Fallback broadcasts were not delivered", delivered.await(5, TimeUnit.SECONDS))
        instrumentation.waitForIdleSync()
        assertEquals(pausesBefore, lifecycle.pauses.get())
        assertEquals(resumesBefore, lifecycle.resumes.get())
        assertFalse(activity.isFinishing)
    }
}
