package jp.namecard.nfctest

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.nfc.NfcAdapter
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.Tag
import android.nfc.TagLostException
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.nfc.tech.NfcV
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.IOException
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val ui = Handler(Looper.getMainLooper())
    private val transferScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val running = AtomicBoolean(false)

    private var adapter: NfcAdapter? = null
    @Volatile
    private var activeNfc: NfcV? = null
    private var readerModeActive = false
    private var screenState by mutableStateOf(MainScreenState())
    private val editor = EditorCanvasState()
    private lateinit var libraryRepository: CardLibraryRepository
    private var libraryCards by mutableStateOf<List<LibraryCard>>(emptyList())
    private var pendingExport: PendingExport? = null
    private var image: ByteArray? = null
    private var imageFormat = NativeImageFormat.FORMAT_DOT_DENSITY
    private var imageName = "画像"
    private var antennaGuide = NfcAntennaGuide.fallback()
    private var recentLinkIssues = 0
    private var lastDataResponseMillis = 0L

    @Volatile
    private var imageTransferSession: ImageTransferSession? = null

    @Volatile
    private var pendingMode = MODE_NONE

    @Volatile
    private var pendingUrl: String? = null

    @Volatile
    private var selectedPatternId = 1

    @Volatile
    private var continuousNextPattern = 1

    @Volatile
    private var cleanImageBeforeWrite = true

    private val editorImagePicker = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) addEditorImage(uri)
    }

    private val libraryImportPicker = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) importLibraryCard(uri)
    }

    private val exportSaver = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        if (uri != null) {
            writePendingExport(uri)
        } else {
            pendingExport = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        adapter = NfcAdapter.getDefaultAdapter(this)
        antennaGuide = readNfcAntennaGuide()
        libraryRepository = CardLibraryRepository(this)
        libraryCards = libraryRepository.list()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enableEdgeToEdge()
        setContent {
            NamecardTheme {
                MainScreen(
                    state = screenState,
                    canvasState = editor,
                    libraryCards = libraryCards,
                    patternNames = patternNames,
                    onTabSelected = { tab ->
                        screenState = screenState.copy(selectedTab = tab)
                    },
                    onImageFormatSelected = { format ->
                        imageFormat = format
                        screenState = screenState.copy(selectedImageFormat = format)
                    },
                    onAddText = ::addEditorText,
                    onPickImage = { editorImagePicker.launch(arrayOf("image/*")) },
                    onUndo = editor::undo,
                    onRedo = editor::redo,
                    onMoveBackward = editor::moveSelectionBackward,
                    onMoveForward = editor::moveSelectionForward,
                    onDelete = editor::deleteSelection,
                    onClear = editor::clearAll,
                    onSaveToLibrary = ::saveEditorToLibrary,
                    onExportEditor = ::exportEditor,
                    onWriteEditor = ::writeEditor,
                    onWriteUrl = ::prepareUrlWrite,
                    onImportCard = {
                        libraryImportPicker.launch(arrayOf("application/octet-stream"))
                    },
                    onWriteCard = ::writeLibraryCard,
                    onEditCard = ::editLibraryCard,
                    onRenameCard = ::renameLibraryCard,
                    onExportCard = ::exportLibraryCard,
                    onDeleteCard = ::deleteLibraryCard,
                    onCleanChanged = { checked ->
                        cleanImageBeforeWrite = checked
                        screenState = screenState.copy(cleanBeforeWrite = checked)
                    },
                    onStatusCheck = ::selectStatusCheck,
                    onPatternSelected = { patternId ->
                        selectedPatternId = patternId
                        screenState = screenState.copy(selectedPatternId = patternId)
                    },
                    onPatternWrite = ::selectPattern,
                    onPatternSequence = ::selectPatternSequence,
                    onDismissWriteProgress = {
                        val progress = screenState.writeProgress
                        if (progress?.outcome != WriteProgressOutcome.RUNNING) {
                            screenState = screenState.copy(writeProgress = null)
                        } else if (progress.canCancel && !running.get()) {
                            pendingMode = MODE_NONE
                            pendingUrl = null
                            imageTransferSession = null
                            screenState = screenState.copy(writeProgress = null)
                            refreshReaderMode()
                            log("NFC書き込みをキャンセルしました。\n")
                        }
                    },
                )
            }
        }
    }

    private fun selectStatusCheck() {
        pendingMode = MODE_STATUS
        log("STATUS確認を選択。名刺にタッチしてください。\n")
    }

    private fun selectPattern() {
        pendingMode = MODE_PATTERN
        log("${patternNames[selectedPatternId - 1]} を選択。名刺にタッチして動かさないでください。\n")
    }

    private fun selectPatternSequence() {
        continuousNextPattern = 1
        pendingMode = MODE_PATTERN_SEQUENCE
        log("10種類の連続書き換えを選択。完了まで同じ位置に固定してください。\n")
    }

    private fun addEditorText(text: String) {
        editor.addText(text)
        screenState = screenState.copy(editorMessage = "テキストを追加しました。直接操作できます。")
    }

    private fun addEditorImage(uri: Uri) {
        runCatching {
            val bitmap = loadBitmap(uri) ?: error("画像をデコードできません")
            editor.addImage(bitmap)
        }.onSuccess {
            screenState = screenState.copy(
                editorMessage = "画像を追加しました。ドラッグ、2本指で拡大・縮小・回転できます。",
            )
        }.onFailure { error ->
            screenState = screenState.copy(editorMessage = "画像追加エラー: ${error.message}")
        }
    }

    private fun saveEditorToLibrary(name: String) {
        runCatching {
            val format = screenState.selectedImageFormat
            libraryRepository.save(name, format, editor.renderNativeImage(format))
        }.onSuccess { card ->
            reloadLibrary()
            screenState = screenState.copy(
                libraryMessage = "「${card.name}」を保存しました。",
                selectedTab = AppTab.LIBRARY,
            )
        }.onFailure { error ->
            screenState = screenState.copy(editorMessage = "保存エラー: ${error.message}")
        }
    }

    private fun exportEditor() {
        val format = screenState.selectedImageFormat
        exportBytes(
            bytes = editor.renderNativeImage(format),
            fileName = "namecard-${if (format == NativeImageFormat.FORMAT_GRAY4) "gray4" else "dither"}.bin",
        )
    }

    private fun writeEditor() {
        val format = screenState.selectedImageFormat
        prepareImageTransfer(editor.renderNativeImage(format), "Newの画像", format)
        screenState = screenState.copy(
            editorMessage = "書き込み準備完了。名刺へタッチして動かさないでください。",
        )
    }

    private fun prepareUrlWrite(url: String) {
        val normalized = validateUrlInput(url).normalizedUrl
        if (normalized == null) {
            screenState = screenState.copy(editorMessage = "URLの形式を確認してください。")
            return
        }
        imageTransferSession = null
        pendingUrl = normalized
        pendingMode = MODE_URL
        screenState = screenState.copy(
            editorMessage = "URL書き込み準備完了。名刺へタッチして動かさないでください。",
            writeProgress = WriteProgressState(
                title = "URL設定",
                detail = "URLを書き込む名刺へタッチしてください。",
                antennaGuide = antennaGuide,
            ),
        )
        refreshReaderMode()
        log("URL書き込みを選択: $normalized\n名刺にタッチしてください。\n")
    }

    private fun importLibraryCard(uri: Uri) {
        runCatching {
            val bytes = contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "ファイルを開けません" }.readBytes()
            }
            val format = NativeImageFormat.formatForByteCount(bytes.size)
            val name = queryDisplayName(uri).substringBeforeLast('.').ifBlank { "インポート画像" }
            libraryRepository.save(name, format, bytes)
        }.onSuccess { card ->
            reloadLibrary()
            screenState = screenState.copy(
                libraryMessage = "「${card.name}」をインポートしました。",
                selectedTab = AppTab.LIBRARY,
            )
        }.onFailure { error ->
            screenState = screenState.copy(libraryMessage = "インポートエラー: ${error.message}")
        }
    }

    private fun writeLibraryCard(card: LibraryCard) {
        imageFormat = card.format
        screenState = screenState.copy(
            selectedImageFormat = card.format,
            libraryMessage = "「${card.name}」を書き込みます。名刺へタッチしてください。",
        )
        prepareImageTransfer(card.bytes, card.name, card.format)
    }

    private fun editLibraryCard(card: LibraryCard) {
        runCatching {
            val bitmap = Bitmap.createBitmap(
                NativeImageFormat.decodeArgb(card.bytes, card.format),
                NativeImageFormat.WIDTH,
                NativeImageFormat.HEIGHT,
                Bitmap.Config.ARGB_8888,
            )
            editor.replaceWithImage(bitmap)
        }.onSuccess {
            imageFormat = card.format
            screenState = screenState.copy(
                selectedTab = AppTab.NEW,
                selectedImageFormat = card.format,
                editorMessage = "「${card.name}」を編集用に読み込みました。",
            )
        }.onFailure { error ->
            screenState = screenState.copy(libraryMessage = "編集読込エラー: ${error.message}")
        }
    }

    private fun renameLibraryCard(card: LibraryCard, name: String) {
        runCatching { libraryRepository.rename(card, name) }
            .onSuccess { renamed ->
                reloadLibrary()
                screenState = screenState.copy(libraryMessage = "「${renamed.name}」へ変更しました。")
            }
            .onFailure { error ->
                screenState = screenState.copy(libraryMessage = "名称変更エラー: ${error.message}")
            }
    }

    private fun exportLibraryCard(card: LibraryCard) {
        val safeName = card.name.replace(Regex("[^A-Za-z0-9._-]+"), "-").trim('-')
            .ifBlank { "namecard" }
        exportBytes(card.bytes, "$safeName.bin")
    }

    private fun deleteLibraryCard(card: LibraryCard) {
        runCatching { libraryRepository.delete(card) }
            .onSuccess {
                reloadLibrary()
                screenState = screenState.copy(libraryMessage = "「${card.name}」を削除しました。")
            }
            .onFailure { error ->
                screenState = screenState.copy(libraryMessage = "削除エラー: ${error.message}")
            }
    }

    private fun exportBytes(bytes: ByteArray, fileName: String) {
        pendingExport = PendingExport(bytes.copyOf(), fileName)
        exportSaver.launch(fileName)
    }

    private fun writePendingExport(uri: Uri) {
        val export = pendingExport ?: return
        runCatching {
            contentResolver.openOutputStream(uri, "w").use { output ->
                requireNotNull(output) { "保存先を開けません" }.write(export.bytes)
            }
        }.onSuccess {
            val message = "${export.fileName}を書き出しました。"
            screenState = if (screenState.selectedTab == AppTab.LIBRARY) {
                screenState.copy(libraryMessage = message)
            } else {
                screenState.copy(editorMessage = message)
            }
        }.onFailure { error ->
            val message = "書き出しエラー: ${error.message}"
            screenState = if (screenState.selectedTab == AppTab.LIBRARY) {
                screenState.copy(libraryMessage = message)
            } else {
                screenState.copy(editorMessage = message)
            }
        }
        pendingExport = null
    }

    private fun reloadLibrary() {
        libraryCards = libraryRepository.list()
    }

    private fun queryDisplayName(uri: Uri): String {
        contentResolver.query(uri, null, null, null, null).use { cursor ->
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        }
        return "image.bin"
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

    private fun prepareImageTransfer(selected: ByteArray, name: String, format: Int) {
        image = selected.copyOf()
        imageFormat = format
        imageName = name
        imageTransferSession = null
        recentLinkIssues = 0
        lastDataResponseMillis = 0L
        pendingMode = MODE_IMAGE
        screenState = screenState.copy(
            writeProgress = WriteProgressState(title = name, antennaGuide = antennaGuide),
        )
        log("$name を${formatName(format)}で読込済み。名刺にタッチして動かさないでください。\n")
    }

    override fun onResume() {
        super.onResume()
        readerModeActive = true
        enableReaderMode()
    }

    override fun onPause() {
        readerModeActive = false
        activeNfc?.runCatching { close() }
        adapter?.disableReaderMode(this)
        super.onPause()
    }

    override fun onDestroy() {
        activeNfc?.runCatching { close() }
        editor.dispose()
        transferScope.cancel()
        super.onDestroy()
    }

    private fun enableReaderMode() {
        val nfcAdapter = adapter ?: return
        if (!readerModeActive || !nfcAdapter.isEnabled) return
        val options = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 120_000)
        }
        val flags = NfcAdapter.FLAG_READER_NFC_V or
            if (pendingMode == MODE_URL) 0 else NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
        nfcAdapter.enableReaderMode(
            this,
            ::handleTag,
            flags,
            options,
        )
    }

    private fun refreshReaderMode() {
        ui.post {
            if (!readerModeActive || isFinishing || isDestroyed) return@post
            enableReaderMode()
        }
    }

    private fun restartReaderModeAfterLoss(tag: Tag) {
        ui.post {
            val nfcAdapter = adapter ?: return@post
            if (!readerModeActive || isFinishing || isDestroyed) return@post

            // Keep Reader Mode active while discarding the stale Tag handle.
            // Disabling it here, even briefly, lets Android's normal NDEF
            // dispatch open the URL if the card re-enters the field meanwhile.
            val waitingForRemoval = runCatching {
                nfcAdapter.ignore(
                    tag,
                    TAG_REMOVAL_DEBOUNCE_MS,
                    { onTagRemovedAfterLoss() },
                    ui,
                )
            }.getOrDefault(false)
            if (waitingForRemoval) {
                log("古いNFC接続を破棄しました。名刺を一度完全に離してください。\n")
            } else {
                // TagLost can arrive after Android has already observed the
                // removal. Reader Mode is still active, so no reset is needed.
                onTagRemovedAfterLoss()
            }
        }
    }

    private fun onTagRemovedAfterLoss() {
        if (!readerModeActive || isFinishing || isDestroyed) return
        log("NFC探索を継続しています。名刺へもう一度タッチしてください。\n")
    }

    private fun handleTag(tag: Tag?) {
        val mode = pendingMode
        if (tag == null) return
        if (mode == MODE_NONE) {
            log("NFC-Vタグを検出しました。先に試験ボタンを選んでください。\n")
            return
        }
        val selectedImage = image
        val selectedUrl = pendingUrl
        if (
            (mode == MODE_IMAGE && selectedImage == null) ||
            (mode == MODE_URL && selectedUrl == null) ||
            !running.compareAndSet(false, true)
        ) {
            return
        }
        log(
            "NFC-V検出 UID=${tag.id.toHex()}" +
                when (mode) {
                    MODE_STATUS -> "。MCU起動を待ちます。\n"
                    MODE_URL -> "。URL書き込みを準備します。\n"
                    else -> "。MCU起動・VRES充電を待ちます。\n"
                },
        )
        if (mode == MODE_IMAGE) {
            showWriteProgressIfNeeded()
            updateWriteProgress(
                progress = 0.04f,
                currentStep = 1,
                status = "NFCタグを検出しました",
                detail = "接続を確立し、名刺側の状態を確認しています。",
            )
        } else if (mode == MODE_URL) {
            showUrlWriteProgressIfNeeded()
            updateWriteProgress(
                progress = 0.08f,
                currentStep = 1,
                status = "NFCタグを検出しました",
                detail = "画像転送を停止し、URL書き込みを準備しています。",
            )
        }
        val transferImage = if (mode == MODE_IMAGE) selectedImage?.copyOf() else null
        val transferImageFormat = imageFormat
        val patternId = selectedPatternId
        setControlsEnabled(false)
        transferScope.launch {
            transfer(tag, mode, transferImage, transferImageFormat, patternId, selectedUrl)
        }
    }

    private suspend fun transfer(
        tag: Tag,
        mode: Int,
        transferImage: ByteArray?,
        transferImageFormat: Int,
        patternId: Int,
        url: String?,
    ) {
        val nfc = NfcV.get(tag)
        var stage = "NFC接続"
        var transferredBytes = 0
        var activeSession: ImageTransferSession? = null
        var restartReader = false
        try {
            checkNotNull(nfc) { "NFC-Vタグではありません" }
            activeNfc = nfc
            nfc.connect()
            if (mode == MODE_URL) {
                stage = "URL書き込み"
                runUrlWrite(tag, nfc, requireNotNull(url)) { nextStage ->
                    stage = nextStage
                }
                pendingUrl = null
                pendingMode = MODE_NONE
                completeWriteProgress("URLを書き込み、読み返して確認しました。")
                ui.post {
                    screenState = screenState.copy(editorMessage = "URLを書き込みました。")
                }
                refreshReaderMode()
                log("URLの書き込みと読み返し確認が完了しました。\n")
                return
            }
            if (mode == MODE_IMAGE) {
                updateWriteProgress(
                    progress = 0.07f,
                    currentStep = 1,
                    status = "NFC接続完了",
                    detail = "Mailboxの準備をしています。",
                )
            }
            val mailbox = St25Mailbox(nfc, tag.id) { ack, responseMillis, requestType ->
                if (mode == MODE_IMAGE) observeNfcLink(ack, responseMillis, requestType)
            }
            delay(BOOT_QUIET_MS)
            stage = "Mailbox有効化"
            mailbox.enable()
            if (mode == MODE_IMAGE) {
                updateWriteProgress(
                    progress = 0.10f,
                    currentStep = 1,
                    status = "名刺と通信できました",
                    detail = "前回の中断位置と表示状態を確認しています。",
                )
            }

            if (mode == MODE_IMAGE) {
                val source = requireNotNull(transferImage)
                synchronized(this) {
                    val previous = imageTransferSession
                    val expectedClean =
                        transferImageFormat == NativeImageFormat.FORMAT_DOT_DENSITY &&
                            cleanImageBeforeWrite
                    if (
                        previous == null ||
                        !previous.image.contentEquals(source) ||
                        previous.format != transferImageFormat ||
                        previous.cleanBeforeWrite != expectedClean
                    ) {
                        imageTransferSession = ImageTransferSession(
                            source,
                            transferImageFormat,
                            cleanImageBeforeWrite,
                        )
                    }
                    activeSession = imageTransferSession
                }
                transferredBytes = requireNotNull(activeSession).overallOffset()
            }
            val transferId = activeSession?.transferId
                ?: (System.currentTimeMillis() and 0xffff).toInt()

            when (mode) {
                MODE_STATUS -> {
                    stage = "STATUS"
                    val ack = mailbox.exchange(NamecardProtocol.frame(4, transferId, 0, 0, byteArrayOf()))
                    ack.requireSuccess()
                    log(
                        String.format(
                            Locale.US,
                            "STATUS OK: state=%d VDD=%dmV min=%dmV error=%d\n",
                            ack.state,
                            ack.vddMv,
                            ack.minimumVddMv,
                            ack.error,
                        ),
                    )
                    return
                }
                MODE_PATTERN -> {
                    stage = "PATTERN $patternId"
                    runPatternUpdate(mailbox, patternId)
                    return
                }
                MODE_PATTERN_SEQUENCE -> {
                    while (continuousNextPattern <= PATTERN_COUNT) {
                        val next = continuousNextPattern
                        stage = "PATTERN連続 $next/$PATTERN_COUNT"
                        log("連続試験 $next/$PATTERN_COUNT: ${patternNames[next - 1]}\n")
                        runPatternUpdate(mailbox, next)
                        continuousNextPattern = next + 1
                    }
                    log("10種類の連続書き換えが完了しました。\n")
                    continuousNextPattern = 1
                    return
                }
            }

            val session = requireNotNull(activeSession)
            stage = "中断状態確認"
            val recovery = mailbox.exchange(NamecardProtocol.frame(4, transferId, 0, 0, byteArrayOf()))
            recovery.requireSuccess()
            if (session.format == NativeImageFormat.FORMAT_GRAY4 && !recovery.supportsGray4) {
                error("接続中のFWは4階調転送に未対応です。FWを更新してください")
            }
            if (
                session.executeSent &&
                recovery.state == 6 &&
                recovery.currentDisplayIsGray ==
                (session.format == NativeImageFormat.FORMAT_GRAY4)
            ) {
                log("前回の表示更新が完了していることを確認しました。\n")
                imageTransferSession = null
                pendingMode = MODE_NONE
                completeWriteProgress("前回の表示更新完了を確認しました。")
                return
            }
            if (
                session.format == NativeImageFormat.FORMAT_GRAY4 &&
                session.planeIndex == 1 &&
                recovery.state == 1 &&
                recovery.hasGrayPlane0Pending
            ) {
                if (recovery.expectedOffset < IMAGE_SIZE) {
                    session.started = true
                    session.committed = false
                    session.sequence = recovery.expectedSequence
                    session.offset = recovery.expectedOffset
                    log("4階調の第2プレーンをFWの受信位置から再開します。\n")
                } else {
                    session.resetCurrentPlane()
                    log("MCU再起動を検出。保存済み第1プレーンから第2プレーンを再送します。\n")
                }
            } else if (
                session.format == NativeImageFormat.FORMAT_GRAY4 &&
                session.planeIndex == 1 &&
                !recovery.hasGrayPlane0Pending
            ) {
                session.resetProgress()
                log("保存済み第1プレーンがないため、4階調画像を先頭から再送します。\n")
            }
            if (!session.recoveryChecked) {
                if (
                    session.format == NativeImageFormat.FORMAT_DOT_DENSITY &&
                    (recovery.hasPendingImage || recovery.state == 7)
                ) {
                    session.requestClean()
                    log("前回の中断状態を検出。クリーニングを自動追加します。\n")
                }
                session.prepareCleaning(recovery.supportsBatchClean)
                when {
                    session.batchClean ->
                        log("FW一括クリーニング: 画像転送後に白→黒→白→本画像を連続実行します。\n")
                    session.cleanRequested ->
                        log("旧FW互換モード: Androidから白→黒→白を順次実行します。\n")
                    else -> log("高速モード: 追加クリーニングを省略します。\n")
                }
                session.recoveryChecked = true
            }

            if (!session.cleanComplete()) {
                stage = "画面クリーニング"
                updateWriteProgress(
                    progress = 0.12f,
                    currentStep = 2,
                    status = "画面をクリーニング中",
                    detail = "前の表示を消してから画像データを送信します。",
                )
                runImageCleanSequence(mailbox, session)
            }

            val maxChunk = minOf(240, nfc.maxTransceiveLength - 28)
            check(maxChunk >= 32) { "NFC転送長が不足しています" }
            session.maxChunk = maxChunk
            log("接続: maxTx=${nfc.maxTransceiveLength}, DATA payload=$maxChunk\n")
            updateWriteProgress(
                progress = imageTransferProgress(session.overallOffset(), session.image.size),
                currentStep = 2,
                status = "画像データを送信中",
                detail = transferDetail(session),
            )

            var complete: Ack? = null
            transferLoop@ while (true) {
                if (session.started) {
                    log(
                        String.format(
                            Locale.US,
                            "前回の進捗から再開: %,d / %,d bytes（seq=%d）\n",
                            session.overallOffset(),
                            session.image.size,
                            session.sequence,
                        ),
                    )
                }

                while (!session.committed) {
                    if (!session.started) {
                        stage = "START送信（${session.planeLabel()}）"
                        val ack = mailbox.exchange(
                            NamecardProtocol.frame(1, transferId, 0, 0, session.metadata()),
                        )
                        ack.requireSuccess()
                        session.started = true
                        session.sequence = ack.expectedSequence
                        session.offset = ack.expectedOffset
                        transferredBytes = session.overallOffset()
                        val frameGap = frameGapMs(ack.vddMv)
                        log("${session.planeLabel()} START ACK。転送間隔=${frameGap}ms。\n")
                        updateWriteProgress(
                            progress = imageTransferProgress(
                                session.overallOffset(),
                                session.image.size,
                            ),
                            currentStep = 2,
                            status = "画像データを送信中",
                            detail = transferDetail(session),
                        )
                        delay(frameGap)
                        continue
                    }

                    if (session.offset < IMAGE_SIZE) {
                        val offset = session.offset
                        val end = minOf(offset + maxChunk, IMAGE_SIZE)
                        val base = session.planeIndex * IMAGE_SIZE
                        val chunk = session.image.copyOfRange(base + offset, base + end)
                        stage = "${session.planeLabel()} DATA $offset–$end bytes"
                        val ack = mailbox.exchange(
                            NamecardProtocol.frame(2, transferId, session.sequence, offset, chunk),
                        )

                        if (ack.error == 7) {
                            if (
                                session.format == NativeImageFormat.FORMAT_GRAY4 &&
                                session.planeIndex == 1 &&
                                ack.hasGrayPlane0Pending
                            ) {
                                session.resetCurrentPlane()
                            } else {
                                session.resetProgress()
                            }
                            transferredBytes = session.overallOffset()
                            log("MCU再起動を検出。保存済み位置から自動再開します。\n")
                            continue
                        }
                        if (
                            (ack.error == 8 || ack.error == 9) &&
                            ack.expectedOffset in 0..IMAGE_SIZE
                        ) {
                            if (
                                session.format == NativeImageFormat.FORMAT_GRAY4 &&
                                session.planeIndex == 1 &&
                                ack.expectedOffset == IMAGE_SIZE &&
                                session.offset < IMAGE_SIZE
                            ) {
                                session.resetCurrentPlane()
                                log("第2プレーンのRAM消失を検出。STARTから再送します。\n")
                            } else {
                                session.sequence = ack.expectedSequence
                                session.offset = ack.expectedOffset
                                log("FWの期待位置へ再同期しました。\n")
                            }
                            transferredBytes = session.overallOffset()
                            continue
                        }

                        ack.requireSuccess()
                        session.sequence = ack.expectedSequence
                        session.offset = ack.expectedOffset
                        transferredBytes = session.overallOffset()
                        log(
                            String.format(
                                Locale.US,
                                "%,d / %,d bytes, VDD=%dmV\n",
                                transferredBytes,
                                session.image.size,
                                ack.vddMv,
                            ),
                        )
                        updateWriteProgress(
                            progress = imageTransferProgress(transferredBytes, session.image.size),
                            currentStep = 2,
                            status = "画像データを送信中",
                            detail = transferDetail(session),
                        )
                        if (session.offset < IMAGE_SIZE) delay(frameGapMs(ack.vddMv))
                        continue
                    }

                    stage = "${session.planeLabel()} COMMIT送信"
                    val ack = mailbox.exchange(
                        NamecardProtocol.frame(
                            3,
                            transferId,
                            session.sequence,
                            IMAGE_SIZE,
                            byteArrayOf(),
                        ),
                    )
                    if (ack.error == 7) {
                        if (
                            session.format == NativeImageFormat.FORMAT_GRAY4 &&
                            session.planeIndex == 1 &&
                            ack.hasGrayPlane0Pending
                        ) {
                            session.resetCurrentPlane()
                        } else {
                            session.resetProgress()
                        }
                        transferredBytes = session.overallOffset()
                        continue
                    }
                    ack.requireSuccess()
                    session.sequence = ack.expectedSequence
                    session.offset = ack.expectedOffset
                    session.committed = true
                    if (
                        session.format == NativeImageFormat.FORMAT_GRAY4 &&
                        session.planeIndex == 0
                    ) {
                        updateWriteProgress(
                            progress = imageTransferProgress(
                                session.overallOffset(),
                                session.image.size,
                            ),
                            currentStep = 2,
                            status = "第1プレーンを確認しました",
                            detail = "名刺へ保存してから第2プレーンを送信します。",
                        )
                    } else {
                        updateWriteProgress(
                            progress = maxOf(
                                0.73f,
                                imageTransferProgress(session.overallOffset(), session.image.size),
                            ),
                            currentStep = 3,
                            status = "データ転送を確認しました",
                            detail = "表示更新に必要な電力を充電しています。",
                        )
                    }
                }

                var sequence = session.sequence
                var firstChargeWait = true
                while (complete == null) {
                    if (firstChargeWait) {
                        log("VRES充電のためRF通信を1.5秒停止します。位置を固定してください。\n")
                        delay(CHARGE_QUIET_MS)
                        firstChargeWait = false
                    }

                    var ready: Ack
                    do {
                        stage = "充電STATUS確認"
                        ready = mailbox.exchange(
                            NamecardProtocol.frame(4, transferId, sequence, IMAGE_SIZE, byteArrayOf()),
                        )
                        ready.requireSuccess()
                        log("充電: state=${ready.state} VDD=${ready.vddMv}mV min=${ready.minimumVddMv}mV\n")
                        if (ready.state == 6) {
                            complete = ready
                            break
                        }
                        if (ready.state == 1) {
                            if (
                                session.format == NativeImageFormat.FORMAT_GRAY4 &&
                                session.planeIndex == 0 &&
                                ready.hasGrayPlane0Pending
                            ) {
                                break
                            }
                            if (
                                session.format == NativeImageFormat.FORMAT_GRAY4 &&
                                session.planeIndex == 1 &&
                                ready.hasGrayPlane0Pending
                            ) {
                                session.resetCurrentPlane()
                            } else {
                                session.resetProgress()
                            }
                            error("MCUが電源断しました。保存済み位置から再送します")
                        }
                        if (ready.state != 3) delay(1_000L)
                    } while (ready.state != 3)
                    if (complete != null) break

                    sequence = ready.expectedSequence
                    if (
                        session.format == NativeImageFormat.FORMAT_GRAY4 &&
                        session.planeIndex == 0
                    ) {
                        session.advancePlane()
                        transferredBytes = session.overallOffset()
                        log("第1プレーンをFlashへ保存しました。第2プレーンを送信します。\n")
                        updateWriteProgress(
                            progress = imageTransferProgress(transferredBytes, session.image.size),
                            currentStep = 2,
                            status = "第2プレーンを送信します",
                            detail = transferDetail(session),
                        )
                        continue@transferLoop
                    }

                    stage = "EXECUTE送信"
                    var ack = mailbox.exchange(
                        NamecardProtocol.frame(5, transferId, sequence, IMAGE_SIZE, byteArrayOf()),
                    )
                    ack.requireSuccess()
                    sequence = ack.expectedSequence
                    session.sequence = sequence
                    session.executeSent = true
                    if (ack.batchCleanActive) session.batchClean = true
                    val quiet = when {
                        session.format == NativeImageFormat.FORMAT_GRAY4 -> maxOf(60_000, ack.quietMs)
                        session.batchClean -> maxOf(1_000, ack.quietMs)
                        else -> maxOf(2_000, ack.quietMs)
                    }
                    log(
                        when {
                            session.format == NativeImageFormat.FORMAT_GRAY4 ->
                                "EXECUTE ACK。32行ごとにEPDを再初期化し、独立して4階調更新します。\n"
                            session.batchClean ->
                                "EXECUTE ACK。FWが白→黒→白→本画像を連続実行します。\n"
                            else -> "EXECUTE ACK受信。表示を更新します。\n"
                        },
                    )
                    updateWriteProgress(
                        progress = 0.78f,
                        currentStep = 3,
                        status = "e-paperを更新中",
                        detail = "表示パネルを書き換えています。端末を固定してください。",
                    )
                    delayWithWriteProgress(
                        durationMs = quiet + 250L,
                        from = 0.78f,
                        to = 0.90f,
                    )

                    do {
                        stage = when {
                            session.format == NativeImageFormat.FORMAT_GRAY4 ->
                                "4階調帯域更新進捗確認"
                            session.batchClean -> "FW一括クリーニング進捗確認"
                            else -> "更新完了STATUS確認"
                        }
                        val progress = mailbox.exchange(
                            NamecardProtocol.frame(4, transferId, sequence, IMAGE_SIZE, byteArrayOf()),
                            if (session.multiStageUpdate()) BATCH_STATUS_TIMEOUT_MS else 1_500L,
                        )
                        complete = progress
                        progress.requireSuccess()
                        updateWriteProgress(
                            progress = if (progress.state == 6) 0.98f else 0.92f,
                            currentStep = 3,
                            status = if (progress.state == 6) {
                                "表示更新を確認しました"
                            } else {
                                "e-paperを更新中"
                            },
                            detail = if (progress.state == 6) {
                                "最終確認をしています。"
                            } else {
                                "名刺側の処理完了を待っています。"
                            },
                        )
                        if (progress.state == 6) break
                        if (progress.state == 1) {
                            if (
                                session.format == NativeImageFormat.FORMAT_GRAY4 &&
                                progress.hasGrayPlane0Pending
                            ) {
                                session.resetCurrentPlane()
                            } else {
                                session.resetProgress()
                            }
                            session.executeSent = false
                            error("更新中に電源断しました。保存済み位置から再送します")
                        }
                        check(session.multiStageUpdate()) {
                            "更新後state=${progress.state} error=${progress.error}"
                        }
                        log(
                            if (session.format == NativeImageFormat.FORMAT_GRAY4) {
                                "4階調帯域更新中: state=${progress.state} VDD=${progress.vddMv}mV " +
                                    "min=${progress.minimumVddMv}mV\n"
                            } else {
                                "FW一括更新中: state=${progress.state} VDD=${progress.vddMv}mV " +
                                    "min=${progress.minimumVddMv}mV\n"
                            },
                        )
                        if (progress.state == 3) {
                            if (session.format == NativeImageFormat.FORMAT_GRAY4) {
                                delay(5_000L)
                                continue
                            }
                            sequence = progress.expectedSequence
                            complete = null
                            firstChargeWait = true
                            break
                        }
                        delay(1_000L)
                    } while (complete.state != 6)
                }
                if (complete?.state == 6) break
            }

            val finished = checkNotNull(complete)
            log("完了: VDD=${finished.vddMv}mV, 更新中min=${finished.minimumVddMv}mV\n")
            imageTransferSession = null
            pendingMode = MODE_NONE
            completeWriteProgress("画像の書き込みが完了しました。")
        } catch (error: TagLostException) {
            markNfcLinkLost()
            log(
                "タグを見失いました: $stage" +
                    if (mode == MODE_IMAGE) {
                        "（$transferredBytes / ${activeSession?.image?.size ?: IMAGE_SIZE} bytes）"
                    } else {
                        ""
                    } +
                    "\n進捗を保持しました。位置を合わせてそのまま再タッチしてください。\n",
            )
            if (mode == MODE_IMAGE) {
                interruptWriteProgress(
                    status = "名刺を見失いました",
                    detail = "${transferredBytes} / ${activeSession?.image?.size ?: IMAGE_SIZE} bytesまで保持しています。位置を合わせて再タッチしてください。",
                )
            } else if (mode == MODE_URL) {
                interruptWriteProgress(
                    status = "名刺を見失いました",
                    detail = "URL書き込みを完了できませんでした。一度離してから再タッチしてください。",
                )
            }
            restartReader = true
        } catch (error: IOException) {
            markNfcLinkLost()
            log(
                "NFC通信が中断しました: $stage: ${error.message}" +
                    if (mode == MODE_IMAGE) {
                        "\n画像の進捗を保持しました。位置を合わせて再タッチしてください。\n"
                    } else {
                        "\n位置を合わせて再タッチしてください。\n"
                    },
            )
            if (mode == MODE_IMAGE) {
                interruptWriteProgress(
                    status = "NFC通信が中断しました",
                    detail = "進捗は保持されています。位置を合わせて再タッチしてください。",
                )
            } else if (mode == MODE_URL) {
                interruptWriteProgress(
                    status = "NFC通信が中断しました",
                    detail = "URL書き込みを完了できませんでした。一度離してから再タッチしてください。",
                )
            }
            restartReader = true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            log(
                "失敗: $stage: ${error.message}" +
                    when (mode) {
                        MODE_IMAGE -> "\n画像の進捗を保持しました。そのまま再タッチしてください。\n"
                        MODE_URL -> "\nURL設定を中止しました。内容を確認してやり直してください。\n"
                        MODE_PATTERN_SEQUENCE ->
                            "\n次のパターン番号を保持しました。位置を合わせてそのまま再タッチしてください。\n"
                        else -> "\nもう一度試験を選んでタッチしてください。\n"
                    },
            )
            if (mode == MODE_IMAGE) {
                interruptWriteProgress(
                    status = "書き込みを完了できませんでした",
                    detail = "${error.message ?: "進捗は保持されています"}。位置を合わせて再タッチしてください。",
                )
            } else if (mode == MODE_URL) {
                pendingMode = MODE_NONE
                pendingUrl = null
                interruptWriteProgress(
                    status = "URLを書き込めませんでした",
                    detail = error.message ?: "名刺側FWとURLを確認してください。",
                )
                refreshReaderMode()
            }
            restartReader = mode == MODE_PATTERN_SEQUENCE
        } finally {
            nfc?.runCatching { close() }
            if (activeNfc === nfc) activeNfc = null
            running.set(false)
            setControlsEnabled(true)
        }
        if (restartReader) restartReaderModeAfterLoss(tag)
    }

    private suspend fun runUrlWrite(
        tag: Tag,
        initialNfc: NfcV,
        url: String,
        setStage: (String) -> Unit,
    ) {
        val message = NdefMessage(arrayOf(NdefRecord.createUri(url)))
        val expected = message.toByteArray()
        require(expected.size <= MAX_URL_NDEF_BYTES) {
            "URLが長すぎます。短いURLを使用してください"
        }

        var mailboxPaused = false
        try {
            setStage("名刺側FWのURL書き込み準備")
            updateWriteProgress(
                progress = 0.18f,
                currentStep = 1,
                status = "URL書き込みを準備中",
                detail = "画像転送用Mailboxを安全に停止しています。",
            )
            delay(BOOT_QUIET_MS)
            val mailbox = St25Mailbox(initialNfc, tag.id)
            mailbox.enable()
            val transferId = (System.currentTimeMillis() and 0xffff).toInt()
            val ack = mailbox.exchange(
                NamecardProtocol.frame(
                    TYPE_NDEF_WRITE_PREPARE,
                    transferId,
                    0,
                    0,
                    byteArrayOf(),
                ),
            )
            check(ack.error != ERROR_COMMAND) {
                "名刺側FWがURL書き込みに未対応です。先にFWを更新してください"
            }
            ack.requireSuccess()
            mailbox.disable()
            mailboxPaused = true
            initialNfc.close()
            if (activeNfc === initialNfc) activeNfc = null

            setStage("NDEF URL書き込み")
            updateWriteProgress(
                progress = 0.48f,
                currentStep = 2,
                status = "URLを書き込み中",
                detail = "完了するまで名刺を動かさないでください。",
            )
            writeNdefMessage(tag, message)

            setStage("NDEF読み返し確認")
            updateWriteProgress(
                progress = 0.82f,
                currentStep = 3,
                status = "URLを確認中",
                detail = "書き込んだ内容を読み返しています。",
            )
            val verifyNfc = checkNotNull(NfcV.get(tag)) { "NFC-Vタグではありません" }
            activeNfc = verifyNfc
            try {
                verifyNfc.connect()
                val verifier = St25Mailbox(verifyNfc, tag.id)
                val actual = verifier.readNdefMessage(expected.size)
                check(actual.contentEquals(expected)) {
                    "URLの読み返し内容が一致しません"
                }
                verifier.enable()
                mailboxPaused = false
            } finally {
                verifyNfc.runCatching { close() }
                if (activeNfc === verifyNfc) activeNfc = null
            }
        } finally {
            if (mailboxPaused && tryResumeMailbox(tag)) {
                log("URL処理後にMailboxを再開しました。\n")
            }
        }
    }

    private fun writeNdefMessage(tag: Tag, message: NdefMessage) {
        val ndef = Ndef.get(tag)
        if (ndef != null) {
            try {
                ndef.connect()
                check(ndef.isWritable) { "この名刺のURL領域は書き込み禁止です" }
                check(message.toByteArray().size <= ndef.maxSize) {
                    "URLが名刺のNDEF容量を超えています"
                }
                ndef.writeNdefMessage(message)
            } finally {
                ndef.runCatching { close() }
            }
            return
        }

        val formatable = NdefFormatable.get(tag)
            ?: error("この端末では未フォーマットの名刺をNDEF化できません")
        try {
            formatable.connect()
            formatable.format(message)
        } finally {
            formatable.runCatching { close() }
        }
    }

    private suspend fun tryResumeMailbox(tag: Tag): Boolean {
        val nfc = NfcV.get(tag) ?: return false
        return try {
            activeNfc = nfc
            nfc.connect()
            St25Mailbox(nfc, tag.id).enable()
            true
        } catch (_: Exception) {
            false
        } finally {
            nfc.runCatching { close() }
            if (activeNfc === nfc) activeNfc = null
        }
    }

    private suspend fun runPatternUpdate(mailbox: St25Mailbox, patternId: Int) {
        val transferId = ((System.currentTimeMillis() + patternId) and 0xffff).toInt()
        var ack = mailbox.exchange(
            NamecardProtocol.frame(6, transferId, 0, 0, byteArrayOf(patternId.toByte())),
        )
        ack.requireSuccess()
        log("PATTERN $patternId ACK: VDD=${ack.vddMv}mV。VRESを充電します。\n")

        delay(CHARGE_QUIET_MS)
        do {
            ack = mailbox.exchange(NamecardProtocol.frame(4, transferId, 1, IMAGE_SIZE, byteArrayOf()))
            ack.requireSuccess()
            log("充電: state=${ack.state} VDD=${ack.vddMv}mV min=${ack.minimumVddMv}mV\n")
            if (ack.state != 3) delay(1_000L)
        } while (ack.state != 3)

        ack = mailbox.exchange(NamecardProtocol.frame(5, transferId, 1, IMAGE_SIZE, byteArrayOf()))
        ack.requireSuccess()
        var sequence = ack.expectedSequence
        val firmwareBatch = ack.batchCleanActive
        var complete: Ack
        while (true) {
            val quiet = if (firmwareBatch) maxOf(1_000, ack.quietMs) else maxOf(2_000, ack.quietMs)
            log("EXECUTE ACK。${quiet}ms、RF通信を停止します。\n")
            delay(quiet + 250L)

            complete = mailbox.exchange(
                NamecardProtocol.frame(4, transferId, sequence, IMAGE_SIZE, byteArrayOf()),
                if (firmwareBatch) BATCH_STATUS_TIMEOUT_MS else 1_500L,
            )
            complete.requireSuccess()
            if (complete.state == 6) break
            check(firmwareBatch) { "PATTERN $patternId 更新後state=${complete.state}" }
            log(
                "PATTERNクリーニング中: state=${complete.state} VDD=${complete.vddMv}mV " +
                    "min=${complete.minimumVddMv}mV\n",
            )
            if (complete.state == 3) {
                sequence = complete.expectedSequence
                ack = mailbox.exchange(
                    NamecardProtocol.frame(5, transferId, sequence, IMAGE_SIZE, byteArrayOf()),
                )
                ack.requireSuccess()
                sequence = ack.expectedSequence
            } else {
                delay(1_000L)
            }
        }
        log("PATTERN $patternId 完了: VDD=${complete.vddMv}mV, 更新中min=${complete.minimumVddMv}mV\n")
    }

    private suspend fun runImageCleanSequence(
        mailbox: St25Mailbox,
        session: ImageTransferSession,
    ) {
        while (!session.cleanComplete()) {
            val step = session.cleanStep
            log(
                "画面クリーニング ${step + 1}/${CLEAN_PATTERN_IDS.size}: " +
                    "全面${CLEAN_PATTERN_NAMES[step]}。Pixelを固定してください。\n",
            )
            runPatternUpdate(mailbox, CLEAN_PATTERN_IDS[step])
            session.cleanStep = step + 1
        }
        log("画面を白へリセットしました。本画像の転送を開始します。\n")
    }

    private fun showWriteProgressIfNeeded() {
        ui.post {
            if (screenState.writeProgress == null) {
                screenState = screenState.copy(
                    writeProgress = WriteProgressState(
                        title = imageName,
                        antennaGuide = antennaGuide,
                    ),
                )
            }
        }
    }

    private fun showUrlWriteProgressIfNeeded() {
        ui.post {
            if (screenState.writeProgress == null) {
                screenState = screenState.copy(
                    writeProgress = WriteProgressState(
                        title = "URL設定",
                        detail = "URLを書き込む名刺へタッチしてください。",
                        antennaGuide = antennaGuide,
                    ),
                )
            }
        }
    }

    private fun readNfcAntennaGuide(): NfcAntennaGuide {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return NfcAntennaGuide.fallback()
        }
        return runCatching {
            val info = adapter?.nfcAntennaInfo ?: return@runCatching null
            nfcAntennaGuide(
                deviceWidthMm = info.deviceWidth,
                deviceHeightMm = info.deviceHeight,
                locationsMm = info.availableNfcAntennas.map { antenna ->
                    antenna.locationX to antenna.locationY
                },
            )
        }.getOrNull() ?: NfcAntennaGuide.fallback()
    }

    private fun observeNfcLink(ack: Ack, responseMillis: Long, requestType: Int) {
        if (requestType == 2) lastDataResponseMillis = responseMillis
        recentLinkIssues = if (ack.error != 0) {
            (recentLinkIssues + 1).coerceAtMost(3)
        } else if (requestType == 2) {
            (recentLinkIssues - 1).coerceAtLeast(0)
        } else {
            recentLinkIssues
        }
        val status = nfcLinkStatus(ack.vddMv, lastDataResponseMillis, recentLinkIssues)
        ui.post {
            val current = screenState.writeProgress ?: return@post
            screenState = screenState.copy(
                writeProgress = current.copy(linkStatus = status),
            )
        }
    }

    private fun markNfcLinkLost() {
        recentLinkIssues = 3
        ui.post {
            val current = screenState.writeProgress ?: return@post
            val previous = current.linkStatus
            screenState = screenState.copy(
                writeProgress = current.copy(
                    linkStatus = NfcLinkStatus(
                        level = NfcLinkLevel.LOST,
                        vddMv = previous?.vddMv ?: 0,
                        responseMillis = previous?.responseMillis ?: 0,
                        recentIssues = recentLinkIssues,
                    ),
                ),
            )
        }
    }

    private fun updateWriteProgress(
        progress: Float,
        currentStep: Int,
        status: String,
        detail: String,
    ) {
        ui.post {
            val current = screenState.writeProgress ?: return@post
            val nextProgress = if (currentStep == 2) {
                progress
            } else {
                maxOf(current.progress, progress)
            }
            screenState = screenState.copy(
                writeProgress = current.copy(
                    progress = nextProgress.coerceIn(0f, 1f),
                    currentStep = currentStep.coerceIn(1, 4),
                    status = status,
                    detail = detail,
                    outcome = WriteProgressOutcome.RUNNING,
                    canCancel = false,
                ),
            )
        }
    }

    private fun completeWriteProgress(detail: String) {
        ui.post {
            val current = screenState.writeProgress ?: return@post
            screenState = screenState.copy(
                writeProgress = current.copy(
                    progress = 1f,
                    currentStep = 4,
                    status = "書き込み完了",
                    detail = detail,
                    outcome = WriteProgressOutcome.COMPLETE,
                    canCancel = false,
                ),
            )
        }
    }

    private fun interruptWriteProgress(status: String, detail: String) {
        ui.post {
            val current = screenState.writeProgress ?: return@post
            screenState = screenState.copy(
                writeProgress = current.copy(
                    status = status,
                    detail = detail,
                    outcome = WriteProgressOutcome.INTERRUPTED,
                    canCancel = false,
                ),
            )
        }
    }

    private suspend fun delayWithWriteProgress(
        durationMs: Long,
        from: Float,
        to: Float,
    ) {
        var elapsed = 0L
        while (elapsed < durationMs) {
            val interval = minOf(PROGRESS_UPDATE_INTERVAL_MS, durationMs - elapsed)
            delay(interval)
            elapsed += interval
            val ratio = elapsed.toFloat() / durationMs.coerceAtLeast(1L)
            updateWriteProgress(
                progress = from + (to - from) * ratio,
                currentStep = 3,
                status = "e-paperを更新中",
                detail = "表示更新の推定進捗です。端末を固定したままお待ちください。",
            )
        }
    }

    private fun transferDetail(session: ImageTransferSession): String {
        val sent = session.overallOffset().coerceIn(0, session.image.size)
        val percent = if (session.image.isEmpty()) {
            0
        } else {
            (sent * 100f / session.image.size).roundToInt()
        }
        return "$sent / ${session.image.size} bytes（$percent%）・${session.planeLabel()}"
    }

    private fun setControlsEnabled(enabled: Boolean) {
        ui.post {
            screenState = screenState.copy(controlsEnabled = enabled)
        }
    }

    private fun log(message: String) {
        ui.post {
            screenState = screenState.copy(statusText = screenState.statusText + message)
        }
    }

    private fun ByteArray.toHex(): String = joinToString(separator = "") {
        String.format(Locale.US, "%02X", it.toInt() and 0xff)
    }

    private companion object {
        const val MODE_NONE = 0
        const val MODE_STATUS = 1
        const val MODE_PATTERN = 2
        const val MODE_IMAGE = 3
        const val MODE_PATTERN_SEQUENCE = 4
        const val MODE_URL = 5
        const val TYPE_NDEF_WRITE_PREPARE = 7
        const val ERROR_COMMAND = 6
        const val MAX_URL_NDEF_BYTES = 480
        const val PATTERN_COUNT = 10
        const val BATCH_STATUS_TIMEOUT_MS = 3_500L
        const val BOOT_QUIET_MS = 1_500L
        const val CHARGE_QUIET_MS = 1_500L
        const val FRAME_GAP_STRONG_MS = 50L
        const val FRAME_GAP_NORMAL_MS = 200L
        const val FRAME_GAP_WEAK_MS = 500L
        const val VDD_STRONG_MV = 3_200
        const val VDD_NORMAL_MV = 3_050
        const val TAG_REMOVAL_DEBOUNCE_MS = 250
        const val PROGRESS_UPDATE_INTERVAL_MS = 1_000L
        const val MAX_DECODE_SIDE = 2048

        val patternNames = arrayOf(
            "1. チェック柄",
            "2. NFC OK（文字）",
            "3. 全面黒",
            "4. 全面白",
            "5. 長辺方向の縞",
            "6. 短辺方向の縞",
            "7. グリッド",
            "8. 斜線",
            "9. ターゲット",
            "10. TEST 10（文字）",
        )

        fun formatName(format: Int): String =
            if (format == NativeImageFormat.FORMAT_GRAY4) "4階調" else "ドット密度"

        fun frameGapMs(vddMv: Int): Long = when {
            vddMv >= VDD_STRONG_MV -> FRAME_GAP_STRONG_MS
            vddMv >= VDD_NORMAL_MV -> FRAME_GAP_NORMAL_MS
            else -> FRAME_GAP_WEAK_MS
        }
    }

    private data class PendingExport(
        val bytes: ByteArray,
        val fileName: String,
    )
}
