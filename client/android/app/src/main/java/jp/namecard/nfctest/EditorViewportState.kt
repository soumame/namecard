package jp.namecard.nfctest

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

internal class EditorViewportState {
    var scale by mutableFloatStateOf(1f)
        private set

    var offsetX by mutableFloatStateOf(0f)
        private set

    var offsetY by mutableFloatStateOf(0f)
        private set

    var rotationDegrees by mutableFloatStateOf(0f)
        private set

    val isDefault: Boolean
        get() = abs(scale - 1f) < 0.001f &&
            abs(offsetX) < 0.5f &&
            abs(offsetY) < 0.5f &&
            abs(rotationDegrees) < 0.01f

    fun transform(
        panX: Float,
        panY: Float,
        zoomFactor: Float,
        rotationDeltaDegrees: Float,
        focusX: Float,
        focusY: Float,
        viewportWidth: Float,
        viewportHeight: Float,
    ) {
        if (viewportWidth <= 0f || viewportHeight <= 0f) return
        val safeZoom = zoomFactor.takeIf { it.isFinite() && it > 0f } ?: 1f
        val safeRotation = rotationDeltaDegrees.takeIf(Float::isFinite) ?: 0f
        val previousScale = scale
        val nextScale = (previousScale * safeZoom).coerceIn(MIN_SCALE, MAX_SCALE)
        val appliedZoom = nextScale / previousScale
        val viewportCenterX = viewportWidth / 2f
        val viewportCenterY = viewportHeight / 2f
        val paperCenterX = viewportCenterX + offsetX
        val paperCenterY = viewportCenterY + offsetY
        val focus = Offset(
            x = focusX.takeIf(Float::isFinite) ?: viewportCenterX,
            y = focusY.takeIf(Float::isFinite) ?: viewportCenterY,
        )
        val transformedCenter = rotateVector(
            x = paperCenterX - focus.x,
            y = paperCenterY - focus.y,
            degrees = safeRotation,
        ) * appliedZoom

        offsetX = focus.x + transformedCenter.x + panX - viewportCenterX
        offsetY = focus.y + transformedCenter.y + panY - viewportCenterY
        scale = nextScale
        rotationDegrees = normalizeDegrees(rotationDegrees + safeRotation)
    }

    fun screenToPaper(
        screenX: Float,
        screenY: Float,
        viewportWidth: Float,
        viewportHeight: Float,
    ): Offset {
        if (viewportWidth <= 0f || viewportHeight <= 0f) return Offset.Unspecified
        val baseScale = basePaperScale(viewportWidth, viewportHeight)
        if (baseScale <= 0f) return Offset.Unspecified
        val paperCenterX = viewportWidth / 2f + offsetX
        val paperCenterY = viewportHeight / 2f + offsetY
        val unrotated = rotateVector(
            x = screenX - paperCenterX,
            y = screenY - paperCenterY,
            degrees = -rotationDegrees,
        )
        return Offset(
            x = unrotated.x / (baseScale * scale) + EditorCanvasState.paperWidth / 2f,
            y = unrotated.y / (baseScale * scale) + EditorCanvasState.paperHeight / 2f,
        )
    }

    fun isPointOnPaper(
        screenX: Float,
        screenY: Float,
        viewportWidth: Float,
        viewportHeight: Float,
    ): Boolean {
        val paper = screenToPaper(screenX, screenY, viewportWidth, viewportHeight)
        return paper.x.isFinite() &&
            paper.y.isFinite() &&
            paper.x in 0f..EditorCanvasState.paperWidth &&
            paper.y in 0f..EditorCanvasState.paperHeight
    }

    fun screenDeltaToPaper(
        deltaX: Float,
        deltaY: Float,
        viewportWidth: Float,
        viewportHeight: Float,
    ): Offset {
        val pixelsPerPaperUnit = basePaperScale(viewportWidth, viewportHeight) * scale
        if (pixelsPerPaperUnit <= 0f) return Offset.Zero
        val unrotated = rotateVector(deltaX, deltaY, -rotationDegrees)
        return unrotated / pixelsPerPaperUnit
    }

    fun reset() {
        scale = 1f
        offsetX = 0f
        offsetY = 0f
        rotationDegrees = 0f
    }

    private fun basePaperScale(viewportWidth: Float, viewportHeight: Float): Float = min(
        viewportWidth / EditorCanvasState.paperWidth,
        viewportHeight / EditorCanvasState.paperHeight,
    )

    private fun rotateVector(x: Float, y: Float, degrees: Float): Offset {
        val radians = Math.toRadians(degrees.toDouble())
        val cosine = cos(radians).toFloat()
        val sine = sin(radians).toFloat()
        return Offset(
            x = x * cosine - y * sine,
            y = x * sine + y * cosine,
        )
    }

    private fun normalizeDegrees(value: Float): Float = ((value + 180f) % 360f + 360f) % 360f - 180f

    companion object {
        private const val MIN_SCALE = 0.5f
        private const val MAX_SCALE = 5f
    }
}
