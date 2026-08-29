package jp.namecard.nfctest

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp

internal enum class AppTab(val title: String, val iconRes: Int) {
    NEW("New", R.drawable.ic_add_box),
    LIBRARY("Library", R.drawable.ic_collections_bookmark),
    SETTINGS("Settings", R.drawable.ic_settings),
}

internal data class MainScreenState(
    val selectedTab: AppTab = AppTab.NEW,
    val statusText: String = initialStatusText,
    val controlsEnabled: Boolean = true,
    val selectedPatternId: Int = 1,
    val selectedImageFormat: Int = NativeImageFormat.FORMAT_DOT_DENSITY,
    val cleanBeforeWrite: Boolean = true,
    val editorMessage: String = "オブジェクトをドラッグ、2本指で拡大・縮小・回転できます。",
    val libraryMessage: String = "",
    val writeProgress: WriteProgressState? = null,
)

@Composable
internal fun MainScreen(
    state: MainScreenState,
    canvasState: EditorCanvasState,
    libraryCards: List<LibraryCard>,
    patternNames: Array<String>,
    onTabSelected: (AppTab) -> Unit,
    onImageFormatSelected: (Int) -> Unit,
    onAddText: (String) -> Unit,
    onPickImage: () -> Unit,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onMoveBackward: () -> Unit,
    onMoveForward: () -> Unit,
    onDelete: () -> Unit,
    onClear: () -> Unit,
    onSaveToLibrary: (String) -> Unit,
    onExportEditor: () -> Unit,
    onWriteEditor: () -> Unit,
    onWriteUrl: (String) -> Unit,
    onImportCard: () -> Unit,
    onWriteCard: (LibraryCard) -> Unit,
    onEditCard: (LibraryCard) -> Unit,
    onRenameCard: (LibraryCard, String) -> Unit,
    onExportCard: (LibraryCard) -> Unit,
    onDeleteCard: (LibraryCard) -> Unit,
    onCleanChanged: (Boolean) -> Unit,
    onPatternSelected: (Int) -> Unit,
    onPatternWrite: () -> Unit,
    onPatternSequence: () -> Unit,
    onStatusCheck: () -> Unit,
    onDismissWriteProgress: () -> Unit,
) {
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            NavigationBar {
                AppTab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = state.selectedTab == tab,
                        onClick = { onTabSelected(tab) },
                        icon = {
                            Icon(
                                painterResource(tab.iconRes),
                                contentDescription = null,
                            )
                        },
                        label = { Text(tab.title) },
                    )
                }
            }
        },
    ) { innerPadding ->
        when (state.selectedTab) {
            AppTab.NEW -> EditorScreen(
                state = EditorScreenState(
                    selectedFormat = state.selectedImageFormat,
                    controlsEnabled = state.controlsEnabled,
                    message = state.editorMessage,
                ),
                canvasState = canvasState,
                onFormatSelected = onImageFormatSelected,
                onAddText = onAddText,
                onPickImage = onPickImage,
                onUndo = onUndo,
                onRedo = onRedo,
                onMoveBackward = onMoveBackward,
                onMoveForward = onMoveForward,
                onDelete = onDelete,
                onClear = onClear,
                onSaveToLibrary = onSaveToLibrary,
                onExportBin = onExportEditor,
                onWrite = onWriteEditor,
                onWriteUrl = onWriteUrl,
                modifier = Modifier.padding(innerPadding),
            )

            AppTab.LIBRARY -> LibraryScreen(
                cards = libraryCards,
                controlsEnabled = state.controlsEnabled,
                message = state.libraryMessage,
                onImport = onImportCard,
                onWrite = onWriteCard,
                onEdit = onEditCard,
                onRename = onRenameCard,
                onExport = onExportCard,
                onDelete = onDeleteCard,
                modifier = Modifier.padding(innerPadding),
            )

            AppTab.SETTINGS -> SettingsScreen(
                state = state,
                patternNames = patternNames,
                onCleanChanged = onCleanChanged,
                onPatternSelected = onPatternSelected,
                onPatternWrite = onPatternWrite,
                onPatternSequence = onPatternSequence,
                onStatusCheck = onStatusCheck,
                modifier = Modifier.padding(innerPadding),
            )
        }
    }

    state.writeProgress?.let { progress ->
        WriteProgressDialog(
            state = progress,
            onDismiss = onDismissWriteProgress,
        )
    }
}

