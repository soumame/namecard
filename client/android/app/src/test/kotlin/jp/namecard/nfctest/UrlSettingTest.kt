package jp.namecard.nfctest

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UrlSettingTest {
    @Test
    fun addsHttpsWhenSchemeIsMissing() {
        val result = validateUrlInput("example.com/namecard")

        assertTrue(result.isValid)
        assertEquals("https://example.com/namecard", result.normalizedUrl)
    }

    @Test
    fun acceptsHttpAndPercentEncodesUnicodePath() {
        val result = validateUrlInput("http://example.com/名刺")

        assertTrue(result.isValid)
        assertEquals("http://example.com/%E5%90%8D%E5%88%BA", result.normalizedUrl)
    }

    @Test
    fun acceptsHostnameWithPortWithoutScheme() {
        val result = validateUrlInput("example.com:8080/profile")

        assertTrue(result.isValid)
        assertEquals("https://example.com:8080/profile", result.normalizedUrl)
    }

    @Test
    fun rejectsNonWebSchemeAndWhitespace() {
        assertFalse(validateUrlInput("mailto:test@example.com").isValid)
        assertFalse(validateUrlInput("https://example.com/a b").isValid)
        assertFalse(validateUrlInput("https://@").isValid)
    }

    @Test
    fun extractsShortCapabilityContainerNdefTlv() {
        val message = byteArrayOf(0xd1.toByte(), 0x01, 0x02, 0x55, 0x00)
        val memory = byteArrayOf(0xe1.toByte(), 0x40, 0x40, 0x00, 0x03, message.size.toByte()) +
            message + byteArrayOf(0xfe.toByte(), 0x00)

        assertArrayEquals(message, extractType5NdefMessage(memory))
    }

    @Test
    fun extractsExtendedCapabilityContainerAndLength() {
        val message = ByteArray(260) { it.toByte() }
        val memory = byteArrayOf(
            0xe2.toByte(), 0x40, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
            0x03, 0xff.toByte(), 0x01, 0x04,
        ) + message + byteArrayOf(0xfe.toByte())

        assertArrayEquals(message, extractType5NdefMessage(memory))
    }

    @Test
    fun incompleteTlvIsNotAccepted() {
        val memory = byteArrayOf(0xe1.toByte(), 0x40, 0x40, 0x00, 0x03, 0x08, 0x01)

        assertNull(extractType5NdefMessage(memory))
    }
}
