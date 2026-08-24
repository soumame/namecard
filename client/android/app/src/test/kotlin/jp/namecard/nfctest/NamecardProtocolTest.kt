package jp.namecard.nfctest

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NamecardProtocolTest {
    @Test
    fun frameUsesLittleEndianHeaderAndValidCrc() {
        val payload = byteArrayOf(0x10, 0x20, 0x30)
        val frame = NamecardProtocol.frame(2, 0x1234, 7, 240, payload)

        assertEquals(19, frame.size)
        assertEquals('N'.code.toByte(), frame[0])
        assertEquals('C'.code.toByte(), frame[1])
        assertEquals(2, frame[3].toInt())
        val buffer = ByteBuffer.wrap(frame).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0x1234, buffer.getShort(4).toInt() and 0xffff)
        assertEquals(7, buffer.getShort(6).toInt() and 0xffff)
        assertEquals(240, buffer.getShort(8).toInt() and 0xffff)
        assertEquals(payload.size, buffer.getShort(10).toInt() and 0xffff)
        assertArrayEquals(payload, frame.copyOfRange(16, frame.size))
        assertEquals(NamecardProtocol.crc16(payload), buffer.getShort(14).toInt() and 0xffff)
    }

    @Test
    fun crc16MatchesCcittFalseCheckVector() {
        assertEquals(0x29b1, NamecardProtocol.crc16("123456789".encodeToByteArray()))
    }

    @Test
    fun graySessionMetadataTracksSelectedPlane() {
        val session = ImageTransferSession(
            ByteArray(NativeImageFormat.GRAY4_BYTE_COUNT),
            NativeImageFormat.FORMAT_GRAY4,
            cleanBeforeWrite = true,
        )
        assertEquals(0, session.metadata()[7].toInt())
        session.advancePlane()
        assertEquals(1, session.metadata()[7].toInt())
        assertEquals(IMAGE_SIZE, session.overallOffset())
    }

    @Test
    fun ackDecodeValidatesCrcAndCapabilities() {
        val raw = ByteArray(32)
        raw[0] = 'N'.code.toByte()
        raw[1] = 'C'.code.toByte()
        raw[2] = 1
        raw[3] = 0x81.toByte()
        raw[10] = 16
        raw[17] = 0
        raw[18] = 6
        raw[20] = 3
        raw[22] = 0x80.toByte()
        raw[23] = 0x12
        raw[24] = 0x80.toByte()
        raw[25] = 0x0c
        raw[31] = 0x60
        val payloadCrc = NamecardProtocol.crc16(raw.copyOfRange(16, 32))
        raw[14] = payloadCrc.toByte()
        raw[15] = (payloadCrc ushr 8).toByte()
        val header = ByteArray(14).apply {
            raw.copyInto(this, endIndex = 12)
            raw.copyInto(this, destinationOffset = 12, startIndex = 14, endIndex = 16)
        }
        val headerCrc = NamecardProtocol.crc16(header)
        raw[12] = headerCrc.toByte()
        raw[13] = (headerCrc ushr 8).toByte()

        val ack = Ack.decode(raw)

        assertEquals(6, ack.state)
        assertEquals(3, ack.expectedSequence)
        assertEquals(0x1280, ack.expectedOffset)
        assertEquals(3_200, ack.vddMv)
        assertTrue(ack.supportsGray4)
        assertTrue(ack.currentDisplayIsGray)
    }
}
