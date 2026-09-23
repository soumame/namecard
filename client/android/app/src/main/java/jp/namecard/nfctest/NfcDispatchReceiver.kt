package jp.namecard.nfctest

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/** Absorb normal tag dispatch while Reader Mode is being restarted. */
class NfcDispatchReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // The scheduled Reader Mode restart already handles rediscovery.
        // This tag can be stale: do not connect, launch an Activity, or reset
        // Reader Mode in response to a delayed foreground-dispatch notification.
        Log.d("NamecardNfc", "Consumed fallback NFC notification without restarting Reader Mode")
    }

    companion object {
        fun pendingIntent(context: Context): PendingIntent {
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            return PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, NfcDispatchReceiver::class.java),
                flags,
            )
        }
    }
}
