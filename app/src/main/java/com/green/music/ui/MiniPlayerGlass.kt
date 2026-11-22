package com.green.music.ui

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.GraphicsLayerScope
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.kyant.backdrop.Backdrop as KyantBackdrop
import com.kyant.backdrop.drawBackdrop
import com.kyant.backdrop.effects.blur
import com.kyant.backdrop.effects.lens
import com.kyant.backdrop.highlight.Highlight

private class MiniPlayerBackdropSource(
    private val layer: GraphicsLayer,
    private val origin: () -> Offset,
    private val background: Color,
) : KyantBackdrop {
    override val isCoordinatesDependent = true

    override fun DrawScope.drawBackdrop(
        density: Density,
        coordinates: LayoutCoordinates?,
        layerBlock: (GraphicsLayerScope.() -> Unit)?,
    ) {
        val position = coordinates?.takeIf { it.isAttached }?.positionInRoot() ?: return
        drawRect(background)
        translate(origin().x - position.x, origin().y - position.y) {
            drawLayer(layer)
        }
    }
}

@Composable
internal fun MiniPlayerGlassBackground(
    modifier: Modifier = Modifier,
    translucent: Boolean,
) {
    val backdrop = LocalBackdrop.current
    val dark = LocalReviewColors.current.dark
    val scene = MaterialTheme.colorScheme.background
    val shape = RoundedCornerShape(24.dp)
    val tint = (if (dark) Color.Black else if (translucent) Color(0xFFF5F5F5) else Color.White)
        .copy(alpha = if (!translucent) .75f else if (dark) .4f else .42f)
    val source = remember(backdrop, scene) {
        backdrop?.let { MiniPlayerBackdropSource(it.layer, { it.origin }, scene) }
    }

    Box(modifier.clip(shape)) {
        if (Build.VERSION.SDK_INT >= 33 && source != null) {
            Box(
                Modifier.matchParentSize().drawBackdrop(
                    backdrop = source,
                    shape = { shape },
                    effects = {
                        blur((if (translucent && !dark) 6f else 2f).dp.toPx())
                        lens(24.dp.toPx(), 24.dp.toPx())
                    },
                    highlight = { Highlight.Default.copy(alpha = if (dark) .35f else .65f) },
                    shadow = null,
                    onDrawSurface = { drawRect(tint) },
                )
            )
        } else {
            if (backdrop != null) {
                BackdropSurface(
                    Modifier.matchParentSize(),
                    backdrop = backdrop,
                    blur = if (translucent && !dark) 6f else 2f,
                )
            }
            Box(Modifier.matchParentSize().background(tint))
        }
    }
}

internal fun miniPlayerGlassTextColor(dark: Boolean): Color =
    if (dark) Color(0xFFF8F9FE) else Color(0xFF141A25)
