package jp.namecard.nfctest

/** Converts an Android-style ARGB canvas to SSD1680 native display data. */
object NativeImageFormat {
    const val WIDTH = 296
    const val HEIGHT = 128
    const val BYTE_COUNT = WIDTH * HEIGHT / 8
    const val GRAY4_BYTE_COUNT = BYTE_COUNT * 2
    const val FORMAT_DOT_DENSITY = 1
    const val FORMAT_GRAY4 = 2

    private val bayer4x4 = arrayOf(
        intArrayOf(0, 8, 2, 10),
        intArrayOf(12, 4, 14, 6),
        intArrayOf(3, 11, 1, 9),
        intArrayOf(15, 7, 13, 5),
    )

    /**
     * Encodes a 296x128 row-major ARGB image. The native result is 16 bytes
     * across the short axis for each of 296 long-axis rows, MSB first, where
     * 1 means white and 0 means black.
     */
    @JvmStatic
    fun encodeArgb(pixels: IntArray, width: Int, height: Int): ByteArray {
        validate(pixels, width, height)
        return ByteArray(BYTE_COUNT) { 0xff.toByte() }.also { nativeImage ->
            for (y in 0 until HEIGHT) {
                for (x in 0 until WIDTH) {
                    val luminance = luminanceOnWhite(pixels[y * WIDTH + x])
                    val threshold = bayer4x4[y and 3][x and 3] * 16 + 8
                    if (luminance < threshold) clearNativeBit(nativeImage, x, y)
                }
            }
        }
    }

    /**
     * Encodes four physical gray levels as the controller's 0x24 and 0x26
     * RAM planes. Plane 0 occupies the first 4,736 bytes and plane 1 the next.
     */
    @JvmStatic
    fun encodeArgbGray4(pixels: IntArray, width: Int, height: Int): ByteArray {
        validate(pixels, width, height)
        return ByteArray(GRAY4_BYTE_COUNT).also { nativeImage ->
            for (y in 0 until HEIGHT) {
                for (x in 0 until WIDTH) {
                    val grayCode = minOf(3, luminanceOnWhite(pixels[y * WIDTH + x]) / 64)
                    val index = x * (HEIGHT / 8) + y / 8
                    val mask = 0x80 ushr (y and 7)
                    if ((grayCode and 0x01) == 0) {
                        nativeImage[index] = (nativeImage[index].toInt() or mask).toByte()
                    }
                    if ((grayCode and 0x02) == 0) {
                        val plane1Index = BYTE_COUNT + index
                        nativeImage[plane1Index] =
                            (nativeImage[plane1Index].toInt() or mask).toByte()
                    }
                }
            }
        }
    }

    @JvmStatic
    fun encodeArgb(pixels: IntArray, width: Int, height: Int, format: Int): ByteArray =
        when (format) {
            FORMAT_DOT_DENSITY -> encodeArgb(pixels, width, height)
            FORMAT_GRAY4 -> encodeArgbGray4(pixels, width, height)
            else -> throw IllegalArgumentException("unknown image format: $format")
        }

    @JvmStatic
    fun byteCountForFormat(format: Int): Int = when (format) {
        FORMAT_DOT_DENSITY -> BYTE_COUNT
        FORMAT_GRAY4 -> GRAY4_BYTE_COUNT
        else -> throw IllegalArgumentException("unknown image format: $format")
    }

    @JvmStatic
    fun formatForByteCount(byteCount: Int): Int = when (byteCount) {
        BYTE_COUNT -> FORMAT_DOT_DENSITY
        GRAY4_BYTE_COUNT -> FORMAT_GRAY4
        else -> throw IllegalArgumentException(
            "BIN must be exactly $BYTE_COUNT or $GRAY4_BYTE_COUNT bytes",
        )
    }

    @JvmStatic
    fun displayName(format: Int): String = when (format) {
        FORMAT_DOT_DENSITY -> "ドット密度"
        FORMAT_GRAY4 -> "4階調"
        else -> throw IllegalArgumentException("unknown image format: $format")
    }

    @JvmStatic
    fun decodeArgb(image: ByteArray, format: Int): IntArray {
        require(image.size == byteCountForFormat(format)) {
            "BIN size does not match image format"
        }
        val shades = intArrayOf(
            0xff000000.toInt(),
            0xff555555.toInt(),
            0xffaaaaaa.toInt(),
            0xffffffff.toInt(),
        )
        return IntArray(WIDTH * HEIGHT) { pixelIndex ->
            val x = pixelIndex % WIDTH
            val y = pixelIndex / WIDTH
            val nativeIndex = x * (HEIGHT / 8) + y / 8
            val mask = 0x80 ushr (y and 7)
            if (format == FORMAT_DOT_DENSITY) {
                if ((image[nativeIndex].toInt() and mask) != 0) shades[3] else shades[0]
            } else {
                val low = if ((image[nativeIndex].toInt() and mask) != 0) 0 else 1
                val highIndex = BYTE_COUNT + nativeIndex
                val high = if ((image[highIndex].toInt() and mask) != 0) 0 else 2
                shades[low + high]
            }
        }
    }

    private fun validate(pixels: IntArray, width: Int, height: Int) {
        require(width == WIDTH && height == HEIGHT) {
            "canvas must be exactly ${WIDTH}x$HEIGHT"
        }
        require(pixels.size == width * height) {
            "ARGB pixel count does not match canvas"
        }
    }

    private fun luminanceOnWhite(color: Int): Int {
        val alpha = color ushr 24
        val red = (((color ushr 16) and 0xff) * alpha + 255 * (255 - alpha)) / 255
        val green = (((color ushr 8) and 0xff) * alpha + 255 * (255 - alpha)) / 255
        val blue = ((color and 0xff) * alpha + 255 * (255 - alpha)) / 255
        return (299 * red + 587 * green + 114 * blue) / 1000
    }

    private fun clearNativeBit(image: ByteArray, x: Int, y: Int) {
        val index = x * (HEIGHT / 8) + y / 8
        image[index] = image[index].toInt()
            .and((0x80 ushr (y and 7)).inv())
            .toByte()
    }
}
