package jp.namecard.nfctest

import android.nfc.tech.NfcV
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.zip.CRC32
import kotlinx.coroutines.delay

internal const val IMAGE_SIZE = NativeImageFormat.BYTE_COUNT
internal const val TRANSFER_FLAG_BATCH_CLEAN = 0x01
internal val CLEAN_PATTERN_IDS = intArrayOf(4, 3, 4)
internal val CLEAN_PATTERN_NAMES = arrayOf("白", "黒", "白")

internal class ImageTransferSession(
    source: ByteArray,
    val format: Int,
    cleanBeforeWrite: Boolean,
) {
    val image: ByteArray = source.copyOf()
    val transferId = (System.currentTimeMillis() and 0xffff).toInt()
    val cleanBeforeWrite =
        format == NativeImageFormat.FORMAT_DOT_DENSITY && cleanBeforeWrite
    var maxChunk = 0
    var sequence = 0
    var offset = 0
    var planeIndex = 0
    var cleanStep = CLEAN_PATTERN_IDS.size
    var started = false
    var committed = false
    var executeSent = false
    var recoveryChecked = false
    var cleanRequested = this.cleanBeforeWrite
    var batchClean = false

    init {
        require(
            format == NativeImageFormat.FORMAT_DOT_DENSITY ||
                format == NativeImageFormat.FORMAT_GRAY4,
        ) { "unknown image format" }
        require(source.size == NativeImageFormat.byteCountForFormat(format)) {
            "image size does not match format"
        }
    }

    fun metadata(): ByteArray {
        val crc = CRC32().apply { update(image, planeIndex * IMAGE_SIZE, IMAGE_SIZE) }
        return ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(NativeImageFormat.WIDTH.toShort())
            .putShort(NativeImageFormat.HEIGHT.toShort())
            .putShort(IMAGE_SIZE.toShort())
            .put(format.toByte())
            .put(
                if (format == NativeImageFormat.FORMAT_GRAY4) {
                    planeIndex.toByte()
                } else {
                    1
                },
            )
            .putInt(crc.value.toInt())
            .putInt(if (batchClean) TRANSFER_FLAG_BATCH_CLEAN else 0)
            .array()
    }

    fun overallOffset(): Int = planeIndex * IMAGE_SIZE + offset

    fun planeLabel(): String = if (format == NativeImageFormat.FORMAT_GRAY4) {
        "4階調プレーン ${planeIndex + 1}/2"
    } else {
        "ドット密度画像"
    }

    fun cleanComplete(): Boolean = cleanStep >= CLEAN_PATTERN_IDS.size

    fun multiStageUpdate(): Boolean = batchClean || format == NativeImageFormat.FORMAT_GRAY4

    fun requireClean() {
        cleanStep = 0
    }

    fun requestClean() {
        cleanRequested = true
    }

    fun prepareCleaning(batchSupported: Boolean) {
        if (!cleanRequested) return
        if (batchSupported) batchClean = true else requireClean()
    }

    fun resetCurrentPlane() {
        sequence = 0
        offset = 0
        started = false
        committed = false
        executeSent = false
    }

    fun advancePlane() {
        check(format == NativeImageFormat.FORMAT_GRAY4 && planeIndex == 0) {
            "cannot advance image plane"
        }
        planeIndex = 1
        resetCurrentPlane()
    }

    fun resetProgress() {
        planeIndex = 0
        resetCurrentPlane()
    }
}

/** A transport failure after which Android must discard the current Tag object. */
internal class NfcSessionException(message: String, cause: Throwable? = null) :
    IOException(message, cause)

