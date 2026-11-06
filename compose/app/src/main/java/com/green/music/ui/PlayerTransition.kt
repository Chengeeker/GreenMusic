package com.green.music.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.*
import androidx.compose.ui.layout.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import com.green.music.data.Song

internal data class PlayerOrigin(val surface:Rect,val cover:Rect,val title:Rect,val titleStyle:TextStyle)
private val playerCurve = CubicBezierEasing(.645f,.045f,.355f,1f)
private val fadeCurve = CubicBezierEasing(0f,0f,.58f,1f)
internal class PlayerFlight(val origin:PlayerOrigin,val offset:Animatable<Float,AnimationVector1D>,val song:Song,val closing:Boolean) {
    val progress get()=playerCurve.transform(1-offset.value)
    val detailOpacity get()=if(closing)1f-fadeCurve.transform((offset.value/.32f).coerceIn(0f,1f))
        else fadeCurve.transform(((.45f-offset.value)/.45f).coerceIn(0f,1f))
}
internal fun Modifier.playerHero(part:String,full:Boolean=false):Modifier=composed {
    val ui=LocalUi.current;val active=LocalPageActive.current;val style=MaterialTheme.typography.titleSmall
    this.onGloballyPositioned {if(full)ui.playerEnd[part]=it.boundsInRoot()else if(active){ui.playerStart[part]=it.boundsInRoot();if(part=="title")ui.miniTitleStyle=style}}
        .graphicsLayer {alpha=if(ui.playerFlight!=null)0f else 1f}
}
internal fun Modifier.playerSurface(origin:PlayerOrigin?,offset:Animatable<Float,AnimationVector1D>):Modifier=drawWithContent {
    if(origin==null){drawContent();return@drawWithContent}
    val t=playerCurve.transform(1-offset.value)
    val rect=androidx.compose.ui.geometry.lerp(origin.surface,Rect(Offset.Zero,size),t)
    val path=Path().apply{addRoundRect(RoundRect(rect,CornerRadius(24.dp.toPx()*(1-t))))}
    drawContext.canvas.saveLayer(Rect(Offset.Zero,size),Paint().apply{alpha=(t/.3f).coerceIn(0f,1f)})
    clipPath(path){translate(rect.center.x-size.width/2,rect.top){this@drawWithContent.drawContent()}}
    drawContext.canvas.restore()
}
@Composable internal fun PlayerFlightOverlay(flight:PlayerFlight) {
    val ui=LocalUi.current;val density=LocalDensity.current;val t=flight.progress
    val fullArtwork=ui.playerEnd["artwork"]
    val art=fullArtwork?.let {androidx.compose.ui.geometry.lerp(flight.origin.cover,it,t)}
        ?: flight.origin.cover.takeIf { flight.closing && t < .3f }
    val title=ui.playerEnd["title"]?.let {androidx.compose.ui.geometry.lerp(flight.origin.title,it,t)}
    val extraTitleOpacity=if(flight.closing)flight.detailOpacity else 1f
    var extraTitleTop by remember { mutableFloatStateOf(Float.POSITIVE_INFINITY) }
    Box(Modifier.fillMaxSize()) {
        if(art!=null)Box(Modifier.offset{IntOffset(art.left.toInt(),art.top.toInt())}.graphicsLayer {
            alpha=if(fullArtwork!=null)1f else (1f-t/.3f).coerceIn(0f,1f)
        }){Cover(flight.song.cover,with(density){art.width.toDp()},(12+16*t).dp)}
        if(title!=null)Text(flight.song.name,Modifier.offset{IntOffset(title.left.toInt(),title.top.toInt())}
            .width(with(density){title.width.toDp()}).drawWithContent {
                if(extraTitleOpacity > 0f && extraTitleOpacity < 1f && extraTitleTop < size.height) {
                    clipRect(bottom=extraTitleTop){this@drawWithContent.drawContent()}
                    val lower=Rect(0f,extraTitleTop,size.width,size.height)
                    drawContext.canvas.saveLayer(lower,Paint().apply { alpha=extraTitleOpacity })
                    clipRect(top=extraTitleTop){this@drawWithContent.drawContent()}
                    drawContext.canvas.restore()
                } else drawContent()
            },style=androidx.compose.ui.text.lerp(flight.origin.titleStyle,TextStyle(fontSize=24.sp,lineHeight=28.8.sp,fontWeight=FontWeight.Bold),t),
            maxLines=if(extraTitleOpacity<=0f)1 else 2,overflow=TextOverflow.Ellipsis,
            onTextLayout={extraTitleTop=if(it.lineCount>1)it.getLineTop(1)else Float.POSITIVE_INFINITY})
    }
}
