package jp.namecard.nfctest

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

internal data class EditorScreenState(
    val selectedFormat: Int,
    val message: String = "白い領域が実画面です。要素をドラッグ、2本指で拡大・縮小できます。",
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EditorScreen(
    state: EditorScreenState,
    canvasState: EditorCanvasState,
    onBack: () -> Unit,
    onFormatSelected: (Int) -> Unit,
    onAddText: (String) -> Unit,
    onPickImage: () -> Unit,
    onResize: (Float) -> Unit,
    onMoveBackward: () -> Unit,
    onMoveForward: () -> Unit,
    onDelete: () -> Unit,
    onClear: () -> Unit,
    onSaveBin: () -> Unit,
    onWrite: () -> Unit,
) {
    var textInput by remember { mutableStateOf("") }
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(
                title = { Text("画像エディター") },
                navigationIcon = {
                    OutlinedButton(onClick = onBack, modifier = Modifier.padding(start = 8.dp)) {
                        Text("戻る")
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = state.selectedFormat == NativeImageFormat.FORMAT_DOT_DENSITY,
                    onClick = { onFormatSelected(NativeImageFormat.FORMAT_DOT_DENSITY) },
                    label = { Text("ドット密度") },
                )
                FilterChip(
                    selected = state.selectedFormat == NativeImageFormat.FORMAT_GRAY4,
                    onClick = { onFormatSelected(NativeImageFormat.FORMAT_GRAY4) },
                    label = { Text("4階調") },
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = textInput,
                    onValueChange = { textInput = it },
                    label = { Text("追加するテキスト") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                Button(
                    onClick = {
                        if (textInput.isNotBlank()) {
                            onAddText(textInput)
                            textInput = ""
                        }
                    },
                ) {
                    Text("追加")
                }
                OutlinedButton(onClick = onPickImage) {
                    Text("画像")
                }
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .background(Color(0xffe8ebf0)),
                contentAlignment = Alignment.Center,
            ) {
                EditorCanvas(
                    state = canvasState,
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(EditorCanvasState.paperWidth / EditorCanvasState.paperHeight)
                        .border(1.dp, MaterialTheme.colorScheme.outline),
                )
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                ToolButton("小さく") { onResize(0.8f) }
                ToolButton("大きく") { onResize(1.25f) }
                ToolButton("背面へ", onMoveBackward)
                ToolButton("前面へ", onMoveForward)
                ToolButton("選択削除", onDelete)
                ToolButton("全消去", onClear)
            }

            Text(
                text = state.message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedButton(onClick = onSaveBin, modifier = Modifier.weight(1f)) {
                    Text("BIN保存")
                }
                Button(onClick = onWrite, modifier = Modifier.weight(1f)) {
                    Text("この画像を書込")
                }
            }
        }
    }
}

@Composable
private fun ToolButton(label: String, action: () -> Unit) {
    OutlinedButton(onClick = action) { Text(label) }
}

@Composable
private fun EditorCanvas(
    state: EditorCanvasState,
    modifier: Modifier = Modifier,
) {
    val revision = state.revision
    Canvas(
        modifier = modifier
            .semantics { contentDescription = "296 x 128 image editor" }
            .pointerInput(state) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    state.selectAt(
                        down.position.x / size.width * EditorCanvasState.paperWidth,
                        down.position.y / size.height * EditorCanvasState.paperHeight,
                    )
                    while (true) {
                        val event = awaitPointerEvent()
                        if (event.changes.size >= 2) {
                            state.resizeSelection(event.calculateZoom())
                        } else {
                            val change = event.changes.firstOrNull() ?: break
                            val delta = change.positionChange()
                            state.moveSelection(
                                delta.x / size.width * EditorCanvasState.paperWidth,
                                delta.y / size.height * EditorCanvasState.paperHeight,
                            )
                        }
                        event.changes.forEach { change ->
                            if (change.positionChange() != Offset.Zero) change.consume()
                        }
                        if (event.changes.none { it.pressed }) break
                    }
                }
            },
    ) {
        revision
        drawContext.canvas.nativeCanvas.apply {
            save()
            scale(
                size.width / EditorCanvasState.paperWidth,
                size.height / EditorCanvasState.paperHeight,
            )
            state.draw(this, showSelection = true)
            restore()
        }
    }
}
