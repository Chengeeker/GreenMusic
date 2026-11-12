@file:OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)

package com.green.music.ui

import android.graphics.Bitmap
import androidx.compose.ui.graphics.vector.ImageVector
import android.view.MotionEvent
import android.view.VelocityTracker
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.layout.*
import androidx.compose.ui.platform.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.*
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlin.math.*
import kotlinx.coroutines.*

@Composable
internal fun navigationGlassMotion(
    selected: Int,
    touching: Boolean,
    dragging: Boolean,
    target: Float,
    longPressed: Boolean,
    reduced: Boolean,
): Pair<Float, Float> {
    val held = touching && dragging
    val water = touching && longPressed && !reduced
    val lens by
        animateFloatAsState(
            if (held) target else selected.toFloat(),
            if (reduced) snap() else glassSpring(if (held) 150 else 350, if (held) .14f else .15f),
            label = "glass-position",
        )
    val press by
        animateFloatAsState(
            if (water) 1f else 0f,
            if (reduced) snap() else if (water) glassSpring(300, .15f) else tween(240, easing = FastOutSlowInEasing),
            label = "glass-thickness",
        )
    return lens to press.coerceIn(0f, 1f)
}

@Composable
internal fun GlassNavigation(
    selected: Int,
    choose: (Int) -> Unit,
    barWidth: Dp,
    barHeight: Dp,
    labelNames: List<String>,
    activeIcons: List<ImageVector>,
    icons: List<ImageVector>,
) {
    val backdrop = LocalBackdrop.current
    val ui = LocalUi.current
    val active = LocalPageActive.current
    val reduced = reducedMotion()
    val context = LocalContext.current
    val density = LocalDensity.current
    val direction = LocalLayoutDirection.current
    val owner = LocalLifecycleOwner.current
    val labelsLayer = rememberGraphicsLayer()
    val selectedLayer = rememberGraphicsLayer()
    val sceneColor = LocalReviewColors.current.background
    val selectedColor = MaterialTheme.colorScheme.primary
    val unselectedColor =
        if (sceneColor.luminance() < .5f) Color.White
        else MaterialTheme.colorScheme.onSurfaceVariant
    val weightDelta = LocalWeightDelta.current
    val scope = rememberCoroutineScope()
    var position by remember { mutableStateOf(Offset.Zero) }
    var dimensions by remember { mutableStateOf(IntSize.Zero) }
    var touching by remember { mutableStateOf(false) }
    var dragging by remember { mutableStateOf(false) }
    var longPressed by remember { mutableStateOf(false) }
    var target by remember { mutableFloatStateOf(selected.toFloat()) }
    val (lens, press) = navigationGlassMotion(selected, touching, dragging, target, longPressed, reduced)
    val dark = LocalReviewColors.current.dark
    val onChoose by rememberUpdatedState(choose)

    var origin by remember { mutableStateOf(Offset.Zero) }
    var vertical by remember { mutableStateOf(false) }
    var velocity by remember { mutableStateOf<VelocityTracker?>(null) }
    var hold by remember { mutableStateOf<Job?>(null) }
    DisposableEffect(active) {
        onDispose {
            hold?.cancel()
            velocity?.recycle()
            velocity = null
            touching = false
            dragging = false
            longPressed = false
        }
    }
    Box(
        Modifier.fillMaxWidth().navigationBarsPadding()
            .padding(bottom = if (WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() > 0.dp) 6.dp else 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.width(barWidth).height(barHeight)) {
            Box(
                Modifier.requiredSize(barWidth + 40.dp, barHeight + 30.dp)
                    .align(Alignment.Center)
                    .onGloballyPositioned {
                        position = it.positionInRoot()
                        dimensions = it.size
                    }
            ) {
            GlassTabLabels(barWidth, barHeight, labelNames, icons, unselectedColor, labelsLayer, false); GlassTabLabels(barWidth, barHeight, labelNames, activeIcons, selectedColor, selectedLayer, true)
            if (backdrop != null) NavigationGlassMaterial(backdrop.layer, { backdrop.origin }, { backdrop.revision },
                labelsLayer, selectedLayer, lens, press, dark, sceneColor,
                ui.app.settings.bool("translucentNavigationGlass", false), labelNames.size, Modifier.fillMaxSize(), active = active)
            else Box(Modifier.fillMaxSize().drawWithContent { drawLayer(labelsLayer) })
        }
            Row(
                Modifier.fillMaxSize().pointerInteropFilter { event ->
                    if (!active) return@pointerInteropFilter false
                    val x = event.x
                    val y = event.y
                    when (event.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            dragging = false
                            longPressed = false
                            hold?.cancel()
                            velocity?.recycle()
                            velocity = VelocityTracker.obtain().also { it.addMovement(event) }
                            origin = Offset(x, y)
                            vertical = false
                            touching = true
                            target =
                                (x / (barWidth.value * density.density) * 3 - .5f).coerceIn(0f, 2f)
                            hold =
                                scope.launch {
                                    delay(220)
                                    longPressed = true
                                    dragging = true
                                    ui.haptic()
                                }
                        }
                        MotionEvent.ACTION_MOVE -> {
                            velocity?.addMovement(event)
                            val dx = x - origin.x
                            val dy = y - origin.y
                            if (hypot(dx, dy) > 18 * density.density) {
                                hold?.cancel()
                                if (abs(dx) > abs(dy)) dragging = true
                                else if (!dragging) vertical = true
                            }
                            if (!vertical)
                                target =
                                    (x / (barWidth.value * density.density) * 3 - .5f).coerceIn(
                                        0f,
                                        2f,
                                    )
                        }
                        MotionEvent.ACTION_UP,
                        MotionEvent.ACTION_CANCEL -> {
                            hold?.cancel()
                            val wasDragging = dragging
                            touching = false
                            velocity?.addMovement(event)
                            velocity?.computeCurrentVelocity(1000)
                            val speed = (velocity?.xVelocity ?: 0f) / density.density
                            val slot =
                                floor(x / (barWidth.value * density.density) * 3)
                                    .toInt()
                                    .coerceIn(0, 2)
                            if (event.actionMasked == MotionEvent.ACTION_UP && !vertical) {
                                val chosen =
                                    if (wasDragging && abs(speed) >= 800 && slot == selected)
                                        (selected + if (speed > 0) 1 else -1).coerceIn(0, 2)
                                    else slot
                                if (!wasDragging || chosen != selected) {
                                    ui.haptic()
                                    onChoose(chosen)
                                }
                            }
                            velocity?.recycle()
                            velocity = null
                            dragging = false
                            longPressed = false
                        }
                    }
                    true
                }
            ) {
                labelNames.forEachIndexed { i, label ->
                    Box(
                        Modifier.weight(1f).fillMaxHeight().semantics {
                            contentDescription = label
                            role = Role.Tab
                            this.selected = selected == i
                            onClick {
                                if (active) { ui.haptic(); onChoose(i) }
                                true
                            }
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun GlassTabLabels(
    barWidth: Dp,
    barHeight: Dp,
    names: List<String>,
    icons: List<ImageVector>,
    color: Color,
    layer: GraphicsLayer,
    selected: Boolean,
) {
    Box(
        Modifier.fillMaxSize()
            .drawWithContent { layer.record { this@drawWithContent.drawContent() } }
            .clearAndSetSemantics {}
    ) {
        Row(Modifier.align(Alignment.Center).size(barWidth, barHeight).padding(horizontal = 4.dp)) {
            names.forEachIndexed { index, name ->
                Column(
                    Modifier.weight(1f).fillMaxHeight(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(icons[index], null, Modifier.size(24.dp), tint = color)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        name,
                        fontSize = 11.sp,
                        lineHeight = 13.2.sp,
                        fontWeight = androidx.compose.ui.text.font.FontWeight(if (selected) 600 else 500),
                        color = color,
                    )
                }
            }
        }
    }
}

internal suspend fun GraphicsLayer.readGlassBitmap(): Bitmap {
    val bitmap = toImageBitmap().asAndroidBitmap()
    if (bitmap.config == Bitmap.Config.ARGB_8888) return bitmap
    return try {
        withContext(Dispatchers.Default) {
            checkNotNull(bitmap.copy(Bitmap.Config.ARGB_8888, false))
        }
    } finally {
        bitmap.recycle()
    }
}
