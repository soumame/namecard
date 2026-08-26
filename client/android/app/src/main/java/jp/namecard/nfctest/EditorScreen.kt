package jp.namecard.nfctest

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateRotation
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import kotlin.math.min

internal data class EditorScreenState(
    val selectedFormat: Int,
    val controlsEnabled: Boolean = true,
    val message: String = "オブジェクトをドラッグ、2本指で拡大・縮小・回転できます。",
)

@Composable
internal fun EditorScreen(
    state: EditorScreenState,
    canvasState: EditorCanvasState,
    onFormatSelected: (Int) -> Unit,
    onAddText: (String) -> Unit,
    onPickImage: () -> Unit,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onMoveBackward: () -> Unit,
    onMoveForward: () -> Unit,
    onDelete: () -> Unit,
    onClear: () -> Unit,
    onSaveToLibrary: (String) -> Unit,
    onExportBin: () -> Unit,
    onWrite: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var showFormatDialog by remember { mutableStateOf(false) }
    var showFileMenu by remember { mutableStateOf(false) }
    var showTextDialog by remember { mutableStateOf(false) }
    var showSaveDialog by remember { mutableStateOf(false) }
    var textInput by remember { mutableStateOf("") }
    var cardName by remember { mutableStateOf("") }
    val viewportState = remember { EditorViewportState() }
    val selectionRevision = canvasState.revision
    val hasSelection = remember(selectionRevision) { canvasState.hasSelection }

    Column(
        modifier = modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Surface(tonalElevation = 3.dp) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .windowInsetsPadding(WindowInsets.statusBars)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {

                IconButton(
                    onClick = onUndo,
                    enabled = state.controlsEnabled && canvasState.canUndo,
                ) {
                    Icon(painterResource(R.drawable.ic_undo), contentDescription = "元に戻す")
                }
                IconButton(
                    onClick = onRedo,
                    enabled = state.controlsEnabled && canvasState.canRedo,
                ) {
                    Icon(painterResource(R.drawable.ic_redo), contentDescription = "やり直す")
                }

                Spacer(Modifier.weight(1f))

                TextButton(
                    onClick = { showFormatDialog = true },
                    enabled = state.controlsEnabled,
                    contentPadding = PaddingValues(horizontal = 10.dp),
                ) {
                    Icon(
                        painterResource(R.drawable.ic_tune),
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                    )
//                    Spacer(Modifier.width(5.dp))
//                    Text("Mode · ${NativeImageFormat.displayName(state.selectedFormat)}")
                }

                val pillContainer = if (state.controlsEnabled) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.surfaceVariant
                }
                val pillContent = if (state.controlsEnabled) {
                    MaterialTheme.colorScheme.onPrimary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Button(
                        onClick = onWrite,
                        enabled = state.controlsEnabled,
                        modifier = Modifier.height(48.dp),
                        shape = RoundedCornerShape(
                            topStart = 24.dp,
                            bottomStart = 24.dp,
                            topEnd = 4.dp,
                            bottomEnd = 4.dp,
                        ),
                        contentPadding = PaddingValues(start = 14.dp, end = 12.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = pillContainer,
                            contentColor = pillContent,
                            disabledContainerColor = pillContainer,
                            disabledContentColor = pillContent,
                        ),
                        elevation = ButtonDefaults.buttonElevation(defaultElevation = 0.dp),
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_nfc),
                            contentDescription = null,
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("書き込み")
                    }
                    Spacer(Modifier.width(4.dp))

                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .clickable(
                                enabled = state.controlsEnabled,
                                role = Role.Button,
                                onClick = { showFileMenu = true },
                            )
                            .clip(
                                shape = RoundedCornerShape(
                                topStart = 4.dp,
                                bottomStart = 4.dp,
                                topEnd = 24.dp,
                                bottomEnd = 24.dp,
                            )
                                ,
                            )
                            .background(pillContainer)
                        ,


                        contentAlignment = Alignment.Center,
                    ) {
                        VerticalDivider(
                            modifier = Modifier
                                .align(Alignment.CenterStart)
                                .height(26.dp),
                            color = pillContent.copy(alpha = 0.35f),
                        )
                        Icon(
                            painterResource(R.drawable.ic_arrow_drop_down),
                            contentDescription = "保存とエクスポート",
                            tint = pillContent,
                        )
                        DropdownMenu(
                            expanded = showFileMenu,
                            onDismissRequest = { showFileMenu = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("Libraryに保存") },
                                leadingIcon = {
                                    Icon(
                                        painterResource(R.drawable.ic_save),
                                        contentDescription = null,
                                    )
                                },
                                onClick = {
                                    showFileMenu = false
                                    showSaveDialog = true
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("BINをエクスポート") },
                                leadingIcon = {
                                    Icon(
                                        painterResource(R.drawable.ic_download),
                                        contentDescription = null,
                                    )
                                },
                                onClick = {
                                    showFileMenu = false
                                    onExportBin()
                                },
                            )
                        }
                    }
                }
            }
        }

        Box(
            modifier = Modifier
                .padding(horizontal = 12.dp)
                .fillMaxWidth()
                .weight(1f)
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            EditorCanvas(
                state = canvasState,
                viewportState = viewportState,
                modifier = Modifier.fillMaxSize(),
            )
            if (!viewportState.isDefault) {
                FilledTonalButton(
                    onClick = viewportState::reset,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(8.dp),
                    contentPadding = PaddingValues(horizontal = 10.dp),
                ) {
                    Icon(
                        painter = painterResource(R.drawable.ic_center_focus_strong),
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("表示をリセット")
                }
            }
        }

        Text(
            text = state.message,
            modifier = Modifier.padding(horizontal = 16.dp),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Surface(tonalElevation = 3.dp) {
            Column(
                modifier = Modifier.padding(vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    "編集ツール",
                    modifier = Modifier.padding(horizontal = 16.dp),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    EditorToolButton(
                        label = "画像",
                        iconRes = R.drawable.ic_add_photo_alternate,
                        enabled = state.controlsEnabled,
                        onClick = onPickImage,
                    )
                    EditorToolButton(
                        label = "テキスト",
                        iconRes = R.drawable.ic_text_fields,
                        enabled = state.controlsEnabled,
                        onClick = { showTextDialog = true },
                    )
                    EditorToolButton(
                        label = "背面へ",
                        iconRes = R.drawable.ic_flip_to_back,
                        enabled = state.controlsEnabled && hasSelection,
                        onClick = onMoveBackward,
                    )
                    EditorToolButton(
                        label = "前面へ",
                        iconRes = R.drawable.ic_flip_to_front,
                        enabled = state.controlsEnabled && hasSelection,
                        onClick = onMoveForward,
                    )
                    EditorToolButton(
                        label = "削除",
                        iconRes = R.drawable.ic_delete,
                        enabled = state.controlsEnabled && hasSelection,
                        onClick = onDelete,
                    )
                    EditorToolButton(
                        label = "グリッド",
                        iconRes = R.drawable.ic_grid_on,
                        enabled = state.controlsEnabled,
                        selected = canvasState.gridEnabled,
                        onClick = canvasState::toggleGrid,
                    )
                    EditorToolButton(
                        label = "スナップ",
                        iconRes = R.drawable.ic_ads_click,
                        enabled = state.controlsEnabled,
                        selected = canvasState.snapEnabled,
                        onClick = canvasState::toggleSnap,
                    )
                    EditorToolButton(
                        label = "全消去",
                        iconRes = R.drawable.ic_delete,
                        enabled = state.controlsEnabled,
                        onClick = onClear,
                    )
                }

            }
        }
    }

    if (showFormatDialog) {
        AlertDialog(
            onDismissRequest = { showFormatDialog = false },
            title = { Text("送信方式") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    FormatRadioOption(
                        label = "ドット密度（高速）",
                        selected = state.selectedFormat ==
                            NativeImageFormat.FORMAT_DOT_DENSITY,
                        onClick = {
                            onFormatSelected(NativeImageFormat.FORMAT_DOT_DENSITY)
                            showFormatDialog = false
                        },
                    )
                    FormatRadioOption(
                        label = "4階調（高画質）",
                        selected = state.selectedFormat == NativeImageFormat.FORMAT_GRAY4,
                        onClick = {
                            onFormatSelected(NativeImageFormat.FORMAT_GRAY4)
                            showFormatDialog = false
                        },
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { showFormatDialog = false }) { Text("閉じる") }
            },
        )
    }

    if (showTextDialog) {
        AlertDialog(
            onDismissRequest = { showTextDialog = false },
            title = { Text("テキストを追加") },
            text = {
                OutlinedTextField(
                    value = textInput,
                    onValueChange = { textInput = it },
                    label = { Text("テキスト") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onAddText(textInput)
                        textInput = ""
                        showTextDialog = false
                    },
                    enabled = textInput.isNotBlank(),
                ) {
                    Text("追加")
                }
            },
            dismissButton = {
                TextButton(onClick = { showTextDialog = false }) { Text("キャンセル") }
            },
        )
    }

    if (showSaveDialog) {
        AlertDialog(
            onDismissRequest = { showSaveDialog = false },
            title = { Text("Libraryに保存") },
            text = {
                OutlinedTextField(
                    value = cardName,
                    onValueChange = { cardName = it },
                    label = { Text("カード名") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onSaveToLibrary(cardName)
                        cardName = ""
                        showSaveDialog = false
                    },
                    enabled = cardName.isNotBlank(),
                ) {
                    Text("保存")
                }
            },
            dismissButton = {
                TextButton(onClick = { showSaveDialog = false }) { Text("キャンセル") }
            },
        )
    }
}

