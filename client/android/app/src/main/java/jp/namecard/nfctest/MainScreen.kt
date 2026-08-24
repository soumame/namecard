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
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

internal data class MainScreenState(
    val statusText: String = initialStatusText,
    val controlsEnabled: Boolean = true,
    val selectedPatternId: Int = 1,
    val selectedImageFormat: Int = NativeImageFormat.FORMAT_DOT_DENSITY,
    val cleanBeforeWrite: Boolean = true,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MainScreen(
    state: MainScreenState,
    patternNames: Array<String>,
    onStatusCheck: () -> Unit,
    onPatternSelected: (Int) -> Unit,
    onPatternWrite: () -> Unit,
    onPatternSequence: () -> Unit,
    onImageFormatSelected: (Int) -> Unit,
    onCleanChanged: (Boolean) -> Unit,
    onOpenEditor: () -> Unit,
    onChooseBin: () -> Unit,
) {
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Namecard Writer", fontWeight = FontWeight.SemiBold)
                        Text(
                            "NFC-V e-paper tool",
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SectionCard(
                title = "接続確認",
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
                title = "画像を書き込む",
                subtitle = "296×128の編集画像、または既存BINを送信します。",
            ) {
                Text("送信方式", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = state.selectedImageFormat ==
                            NativeImageFormat.FORMAT_DOT_DENSITY,
                        onClick = {
                            onImageFormatSelected(NativeImageFormat.FORMAT_DOT_DENSITY)
                        },
                        enabled = state.controlsEnabled,
                        label = { Text("ドット密度") },
                    )
                    FilterChip(
                        selected = state.selectedImageFormat == NativeImageFormat.FORMAT_GRAY4,
                        onClick = { onImageFormatSelected(NativeImageFormat.FORMAT_GRAY4) },
                        enabled = state.controlsEnabled,
                        label = { Text("4階調") },
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("画質優先クリーニング", fontWeight = FontWeight.Medium)
                        Text(
                            if (state.selectedImageFormat == NativeImageFormat.FORMAT_GRAY4) {
                                "4階調では使用しません"
                            } else {
                                "白→黒→白のあと本画像を更新"
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(
                        checked = state.cleanBeforeWrite,
                        onCheckedChange = onCleanChanged,
                        enabled = state.controlsEnabled &&
                            state.selectedImageFormat == NativeImageFormat.FORMAT_DOT_DENSITY,
                    )
                }
                Button(
                    onClick = onOpenEditor,
                    enabled = state.controlsEnabled,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("テキスト・画像を編集")
                }
                OutlinedButton(
                    onClick = onChooseBin,
                    enabled = state.controlsEnabled,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("BINファイルを選択")
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
}

@Composable
private fun SectionCard(
    title: String,
    subtitle: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface,
        ),
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
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
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
    "試験を選んでから名刺へタッチしてください。\n" +
        "FWが前回表示を保持し、差分Partial更新します。\n" +
        "画像書込は白→黒→白クリーニングが既定です。\n" +
        "4階調では2プレーンを送信します。\n"
