package jp.namecard.nfctest

import kotlin.math.abs
import kotlin.math.round

internal fun normalizeEditorRotationDegrees(value: Float): Float =
    ((value + 180f) % 360f + 360f) % 360f - 180f

/** Shared 15-degree snapping for object and viewport rotation. */
internal fun snapEditorRotationDegrees(value: Float): Float {
    val angle = normalizeEditorRotationDegrees(value)
    val nearest = round(angle / 15f) * 15f
    return if (abs(angle - nearest) <= 4f) normalizeEditorRotationDegrees(nearest) else angle
}
