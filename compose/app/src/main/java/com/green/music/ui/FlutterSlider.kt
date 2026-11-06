@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package com.green.music.ui
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.interaction.*
import androidx.compose.animation.core.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.geometry.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.*
import androidx.compose.ui.unit.*
import androidx.compose.ui.window.Popup
import androidx.compose.ui.semantics.*
import kotlin.math.roundToInt

@Composable internal fun FlutterSlider(value:Float,onValueChange:(Float)->Unit,valueRange:ClosedFloatingPointRange<Float>,steps:Int,label:String=value.roundToInt().toString(),onValueChangeFinished:()->Unit) {
    val c=MaterialTheme.colorScheme
    val interactions=remember{MutableInteractionSource()};val pressed by interactions.collectIsPressedAsState();val dragged by interactions.collectIsDraggedAsState()
    val activation by animateFloatAsState(if(pressed||dragged)1f else 0f,tween(if(reducedMotion())0 else 75),label="slider value")
    Slider(value,onValueChange,Modifier.padding(horizontal=14.dp).height(48.dp),valueRange=valueRange,steps=steps,onValueChangeFinished=onValueChangeFinished,interactionSource=interactions,
        thumb={Box(Modifier.size(20.dp).shadow(1.dp,CircleShape).background(c.primary,CircleShape)) {
            if(activation>0f) {
                val density=LocalDensity.current;val measurer=rememberTextMeasurer();val text=measurer.measure(label,MaterialTheme.typography.labelMedium.copy(color=c.onPrimary))
                val width=with(density){maxOf(20.dp,text.size.width.toDp())+8.dp}
                Popup(alignment=Alignment.TopCenter,offset=IntOffset(0,with(density){(-40).dp.roundToPx()})) {
                    Canvas(Modifier.size(width,34.dp).graphicsLayer{scaleX=activation;scaleY=activation;transformOrigin=TransformOrigin(.5f,1f)}.semantics{contentDescription="当前值 $label"}) {
                        val path=Path().apply {moveTo(size.width/2,size.height);lineTo(size.width/2-10.dp.toPx(),24.dp.toPx());lineTo(size.width/2+10.dp.toPx(),24.dp.toPx());close();addRoundRect(RoundRect(Rect(0f,0f,size.width,28.dp.toPx()),CornerRadius(14.dp.toPx())))}
                        drawPath(path,c.primary);drawText(text,topLeft=Offset((size.width-text.size.width)/2,14.dp.toPx()-text.size.height/2))
                    }
                }
            }
        }},
        track={state->Canvas(Modifier.fillMaxWidth().height(4.dp)){
            val fraction=((state.value-valueRange.start)/(valueRange.endInclusive-valueRange.start)).coerceIn(0f,1f);val x=size.width*fraction;val y=size.height/2
            drawLine(c.surfaceContainerHighest,Offset(0f,y),Offset(size.width,y),4.dp.toPx(),StrokeCap.Round)
            drawLine(c.primary,Offset(0f,y),Offset(x,y),6.dp.toPx(),StrokeCap.Round)
            if(steps>0)for(i in 0..steps+1){val at=size.width*i/(steps+1);drawCircle(if(at<=x)c.onPrimary.copy(alpha=.38f)else c.onSurfaceVariant.copy(alpha=.38f),1.dp.toPx(),Offset(at,y))}
        }})
}