internal class St25Mailbox(
    private val nfc: NfcV,
    private val uid: ByteArray,
) {
    suspend fun enable() {
        val control = try {
            readControl()
        } catch (error: St25CommandException) {
            throw explainMailboxError(error)
        }
        if (control and 0x01 != 0) return
        try {
            command(0xae, byteArrayOf(0x0d, 0x01))
        } catch (error: St25CommandException) {
            throw explainMailboxError(error)
        }
        check(readControl() and 0x01 != 0) { "MB_ENを書き込めませんでした" }
    }

    suspend fun exchange(message: ByteArray, ackTimeoutMs: Long = 1_500L): Ack {
        waitMailboxFree(1_000L)
        val write = ByteArray(1 + message.size).apply {
            this[0] = (message.size - 1).toByte()
            message.copyInto(this, destinationOffset = 1)
        }
        command(0xaa, write)

        // Avoid hammering MB_CTRL_Dyn while EH and the MCU's I2C are active.
        delay(ACK_SETTLE_MS)
        val deadline = System.currentTimeMillis() + ackTimeoutMs
        while (System.currentTimeMillis() < deadline) {
            val control = readControl()
            if (control and 0x02 != 0) return Ack.decode(readHostMessage())
            delay(ACK_POLL_MS)
        }

        val diagnostic = try {
            String.format(
                Locale.US,
                " MB_CTRL=%02X EH_CTRL=%02X",
                readControl(),
                readDynamic(0x02),
            )
        } catch (_: Exception) {
            " (dynamic register diagnostic failed)"
        }
        throw NfcSessionException("MCU ACK timeout;$diagnostic")
    }

    private suspend fun waitMailboxFree(timeoutMs: Long) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val control = readControl()
            if (control and 0x06 == 0) return
            if (control and 0x02 != 0) readHostMessage()
            delay(10L)
        }
        throw NfcSessionException("mailbox busy")
    }

    private fun readControl(): Int = readDynamic(0x0d)

    private fun readDynamic(address: Int): Int =
        command(0xad, byteArrayOf(address.toByte()))[0].toInt() and 0xff

    private fun readHostMessage(): ByteArray {
        val answer = command(0xac, byteArrayOf(0, (ACK_FRAME_SIZE - 1).toByte()))
        if (answer.size != ACK_FRAME_SIZE) {
            throw NfcSessionException("ACK length mismatch: ${answer.size}")
        }
        return answer
    }

    private fun command(code: Int, parameters: ByteArray): ByteArray {
        val request = ByteArray(3 + uid.size + parameters.size).apply {
            this[0] = FLAGS.toByte()
            this[1] = code.toByte()
            this[2] = MFG_ST.toByte()
            uid.copyInto(this, destinationOffset = 3)
            parameters.copyInto(this, destinationOffset = 3 + uid.size)
        }
        check(request.size <= nfc.maxTransceiveLength) {
            "phone maxTransceiveLength exceeded: ${request.size}"
        }
        val response = nfc.transceive(request)
        if (response.isEmpty()) throw NfcSessionException("empty NFC response")
        if (response[0].toInt() and 0x01 != 0) {
            val error = response.getOrNull(1)?.toInt()?.and(0xff) ?: -1
            throw St25CommandException(code, error)
        }
        return response.copyOfRange(1, response.size)
    }

    private fun explainMailboxError(error: St25CommandException): Exception =
        if (error.errorCode == 0x10) {
            IllegalStateException(
                "Mailbox register unavailable。ST25公式アプリで静的MB_MODE=1を設定してください",
                error,
            )
        } else {
            error
        }

    private companion object {
        const val FLAGS = 0x22
        const val MFG_ST = 0x02
        const val ACK_FRAME_SIZE = 32
        const val ACK_SETTLE_MS = 50L
        const val ACK_POLL_MS = 15L
    }
}

internal class St25CommandException(
    val commandCode: Int,
    val errorCode: Int,
) : Exception(String.format(Locale.US, "ST25 command %02X error %02X", commandCode, errorCode))

