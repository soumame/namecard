package jp.namecard.nfctest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WriteProgressTest {
    @Test
    fun dataTransferMapsIntoOverallProgressRange() {
        val start = imageTransferProgress(0, 4_736)
        val middle = imageTransferProgress(2_368, 4_736)
        val end = imageTransferProgress(4_736, 4_736)

        assertEquals(0.15f, start, 0.0001f)
        assertTrue(middle > start)
        assertTrue(end > middle)
        assertEquals(0.72f, end, 0.0001f)
    }

    @Test
    fun progressStateClampsDisplayedPercentage() {
        assertEquals(0, WriteProgressState(title = "test", progress = -1f).percent)
        assertEquals(100, WriteProgressState(title = "test", progress = 2f).percent)
    }

    @Test
    fun dialogCanOnlyBeCancelledBeforeNfcCommunicationStarts() {
        val waiting = WriteProgressState(title = "test")
        val transferring = waiting.copy(canCancel = false)
        val complete = transferring.copy(outcome = WriteProgressOutcome.COMPLETE)

        assertTrue(waiting.canDismiss)
        assertEquals(false, transferring.canDismiss)
        assertTrue(complete.canDismiss)
    }

    @Test
    fun antennaCoordinatesKeepTheDeviceReportedVerticalDirection() {
        val guide = requireNotNull(
            nfcAntennaGuide(
                deviceWidthMm = 70,
                deviceHeightMm = 160,
                locationsMm = listOf(35 to 128),
            ),
        )

        assertEquals(0.5f, guide.points.single().xRatio, 0.0001f)
        assertEquals(0.8f, guide.points.single().yRatioFromTop, 0.0001f)
        assertTrue(guide.deviceReported)
    }

    @Test
    fun linkQualityUsesVoltageLatencyAndRecentErrors() {
        assertEquals(NfcLinkLevel.GOOD, nfcLinkStatus(3_250, 100, 0).level)
        assertEquals(NfcLinkLevel.FAIR, nfcLinkStatus(3_100, 100, 0).level)
        assertEquals(NfcLinkLevel.WEAK, nfcLinkStatus(3_250, 900, 0).level)
        assertEquals(NfcLinkLevel.WEAK, nfcLinkStatus(3_250, 100, 2).level)
    }
}
