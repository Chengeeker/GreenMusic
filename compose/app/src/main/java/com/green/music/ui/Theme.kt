package com.green.music.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color

import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import com.green.music.data.AppSettings
import org.json.JSONObject

data class ReviewColors(val background: Color, val card: Color, val appBar: Color, val nav: Color, val dark: Boolean)
val LocalReviewColors = staticCompositionLocalOf { ReviewColors(Color.White, Color.White, Color.White, Color.White, false) }
val LocalWeightDelta = staticCompositionLocalOf { 0 }
@Composable
fun GreenMusicTheme(settings: AppSettings, content: @Composable () -> Unit) {
    val dark = when (settings.int("themeMode")) { 1 -> false; 2 -> true; else -> isSystemInDarkTheme() }
    val context = LocalContext.current
    val palettes = remember { JSONObject(context.assets.open("flutter_theme_colors.json").bufferedReader().use { it.readText() }) }
    val index = settings.int("colorIndex", 3).coerceIn(0,7)
    val pure = settings.bool("pureBlack") && dark
    val dynamic=settings.bool("dynamicColor",true)
    val scheme = remember(dark, index, pure, dynamic) {
        var value = if (dynamic && Build.VERSION.SDK_INT >= 31) {
            flutterDynamicScheme(dark) { palette,tone ->
                val id=context.resources.getIdentifier("system_${palette}_${1000-tone*10}","color","android")
                Color(context.resources.getColor(id,context.theme))
            }
        } else {
            val p = palettes.getJSONObject("${index}_${if (dark) "dark" else "light"}")
            fun c(key: String) = Color(p.getLong(key).toInt())
            (if (dark) darkColorScheme() else lightColorScheme()).copy(
                primary=c("primary"), onPrimary=c("onPrimary"), primaryContainer=c("primaryContainer"), onPrimaryContainer=c("onPrimaryContainer"),
                secondary=c("secondary"), onSecondary=c("onSecondary"), secondaryContainer=c("secondaryContainer"), onSecondaryContainer=c("onSecondaryContainer"),
                tertiary=c("tertiary"), onTertiary=c("onTertiary"), tertiaryContainer=c("tertiaryContainer"), onTertiaryContainer=c("onTertiaryContainer"),
                error=c("error"), onError=c("onError"), errorContainer=c("errorContainer"), onErrorContainer=c("onErrorContainer"),
                surface=c("surface"), onSurface=c("onSurface"), surfaceVariant=c("surfaceVariant"), onSurfaceVariant=c("onSurfaceVariant"),
                outline=c("outline"), outlineVariant=c("outlineVariant"), surfaceContainerLowest=c("surfaceContainerLowest"),
                surfaceContainerLow=c("surfaceContainerLow"), surfaceContainer=c("surfaceContainer"), surfaceContainerHigh=c("surfaceContainerHigh"),
                surfaceContainerHighest=c("surfaceContainerHighest"), inverseSurface=c("inverseSurface"), inverseOnSurface=c("inverseOnSurface"),
                inversePrimary=c("inversePrimary"), scrim=c("scrim"),background=c("background"),onBackground=c("onBackground"),
                surfaceTint=c("surfaceTint"),surfaceDim=c("surfaceDim"),surfaceBright=c("surfaceBright"))
        }
        if (pure) value = value.copy(surface=Color.Black, surfaceContainer=Color(0xFF121212), surfaceContainerHigh=Color(0xFF181818), surfaceContainerHighest=Color(0xFF222222))
        value
    }
    val config = LocalConfiguration.current
    val systemDelta = systemWeightAdjustment(config,context)
    val rawDelta = if (settings.bool("customFontWeight")) settings.int("fontWeightDelta").coerceIn(-300,300) else systemDelta
    val delta=kotlin.math.round(rawDelta/100f).toInt()*100
    fun style(size: Float, height: Float, weight: Int) = TextStyle(fontSize=size.sp, lineHeight=height.sp, letterSpacing=0.sp,
        fontWeight=FontWeight((weight+delta).coerceIn(100,900)))
    val typography = Typography(
        displayLarge=style(57f,57f*1.12f,400), displayMedium=style(45f,45f*1.16f,400), displaySmall=style(36f,36f*1.22f,400),
        headlineLarge=style(32f,40f,400), headlineMedium=style(28f,28f*1.29f,400), headlineSmall=style(24f,24f*1.33f,400),
        titleLarge=style(22f,22f*1.27f,700), titleMedium=style(16f,24f,600), titleSmall=style(14f,14f*1.43f,600).copy(color=scheme.onSurfaceVariant),
        bodyLarge=style(16f,24f,400), bodyMedium=style(14f,14f*1.43f,400), bodySmall=style(12f,12f*1.33f,400).copy(color=scheme.onSurfaceVariant),
        labelLarge=style(14f,14f*1.43f,600), labelMedium=style(12f,12f*1.33f,500), labelSmall=style(11f,11f*1.45f,400))
    val review = ReviewColors(if (dark) if (pure) Color.Black else Color(0xFF111215) else scheme.surface,
        if (dark) if (pure) Color(0xFF121212) else Color(0xFF1B1C20) else scheme.surfaceContainerLowest,
        if (dark) if (pure) Color.Black else Color(0xFF111215) else scheme.surface,
        if (dark) if (pure) Color.Black else Color(0xFF16171B) else scheme.surfaceContainer, dark)
    val density = LocalDensity.current
    CompositionLocalProvider(LocalReviewColors provides review, LocalWeightDelta provides delta,
        LocalDensity provides Density(density.density, density.fontScale * settings.float("appTextScale").coerceIn(.8f,1.5f))) {
        MaterialTheme(colorScheme=scheme, typography=typography) {
            CompositionLocalProvider(
                LocalContentColor provides scheme.onSurface,
                LocalTextStyle provides typography.bodyMedium,
                content=content,
            )
        }
    }
}

internal fun systemWeightAdjustment(config:android.content.res.Configuration,context:android.content.Context):Int =
    if(Build.VERSION.SDK_INT>=31&&config.fontWeightAdjustment!=Int.MAX_VALUE)config.fontWeightAdjustment
    else if(android.provider.Settings.Secure.getInt(context.contentResolver,"accessibility_display_bold_text_enabled",0)>0)300 else 0