internal object NamecardProtocol {
    fun frame(
        type: Int,
        transferId: Int,
        sequence: Int,
        offset: Int,
        payload: ByteArray,
    ): ByteArray {
        val raw = ByteBuffer.allocate(16 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
            .put('N'.code.toByte())
            .put('C'.code.toByte())
            .put(1)
            .put(type.toByte())
            .putShort(transferId.toShort())
            .putShort(sequence.toShort())
            .putShort(offset.toShort())
            .putShort(payload.size.toShort())
            .putShort(0)
            .putShort(crc16(payload).toShort())
            .put(payload)
            .array()
        val headerCrcInput = ByteArray(14).apply {
            raw.copyInto(this, endIndex = 12)
            raw.copyInto(this, destinationOffset = 12, startIndex = 14, endIndex = 16)
        }
        ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(12, crc16(headerCrcInput).toShort())
        return raw
    }

    fun crc16(data: ByteArray): Int {
        var crc = 0xffff
        for (item in data) {
            crc = crc xor ((item.toInt() and 0xff) shl 8)
            repeat(8) {
                crc = if (crc and 0x8000 != 0) {
                    ((crc shl 1) xor 0x1021) and 0xffff
                } else {
                    (crc shl 1) and 0xffff
                }
            }
        }
        return crc
    }
}

internal data class Ack(
    val code: Int,
    val state: Int,
    val error: Int,
    val expectedSequence: Int,
    val expectedOffset: Int,
    val vddMv: Int,
    val minimumVddMv: Int,
    val quietMs: Int,
    val capabilities: Int,
) {
    val hasPendingImage: Boolean get() = capabilities and 0x04 != 0
    val supportsBatchClean: Boolean get() = capabilities and 0x08 != 0
    val batchCleanActive: Boolean get() = capabilities and 0x10 != 0
    val supportsGray4: Boolean get() = capabilities and 0x20 != 0
    val currentDisplayIsGray: Boolean get() = capabilities and 0x40 != 0
    val hasGrayPlane0Pending: Boolean get() = capabilities and 0x80 != 0

    fun requireSuccess() {
        check(code != 0x80 && error == 0) {
            "FW error=$error (${errorName(error)})"
        }
    }

    companion object {
        fun decode(raw: ByteArray): Ack {
            if (
                raw.size < 32 ||
                raw[0] != 'N'.code.toByte() ||
                raw[1] != 'C'.code.toByte()
            ) {
                throw NfcSessionException("invalid ACK frame")
            }
            val copy = raw.copyOf()
            val storedHeaderCrc = u16(copy, 12)
            copy[12] = 0
            copy[13] = 0
            val check = ByteArray(14).apply {
                copy.copyInto(this, endIndex = 12)
                copy.copyInto(this, destinationOffset = 12, startIndex = 14, endIndex = 16)
            }
            if (
                NamecardProtocol.crc16(check) != storedHeaderCrc ||
                NamecardProtocol.crc16(raw.copyOfRange(16, raw.size)) != u16(raw, 14)
            ) {
                throw NfcSessionException("ACK CRC mismatch")
            }
            return Ack(
                code = raw[17].toInt() and 0xff,
                state = raw[18].toInt() and 0xff,
                error = raw[19].toInt() and 0xff,
                expectedSequence = u16(raw, 20),
                expectedOffset = u16(raw, 22),
                vddMv = u16(raw, 24),
                minimumVddMv = u16(raw, 26),
                quietMs = u16(raw, 28),
                capabilities = raw[31].toInt() and 0xff,
            )
        }

        private fun errorName(error: Int): String = when (error) {
            14 -> "VDD charge timeout"
            15 -> "VDD droop"
            16 -> "EPD BUSY timeout"
            17 -> "EPD I/O"
            18 -> "STM32-ST25 I2C/Mailbox I/O"
            19 -> "EXECUTE ACK timeout"
            20 -> "hardware gate"
            21 -> "display Flash store error"
            else -> "protocol"
        }

        private fun u16(value: ByteArray, offset: Int): Int =
            (value[offset].toInt() and 0xff) or
                ((value[offset + 1].toInt() and 0xff) shl 8)
    }
}
