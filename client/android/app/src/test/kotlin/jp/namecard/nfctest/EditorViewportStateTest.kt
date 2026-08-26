package jp.namecard.nfctest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorViewportStateTest {
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
