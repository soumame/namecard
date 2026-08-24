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
import androidx.compose.runtime.setValue

internal class EditorCanvasState {
    private val layers = mutableListOf<Layer>()
    private val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
        colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(0f) })
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
    }
    private val selectionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(21, 94, 239)
        style = Paint.Style.STROKE
        strokeWidth = 1.5f
        pathEffect = DashPathEffect(floatArrayOf(5f, 3f), 0f)
    }
    private var selectedIndex = -1

    var revision by mutableIntStateOf(0)
        private set

    val hasSelection: Boolean get() = selectedLayer() != null

    fun addText(value: String) {
        val text = value.trim()
        if (text.isEmpty()) return
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

    fun selectAt(x: Float, y: Float) {
        selectedIndex = -1
        for (index in layers.indices.reversed()) {
            val hit = layers[index].bounds(textPaint).apply { inset(-5f, -5f) }
            if (hit.contains(x, y)) {
                selectedIndex = index
                break
            }
        }
        changed()
    }

    fun moveSelection(deltaX: Float, deltaY: Float) {
        val selected = selectedLayer() ?: return
        selected.centerX = (selected.centerX + deltaX).coerceIn(0f, paperWidth)
        selected.centerY = (selected.centerY + deltaY).coerceIn(0f, paperHeight)
        changed()
    }

    fun resizeSelection(factor: Float) {
        selectedLayer()?.resize(factor) ?: return
        changed()
    }

    fun deleteSelection() {
        if (selectedIndex !in layers.indices) return
        layers.removeAt(selectedIndex).bitmap
            ?.takeUnless(Bitmap::isRecycled)
            ?.recycle()
        selectedIndex = if (layers.isEmpty()) -1 else minOf(selectedIndex, layers.lastIndex)
        changed()
    }

    fun moveSelectionForward() {
        if (selectedIndex !in 0 until layers.lastIndex) return
        val selected = layers.removeAt(selectedIndex)
        selectedIndex += 1
        layers.add(selectedIndex, selected)
        changed()
    }

    fun moveSelectionBackward() {
        if (selectedIndex !in 1..layers.lastIndex) return
        val selected = layers.removeAt(selectedIndex)
        selectedIndex -= 1
        layers.add(selectedIndex, selected)
        changed()
    }

    fun clearAll() {
        layers.forEach { layer ->
            layer.bitmap?.takeUnless(Bitmap::isRecycled)?.recycle()
        }
        layers.clear()
        selectedIndex = -1
        changed()
    }

    fun draw(canvas: Canvas, showSelection: Boolean) {
        canvas.drawColor(Color.WHITE)
        layers.forEach { drawLayer(canvas, it) }
        if (showSelection) {
            selectedLayer()?.let { selected ->
                canvas.drawRect(selected.bounds(textPaint), selectionPaint)
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
        layers.forEach { layer ->
            layer.bitmap?.takeUnless(Bitmap::isRecycled)?.recycle()
        }
        layers.clear()
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

    private fun changed() {
        revision += 1
    }

    private data class Layer(
        val text: String? = null,
        val bitmap: Bitmap? = null,
        var centerX: Float,
        var centerY: Float,
        var width: Float = 0f,
        var height: Float = 0f,
        var textSize: Float = 0f,
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
    }
}
