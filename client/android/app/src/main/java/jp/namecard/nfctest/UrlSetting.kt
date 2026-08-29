package jp.namecard.nfctest

import java.net.URI

internal data class UrlInputResult(
    val normalizedUrl: String? = null,
    val error: String? = null,
) {
    val isValid: Boolean get() = normalizedUrl != null
}

internal fun validateUrlInput(input: String): UrlInputResult {
    val trimmed = input.trim()
    if (trimmed.isEmpty()) return UrlInputResult(error = "URLを入力してください")
    if (trimmed.any { it.isWhitespace() || it.isISOControl() }) {
        return UrlInputResult(error = "空白を含まないURLを入力してください")
    }

    val hasWebStyleScheme = SCHEME_PREFIX.containsMatchIn(trimmed)
    val schemeWithoutSlashes = SCHEME_WITHOUT_SLASHES.find(trimmed)
    if (!hasWebStyleScheme && schemeWithoutSlashes != null) {
        val afterColon = trimmed.substring(schemeWithoutSlashes.range.last + 1)
        val looksLikePort = afterColon.substringBefore('/').toIntOrNull() != null
        if (!looksLikePort) {
            return UrlInputResult(error = "http:// または https:// のURLを入力してください")
        }
    }
    val candidate = if (hasWebStyleScheme) trimmed else "https://$trimmed"
    val uri = runCatching { URI(candidate) }.getOrNull()
        ?: return UrlInputResult(error = "URLの形式を確認してください")
    val scheme = uri.scheme?.lowercase()
    if (scheme != "https" && scheme != "http") {
        return UrlInputResult(error = "http:// または https:// のURLを入力してください")
    }
    if (uri.host.isNullOrBlank()) {
        return UrlInputResult(error = "ホスト名を含むURLを入力してください")
    }
    return UrlInputResult(normalizedUrl = uri.toASCIIString())
}

/** Extracts the first NDEF TLV value from a Type 5 Tag memory dump. */
internal fun extractType5NdefMessage(memory: ByteArray): ByteArray? {
    if (memory.size < TYPE5_SHORT_CC_SIZE) return null
    val magic = memory[0].toInt() and 0xff
    if (magic != TYPE5_SHORT_CC_MAGIC && magic != TYPE5_EXTENDED_CC_MAGIC) return null
    val ccSize = if (memory[2].toInt() and 0xff == 0) {
        TYPE5_EXTENDED_CC_SIZE
    } else {
        TYPE5_SHORT_CC_SIZE
    }
    if (memory.size < ccSize) return null

    var offset = ccSize
    while (offset < memory.size) {
        when (val type = memory[offset++].toInt() and 0xff) {
            TYPE5_NULL_TLV -> continue
            TYPE5_TERMINATOR_TLV -> return null
            else -> {
                if (offset >= memory.size) return null
                var length = memory[offset++].toInt() and 0xff
                if (length == TYPE5_EXTENDED_LENGTH) {
                    if (offset + 1 >= memory.size) return null
                    length = ((memory[offset].toInt() and 0xff) shl 8) or
                        (memory[offset + 1].toInt() and 0xff)
                    offset += 2
                }
                if (length < 0 || offset + length > memory.size) return null
                if (type == TYPE5_NDEF_TLV) return memory.copyOfRange(offset, offset + length)
                offset += length
            }
        }
    }
    return null
}

private val SCHEME_PREFIX = Regex("^[A-Za-z][A-Za-z0-9+.-]*://")
private val SCHEME_WITHOUT_SLASHES = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")
private const val TYPE5_SHORT_CC_SIZE = 4
private const val TYPE5_EXTENDED_CC_SIZE = 8
private const val TYPE5_SHORT_CC_MAGIC = 0xe1
private const val TYPE5_EXTENDED_CC_MAGIC = 0xe2
private const val TYPE5_NULL_TLV = 0x00
private const val TYPE5_NDEF_TLV = 0x03
private const val TYPE5_TERMINATOR_TLV = 0xfe
private const val TYPE5_EXTENDED_LENGTH = 0xff
