package jp.namecard.nfctest

import android.graphics.Paint
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.test.AndroidTestCase

@Suppress("DEPRECATION")
class EditorTextRenderingTest : AndroidTestCase() {
    fun testObjectRotationSnapAccumulatesForTextAndImagesAndSupportsUndo() {
        for (imageLayer in listOf(false, true)) {
            val state = rotationFixture(imageLayer)
            try {
                val original = state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)
                assertFalse(state.objectRotationSnapEnabled)
                state.toggleObjectRotationSnap()
                assertFalse(state.snapEnabled)
                state.beginTransform()
                repeat(4) { state.transformSelection(0f, 0f, 1f, 1f) }
                assertTrue(original.contentEquals(state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)))
                state.transformSelection(0f, 0f, 1f, 1f)
                assertRotationPixels(state, imageLayer, 5f)
                state.transformSelection(0f, 0f, 1f, 7f)
                state.endTransform()
                assertRotationPixels(state, imageLayer, 15f)
                state.undo()
                assertTrue(original.contentEquals(state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)))
                state.redo()
                assertRotationPixels(state, imageLayer, 15f)
                state.beginTransform()
                state.transformSelection(0f, 0f, 1f, 5f)
                state.endTransform()
                assertRotationPixels(state, imageLayer, 20f)
            } finally {
                state.dispose()
            }
        }
    }

    fun testObjectRotationSnapToggleDoesNotJumpAndResetsRawAngle() {
        val state = rotationFixture(false)
        try {
            state.beginTransform()
            state.transformSelection(0f, 0f, 1f, 28f)
            state.endTransform()
            state.toggleObjectRotationSnap()
            assertRotationPixels(state, false, 28f)
            state.beginTransform()
            state.transformSelection(0f, 0f, 2f, 0f)
            state.transformSelection(0f, 0f, 0.5f, 0f)
            assertRotationPixels(state, false, 28f)
            state.transformSelection(0f, 0f, 1f, 1f)
            assertRotationPixels(state, false, 30f)
            state.toggleObjectRotationSnap()
            state.transformSelection(0f, 0f, 1f, 1f)
            state.endTransform()
            assertRotationPixels(state, false, 31f)
        } finally {
            state.dispose()
        }
    }

    fun testObjectRotationSnapWrapsAndDoesNotLeakIntoNewLayers() {
        val state = rotationFixture(false)
        try {
            state.beginTransform()
            state.transformSelection(0f, 0f, 1f, 178f)
            state.endTransform()
            state.toggleObjectRotationSnap()
            state.beginTransform()
            state.transformSelection(0f, 0f, 1f, 1f)
            state.endTransform()
            assertRotationPixels(state, false, -180f)
            state.undo()
            assertRotationPixels(state, false, 178f)
            state.redo()
            state.clearAll()
            state.addText("Snap")
            state.beginTransform()
            state.transformSelection(0f, 0f, 1f, 12f)
            state.endTransform()
            assertRotationPixels(state, false, 15f)
        } finally {
            state.dispose()
        }
    }

    private fun rotationFixture(imageLayer: Boolean) = EditorCanvasState().apply {
        if (imageLayer) {
            addImage(Bitmap.createBitmap(24, 12, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLACK) })
        } else {
            addText("Snap")
        }
    }

    private fun assertRotationPixels(state: EditorCanvasState, imageLayer: Boolean, angle: Float) {
        val reference = rotationFixture(imageLayer)
        try {
            reference.beginTransform()
            reference.transformSelection(0f, 0f, 1f, angle)
            reference.endTransform()
            assertTrue("Expected rendered rotation $angle", reference.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)
                .contentEquals(state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)))
        } finally {
            reference.dispose()
        }
    }

    fun testEveryBoldItalicCombinationAndUnderlineResetsPaint() {
        val paint = Paint()
        for (bold in listOf(false, true)) {
            for (italic in listOf(false, true)) {
                EditorTextStyle(bold = bold, italic = italic, underline = true).applyTo(paint, 24f)
                assertEquals(bold, paint.typeface.isBold)
                assertEquals(italic, paint.typeface.isItalic)
                assertTrue(paint.isUnderlineText)
            }
        }
        EditorTextStyle(bold = false).applyTo(paint, 20f)
        assertEquals(Typeface.NORMAL, paint.typeface.style)
        assertFalse(paint.isUnderlineText)
        assertEquals(20f, paint.textSize)
    }

    fun testEachTextOptionChangesTheExportedPixels() {
        val normal = render(EditorTextStyle(bold = false))
        for (style in listOf(
            EditorTextStyle(bold = true),
            EditorTextStyle(bold = false, italic = true),
            EditorTextStyle(bold = false, underline = true),
            EditorTextStyle(fontFamily = EditorFontFamily.SERIF, bold = false),
            EditorTextStyle(fontFamily = EditorFontFamily.MONOSPACE, bold = false),
        )) {
            assertFalse("Style must affect exported image: $style", normal.contentEquals(render(style)))
        }
    }

    fun testJapaneseSerifUsesTheSystemFallback() {
        val blank = render(EditorTextStyle(), "")
        for (family in EditorFontFamily.entries) {
            val style = EditorTextStyle(fontFamily = family)
            val japanese = render(style, "名刺太郎")
            assertFalse("Japanese text must render with $family", blank.contentEquals(japanese))
            assertTrue(japanese.contentEquals(render(style, "名刺太郎")))
        }
    }

    fun testJapaneseBoldItalicAndUnderlineChangeExportedPixels() {
        val value = "名刺太郎"
        val normal = render(EditorTextStyle(bold = false), value)
        for (style in listOf(
            EditorTextStyle(bold = true),
            EditorTextStyle(bold = false, italic = true),
            EditorTextStyle(bold = false, underline = true),
        )) {
            assertFalse("Japanese text style must affect export: $style",
                normal.contentEquals(render(style, value)))
        }
    }

    fun testUndoRedoPreservesEachLayersFormatting() {
        val state = EditorCanvasState()
        try {
            state.addText("First", EditorTextStyle(fontFamily = EditorFontFamily.SERIF, italic = true))
            state.moveSelection(-70f, -20f)
            val first = state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)
            state.addText("Second", EditorTextStyle(bold = false, underline = true))
            val both = state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)
            state.undo()
            assertTrue(first.contentEquals(state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)))
            state.redo()
            assertTrue(both.contentEquals(state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)))
            // Drawing the second layer must not leak its style into subsequent renders.
            assertTrue(both.contentEquals(state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)))
        } finally {
            state.dispose()
        }
    }

    private fun render(style: EditorTextStyle, value: String = "Namecard 123"): ByteArray {
        val state = EditorCanvasState()
        return try {
            state.addText(value, style)
            state.renderNativeImage(NativeImageFormat.FORMAT_GRAY4)
        } finally {
            state.dispose()
        }
    }
}
