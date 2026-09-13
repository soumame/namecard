package jp.namecard.nfctest

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
internal fun QrCodeDialog(controlsEnabled: Boolean, onAdd: (QrCode) -> Unit, onDismiss: () -> Unit) {
    var input by remember { mutableStateOf("") }
    var code by remember { mutableStateOf<QrCode?>(null) }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var generating by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val validation = validateUrlInput(input)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("QRコードを作成") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it; code = null; preview = null; error = null },
                    label = { Text("URL") },
                    placeholder = { Text("https://example.com") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    enabled = !generating,
                    isError = input.isNotBlank() && !validation.isValid,
                    supportingText = if (input.isNotBlank() && !validation.isValid) {
                        { Text(validation.error.orEmpty()) }
                    } else { null },
                )
                Text("http://・https://がない場合はhttps://を付けます。", style = MaterialTheme.typography.bodySmall)
                TextButton(
                    enabled = controlsEnabled && validation.isValid && !generating,
                    onClick = {
                        generating = true
                        error = null
                        code = null
                        preview = null
                        scope.launch {
                            try {
                                val result = withContext(Dispatchers.Default) {
                                    val generated = QrCode.generate(input)
                                    val side = generated.moduleCount * generated.previewScale
                                    generated to Bitmap.createBitmap(generated.pixels(generated.previewScale), side, side, Bitmap.Config.ARGB_8888)
                                }
                                code = result.first
                                preview = result.second
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (failure: Exception) {
                                error = failure.message ?: "QRコードを作成できませんでした。"
                            } finally {
                                generating = false
                            }
                        }
                    },
                ) { Text("QRコードを生成") }
                if (generating) CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
                preview?.let { bitmap ->
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = "生成したQRコード",
                        modifier = Modifier.size(200.dp).align(Alignment.CenterHorizontally),
                        filterQuality = FilterQuality.None,
                    )
                }
                code?.let { generated ->
                    Text(generated.url, style = MaterialTheme.typography.bodySmall)
                    Text(
                        if (generated.canAddToCanvas) "名刺に画像として追加します。追加後に位置やサイズを調整できます。" else
                            "名刺に読み取りやすく載せるにはURLが長すぎます。短いURLを入力してください。",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = controlsEnabled && code?.canAddToCanvas == true && !generating,
                onClick = { code?.let(onAdd); onDismiss() },
            ) { Text("名刺に追加") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("閉じる") } },
    )
}
