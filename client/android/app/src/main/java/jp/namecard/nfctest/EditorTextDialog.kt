package jp.namecard.nfctest

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
internal fun EditorTextDialog(
    value: String,
    style: EditorTextStyle,
    onValueChange: (String) -> Unit,
    onStyleChange: (EditorTextStyle) -> Unit,
    onAdd: () -> Unit,
    onDismiss: () -> Unit,
) {
    var showFonts by remember { mutableStateOf(false) }
    val previewStyle = MaterialTheme.typography.bodyLarge.copy(
        fontFamily = FontFamily(style.typeface),
        fontWeight = if (style.bold) FontWeight.Bold else FontWeight.Normal,
        fontStyle = if (style.italic) FontStyle.Italic else FontStyle.Normal,
        textDecoration = if (style.underline) TextDecoration.Underline else TextDecoration.None,
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("テキストを追加") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedTextField(
                    value = value,
                    onValueChange = onValueChange,
                    label = { Text("テキスト") },
                    singleLine = true,
                    textStyle = previewStyle,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text("書式", style = MaterialTheme.typography.labelMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = style.bold,
                        onClick = { onStyleChange(style.copy(bold = !style.bold)) },
                        label = { Text("B", fontWeight = FontWeight.Bold) },
                        modifier = Modifier.weight(1f).semantics { contentDescription = "太字" },
                    )
                    FilterChip(
                        selected = style.italic,
                        onClick = { onStyleChange(style.copy(italic = !style.italic)) },
                        label = { Text("I", fontStyle = FontStyle.Italic) },
                        modifier = Modifier.weight(1f).semantics { contentDescription = "斜体" },
                    )
                    FilterChip(
                        selected = style.underline,
                        onClick = { onStyleChange(style.copy(underline = !style.underline)) },
                        label = { Text("U", textDecoration = TextDecoration.Underline) },
                        modifier = Modifier.weight(1f).semantics { contentDescription = "下線" },
                    )
                }
                Text("フォント", style = MaterialTheme.typography.labelMedium)
                Box {
                    OutlinedButton(
                        onClick = { showFonts = true },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("${style.fontFamily.label} ▾")
                    }
                    DropdownMenu(
                        expanded = showFonts,
                        onDismissRequest = { showFonts = false },
                        modifier = Modifier.heightIn(max = 280.dp),
                    ) {
                        EditorFontFamily.entries.forEach { family ->
                            DropdownMenuItem(
                                text = { Text(family.label) },
                                onClick = {
                                    onStyleChange(style.copy(fontFamily = family))
                                    showFonts = false
                                },
                            )
                        }
                    }
                }
                Text(
                    value.trim().ifEmpty { "名刺 Namecard 123" },
                    style = previewStyle.copy(fontSize = 24.sp),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onAdd, enabled = value.isNotBlank()) { Text("追加") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("キャンセル") }
        },
    )
}
