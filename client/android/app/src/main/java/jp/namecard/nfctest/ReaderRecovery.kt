package jp.namecard.nfctest

/** Main-thread owner of Reader Mode callbacks and one transfer at a time. */
internal class ReaderRecovery(
    private val start: (Long) -> Unit,
    private val stop: () -> Unit,
    private val schedule: (Long, () -> Unit) -> Unit,
) {
    private var foreground = false
    private var generation = 0L
    private var nextTicket = 0L
    private var activeTicket: Long? = null
    private var refreshPending = false
    private var restartPending = false
    private var recovering = false
    val isBusy: Boolean get() = activeTicket != null

    fun resume() {
        foreground = true
        refresh()
    }

    fun pause() {
        foreground = false
        generation++
        recovering = false
        refreshPending = true
        stop()
    }

    fun refresh() {
        if (!foreground) return
        if (isBusy || recovering) { refreshPending = true; return }
        refreshPending = false
        if (restartPending) {
            restartPending = false
            recovering = true
            val token = ++generation
            stop()
            schedule(300) {
                if (!foreground || generation != token || isBusy) return@schedule
                recovering = false
                // This reset also covers requests made during the interval.
                restartPending = false
                refresh()
            }
            return
        }
        start(++generation)
    }

    /** A new user operation must discard any previously discovered tag, even
     * after a successful transfer or a detection before pressing Write. */
    fun requestScan() {
        restartPending = true
        refresh()
    }

    fun accepts(token: Long): Boolean = foreground && !recovering && token == generation

    fun claim(token: Long): Long? {
        if (!accepts(token) || isBusy) return null
        return (++nextTicket).also { activeTicket = it }
    }

    fun finish(ticket: Long, restart: Boolean) {
        if (activeTicket != ticket) return
        activeTicket = null
        restartPending = restartPending || restart
        if (!foreground) return
        if (refreshPending || restartPending) refresh()
    }
}
