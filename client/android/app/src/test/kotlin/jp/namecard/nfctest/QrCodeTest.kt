package jp.namecard.nfctest

import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class QrCodeTest {
    @Test fun generatedPreviewAndCanvasPixelsDecodeToNormalizedURL() {
        for (input in listOf("example.com", "https://example.com/名刺?a=1&b=2", "http://example.com/a%2F#test")) {
            val code = QrCode.generate(input)
            assertTrue(code.canAddToCanvas)
            for (scale in listOf(code.canvasScale, code.previewScale)) {
                val side = code.moduleCount * scale
                val pixels = code.pixels(scale)
                val source = RGBLuminanceSource(side, side, pixels)
                val result = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)))
                assertEquals(validateUrlInput(input).normalizedUrl, result.text)
                assertTrue(pixels.all { it == 0xff000000.toInt() || it == 0xffffffff.toInt() })
            }
        }
    }

    @Test fun quietZoneIsFourWhiteModulesAndCanvasFits() {
        val code = QrCode.generate("https://example.com/namecard")
        val scale = code.canvasScale
        val side = code.moduleCount * scale
        assertTrue(side <= 120)
        assertTrue(scale >= 2)
        val pixels = code.pixels(scale)
        for (y in 0 until side) for (x in 0 until side) {
            if (x < 4 * scale || y < 4 * scale || x >= side - 4 * scale || y >= side - 4 * scale) {
                assertEquals(0xffffffff.toInt(), pixels[y * side + x])
            }
        }
    }

    @Test fun denseCodeCanBePreviewedButCannotBeAddedUnreadablySmall() {
        val code = QrCode.generate("https://example.com/" + "x".repeat(600))
        assertFalse(code.canAddToCanvas)
        val scale = code.previewScale
        val side = code.moduleCount * scale
        val source = RGBLuminanceSource(side, side, code.pixels(scale))
        // This is the generated raster itself, with no camera perspective.
        val result = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)), mapOf(DecodeHintType.PURE_BARCODE to true))
        assertEquals(code.url, result.text)
    }

    @Test fun invalidAndExcessivelyLongURLsAreRejected() {
        for (input in listOf("", " \n", "mailto:a@example.com", "https://example.com/a b", "https://example.com/" + "x".repeat(2000))) {
            assertThrows(IllegalArgumentException::class.java) { QrCode.generate(input) }
        }
    }
}
