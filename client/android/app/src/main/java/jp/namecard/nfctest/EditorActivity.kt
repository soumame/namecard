package jp.namecard.nfctest

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.Locale

class EditorActivity : ComponentActivity() {
    private val editor = EditorCanvasState()
    private var screenState by mutableStateOf(
        EditorScreenState(NativeImageFormat.FORMAT_DOT_DENSITY),
    )
    private var pendingBin: ByteArray? = null
    private var pendingBinFormat = NativeImageFormat.FORMAT_DOT_DENSITY

    private val imagePicker = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) addImage(uri)
    }

    private val binSaver = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        if (uri != null) writePendingBin(uri)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enableEdgeToEdge()
        val requestedFormat = intent.getIntExtra(
            EXTRA_IMAGE_FORMAT,
            NativeImageFormat.FORMAT_DOT_DENSITY,
        )
        screenState = screenState.copy(selectedFormat = requestedFormat)
        setContent {
            NamecardTheme {
                EditorScreen(
                    state = screenState,
                    canvasState = editor,
                    onBack = ::finish,
                    onFormatSelected = { format ->
                        screenState = screenState.copy(selectedFormat = format)
                    },
                    onAddText = { text ->
                        editor.addText(text)
                        showMessage("テキストを追加しました。ドラッグで移動できます。")
                    },
                    onPickImage = { imagePicker.launch(arrayOf("image/*")) },
                    onResize = editor::resizeSelection,
                    onMoveBackward = editor::moveSelectionBackward,
                    onMoveForward = editor::moveSelectionForward,
                    onDelete = editor::deleteSelection,
                    onClear = editor::clearAll,
                    onSaveBin = ::saveBin,
                    onWrite = ::finishForWrite,
                )
            }
        }
    }

    override fun onDestroy() {
        editor.dispose()
        super.onDestroy()
    }

    private fun addImage(uri: Uri) {
        try {
            val bitmap = loadBitmap(uri)
                ?: throw IllegalArgumentException("画像をデコードできません")
            editor.addImage(bitmap)
            showMessage("画像を追加しました。ドラッグで移動、2本指で拡大・縮小できます。")
        } catch (error: Exception) {
            showMessage("処理エラー: ${error.message}")
        }
    }

    private fun saveBin() {
        pendingBinFormat = screenState.selectedFormat
        pendingBin = editor.renderNativeImage(pendingBinFormat)
        binSaver.launch(
            if (pendingBinFormat == NativeImageFormat.FORMAT_GRAY4) {
                "namecard-gray4.bin"
            } else {
                "namecard-dither.bin"
            },
        )
    }

    private fun writePendingBin(uri: Uri) {
        try {
            val bytes = pendingBin
                ?.takeIf { it.size == NativeImageFormat.byteCountForFormat(pendingBinFormat) }
                ?: throw IllegalStateException("保存するBINがありません")
            contentResolver.openOutputStream(uri, "w").use { output ->
                requireNotNull(output) { "保存先を開けません" }
                output.write(bytes)
            }
            showMessage(String.format(Locale.US, "%,d-byteのBINを保存しました。", bytes.size))
            pendingBin = null
        } catch (error: Exception) {
            showMessage("処理エラー: ${error.message}")
        }
    }

    private fun finishForWrite() {
        val format = screenState.selectedFormat
        setResult(
            RESULT_OK,
            Intent().apply {
                putExtra(EXTRA_NATIVE_IMAGE, editor.renderNativeImage(format))
                putExtra(EXTRA_IMAGE_FORMAT, format)
            },
        )
        finish()
    }

    private fun showMessage(message: String) {
        screenState = screenState.copy(message = message)
    }

    private fun loadBitmap(uri: Uri): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return ImageDecoder.decodeBitmap(
                ImageDecoder.createSource(contentResolver, uri),
            ) { decoder, info, _ ->
                val width = info.size.width
                val height = info.size.height
                val longest = maxOf(width, height)
                if (longest > MAX_DECODE_SIDE) {
                    val scale = MAX_DECODE_SIDE / longest.toFloat()
                    decoder.setTargetSize(
                        maxOf(1, Math.round(width * scale)),
                        maxOf(1, Math.round(height * scale)),
                    )
                }
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri).use { input ->
            BitmapFactory.decodeStream(input, null, bounds)
        }
        var sample = 1
        while (maxOf(bounds.outWidth / sample, bounds.outHeight / sample) > MAX_DECODE_SIDE) {
            sample *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return contentResolver.openInputStream(uri).use { input ->
            BitmapFactory.decodeStream(input, null, options)
        }
    }

    companion object {
        const val EXTRA_NATIVE_IMAGE = "jp.namecard.nfctest.NATIVE_IMAGE"
        const val EXTRA_IMAGE_FORMAT = "jp.namecard.nfctest.IMAGE_FORMAT"
        private const val MAX_DECODE_SIDE = 2048
    }
}
