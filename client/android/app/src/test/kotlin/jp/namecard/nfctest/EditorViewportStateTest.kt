package jp.namecard.nfctest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorViewportStateTest {
    @Test
    fun rotationSnapIsOffUntilEnabled() {
        val state = EditorViewportState()
        assertFalse(state.rotationSnapEnabled)
        rotate(state, 13f)
        assertEquals(13f, state.rotationDegrees, 0.0001f)
        state.toggleRotationSnap()
        assertEquals(13f, state.rotationDegrees, 0.0001f)
        rotate(state, 0f)
        assertEquals(13f, state.rotationDegrees, 0.0001f)
        rotate(state, 1f)
        assertEquals(15f, state.rotationDegrees, 0.0001f)
    }

    @Test
    fun snapUsesFifteenDegreeStepsAndFourDegreeThresholdInBothDirections() {
        for ((input, expected) in listOf(11f to 15f, 10f to 10f, -11f to -15f,
            -10f to -10f, 86f to 90f, 176f to -180f, -176f to -180f)) {
            val state = EditorViewportState()
            state.toggleRotationSnap()
            rotate(state, input)
            assertEquals("angle $input", expected, state.rotationDegrees, 0.0001f)
        }
    }

    @Test
    fun smallDeltasAccumulateAndEscapeSnap() {
        val state = EditorViewportState()
        state.toggleRotationSnap()
        state.beginTransform()
        repeat(4) { rotate(state, 1f) }
        assertEquals(0f, state.rotationDegrees, 0.0001f)
        rotate(state, 1f)
        assertEquals(5f, state.rotationDegrees, 0.0001f)
        repeat(6) { rotate(state, 1f) }
        assertEquals(15f, state.rotationDegrees, 0.0001f)
        state.endTransform()
        state.beginTransform()
        rotate(state, -1f)
        assertEquals(15f, state.rotationDegrees, 0.0001f)
    }

    @Test
    fun snappedZoomRotationAndPanKeepTheGestureAnchor() {
        val state = EditorViewportState()
        state.toggleRotationSnap()
        val before = state.screenToPaper(100f, 80f, 400f, 400f)
        state.transform(
            panX = 12f,
            panY = -7f,
            zoomFactor = 1.7f,
            rotationDeltaDegrees = 13f,
            focusX = 100f,
            focusY = 80f,
            viewportWidth = 400f,
            viewportHeight = 400f,
        )
        val after = state.screenToPaper(112f, 73f, 400f, 400f)
        assertEquals(15f, state.rotationDegrees, 0.0001f)
        assertEquals(before.x, after.x, 0.0001f)
        assertEquals(before.y, after.y, 0.0001f)
    }

    @Test
    fun disablingSnapAndResettingClearTheRawAngle() {
        val state = EditorViewportState()
        state.toggleRotationSnap()
        rotate(state, 13f)
        state.toggleRotationSnap()
        rotate(state, 1f)
        assertEquals(16f, state.rotationDegrees, 0.0001f)
        state.toggleRotationSnap()
        state.reset()
        assertTrue(state.rotationSnapEnabled)
        assertTrue(state.isDefault)
        rotate(state, 5f)
        assertEquals(5f, state.rotationDegrees, 0.0001f)
    }

    @Test
    fun rotationWrapRetainsAnchorAtTheHalfTurn() {
        val state = EditorViewportState()
        rotate(state, 173f)
        state.toggleRotationSnap()
        val before = state.screenToPaper(50f, 60f, 400f, 400f)
        state.transform(0f, 0f, 1f, 4f, 50f, 60f, 400f, 400f)
        val after = state.screenToPaper(50f, 60f, 400f, 400f)
        assertEquals(-180f, state.rotationDegrees, 0.0001f)
        assertEquals(before.x, after.x, 0.0001f)
        assertEquals(before.y, after.y, 0.0001f)
    }

    private fun rotate(state: EditorViewportState, delta: Float) {
        state.transform(0f, 0f, 1f, delta, 200f, 200f, 400f, 400f)
    }

    @Test
    fun panChangesViewportAndResetRestoresDefault() {
        val state = EditorViewportState()

        state.transform(
            panX = 20f,
            panY = -10f,
            zoomFactor = 1f,
            rotationDeltaDegrees = 30f,
            focusX = 200f,
            focusY = 200f,
            viewportWidth = 400f,
            viewportHeight = 400f,
        )

        assertFalse(state.isDefault)
        assertEquals(20f, state.offsetX, 0.0001f)
        assertEquals(-10f, state.offsetY, 0.0001f)
        assertEquals(30f, state.rotationDegrees, 0.0001f)
        state.reset()
        assertTrue(state.isDefault)
    }

    @Test
    fun zoomKeepsTheGestureFocusAtTheSamePaperCoordinate() {
        val state = EditorViewportState()
        val before = state.screenToPaper(100f, 100f, 400f, 400f)

        state.transform(
            panX = 0f,
            panY = 0f,
            zoomFactor = 2f,
            rotationDeltaDegrees = 35f,
            focusX = 100f,
            focusY = 100f,
            viewportWidth = 400f,
            viewportHeight = 400f,
        )
        val after = state.screenToPaper(100f, 100f, 400f, 400f)

        assertEquals(before.x, after.x, 0.0001f)
        assertEquals(before.y, after.y, 0.0001f)
    }

    @Test
    fun paperHitTestSeparatesWhitePaperFromGrayViewport() {
        val state = EditorViewportState()

        assertTrue(state.isPointOnPaper(200f, 200f, 400f, 400f))
        assertFalse(state.isPointOnPaper(200f, 50f, 400f, 400f))
    }

    @Test
    fun screenMovementIsConvertedThroughPaperRotation() {
        val state = EditorViewportState()
        state.transform(
            panX = 0f,
            panY = 0f,
            zoomFactor = 1f,
            rotationDeltaDegrees = 90f,
            focusX = 200f,
            focusY = 200f,
            viewportWidth = 400f,
            viewportHeight = 400f,
        )

        val delta = state.screenDeltaToPaper(0f, 10f, 400f, 400f)

        assertTrue(delta.x > 0f)
        assertEquals(0f, delta.y, 0.0001f)
    }
}
