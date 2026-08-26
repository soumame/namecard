package jp.namecard.nfctest

import android.content.Context
import java.io.File
import java.util.UUID
import org.json.JSONObject

internal data class LibraryCard(
    val id: String,
    val name: String,
    val format: Int,
    val createdAt: Long,
    val updatedAt: Long,
    val bytes: ByteArray,
)

internal class CardLibraryRepository(context: Context) {
    private val directory = File(context.filesDir, "card-library").apply { mkdirs() }

    fun list(): List<LibraryCard> = directory
        .listFiles { file -> file.extension == "json" }
        .orEmpty()
        .mapNotNull(::readCard)
        .sortedByDescending(LibraryCard::updatedAt)

    fun save(name: String, format: Int, bytes: ByteArray): LibraryCard {
        require(bytes.size == NativeImageFormat.byteCountForFormat(format)) {
            "BINサイズと送信方式が一致しません"
        }
        val now = System.currentTimeMillis()
        val card = LibraryCard(
            id = UUID.randomUUID().toString(),
            name = normalizeName(name),
            format = format,
            createdAt = now,
            updatedAt = now,
            bytes = bytes.copyOf(),
        )
        binFile(card.id).writeBytes(card.bytes)
        writeMetadata(card)
        return card
    }

    fun rename(card: LibraryCard, name: String): LibraryCard {
        val updated = card.copy(
            name = normalizeName(name),
            updatedAt = System.currentTimeMillis(),
        )
        writeMetadata(updated)
        return updated
    }

    fun delete(card: LibraryCard) {
        check(binFile(card.id).delete() || !binFile(card.id).exists()) {
            "カードのBINを削除できません"
        }
        check(metadataFile(card.id).delete() || !metadataFile(card.id).exists()) {
            "カード情報を削除できません"
        }
    }

    private fun readCard(metadata: File): LibraryCard? = runCatching {
        val json = JSONObject(metadata.readText())
        val id = json.getString("id")
        val format = json.getInt("format")
        val bytes = binFile(id).readBytes()
        require(bytes.size == NativeImageFormat.byteCountForFormat(format))
        LibraryCard(
            id = id,
            name = json.getString("name"),
            format = format,
            createdAt = json.getLong("createdAt"),
            updatedAt = json.getLong("updatedAt"),
            bytes = bytes,
        )
    }.getOrNull()

    private fun writeMetadata(card: LibraryCard) {
        metadataFile(card.id).writeText(
            JSONObject()
                .put("id", card.id)
                .put("name", card.name)
                .put("format", card.format)
                .put("createdAt", card.createdAt)
                .put("updatedAt", card.updatedAt)
                .toString(),
        )
    }

    private fun metadataFile(id: String) = File(directory, "$id.json")

    private fun binFile(id: String) = File(directory, "$id.bin")

    private fun normalizeName(name: String): String =
        name.trim().ifEmpty { "名称未設定" }.take(MAX_NAME_LENGTH)

    private companion object {
        const val MAX_NAME_LENGTH = 80
    }
}