@Composable
private fun SettingsScreen(
    state: MainScreenState,
    patternNames: Array<String>,
    onCleanChanged: (Boolean) -> Unit,
    onPatternSelected: (Int) -> Unit,
    onPatternWrite: () -> Unit,
    onPatternSequence: () -> Unit,
    onStatusCheck: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.statusBars)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            "Settings",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
        )

        SectionCard(
            title = "書き換え前のクリーニング",
            subtitle = "ドット密度で白→黒→白のあと本画像を更新します。",
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(if (state.cleanBeforeWrite) "有効" else "無効")
                Switch(
                    checked = state.cleanBeforeWrite,
                    onCheckedChange = onCleanChanged,
                    enabled = state.controlsEnabled,
                )
            }
        }

        SectionCard(
            title = "内蔵パターン",
            subtitle = "画像転送なしで表示更新を試験します。",
        ) {
            PatternPicker(
                names = patternNames,
                selectedId = state.selectedPatternId,
                enabled = state.controlsEnabled,
                onSelected = onPatternSelected,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(
                    onClick = onPatternWrite,
                    enabled = state.controlsEnabled,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("選択を書込")
                }
                OutlinedButton(
                    onClick = onPatternSequence,
                    enabled = state.controlsEnabled,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("10種連続")
                }
            }
        }

        SectionCard(
            title = "ステータスチェック",
            subtitle = "表示を書き換えず、電圧とFW状態を確認します。",
        ) {
            Button(
                onClick = onStatusCheck,
                enabled = state.controlsEnabled,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("STATUSを確認")
            }
        }

        SectionCard(
            title = "通信ログ",
            subtitle = "完了するまでPixelと名刺の位置を固定してください。",
        ) {
            SelectionContainer {
                Text(
                    text = state.statusText,
                    modifier = Modifier.fillMaxWidth(),
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
    }
}

@Composable
private fun SectionCard(
    title: String,
    subtitle: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            content()
        }
    }
}

@Composable
private fun PatternPicker(
    names: Array<String>,
    selectedId: Int,
    enabled: Boolean,
    onSelected: (Int) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        OutlinedButton(
            onClick = { expanded = true },
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(names[selectedId - 1], modifier = Modifier.weight(1f))
            Text("▼")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            names.forEachIndexed { index, name ->
                DropdownMenuItem(
                    text = { Text(name) },
                    onClick = {
                        onSelected(index + 1)
                        expanded = false
                    },
                )
            }
        }
    }
}

private const val initialStatusText =
    "操作を選んでから名刺へタッチしてください。\n" +
        "FWが前回表示を保持し、差分Partial更新します。\n"

@Preview(
    name = "01 New",
    showBackground = true,
    showSystemUi = true,
    widthDp = 393,
    heightDp = 852,
)
@Composable
private fun MainNewPreview() {
    PreviewMainScreen(AppTab.NEW)
}

@Preview(
    name = "02 Library",
    showBackground = true,
    showSystemUi = true,
    widthDp = 393,
    heightDp = 852,
)
@Composable
private fun MainLibraryPreview() {
    PreviewMainScreen(AppTab.LIBRARY)
}

@Preview(
    name = "03 Settings",
    showBackground = true,
    showSystemUi = true,
    widthDp = 393,
    heightDp = 852,
)
@Composable
private fun MainSettingsPreview() {
    PreviewMainScreen(AppTab.SETTINGS)
}

@Composable
private fun PreviewMainScreen(selectedTab: AppTab) {
    val canvasState = remember {
        EditorCanvasState().apply { addText("NAMECARD") }
    }
    val cards = remember {
        val pixels = IntArray(NativeImageFormat.WIDTH * NativeImageFormat.HEIGHT) { index ->
            val x = index % NativeImageFormat.WIDTH
            val y = index / NativeImageFormat.WIDTH
            if ((x / 32 + y / 16) % 2 == 0) 0xff111111.toInt() else 0xffeeeeee.toInt()
        }
        listOf(
            LibraryCard(
                id = "preview-dither",
                name = "イベント用カード",
                format = NativeImageFormat.FORMAT_DOT_DENSITY,
                createdAt = 0,
                updatedAt = 0,
                bytes = NativeImageFormat.encodeArgb(
                    pixels,
                    NativeImageFormat.WIDTH,
                    NativeImageFormat.HEIGHT,
                ),
            ),
            LibraryCard(
                id = "preview-gray",
                name = "4階調プロフィール",
                format = NativeImageFormat.FORMAT_GRAY4,
                createdAt = 0,
                updatedAt = 0,
                bytes = NativeImageFormat.encodeArgbGray4(
                    pixels,
                    NativeImageFormat.WIDTH,
                    NativeImageFormat.HEIGHT,
                ),
            ),
        )
    }
    NamecardTheme {
        MainScreen(
            state = MainScreenState(selectedTab = selectedTab),
            canvasState = canvasState,
            libraryCards = cards,
            patternNames = arrayOf("チェック柄", "NFC OK", "全面黒", "全面白"),
            onTabSelected = {},
            onImageFormatSelected = {},
            onAddText = {},
            onPickImage = {},
            onUndo = canvasState::undo,
            onRedo = canvasState::redo,
            onMoveBackward = canvasState::moveSelectionBackward,
            onMoveForward = canvasState::moveSelectionForward,
            onDelete = canvasState::deleteSelection,
            onClear = canvasState::clearAll,
            onSaveToLibrary = {},
            onExportEditor = {},
            onWriteEditor = {},
            onWriteUrl = {},
            onImportCard = {},
            onWriteCard = {},
            onEditCard = {},
            onRenameCard = { _, _ -> },
            onExportCard = {},
            onDeleteCard = {},
            onCleanChanged = {},
            onPatternSelected = {},
            onPatternWrite = {},
            onPatternSequence = {},
            onStatusCheck = {},
            onDismissWriteProgress = {},
        )
    }
}
