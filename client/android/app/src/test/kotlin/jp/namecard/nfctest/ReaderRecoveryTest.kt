package jp.namecard.nfctest

import java.io.Closeable
import kotlinx.coroutines.CancellationException
import org.junit.Assert.*
import org.junit.Test

class ReaderRecoveryTest {
    private class Fixture {
        val events = mutableListOf<String>()
        val timers = ArrayDeque<() -> Unit>()
        var token = 0L
        val reader = ReaderRecovery(
            start = { token = it; events += "start" },
            stop = { events += "stop" },
            schedule = { milliseconds, action ->
                assertEquals(300L, milliseconds)
                timers.addLast(action)
            },
        )
    }

    @Test fun fourDisconnectsReleaseOwnershipAndReplaceOldCallbacks() {
        val f = Fixture()
        f.reader.resume()
        repeat(4) {
            val old = f.token
            val ticket = requireNotNull(f.reader.claim(old))
            assertNull(f.reader.claim(old))
            f.reader.finish(ticket, restart = true)
            assertFalse(f.reader.isBusy)
            assertNull(f.reader.claim(old))
            assertEquals("stop", f.events.last())
            f.timers.removeFirst()()
            assertFalse(f.reader.accepts(old))
            assertTrue(f.reader.accepts(f.token))
        }
        assertEquals(5, f.events.count { it == "start" })
    }

    @Test fun pauseResumeWaitsForCancelledWorkerBeforeAcceptingATag() {
        val f = Fixture()
        f.reader.resume()
        val old = f.token
        val ticket = requireNotNull(f.reader.claim(old))
        f.reader.pause()
        f.reader.resume()
        assertTrue(f.reader.isBusy)
        assertFalse(f.reader.accepts(old))
        assertEquals(1, f.events.count { it == "start" })
        f.reader.finish(ticket, restart = true)
        f.timers.removeFirst()()
        val next = requireNotNull(f.reader.claim(f.token))
        f.reader.finish(ticket, restart = true) // Late cleanup cannot release the new owner.
        assertTrue(f.reader.isBusy)
        f.reader.finish(next, restart = false)
        assertFalse(f.reader.isBusy)
    }

    @Test fun oldRestartTimerCannotStartReaderInBackgroundOrReplaceNewSession() {
        val f = Fixture()
        f.reader.resume()
        f.reader.finish(requireNotNull(f.reader.claim(f.token)), restart = true)
        f.reader.pause()
        f.timers.removeFirst()()
        assertEquals(1, f.events.count { it == "start" })
        f.reader.resume()
        val ticket = requireNotNull(f.reader.claim(f.token))
        f.reader.finish(ticket, restart = true)
        val staleTimer = f.timers.removeFirst()
        f.reader.pause()
        f.reader.resume()
        val current = f.token
        staleTimer()
        assertEquals(current, f.token)
        assertTrue(f.reader.accepts(current))
    }

    @Test fun successfulTransferKeepsFieldAndDefersReaderConfigurationUntilFinished() {
        val f = Fixture()
        f.reader.resume()
        val ticket = requireNotNull(f.reader.claim(f.token))
        f.reader.refresh() // e.g. URL finished; do not reset during I/O.
        assertEquals(listOf("start"), f.events)
        f.reader.finish(ticket, restart = false)
        assertEquals(listOf("start", "start"), f.events)
        assertTrue(f.timers.isEmpty())
    }

    @Test fun nextWriteAfterSuccessRediscoversWithoutWaitingForPresenceCheck() {
        val f = Fixture()
        f.reader.resume()
        repeat(3) {
            f.reader.requestScan()
            f.timers.removeFirst()()
            val token = f.token
            val ticket = requireNotNull(f.reader.claim(token))
            val stops = f.events.count { it == "stop" }
            f.reader.finish(ticket, restart = false)
            // Completion itself must not cut power to the panel.
            assertEquals(stops, f.events.count { it == "stop" })
            assertFalse(f.reader.isBusy)
            // The card can remain detected; the next button must force a reset.
        }
        assertEquals(3, f.events.count { it == "stop" })
        assertEquals(4, f.events.count { it == "start" })
    }

    @Test fun writeAfterAnIdleDetectionRejectsThatOldCallback() {
        val f = Fixture()
        f.reader.resume()
        val idleToken = f.token // A card was detected before selecting an action.
        f.reader.requestScan()
        assertFalse(f.reader.accepts(idleToken))
        assertNull(f.reader.claim(idleToken))
        f.timers.removeFirst()()
        assertFalse(f.reader.accepts(idleToken))
        assertNotNull(f.reader.claim(f.token))
    }

    @Test fun newScanWaitsForWorkerAndUsesLatestModeOnlyOnce() {
        val f = Fixture()
        f.reader.resume()
        val old = f.token
        val ticket = requireNotNull(f.reader.claim(old))
        f.reader.requestScan()
        assertTrue(f.timers.isEmpty()) // No RF interruption during active I/O/quiet.
        f.reader.finish(ticket, restart = false)
        assertEquals(1, f.timers.size)
        f.reader.requestScan() // e.g. switch URL -> image during reset.
        f.reader.refresh() // A normal-dispatch intent must not replace the timer.
        assertEquals(1, f.timers.size)
        f.timers.removeFirst()()
        assertEquals(listOf("start", "stop", "start"), f.events)
        assertFalse(f.reader.accepts(old))
        assertTrue(f.timers.isEmpty())
    }

    @Test fun imageUrlImageRequestsUseFreshDetectionAndCurrentConfiguration() {
        val f = Fixture()
        var selectedMode = "image"
        val enabledModes = mutableListOf<String>()
        val reader = ReaderRecovery(
            start = { f.token = it; enabledModes += selectedMode },
            stop = {},
            schedule = { _, action -> f.timers.addLast(action) },
        )
        reader.resume()
        for (mode in listOf("image", "url", "image")) {
            val stale = f.token
            selectedMode = mode
            reader.requestScan()
            f.timers.removeFirst()()
            assertNull(reader.claim(stale))
            reader.finish(requireNotNull(reader.claim(f.token)), restart = false)
        }
        assertEquals(listOf("image", "image", "url", "image"), enabledModes)
    }

    @Test fun cancellationClosesCurrentTechnologyAndRejectsLaterConnection() {
        for (name in listOf("NfcV", "Ndef", "NdefFormatable")) {
            val owner = TagConnectionOwner()
            val closed = mutableListOf<String>()
            val first = Closeable { closed += "old" }
            val current = Closeable { closed += name }
            owner.attach(first)
            owner.release(first)
            owner.attach(current)
            owner.release(first)
            assertEquals(listOf("old"), closed)
            owner.cancel()
            assertEquals(listOf("old", name), closed)
            owner.release(current)
            owner.cancel()
            assertEquals(listOf("old", name, name), closed)
            try {
                owner.attach(Closeable { closed += "late" })
                fail("Cancelled owner admitted a connection")
            } catch (_: CancellationException) { }
            assertEquals(listOf("old", name, name, "late"), closed)
        }
    }

    @Test fun cancellationRacingConnectStillClosesAfterWorkerExits() {
        val owner = TagConnectionOwner()
        var connected = false
        val connection = Closeable { connected = false }
        owner.attach(connection)
        owner.cancel()
        connected = true // Native connect finishes after the cancellation close.
        owner.release(connection)
        assertFalse(connected)
    }
}