@Composable
private fun EditorCanvas(
    state: EditorCanvasState,
    viewportState: EditorViewportState,
    modifier: Modifier = Modifier,
) {
    val revision = state.revision
    val viewportScale = viewportState.scale
    val viewportOffsetX = viewportState.offsetX
    val viewportOffsetY = viewportState.offsetY
    val viewportRotation = viewportState.rotationDegrees
    val outlineColor = MaterialTheme.colorScheme.outline.toArgb()
    val paperOutlinePaint = remember {
        Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    }.apply { color = outlineColor }
    Canvas(
        modifier = modifier
            .semantics {
                contentDescription =
                    "296 x 128 image editor. Drag the gray area to move the paper."
            }
            .pointerInput(state, viewportState) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val viewportWidth = size.width.toFloat()
                    val viewportHeight = size.height.toFloat()
                    val downOnPaper = viewportState.isPointOnPaper(
                        screenX = down.position.x,
                        screenY = down.position.y,
                        viewportWidth = viewportWidth,
                        viewportHeight = viewportHeight,
                    )
                    val paperPosition = viewportState.screenToPaper(
                        screenX = down.position.x,
                        screenY = down.position.y,
                        viewportWidth = viewportWidth,
                        viewportHeight = viewportHeight,
                    )
                    if (downOnPaper) {
                        state.selectAt(paperPosition.x, paperPosition.y)
                    } else {
                        state.selectAt(-1f, -1f)
                    }
                    val transformsObject = downOnPaper && state.hasSelection
                    val transformsPaper = !downOnPaper
                    if (transformsObject) state.beginTransform()
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            if (event.changes.none { it.pressed }) break
                            val pan = event.calculatePan()
                            val zoom = event.calculateZoom()
                            if (transformsObject) {
                                val paperDelta = viewportState.screenDeltaToPaper(
                                    deltaX = pan.x,
                                    deltaY = pan.y,
                                    viewportWidth = viewportWidth,
                                    viewportHeight = viewportHeight,
                                )
                                state.transformSelection(
                                    deltaX = paperDelta.x,
                                    deltaY = paperDelta.y,
                                    scaleFactor = zoom,
                                    rotationDegrees = event.calculateRotation(),
                                )
                            } else if (transformsPaper) {
                                val centroid = event.calculateCentroid(useCurrent = false)
                                viewportState.transform(
                                    panX = pan.x,
                                    panY = pan.y,
                                    zoomFactor = zoom,
                                    rotationDeltaDegrees = event.calculateRotation(),
                                    focusX = centroid.x,
                                    focusY = centroid.y,
                                    viewportWidth = viewportWidth,
                                    viewportHeight = viewportHeight,
                                )
                            }
                            event.changes.forEach { change ->
                                if (change.position != change.previousPosition) change.consume()
                            }
                        }
                    } finally {
                        if (transformsObject) state.endTransform()
                    }
                }
            },
    ) {
        revision
        val paperScale = min(
            size.width / EditorCanvasState.paperWidth,
            size.height / EditorCanvasState.paperHeight,
        )
        drawContext.canvas.nativeCanvas.apply {
            save()
            clipRect(0f, 0f, size.width, size.height)
            translate(size.width / 2f + viewportOffsetX, size.height / 2f + viewportOffsetY)
            rotate(viewportRotation)
            scale(paperScale * viewportScale, paperScale * viewportScale)
            translate(-EditorCanvasState.paperWidth / 2f, -EditorCanvasState.paperHeight / 2f)
            state.draw(
                canvas = this,
                showSelection = true,
                showGrid = state.gridEnabled,
            )
            drawRect(
                0f,
                0f,
                EditorCanvasState.paperWidth,
                EditorCanvasState.paperHeight,
                paperOutlinePaint.apply {
                    strokeWidth = 1.dp.toPx() / (paperScale * viewportScale)
                },
            )
            restore()
        }
    }
}

