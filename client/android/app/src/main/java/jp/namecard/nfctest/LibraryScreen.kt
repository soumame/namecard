package jp.namecard.nfctest

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
internal fun LibraryScreen(
    cards: List<LibraryCard>,
    controlsEnabled: Boolean,
    message: String,
    onImport: () -> Unit,
    onWrite: (LibraryCard) -> Unit,
    onEdit: (LibraryCard) -> Unit,
    onRename: (LibraryCard, String) -> Unit,
    onExport: (LibraryCard) -> Unit,
    onDelete: (LibraryCard) -> Unit,
    modifier: Modifier = Modifier,
) {
    var renameTarget by remember { mutableStateOf<LibraryCard?>(null) }
    var renameText by remember { mutableStateOf("") }
    var deleteTarget by remember { mutableStateOf<LibraryCard?>(null) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column {
                Text(
                    "Library",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "保存したカードを再利用できます",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Button(onClick = onImport, enabled = controlsEnabled) {
                Icon(painterResource(R.drawable.ic_upload_file), contentDescription = null)
                Spacer(Modifier.size(8.dp))
                Text("インポート")
            }
        }

        if (message.isNotBlank()) {
            Text(
                message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (cards.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "保存したカードはまだありません。\nNewで作成するか、BINをインポートしてください。",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                modifier = Modifier.fillMaxSize(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(cards, key = LibraryCard::id) { card ->
                    LibraryCardItem(
                        card = card,
                        controlsEnabled = controlsEnabled,
                        onWrite = { onWrite(card) },
                        onEdit = { onEdit(card) },
                        onRename = {
                            renameTarget = card
                            renameText = card.name
                        },
                        onExport = { onExport(card) },
                        onDelete = { deleteTarget = card },
                    )
                }
            }
        }
    }

    renameTarget?.let { card ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("カード名を変更") },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    label = { Text("カード名") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onRename(card, renameText)
                        renameTarget = null
                    },
                    enabled = renameText.isNotBlank(),
                ) {
                    Text("保存")
                }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) { Text("キャンセル") }
            },
        )
    }

    deleteTarget?.let { card ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("カードを削除") },
            text = { Text("「${card.name}」をLibraryから削除します。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        onDelete(card)
                        deleteTarget = null
                    },
                ) {
                    Text("削除", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("キャンセル") }
            },
        )
    }
}

@Composable
private fun LibraryCardItem(
    card: LibraryCard,
    controlsEnabled: Boolean,
    onWrite: () -> Unit,
    onEdit: () -> Unit,
    onRename: () -> Unit,
    onExport: () -> Unit,
    onDelete: () -> Unit,
) {
    var menuExpanded by remember(card.id) { mutableStateOf(false) }
    val preview = remember(card.id, card.updatedAt) {
        Bitmap.createBitmap(
            NativeImageFormat.decodeArgb(card.bytes, card.format),
            NativeImageFormat.WIDTH,
            NativeImageFormat.HEIGHT,
            Bitmap.Config.ARGB_8888,
        ).asImageBitmap()
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Image(
                bitmap = preview,
                contentDescription = "${card.name}のプレビュー",
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(EditorCanvasState.paperWidth / EditorCanvasState.paperHeight)
                    .background(androidx.compose.ui.graphics.Color.White),
                contentScale = ContentScale.Fit,
            )
            Column(
                modifier = Modifier.padding(horizontal = 10.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    card.name,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    NativeImageFormat.displayName(card.format),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 8.dp, end = 8.dp, bottom = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FilledIconButton(
                    onClick = onWrite,
                    enabled = controlsEnabled,
                    modifier = Modifier.size(48.dp),
                ) {
                    Icon(
                        painterResource(R.drawable.ic_nfc),
                        contentDescription = "${card.name}を書き込む",
                    )
                }
                FilledTonalIconButton(
                    onClick = onEdit,
                    enabled = controlsEnabled,
                    modifier = Modifier.size(48.dp),
                ) {
                    Icon(
                        painterResource(R.drawable.ic_edit),
                        contentDescription = "${card.name}を編集する",
                    )
                }
                Box {
                    IconButton(
                        onClick = { menuExpanded = true },
                        enabled = controlsEnabled,
                        modifier = Modifier.size(48.dp),
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_more_vert),
                            contentDescription = "${card.name}のその他の操作",
                        )
                    }
                    DropdownMenu(
                        expanded = menuExpanded,
                        onDismissRequest = { menuExpanded = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text("名称変更") },
                            leadingIcon = {
                                Icon(painterResource(R.drawable.ic_edit), contentDescription = null)
                            },
                            onClick = {
                                menuExpanded = false
                                onRename()
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
                                menuExpanded = false
                                onExport()
                            },
                        )
                        DropdownMenuItem(
                            text = {
                                Text("削除", color = MaterialTheme.colorScheme.error)
                            },
                            leadingIcon = {
                                Icon(
                                    painterResource(R.drawable.ic_delete),
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                )
                            },
                            onClick = {
                                menuExpanded = false
                                onDelete()
                            },
                        )
                    }
                }
            }
        }
    }
}
