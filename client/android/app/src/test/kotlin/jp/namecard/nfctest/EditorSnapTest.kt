package jp.namecard.nfctest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EditorSnapTest {
    @Test
    fun rotationSnapUsesInclusiveThresholdAndNormalizesBothDirections() {
        for ((angle, expected) in listOf(
            4f to 0f, 4.1f to 4.1f, 11f to 15f, -11f to -15f,
            179f to -180f, -179f to -180f, 374f to 15f,
        )) {
            assertEquals(expected, snapEditorRotationDegrees(angle), 0.0001f)
        }
    }

    @Test
    fun alignmentSnapChoosesClosestCandidateInsideThreshold() {
        val candidates = listOf(0f, 64f, 96f, 128f)

        assertEquals(2, closestEditorSnapIndex(93f, candidates, 4f))
        assertNull(closestEditorSnapIndex(90f, candidates, 4f))
    }

    @Test
    fun gridSnapUsesTheSameCenterOriginAsTheDrawnGrid() {
        assertEquals(148f, editorGridCoordinate(151f, 148f, 8f), 0.0001f)
        assertEquals(156f, editorGridCoordinate(153f, 148f, 8f), 0.0001f)
    }
}
