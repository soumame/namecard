package jp.namecard.nfctest

import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.TagLostException
import android.nfc.tech.NfcV
import android.net.Uri
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
    private var image: ByteArray? = null
    private var imageFormat = NativeImageFormat.FORMAT_DOT_DENSITY

    @Volatile
    private var imageTransferSession: ImageTransferSession? = null

    @Volatile
    private var pendingMode = MODE_NONE

    @Volatile
    private var selectedPatternId = 1

    @Volatile
    private var continuousNextPattern = 1

    @Volatile
    private var cleanImageBeforeWrite = true

    private val binPicker = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) loadNativeImage(uri)
    }

    private val editorLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == RESULT_OK) handleEditorResult(result.data)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        adapter = NfcAdapter.getDefaultAdapter(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enableEdgeToEdge()
        setContent {
            NamecardTheme {
                MainScreen(
                    state = screenState,
                    patternNames = patternNames,
                    onStatusCheck = ::selectStatusCheck,
                    onPatternSelected = { patternId ->
                        selectedPatternId = patternId
                        screenState = screenState.copy(selectedPatternId = patternId)
                    },
                    onPatternWrite = ::selectPattern,
                    onPatternSequence = ::selectPatternSequence,
                    onImageFormatSelected = { format ->
                        imageFormat = format
                        screenState = screenState.copy(selectedImageFormat = format)
                    },
                    onCleanChanged = { checked ->
                        cleanImageBeforeWrite = checked
                        screenState = screenState.copy(cleanBeforeWrite = checked)
                    },
                    onOpenEditor = ::openEditor,
                    onChooseBin = ::chooseImage,
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

    private fun chooseImage() {
        binPicker.launch(arrayOf("application/octet-stream"))
    }

    private fun openEditor() {
        editorLauncher.launch(
            Intent(this, EditorActivity::class.java).apply {
                putExtra(EditorActivity.EXTRA_IMAGE_FORMAT, imageFormat)
            },
        )
    }

    private fun handleEditorResult(data: Intent?) {
        data ?: return
        val edited = data.getByteArrayExtra(EditorActivity.EXTRA_NATIVE_IMAGE)
        val format = data.getIntExtra(
            EditorActivity.EXTRA_IMAGE_FORMAT,
            NativeImageFormat.FORMAT_DOT_DENSITY,
        )
        if (edited == null || edited.size != NativeImageFormat.byteCountForFormat(format)) {
            log("エディター画像エラー: 出力方式とBINサイズが一致しません。\n")
            return
        }
        imageFormat = format
        screenState = screenState.copy(selectedImageFormat = format)
        prepareImageTransfer(edited, "エディター画像", format)
    }

    private fun loadNativeImage(uri: Uri) {
        try {
            val selected = contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "ファイルを開けません" }
                input.readBytes()
            }
            val format = imageFormat
            val expectedSize = NativeImageFormat.byteCountForFormat(format)
            require(selected.size == expectedSize) {
                String.format(Locale.US, "選択方式の画像は正確に%,dバイト必要です", expectedSize)
            }
            var name = "image.bin"
            contentResolver.query(uri, null, null, null, null).use { cursor ->
                if (cursor != null && cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) name = cursor.getString(index)
                }
            }
            prepareImageTransfer(selected, name, format)
        } catch (error: Exception) {
            log("画像読込エラー: ${error.message}\n")
        }
    }

    private fun prepareImageTransfer(selected: ByteArray, name: String, format: Int) {
        image = selected.copyOf()
        imageFormat = format
        imageTransferSession = null
        pendingMode = MODE_IMAGE
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
        transferScope.cancel()
        super.onDestroy()
    }

    private fun enableReaderMode() {
        val nfcAdapter = adapter ?: return
        if (!readerModeActive || !nfcAdapter.isEnabled) return
        val options = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 120_000)
        }
        nfcAdapter.enableReaderMode(
            this,
            ::handleTag,
            NfcAdapter.FLAG_READER_NFC_V or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
            options,
        )
    }

    private fun restartReaderModeAfterLoss() {
        ui.post {
            val nfcAdapter = adapter ?: return@post
            if (!readerModeActive || isFinishing || isDestroyed) return@post
            nfcAdapter.disableReaderMode(this)
            ui.postDelayed({
                if (!readerModeActive || isFinishing || isDestroyed) return@postDelayed
                enableReaderMode()
                log("NFC探索を再開しました。そのまま位置を合わせてください。\n")
            }, READER_RESTART_DELAY_MS)
        }
    }

    private fun handleTag(tag: Tag?) {
        val mode = pendingMode
        if (tag == null) return
        if (mode == MODE_NONE) {
            log("NFC-Vタグを検出しました。先に試験ボタンを選んでください。\n")
            return
        }
        val selectedImage = image
        if ((mode == MODE_IMAGE && selectedImage == null) || !running.compareAndSet(false, true)) {
            return
        }
        log(
            "NFC-V検出 UID=${tag.id.toHex()}" +
                if (mode == MODE_STATUS) {
                    "。MCU起動を待ちます。\n"
                } else {
                    "。MCU起動・VRES充電を待ちます。\n"
                },
        )
        val transferImage = if (mode == MODE_IMAGE) selectedImage?.copyOf() else null
        val transferImageFormat = imageFormat
        val patternId = selectedPatternId
        setControlsEnabled(false)
        transferScope.launch {
            transfer(tag, mode, transferImage, transferImageFormat, patternId)
        }
    }

    private suspend fun transfer(
        tag: Tag,
        mode: Int,
        transferImage: ByteArray?,
        transferImageFormat: Int,
        patternId: Int,
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
            val mailbox = St25Mailbox(nfc, tag.id)
            delay(BOOT_QUIET_MS)
            stage = "Mailbox有効化"
            mailbox.enable()

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
                transferredBytes = requireNotNull(activeSession).offset
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
                runImageCleanSequence(mailbox, session)
            }

            val maxChunk = minOf(240, nfc.maxTransceiveLength - 28)
            check(maxChunk >= 32) { "NFC転送長が不足しています" }
            session.maxChunk = maxChunk
            log("接続: maxTx=${nfc.maxTransceiveLength}, DATA payload=$maxChunk\n")

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
                    delay(quiet + 250L)

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
        } catch (error: TagLostException) {
            log(
                "タグを見失いました: $stage" +
                    if (mode == MODE_IMAGE) {
                        "（$transferredBytes / ${activeSession?.image?.size ?: IMAGE_SIZE} bytes）"
                    } else {
                        ""
                    } +
                    "\n進捗を保持しました。位置を合わせてそのまま再タッチしてください。\n",
            )
            restartReader = true
        } catch (error: IOException) {
            log(
                "NFC通信が中断しました: $stage: ${error.message}" +
                    if (mode == MODE_IMAGE) {
                        "\n画像の進捗を保持しました。位置を合わせて再タッチしてください。\n"
                    } else {
                        "\n位置を合わせて再タッチしてください。\n"
                    },
            )
            restartReader = true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            log(
                "失敗: $stage: ${error.message}" +
                    when (mode) {
                        MODE_IMAGE -> "\n画像の進捗を保持しました。そのまま再タッチしてください。\n"
                        MODE_PATTERN_SEQUENCE ->
                            "\n次のパターン番号を保持しました。位置を合わせてそのまま再タッチしてください。\n"
                        else -> "\nもう一度試験を選んでタッチしてください。\n"
                    },
            )
            restartReader = mode == MODE_PATTERN_SEQUENCE
        } finally {
            nfc?.runCatching { close() }
            if (activeNfc === nfc) activeNfc = null
            running.set(false)
            setControlsEnabled(true)
        }
        if (restartReader) restartReaderModeAfterLoss()
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
        const val PATTERN_COUNT = 10
        const val BATCH_STATUS_TIMEOUT_MS = 3_500L
        const val BOOT_QUIET_MS = 1_500L
        const val CHARGE_QUIET_MS = 1_500L
        const val FRAME_GAP_STRONG_MS = 50L
        const val FRAME_GAP_NORMAL_MS = 200L
        const val FRAME_GAP_WEAK_MS = 500L
        const val VDD_STRONG_MV = 3_200
        const val VDD_NORMAL_MV = 3_050
        const val READER_RESTART_DELAY_MS = 300L

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
}
