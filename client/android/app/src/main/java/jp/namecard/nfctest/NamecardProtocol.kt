package jp.namecard.nfctest

import android.nfc.tech.NfcV
import android.os.SystemClock
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
    private val onExchangeResult: ((ack: Ack, responseMillis: Long, requestType: Int) -> Unit)? =
        null,
) {
    suspend fun enable() {
        val deadline = SystemClock.elapsedRealtime() + MAILBOX_ENABLE_TIMEOUT_MS
        var lastEhControl = -1
        var lastMailboxControl = -1
        var lastCommandError: St25CommandException? = null

        while (SystemClock.elapsedRealtime() < deadline) {
            /* RF discovery needs only the passive tag, but FTM needs the
             * harvested SYS_VDD to be present on ST25 VCC.  Weaker phones can
             * therefore discover the card well before MB_EN is writable.
             * Poll at a low rate and leave almost all of this interval quiet
             * so VRES can charge. */
            lastEhControl = try {
                readDynamic(0x02)
            } catch (error: St25CommandException) {
                lastCommandError = error
                -1
            }

            if ((lastEhControl >= 0) && (lastEhControl and EH_CTRL_VCC_ON == 0)) {
                delayUntilRetry(deadline)
                continue
            }

            try {
                lastMailboxControl = readControl()
                if (lastMailboxControl and MB_CTRL_MB_EN != 0) return

                command(0xae, byteArrayOf(0x0d, MB_CTRL_MB_EN.toByte()))
                delay(MAILBOX_ENABLE_VERIFY_DELAY_MS)
                lastMailboxControl = readControl()
                if (lastMailboxControl and MB_CTRL_MB_EN != 0) return
            } catch (error: St25CommandException) {
                if (error.errorCode != 0x10) throw error
                lastCommandError = error
            }
            delayUntilRetry(deadline)
        }

        val diagnostic = String.format(
            Locale.US,
            "EH_CTRL=%s MB_CTRL=%s",
            if (lastEhControl >= 0) "%02X".format(lastEhControl) else "??",
            if (lastMailboxControl >= 0) "%02X".format(lastMailboxControl) else "??",
        )
        val reason = if ((lastEhControl >= 0) && (lastEhControl and EH_CTRL_VCC_ON == 0)) {
            "ST25のVCCが立ち上がっていません。端末のNFCアンテナへさらに近づけて位置を固定してください"
        } else {
            "MB_ENを有効化できません。VCCが不安定か、静的MB_MODEが未設定です"
        }
        throw NfcSessionException("$reason（$diagnostic）", lastCommandError)
    }

    private suspend fun delayUntilRetry(deadline: Long) {
        val remaining = deadline - SystemClock.elapsedRealtime()
        if (remaining > 0L) delay(minOf(MAILBOX_ENABLE_RETRY_QUIET_MS, remaining))
    }

    suspend fun disable() {
        val control = try {
            readControl()
        } catch (error: St25CommandException) {
            if (error.errorCode == 0x10) return
            throw error
        }
        if (control and 0x01 == 0) return
        command(0xae, byteArrayOf(0x0d, 0x00))
        check(readControl() and 0x01 == 0) { "MB_ENを解除できませんでした" }
    }

    fun readNdefMessage(expectedLength: Int): ByteArray {
        require(expectedLength in 1..MAX_VERIFIABLE_NDEF_BYTES) {
            "URLが長すぎて読み返し確認できません"
        }
        val firstBlock = readUserBlock(0)
        val ccSize = if (firstBlock[2].toInt() and 0xff == 0) 8 else 4
        val requiredBytes = ccSize + expectedLength + MAX_TLV_OVERHEAD
        val blockCount = (requiredBytes + USER_BLOCK_SIZE - 1) / USER_BLOCK_SIZE
        check(blockCount <= MAX_STANDARD_BLOCK_COUNT) { "NDEF確認範囲が大きすぎます" }
        val memory = ByteArray(blockCount * USER_BLOCK_SIZE)
        firstBlock.copyInto(memory)
        for (block in 1 until blockCount) {
            readUserBlock(block).copyInto(memory, destinationOffset = block * USER_BLOCK_SIZE)
        }
        return extractType5NdefMessage(memory)
            ?: throw NfcSessionException("書き込んだNDEFを読み返せませんでした")
    }

    suspend fun exchange(message: ByteArray, ackTimeoutMs: Long = 1_500L): Ack {
        val startedAt = SystemClock.elapsedRealtime()
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
            if (control and 0x02 != 0) {
                val ack = Ack.decode(readHostMessage())
                onExchangeResult?.invoke(
                    ack,
                    SystemClock.elapsedRealtime() - startedAt,
                    message.getOrNull(3)?.toInt()?.and(0xff) ?: 0,
                )
                return ack
            }
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

    private fun readUserBlock(block: Int): ByteArray {
        require(block in 0 until MAX_STANDARD_BLOCK_COUNT)
        val request = ByteArray(2 + uid.size + 1).apply {
            this[0] = FLAGS.toByte()
            this[1] = ISO_READ_SINGLE_BLOCK.toByte()
            uid.copyInto(this, destinationOffset = 2)
            this[lastIndex] = block.toByte()
        }
        val response = nfc.transceive(request)
        if (response.isEmpty()) throw NfcSessionException("empty NFC response")
        if (response[0].toInt() and 0x01 != 0) {
            val error = response.getOrNull(1)?.toInt()?.and(0xff) ?: -1
            throw St25CommandException(ISO_READ_SINGLE_BLOCK, error)
        }
        val data = response.copyOfRange(1, response.size)
        if (data.size != USER_BLOCK_SIZE) {
            throw NfcSessionException("NFC-V block length mismatch: ${data.size}")
        }
        return data
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
        const val MB_CTRL_MB_EN = 0x01
        const val EH_CTRL_VCC_ON = 0x08
        const val MAILBOX_ENABLE_TIMEOUT_MS = 8_000L
        const val MAILBOX_ENABLE_RETRY_QUIET_MS = 1_000L
        const val MAILBOX_ENABLE_VERIFY_DELAY_MS = 25L
        const val ACK_FRAME_SIZE = 32
        const val ACK_SETTLE_MS = 50L
        const val ACK_POLL_MS = 15L
        const val ISO_READ_SINGLE_BLOCK = 0x20
        const val USER_BLOCK_SIZE = 4
        const val MAX_STANDARD_BLOCK_COUNT = 128
        const val MAX_VERIFIABLE_NDEF_BYTES = 480
        const val MAX_TLV_OVERHEAD = 4
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
