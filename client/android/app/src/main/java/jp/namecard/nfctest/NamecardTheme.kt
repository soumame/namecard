package jp.namecard.nfctest

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

private val expressiveLightColors = lightColorScheme(
    primary = Color(0xff6750a4),
    onPrimary = Color.White,
    primaryContainer = Color(0xffe9ddff),
    onPrimaryContainer = Color(0xff22005d),
    secondary = Color(0xff006a6a),
    onSecondary = Color.White,
    secondaryContainer = Color(0xff9cf1f0),
    onSecondaryContainer = Color(0xff002020),
    tertiary = Color(0xff9c4146),
    onTertiary = Color.White,
    tertiaryContainer = Color(0xffffdadb),
    onTertiaryContainer = Color(0xff40000b),
    background = Color(0xfffff8ff),
    onBackground = Color(0xff1d1b20),
    surface = Color(0xfffff8ff),
    onSurface = Color(0xff1d1b20),
    surfaceVariant = Color(0xffe7e0ec),
    onSurfaceVariant = Color(0xff49454f),
    outline = Color(0xff79747e),
    outlineVariant = Color(0xffcac4d0),
    error = Color(0xffba1a1a),
    onError = Color.White,
    errorContainer = Color(0xffffdad6),
    onErrorContainer = Color(0xff410002),
)

private val expressiveDarkColors = darkColorScheme(
    primary = Color(0xffd0bcff),
    onPrimary = Color(0xff381e72),
    primaryContainer = Color(0xff4f378b),
    onPrimaryContainer = Color(0xffeaddff),
    secondary = Color(0xff4fd8d8),
    onSecondary = Color(0xff003737),
    secondaryContainer = Color(0xff004f4f),
    onSecondaryContainer = Color(0xff9cf1f0),
    tertiary = Color(0xffffb3b6),
    onTertiary = Color(0xff5f131b),
    tertiaryContainer = Color(0xff7d2930),
    onTertiaryContainer = Color(0xffffdadb),
    background = Color(0xff141218),
    onBackground = Color(0xffe6e1e5),
    surface = Color(0xff141218),
    onSurface = Color(0xffe6e1e5),
    surfaceVariant = Color(0xff49454f),
    onSurfaceVariant = Color(0xffcac4d0),
    outline = Color(0xff938f99),
    outlineVariant = Color(0xff49454f),
    error = Color(0xffffb4ab),
    onError = Color(0xff690005),
    errorContainer = Color(0xff93000a),
    onErrorContainer = Color(0xffffdad6),
)

private val expressiveShapes = Shapes(
    extraSmall = RoundedCornerShape(10.dp),
    small = RoundedCornerShape(14.dp),
    medium = RoundedCornerShape(20.dp),
    large = RoundedCornerShape(28.dp),
    extraLarge = RoundedCornerShape(36.dp),
)

@Composable
internal fun NamecardTheme(
    useDynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val darkTheme = isSystemInDarkTheme()
    val colorScheme = when {
        useDynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> expressiveDarkColors
        else -> expressiveLightColors
    }

    MaterialTheme(
        colorScheme = colorScheme,
        shapes = expressiveShapes,
        content = content,
    )
}
