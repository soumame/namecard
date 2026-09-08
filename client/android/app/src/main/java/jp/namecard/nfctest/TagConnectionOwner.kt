package jp.namecard.nfctest

import java.io.Closeable
import kotlinx.coroutines.CancellationException

/** One owner per coroutine; cancellation also unblocks Android's blocking NFC I/O. */
internal class TagConnectionOwner {
    private var active: Closeable? = null
    private var cancelled = false

    fun attach(connection: Closeable) {
        val rejected = synchronized(this) {
            if (cancelled) true else {
                check(active == null) { "Previous NFC technology is still connected" }
                active = connection
                false
            }
        }
        if (rejected) {
            runCatching { connection.close() }
            throw CancellationException("NFC transfer was cancelled")
        }
    }

    fun release(connection: Closeable) {
        val owned = synchronized(this) {
            if (active === connection) { active = null; true } else false
        }
        if (owned) runCatching { connection.close() }
    }

    fun cancel(close: (Closeable) -> Unit = { runCatching { it.close() } }) {
        val connection = synchronized(this) {
            if (cancelled) return
            cancelled = true
            // Keep ownership until the worker exits. connect() can race this
            // close, so release() closes once more after the worker unwinds.
            active
        }
        connection?.let(close)
    }
}
