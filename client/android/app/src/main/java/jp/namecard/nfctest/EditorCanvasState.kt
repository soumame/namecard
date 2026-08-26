package jp.namecard.nfctest

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.ArrayDeque
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.round
import kotlin.math.sin

internal fun closestEditorSnapIndex(
    value: Float,
    candidates: List<Float>,
    threshold: Float,
): Int? = candidates.indices
    .map { index -> index to abs(value - candidates[index]) }
    .filter { (_, distance) -> distance <= threshold }
    .minByOrNull { (_, distance) -> distance }
    ?.first

internal fun editorGridCoordinate(value: Float, origin: Float, spacing: Float): Float =
    origin + round((value - origin) / spacing) * spacing

internal class EditorCanvasState {
    private val layers = mutableListOf<Layer>()
    private val ownedBitmaps = mutableSetOf<Bitmap>()
    private val undoStack = ArrayDeque<Snapshot>()
    private val redoStack = ArrayDeque<Snapshot>()
    private val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
        colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(0f) })
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
    }
    private val backgroundPaint = Paint().apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(72, 73, 69, 79)
        strokeWidth = 0.45f
    }
    private val gridCenterPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(128, 103, 80, 164)
        strokeWidth = 0.8f
    }
    private val selectionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(21, 94, 239)
        style = Paint.Style.STROKE
        strokeWidth = 1.5f
        pathEffect = DashPathEffect(floatArrayOf(5f, 3f), 0f)
    }
    private val snapGuidePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(255, 193, 7)
        strokeWidth = 1.2f
    }
    private var selectedIndex = -1
    private var pendingTransformSnapshot: Snapshot? = null
    private var transformHistoryRecorded = false
    private var rawTransformCenterX: Float? = null
    private var rawTransformCenterY: Float? = null
    private var activeSnapGuideX: Float? = null
    private var activeSnapGuideY: Float? = null

    var revision by mutableIntStateOf(0)
        private set

    var canUndo by mutableStateOf(false)
        private set

    var canRedo by mutableStateOf(false)
        private set

    var gridEnabled by mutableStateOf(false)
        private set

    var snapEnabled by mutableStateOf(false)
        private set

    val hasSelection: Boolean get() = selectedLayer() != null

    fun addText(value: String) {
        val text = value.trim()
        if (text.isEmpty()) return
        recordChange()
        layers += Layer.text(text, paperWidth / 2f, paperHeight / 2f)
        selectedIndex = layers.lastIndex
        changed()
    }

    fun addImage(bitmap: Bitmap) {
        val fit = minOf(
            1f,
            (paperWidth * 0.55f) / bitmap.width,
            (paperHeight * 0.70f) / bitmap.height,
        )
        recordChange()
        ownedBitmaps += bitmap
        layers += Layer.image(
            bitmap,
            paperWidth / 2f,
            paperHeight / 2f,
            bitmap.width * fit,
            bitmap.height * fit,
        )
        selectedIndex = layers.lastIndex
        changed()
    }

    fun replaceWithImage(bitmap: Bitmap) {
        recordChange()
        ownedBitmaps += bitmap
        layers.clear()
        layers += Layer.image(
            bitmap = bitmap,
            x = paperWidth / 2f,
            y = paperHeight / 2f,
            width = paperWidth,
            height = paperHeight,
        )
        selectedIndex = 0
        changed()
    }

    fun toggleGrid() {
        gridEnabled = !gridEnabled
        changed()
    }

    fun toggleSnap() {
        snapEnabled = !snapEnabled
        clearSnapGuides()
        changed()
    }

    fun selectAt(x: Float, y: Float) {
        val previousIndex = selectedIndex
        selectedIndex = -1
        for (index in layers.indices.reversed()) {
            if (layers[index].contains(x, y, textPaint)) {
                selectedIndex = index
                break
            }
        }
        if (previousIndex != selectedIndex) changed()
    }

    fun beginTransform() {
        val selected = selectedLayer()
        pendingTransformSnapshot = selected?.let { snapshot() }
        transformHistoryRecorded = false
        rawTransformCenterX = selected?.centerX
        rawTransformCenterY = selected?.centerY
        clearSnapGuides()
    }

    fun transformSelection(
        deltaX: Float,
        deltaY: Float,
        scaleFactor: Float,
        rotationDegrees: Float,
    ) {
        val selected = selectedLayer() ?: return
        val hasMovement = deltaX != 0f || deltaY != 0f
        val hasScale = scaleFactor !in 0.999f..1.001f
        val hasRotation = rotationDegrees !in -0.01f..0.01f
        if (!hasMovement && !hasScale && !hasRotation) return
        recordPendingTransform()
        val rawX = ((rawTransformCenterX ?: selected.centerX) + deltaX)
            .coerceIn(0f, paperWidth)
        val rawY = ((rawTransformCenterY ?: selected.centerY) + deltaY)
            .coerceIn(0f, paperHeight)
        rawTransformCenterX = rawX
        rawTransformCenterY = rawY
        if (hasScale) selected.resize(scaleFactor)
        if (hasRotation) selected.rotate(rotationDegrees)
        val snapped = if (snapEnabled) {
            snappedPosition(selected, rawX, rawY)
        } else {
            SnappedPosition(rawX, rawY)
        }
        selected.centerX = snapped.centerX.coerceIn(0f, paperWidth)
        selected.centerY = snapped.centerY.coerceIn(0f, paperHeight)
        activeSnapGuideX = snapped.guideX
        activeSnapGuideY = snapped.guideY
        changed()
    }

    fun endTransform() {
        pendingTransformSnapshot = null
        transformHistoryRecorded = false
        rawTransformCenterX = null
        rawTransformCenterY = null
        val hadGuides = activeSnapGuideX != null || activeSnapGuideY != null
        clearSnapGuides()
        if (hadGuides) changed()
    }

    fun moveSelection(deltaX: Float, deltaY: Float) {
        val selected = selectedLayer() ?: return
        recordChange()
        selected.centerX = (selected.centerX + deltaX).coerceIn(0f, paperWidth)
        selected.centerY = (selected.centerY + deltaY).coerceIn(0f, paperHeight)
        changed()
    }

    fun resizeSelection(factor: Float) {
        val selected = selectedLayer() ?: return
        recordChange()
        selected.resize(factor)
        changed()
    }

    fun deleteSelection() {
        if (selectedIndex !in layers.indices) return
        recordChange()
        layers.removeAt(selectedIndex)
        selectedIndex = if (layers.isEmpty()) -1 else minOf(selectedIndex, layers.lastIndex)
        changed()
    }

    fun moveSelectionForward() {
        if (selectedIndex !in 0 until layers.lastIndex) return
        recordChange()
        val selected = layers.removeAt(selectedIndex)
        selectedIndex += 1
        layers.add(selectedIndex, selected)
        changed()
    }

    fun moveSelectionBackward() {
        if (selectedIndex !in 1..layers.lastIndex) return
        recordChange()
        val selected = layers.removeAt(selectedIndex)
        selectedIndex -= 1
        layers.add(selectedIndex, selected)
        changed()
    }

    fun clearAll() {
        if (layers.isEmpty()) return
        recordChange()
        layers.clear()
        selectedIndex = -1
        changed()
    }

    fun undo() {
        if (undoStack.isEmpty()) return
        redoStack.addLast(snapshot())
        restore(undoStack.removeLast())
    }

    fun redo() {
        if (redoStack.isEmpty()) return
        undoStack.addLast(snapshot())
        if (undoStack.size > MAX_HISTORY) undoStack.removeFirst()
        restore(redoStack.removeLast())
    }

    fun draw(canvas: Canvas, showSelection: Boolean, showGrid: Boolean = false) {
        canvas.drawRect(0f, 0f, paperWidth, paperHeight, backgroundPaint)
        if (showGrid) drawGrid(canvas)
        layers.forEach { layer ->
            canvas.save()
            canvas.rotate(layer.rotationDegrees, layer.centerX, layer.centerY)
            drawLayer(canvas, layer)
            canvas.restore()
        }
        if (showSelection) {
            drawSnapGuides(canvas)
            selectedLayer()?.let { selected ->
                canvas.save()
                canvas.rotate(
                    selected.rotationDegrees,
                    selected.centerX,
                    selected.centerY,
                )
                canvas.drawRect(selected.bounds(textPaint), selectionPaint)
                canvas.restore()
            }
        }
    }

    fun renderNativeImage(format: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(
            NativeImageFormat.WIDTH,
            NativeImageFormat.HEIGHT,
            Bitmap.Config.ARGB_8888,
        )
        return try {
            draw(Canvas(bitmap), showSelection = false)
            val pixels = IntArray(NativeImageFormat.WIDTH * NativeImageFormat.HEIGHT)
            bitmap.getPixels(
                pixels,
                0,
                NativeImageFormat.WIDTH,
                0,
                0,
                NativeImageFormat.WIDTH,
                NativeImageFormat.HEIGHT,
            )
            NativeImageFormat.encodeArgb(
                pixels,
                NativeImageFormat.WIDTH,
                NativeImageFormat.HEIGHT,
                format,
            )
        } finally {
            bitmap.recycle()
        }
    }

    fun dispose() {
        ownedBitmaps.forEach { bitmap ->
            bitmap.takeUnless(Bitmap::isRecycled)?.recycle()
        }
        ownedBitmaps.clear()
        layers.clear()
        undoStack.clear()
        redoStack.clear()
        pendingTransformSnapshot = null
        transformHistoryRecorded = false
        rawTransformCenterX = null
        rawTransformCenterY = null
        clearSnapGuides()
    }

    private fun drawLayer(canvas: Canvas, layer: Layer) {
        layer.bitmap?.let { bitmap ->
            canvas.drawBitmap(bitmap, null, layer.bounds(textPaint), bitmapPaint)
            return
        }
        val text = layer.text ?: return
        textPaint.textSize = layer.textSize
        val width = textPaint.measureText(text)
        val metrics = textPaint.fontMetrics
        val baseline = layer.centerY - (metrics.ascent + metrics.descent) / 2f
        canvas.drawText(text, layer.centerX - width / 2f, baseline, textPaint)
    }

    private fun selectedLayer(): Layer? = layers.getOrNull(selectedIndex)

    private fun recordChange() {
        pushUndo(snapshot())
        pendingTransformSnapshot = null
        transformHistoryRecorded = false
    }

    private fun recordPendingTransform() {
        if (!transformHistoryRecorded) {
            pendingTransformSnapshot?.let(::pushUndo)
            transformHistoryRecorded = true
        }
    }

    private fun pushUndo(value: Snapshot) {
        undoStack.addLast(value)
        if (undoStack.size > MAX_HISTORY) undoStack.removeFirst()
        redoStack.clear()
        updateHistoryState()
    }

    private fun snapshot() = Snapshot(
        layers = layers.map(Layer::copy),
        selectedIndex = selectedIndex,
    )

    private fun restore(value: Snapshot) {
        layers.clear()
        layers += value.layers.map(Layer::copy)
        selectedIndex = value.selectedIndex.coerceAtMost(layers.lastIndex)
        pendingTransformSnapshot = null
        transformHistoryRecorded = false
        rawTransformCenterX = null
        rawTransformCenterY = null
        clearSnapGuides()
        changed()
    }

    private fun snappedPosition(selected: Layer, rawX: Float, rawY: Float): SnappedPosition {
        val bounds = selected.bounds(textPaint)
        val radians = Math.toRadians(selected.rotationDegrees.toDouble())
        val halfWidth =
            abs(cos(radians)).toFloat() * bounds.width() / 2f +
                abs(sin(radians)).toFloat() * bounds.height() / 2f
        val halfHeight =
            abs(sin(radians)).toFloat() * bounds.width() / 2f +
                abs(cos(radians)).toFloat() * bounds.height() / 2f

        val xTargets = mutableListOf(
            SnapTarget(paperWidth / 2f, paperWidth / 2f),
        )
        val yTargets = mutableListOf(
            SnapTarget(paperHeight / 2f, paperHeight / 2f),
        )
        if (halfWidth * 2f <= paperWidth) {
            xTargets += SnapTarget(halfWidth, 0f)
            xTargets += SnapTarget(paperWidth - halfWidth, paperWidth)
        }
        if (halfHeight * 2f <= paperHeight) {
            yTargets += SnapTarget(halfHeight, 0f)
            yTargets += SnapTarget(paperHeight - halfHeight, paperHeight)
        }
        layers.forEach { layer ->
            if (layer !== selected) {
                xTargets += SnapTarget(layer.centerX, layer.centerX)
                yTargets += SnapTarget(layer.centerY, layer.centerY)
            }
        }
        if (gridEnabled) {
            val gridX = snapCoordinate(rawX, paperWidth / 2f).coerceIn(0f, paperWidth)
            val gridY = snapCoordinate(rawY, paperHeight / 2f).coerceIn(0f, paperHeight)
            xTargets += SnapTarget(gridX, gridX)
            yTargets += SnapTarget(gridY, gridY)
        }

        val xTarget = closestSnapTarget(rawX, xTargets)
        val yTarget = closestSnapTarget(rawY, yTargets)
        return SnappedPosition(
            centerX = xTarget?.center ?: rawX,
            centerY = yTarget?.center ?: rawY,
            guideX = xTarget?.guide,
            guideY = yTarget?.guide,
        )
    }

    private fun closestSnapTarget(value: Float, targets: List<SnapTarget>): SnapTarget? =
        closestEditorSnapIndex(value, targets.map(SnapTarget::center), SNAP_THRESHOLD)
            ?.let(targets::get)

    private fun drawSnapGuides(canvas: Canvas) {
        activeSnapGuideX?.let { x ->
            canvas.drawLine(x, 0f, x, paperHeight, snapGuidePaint)
        }
        activeSnapGuideY?.let { y ->
            canvas.drawLine(0f, y, paperWidth, y, snapGuidePaint)
        }
    }

    private fun clearSnapGuides() {
        activeSnapGuideX = null
        activeSnapGuideY = null
    }

    private fun drawGrid(canvas: Canvas) {
        drawGridAxis(paperWidth / 2f, paperWidth) { x, paint ->
            canvas.drawLine(x, 0f, x, paperHeight, paint)
        }
        drawGridAxis(paperHeight / 2f, paperHeight) { y, paint ->
            canvas.drawLine(0f, y, paperWidth, y, paint)
        }
    }

    private inline fun drawGridAxis(
        origin: Float,
        limit: Float,
        drawLine: (Float, Paint) -> Unit,
    ) {
        drawLine(origin, gridCenterPaint)
        var distance = GRID_SPACING
        while (origin - distance >= 0f || origin + distance <= limit) {
            if (origin - distance >= 0f) drawLine(origin - distance, gridPaint)
            if (origin + distance <= limit) drawLine(origin + distance, gridPaint)
            distance += GRID_SPACING
        }
    }

    private fun snapCoordinate(value: Float, origin: Float): Float =
        editorGridCoordinate(value, origin, GRID_SPACING)

    private fun changed() {
        revision += 1
        updateHistoryState()
    }

    private fun updateHistoryState() {
        canUndo = undoStack.isNotEmpty()
        canRedo = redoStack.isNotEmpty()
    }

    private data class Snapshot(
        val layers: List<Layer>,
        val selectedIndex: Int,
    )

    private data class SnapTarget(val center: Float, val guide: Float)

    private data class SnappedPosition(
        val centerX: Float,
        val centerY: Float,
        val guideX: Float? = null,
        val guideY: Float? = null,
    )

    private data class Layer(
        val text: String? = null,
        val bitmap: Bitmap? = null,
        var centerX: Float,
        var centerY: Float,
        var width: Float = 0f,
        var height: Float = 0f,
        var textSize: Float = 0f,
        var rotationDegrees: Float = 0f,
    ) {
        fun bounds(paint: Paint): RectF {
            if (bitmap != null) {
                return RectF(
                    centerX - width / 2f,
                    centerY - height / 2f,
                    centerX + width / 2f,
                    centerY + height / 2f,
                )
            }
            val value = requireNotNull(text)
            paint.textSize = textSize
            val metrics = paint.fontMetrics
            val measuredWidth = paint.measureText(value)
            val measuredHeight = metrics.descent - metrics.ascent
            return RectF(
                centerX - measuredWidth / 2f - 2f,
                centerY - measuredHeight / 2f - 2f,
                centerX + measuredWidth / 2f + 2f,
                centerY + measuredHeight / 2f + 2f,
            )
        }

        fun contains(x: Float, y: Float, paint: Paint): Boolean {
            val radians = Math.toRadians(-rotationDegrees.toDouble())
            val deltaX = x - centerX
            val deltaY = y - centerY
            val localX = centerX + deltaX * cos(radians) - deltaY * sin(radians)
            val localY = centerY + deltaX * sin(radians) + deltaY * cos(radians)
            return bounds(paint).apply { inset(-5f, -5f) }.contains(
                localX.toFloat(),
                localY.toFloat(),
            )
        }

        fun resize(factor: Float) {
            val safeFactor = factor.coerceIn(0.5f, 2f)
            if (bitmap != null) {
                val minimumFactor = 2f / maxOf(width, height)
                val maximumFactor = minOf(
                    (paperWidth * 2f) / width,
                    (paperHeight * 2f) / height,
                )
                val applied = safeFactor.coerceIn(minimumFactor, maximumFactor)
                width *= applied
                height *= applied
            } else {
                textSize = (textSize * safeFactor).coerceIn(6f, 96f)
            }
        }

        fun rotate(deltaDegrees: Float) {
            val value = rotationDegrees + deltaDegrees
            rotationDegrees = ((value + 180f) % 360f + 360f) % 360f - 180f
        }

        companion object {
            fun text(value: String, x: Float, y: Float) = Layer(
                text = value,
                centerX = x,
                centerY = y,
                textSize = 24f,
            )

            fun image(bitmap: Bitmap, x: Float, y: Float, width: Float, height: Float) = Layer(
                bitmap = bitmap,
                centerX = x,
                centerY = y,
                width = width,
                height = height,
            )
        }
    }

    companion object {
        const val paperWidth = 296f
        const val paperHeight = 128f
        private const val GRID_SPACING = 8f
        private const val SNAP_THRESHOLD = 4f
        private const val MAX_HISTORY = 50
    }
}
