package jp.namecard.nfctest

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.WriterException
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

internal class QrCode private constructor(val url: String, private val modules: BitMatrix) {
    val moduleCount: Int get() = modules.width
    // Include the quiet zone and leave space around the initial placement.
    val canvasScale: Int get() = 120 / moduleCount
    val canAddToCanvas: Boolean get() = canvasScale >= 2
    val previewScale: Int get() = maxOf(1, 512 / moduleCount)

    fun pixels(scale: Int): IntArray {
        require(scale in 1..32)
        val side = moduleCount * scale
        return IntArray(side * side) { index ->
            if (modules[index % side / scale, index / side / scale]) 0xff000000.toInt() else 0xffffffff.toInt()
        }
    }

    companion object {
        fun generate(input: String): QrCode {
            val validation = validateUrlInput(input)
            val url = requireNotNull(validation.normalizedUrl) { validation.error.orEmpty() }
            require(url.length <= 2_000) { "URLが長すぎます。短いURLを入力してください。" }
            val modules = try {
                QRCodeWriter().encode(
                    url, BarcodeFormat.QR_CODE, 0, 0,
                    mapOf(EncodeHintType.MARGIN to 4, EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M),
                )
            } catch (_: WriterException) {
                throw IllegalArgumentException("URLが長すぎます。短いURLを入力してください。")
            }
            return QrCode(url, modules)
        }
    }
}
