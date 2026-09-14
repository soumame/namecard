package jp.namecard.nfctest

import android.graphics.Paint
import android.graphics.Typeface

// Android exposes system font files on API 29+, but no public family-name catalog.
// These generic families resolve through the OS, including its Japanese fallback.
internal enum class EditorFontFamily(val systemName: String, val label: String) {
    SANS_SERIF("sans-serif", "ゴシック体"),
    SERIF("serif", "明朝体"),
    MONOSPACE("monospace", "等幅"),
    CURSIVE("cursive", "筆記体"),
    CASUAL("casual", "手書き風"),
}

internal data class EditorTextStyle(
    val fontFamily: EditorFontFamily = EditorFontFamily.SANS_SERIF,
    val bold: Boolean = true,
    val italic: Boolean = false,
    val underline: Boolean = false,
) {
    val typeface: Typeface by lazy {
        val flags = (if (bold) Typeface.BOLD else Typeface.NORMAL) or
            (if (italic) Typeface.ITALIC else Typeface.NORMAL)
        Typeface.create(fontFamily.systemName, flags)
    }

    fun applyTo(paint: Paint, size: Float) {
        paint.typeface = typeface
        paint.textSize = size
        paint.isUnderlineText = underline
    }
}