@Composable
private fun FormatRadioOption(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(56.dp)
            .selectable(
                selected = selected,
                onClick = onClick,
                role = Role.RadioButton,
            )
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected,
            onClick = null,
        )
        Text(
            text = label,
            modifier = Modifier.padding(start = 16.dp),
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

@Composable
private fun EditorToolButton(
    label: String,
    iconRes: Int,
    enabled: Boolean,
    onClick: () -> Unit,
    selected: Boolean = false,
) {

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                maxLines = 1,
            )
            Spacer(Modifier.height(5.dp))

            FilledTonalButton(
                onClick = onClick,
                enabled = enabled,
                modifier = Modifier.size(width = 76.dp, height = 50.dp),
                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 8.dp),
                shape = RoundedCornerShape(12.dp),
                colors = if (selected) {
                    ButtonDefaults.filledTonalButtonColors(
                        containerColor = MaterialTheme.colorScheme.primaryContainer,
                        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                } else {
                    ButtonDefaults.filledTonalButtonColors()
                },
            ){
                Icon(
                    painter = painterResource(iconRes),
                    contentDescription = null,
                    modifier = Modifier.size(24.dp),
                )
            }


        }

}

@OptIn(ExperimentalMaterial3Api::class)
@Preview(
    name = "New・画像エディター",
    showBackground = true,
    showSystemUi = true,
    widthDp = 393,
    heightDp = 852,
)
@Composable
private fun EditorScreenPreview() {
    val canvasState = remember {
        EditorCanvasState().apply { addText("NAMECARD") }
    }
    NamecardTheme {
        Scaffold(contentWindowInsets = WindowInsets(0, 0, 0, 0)) { innerPadding ->
            EditorScreen(
                state = EditorScreenState(
                    selectedFormat = NativeImageFormat.FORMAT_DOT_DENSITY,
                    message = "Previewです。選択中の要素は青い枠で表示されます。",
                ),
                canvasState = canvasState,
                onFormatSelected = {},
                onAddText = {},
                onPickImage = {},
                onUndo = canvasState::undo,
                onRedo = canvasState::redo,
                onMoveBackward = canvasState::moveSelectionBackward,
                onMoveForward = canvasState::moveSelectionForward,
                onDelete = canvasState::deleteSelection,
                onClear = canvasState::clearAll,
                onSaveToLibrary = {},
                onExportBin = {},
                onWrite = {},
                modifier = Modifier.padding(innerPadding),
            )
        }
    }
}
