package jp.namecard.nfctest

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val namecardColors = lightColorScheme(
    primary = Color(0xff155eef),
    onPrimary = Color.White,
    primaryContainer = Color(0xffdbe7ff),
    onPrimaryContainer = Color(0xff082d72),
    secondary = Color(0xff52617a),
    secondaryContainer = Color(0xffd8e3f8),
    surface = Color(0xfffbfaff),
    surfaceVariant = Color(0xffe7eaf1),
    background = Color(0xfff4f6fb),
    error = Color(0xffba1a1a),
)

@Composable
internal fun NamecardTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = namecardColors,
        content = content,
    )
}
