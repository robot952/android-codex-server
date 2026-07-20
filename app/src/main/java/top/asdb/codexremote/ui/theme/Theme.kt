package top.asdb.codexremote.ui.theme

import android.app.Activity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat

val CodexBackground = Color(0xFF181818)
val CodexSurface = Color(0xFF1F1F1F)
val CodexSurfaceRaised = Color(0xFF272727)
val CodexBorder = Color(0xFF373737)
val CodexText = Color(0xFFF0F0F0)
val CodexMuted = Color(0xFFA6A6A6)
val CodexGreen = Color(0xFF68C77B)
val CodexRed = Color(0xFFF07178)
val CodexBlue = Color(0xFF71A7F7)
val CodexAmber = Color(0xFFE5B567)

private val DarkColors = darkColorScheme(
    primary = CodexText,
    onPrimary = Color(0xFF171717),
    primaryContainer = Color(0xFF343434),
    onPrimaryContainer = CodexText,
    secondary = CodexGreen,
    onSecondary = Color(0xFF102514),
    secondaryContainer = CodexSurfaceRaised,
    onSecondaryContainer = CodexText,
    tertiary = CodexBlue,
    tertiaryContainer = CodexSurfaceRaised,
    onTertiaryContainer = CodexText,
    background = CodexBackground,
    onBackground = CodexText,
    surface = CodexSurface,
    onSurface = CodexText,
    surfaceVariant = CodexSurfaceRaised,
    onSurfaceVariant = CodexMuted,
    outline = CodexBorder,
    error = CodexRed,
)

private val LightColors = lightColorScheme(
    primary = Color(0xFF202020),
    onPrimary = Color.White,
    secondary = Color(0xFF24783A),
    tertiary = Color(0xFF245DA6),
    secondaryContainer = Color(0xFFEAEAEA),
    onSecondaryContainer = Color(0xFF202020),
    tertiaryContainer = Color(0xFFEAEAEA),
    onTertiaryContainer = Color(0xFF202020),
    background = Color(0xFFF5F5F5),
    onBackground = Color(0xFF202020),
    surface = Color.White,
    onSurface = Color(0xFF202020),
    surfaceVariant = Color(0xFFEAEAEA),
    onSurfaceVariant = Color(0xFF616161),
    outline = Color(0xFFD0D0D0),
    error = Color(0xFFB3261E),
)

private val Typography = androidx.compose.material3.Typography(
    bodyLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 16.sp, letterSpacing = 0.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp, letterSpacing = 0.sp),
    bodySmall = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 12.sp, letterSpacing = 0.sp),
    titleLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 20.sp, letterSpacing = 0.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 16.sp, letterSpacing = 0.sp),
    titleSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp, letterSpacing = 0.sp),
    labelLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp, letterSpacing = 0.sp),
    labelMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 12.sp, letterSpacing = 0.sp),
)

@Composable
fun CodexRemoteTheme(darkTheme: Boolean = true, content: @Composable () -> Unit) {
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = if (darkTheme) CodexBackground.toArgb() else Color(0xFFF5F5F5).toArgb()
            window.navigationBarColor = if (darkTheme) CodexBackground.toArgb() else Color(0xFFF5F5F5).toArgb()
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !darkTheme
                isAppearanceLightNavigationBars = !darkTheme
            }
        }
    }
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = Typography,
        content = content,
    )
}
