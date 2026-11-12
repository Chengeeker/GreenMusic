@file:android.annotation.SuppressLint("RestrictedApi")
// The bundled, pinned Material 1.14.0 utility API is used to match Flutter's color algorithm.
package com.green.music.ui

import android.graphics.Bitmap
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.google.android.material.color.utilities.Hct
import com.google.android.material.color.utilities.QuantizerCelebi
import com.google.android.material.color.utilities.SchemeTonalSpot
import com.google.android.material.color.utilities.Score
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Match Flutter ColorScheme.fromImageProvider: 112 px, Celebi 128, top Score, tonal spot.
suspend fun artworkSeed(bitmap:Bitmap):Int=withContext(Dispatchers.Default) {
    val ratio=minOf(1f,112f/maxOf(bitmap.width,bitmap.height))
    val scaled=Bitmap.createScaledBitmap(bitmap,(bitmap.width*ratio).toInt().coerceAtLeast(1),(bitmap.height*ratio).toInt().coerceAtLeast(1),false)
    try {val pixels=IntArray(scaled.width*scaled.height);scaled.getPixels(pixels,0,scaled.width,0,0,scaled.width,scaled.height)
        Score.score(QuantizerCelebi.quantize(pixels,128),1).first()
    }finally {if(scaled!==bitmap)scaled.recycle()}
}
fun artworkScheme(seed:Int,dark:Boolean):ColorScheme {
    val s=SchemeTonalSpot(Hct.fromInt(seed),dark,0.0)
    return lightColorScheme(primary=Color(s.primary),onPrimary=Color(s.onPrimary),primaryContainer=Color(s.primaryContainer),onPrimaryContainer=Color(s.onPrimaryContainer),
        secondary=Color(s.secondary),onSecondary=Color(s.onSecondary),secondaryContainer=Color(s.secondaryContainer),onSecondaryContainer=Color(s.onSecondaryContainer),
        tertiary=Color(s.tertiary),onTertiary=Color(s.onTertiary),tertiaryContainer=Color(s.tertiaryContainer),onTertiaryContainer=Color(s.onTertiaryContainer),
        background=Color(s.background),onBackground=Color(s.onBackground),surface=Color(s.surface),onSurface=Color(s.onSurface),surfaceVariant=Color(s.surfaceVariant),onSurfaceVariant=Color(s.onSurfaceVariant),
        surfaceContainer=Color(s.surfaceContainer),surfaceContainerLow=Color(s.surfaceContainerLow),surfaceContainerLowest=Color(s.surfaceContainerLowest),surfaceContainerHigh=Color(s.surfaceContainerHigh),surfaceContainerHighest=Color(s.surfaceContainerHighest),
        surfaceDim=Color(s.surfaceDim),surfaceBright=Color(s.surfaceBright),surfaceTint=Color(s.surfaceTint),outline=Color(s.outline),outlineVariant=Color(s.outlineVariant),inverseSurface=Color(s.inverseSurface),inverseOnSurface=Color(s.inverseOnSurface),inversePrimary=Color(s.inversePrimary),
        error=Color(s.error),onError=Color(s.onError),errorContainer=Color(s.errorContainer),onErrorContainer=Color(s.onErrorContainer),scrim=Color(s.scrim))
}

// dynamic_color 1.9.0 uses OS legacy roles plus fromSeed(primary) for newer surface roles.
internal fun flutterDynamicScheme(dark:Boolean,tone:(String,Int)->Color):ColorScheme {
    val primary=tone("accent1",if(dark)80 else 40)
    fun e(t:Int)=Color(Hct.from(25.0,84.0,t.toDouble()).toInt())
    val on=if(dark)20 else 100;val container=if(dark)30 else 90;val onContainer=if(dark)90 else 10
    return artworkScheme(primary.toArgb(),dark).copy(
        primary=primary,onPrimary=tone("accent1",on),primaryContainer=tone("accent1",container),onPrimaryContainer=tone("accent1",onContainer),
        secondary=tone("accent2",if(dark)80 else 40),onSecondary=tone("accent2",on),secondaryContainer=tone("accent2",container),onSecondaryContainer=tone("accent2",onContainer),
        tertiary=tone("accent3",if(dark)80 else 40),onTertiary=tone("accent3",on),tertiaryContainer=tone("accent3",container),onTertiaryContainer=tone("accent3",onContainer),
        error=e(if(dark)80 else 40),onError=e(on),errorContainer=e(container),onErrorContainer=e(if(dark)80 else 10),
        surface=tone("neutral1",if(dark)10 else 99),onSurface=tone("neutral1",if(dark)90 else 10),
        surfaceVariant=tone("neutral2",if(dark)30 else 90),onSurfaceVariant=tone("neutral2",if(dark)80 else 30),
        outline=tone("neutral2",if(dark)60 else 50),outlineVariant=tone("neutral2",if(dark)30 else 80),
        inverseSurface=tone("neutral1",if(dark)90 else 20),inverseOnSurface=tone("neutral1",if(dark)20 else 95),
        inversePrimary=tone("accent1",if(dark)40 else 80),surfaceTint=primary,scrim=tone("neutral1",0))
}
