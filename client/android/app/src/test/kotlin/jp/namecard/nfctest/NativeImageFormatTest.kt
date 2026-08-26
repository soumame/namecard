package jp.namecard.nfctest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeImageFormatTest {
    @Test
    fun solidWhiteAndBlackEncodeToNativeBits() {
        val white = IntArray(NativeImageFormat.WIDTH * NativeImageFormat.HEIGHT) { 0xffffffff.toInt() }
        val black = IntArray(white.size) { 0xff000000.toInt() }

        assertFilled(
            NativeImageFormat.encodeArgb(white, NativeImageFormat.WIDTH, NativeImageFormat.HEIGHT),
            0xff.toByte(),
        )
        assertFilled(
            NativeImageFormat.encodeArgb(black, NativeImageFormat.WIDTH, NativeImageFormat.HEIGHT),
            0x00,
        )
    }

    @Test
    fun nativeCoordinatesUseControllerOrder() {
        val pixels = IntArray(NativeImageFormat.WIDTH * NativeImageFormat.HEIGHT) { 0xffffffff.toInt() }
        pixels[0] = 0xff000000.toInt()
        pixels[127 * NativeImageFormat.WIDTH + 295] = 0xff000000.toInt()

        val encoded = NativeImageFormat.encodeArgb(
            pixels,
            NativeImageFormat.WIDTH,
            NativeImageFormat.HEIGHT,
        )

        assertEquals(NativeImageFormat.BYTE_COUNT, encoded.size)
        assertEquals(0, encoded[0].toInt() and 0x80)
        assertEquals(0, encoded[295 * 16 + 15].toInt() and 0x01)
    }

    @Test
    fun grayLevelsMapToTwoControllerPlanes() {
        val white = IntArray(NativeImageFormat.WIDTH * NativeImageFormat.HEIGHT) { 0xffffffff.toInt() }
        val black = IntArray(white.size) { 0xff000000.toInt() }
        assertFilled(
            NativeImageFormat.encodeArgbGray4(white, NativeImageFormat.WIDTH, NativeImageFormat.HEIGHT),
            0x00,
        )
        assertFilled(
            NativeImageFormat.encodeArgbGray4(black, NativeImageFormat.WIDTH, NativeImageFormat.HEIGHT),
            0xff.toByte(),
        )

        val levels = white.copyOf()
        levels[0] = 0xff404040.toInt()
        levels[1] = 0xff808080.toInt()
        val gray = NativeImageFormat.encodeArgbGray4(
            levels,
            NativeImageFormat.WIDTH,
            NativeImageFormat.HEIGHT,
        )

        assertEquals(NativeImageFormat.GRAY4_BYTE_COUNT, gray.size)
        assertEquals(0, gray[0].toInt() and 0x80)
        assertTrue(gray[NativeImageFormat.BYTE_COUNT].toInt() and 0x80 != 0)
        assertTrue(gray[16].toInt() and 0x80 != 0)
        assertEquals(0, gray[NativeImageFormat.BYTE_COUNT + 16].toInt() and 0x80)
    }

    @Test
    fun nativeImagesDecodeForLibraryPreview() {
        val blackAndWhite = IntArray(NativeImageFormat.WIDTH * NativeImageFormat.HEIGHT) { index ->
            if (index % 2 == 0) 0xff000000.toInt() else 0xffffffff.toInt()
        }
        val grayLevels = intArrayOf(
            0xff000000.toInt(),
            0xff555555.toInt(),
            0xffaaaaaa.toInt(),
            0xffffffff.toInt(),
        )
        val gray = IntArray(blackAndWhite.size) { grayLevels[it % grayLevels.size] }

        assertArrayEquals(
            blackAndWhite,
            NativeImageFormat.decodeArgb(
                NativeImageFormat.encodeArgb(
                    blackAndWhite,
                    NativeImageFormat.WIDTH,
                    NativeImageFormat.HEIGHT,
                ),
                NativeImageFormat.FORMAT_DOT_DENSITY,
            ),
        )
        assertArrayEquals(
            gray,
            NativeImageFormat.decodeArgb(
                NativeImageFormat.encodeArgbGray4(
                    gray,
                    NativeImageFormat.WIDTH,
                    NativeImageFormat.HEIGHT,
                ),
                NativeImageFormat.FORMAT_GRAY4,
            ),
        )
    }

    @Test
    fun binSizeDeterminesImportedFormat() {
        assertEquals(
            NativeImageFormat.FORMAT_DOT_DENSITY,
            NativeImageFormat.formatForByteCount(NativeImageFormat.BYTE_COUNT),
        )
        assertEquals(
            NativeImageFormat.FORMAT_GRAY4,
            NativeImageFormat.formatForByteCount(NativeImageFormat.GRAY4_BYTE_COUNT),
        )
    }

    private fun assertFilled(value: ByteArray, expected: Byte) {
        assertTrue(value.all { it == expected })
    }
}
