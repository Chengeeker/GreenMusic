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
    var gpuFailed by remember { mutableStateOf(false) }
    val gpu = android.os.Build.VERSION.SDK_INT >= 33 && !gpuFailed
    val view = remember(gpu, backdrop) { if (gpu || backdrop == null) null else GlassView(context) }
    val crop = rememberGraphicsLayer()
    val labelsLayer = rememberGraphicsLayer()
    val selectedLayer = rememberGraphicsLayer()
    val sceneColor = LocalReviewColors.current.background
    val selectedColor = MaterialTheme.colorScheme.primary
    val unselectedColor =
        if (sceneColor.luminance() < .5f) Color.White
        else MaterialTheme.colorScheme.onSurfaceVariant
    val weightDelta = LocalWeightDelta.current
    val scope = rememberCoroutineScope()
    var failed by remember { mutableStateOf(false) }
    var visible by remember { mutableStateOf(false) }
    var position by remember { mutableStateOf(Offset.Zero) }
    var dimensions by remember { mutableStateOf(IntSize.Zero) }
    var touching by remember { mutableStateOf(false) }
    var dragging by remember { mutableStateOf(false) }
    var longPressed by remember { mutableStateOf(false) }
    var target by remember { mutableFloatStateOf(selected.toFloat()) }
    val (lens, press) = navigationGlassMotion(selected, touching, dragging, target, longPressed, reduced)
    val dark = LocalReviewColors.current.dark
    val onChoose by rememberUpdatedState(choose)
    val latest by rememberUpdatedState(listOf(lens, press, if (dark) 1f else 0f))
    if (view != null && backdrop != null) {
        DisposableEffect(view) {
            view.failure = {
                failed = true
                android.util.Log.w("GreenMusic", "Navigation glass unavailable: $it")
            }
            onDispose { view.close() }
        }
        LaunchedEffect(
            view,
            backdrop,
            position,
            dimensions,
            failed,
            sceneColor,
            selectedColor,
            unselectedColor,
            density,
            weightDelta,
            active,
        ) {
            if (!active) return@LaunchedEffect
            var lastFrame = 0L
            var previousLens = latest[0]
            var previousVelocity = 0f
            var previousRevision = -1L
            var previousValues = emptyList<Float>()
            var previousOrigin = Offset.Unspecified
            var generation = -1
            var lastRead = 0L
            while (isActive && !failed) {
                val frame = withFrameNanos { it }
                val lensVelocity =
                    if (lastFrame == 0L) 0f
                    else (latest[0] - previousLens) * 1_000_000_000f / (frame - lastFrame)
                lastFrame = frame
                previousLens = latest[0]
                if (
                    !view.ready ||
                        dimensions.width == 0 ||
                        labelsLayer.size != dimensions ||
                        selectedLayer.size != dimensions ||
                        !owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
                )
                    continue
                val values = latest
                val currentGeneration = view.surfaceGeneration
                val origin = backdrop.origin
                val readLabels = currentGeneration != generation
                val readBackground =
                    readLabels ||
                        previousOrigin != origin ||
                        (previousRevision != backdrop.revision && frame - lastRead >= 32_000_000L)
                if (!readBackground && previousValues == values && previousVelocity == lensVelocity)
                    continue
                val revision = backdrop.revision
                var background: Bitmap? = null
                var labels: Bitmap? = null
                var activeLabels: Bitmap? = null
                try {
                    if (readBackground) {
                        val sampled =
                            IntSize((dimensions.width + 1) / 2, (dimensions.height + 1) / 2)
                        crop.record(density, direction, sampled) {
                            drawRect(sceneColor)
                            scale(
                                sampled.width.toFloat() / dimensions.width,
                                sampled.height.toFloat() / dimensions.height,
                                Offset.Zero,
                            ) {
                                translate(-position.x + origin.x, -position.y + origin.y) {
                                    drawLayer(backdrop.layer)
                                }
                            }
                        }
                        lastRead = frame
                        background = crop.readGlassBitmap()
                    }
                    if (readLabels) {
                        labels = labelsLayer.readGlassBitmap()
                        activeLabels = selectedLayer.readGlassBitmap()
                    }
                    val done = CompletableDeferred<Boolean>()
                    view.render(
                        background,
                        labels,
                        values[0],
                        values[1],
                        values[2] > 0,
                        density.density,
                        lensVelocity = lensVelocity,
                        selectedLabels = activeLabels,
                        generation = currentGeneration,
                        outputSize = dimensions,
                    ) {
                        done.complete(it)
                    }
                    background = null
                    labels = null
                    activeLabels = null
                    if (done.await()) {
                        visible = true
                        generation = currentGeneration
                        if (readBackground) {
                            previousRevision = revision
                            previousOrigin = origin
                        }
                        previousVelocity = lensVelocity
                        previousValues = values
                    } else {
                        generation = -1
                        visible = false
                    }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    failed = true
                    android.util.Log.w("GreenMusic", "Navigation glass backdrop unavailable", e)
                } finally {
                    background?.recycle()
                    labels?.recycle()
                    activeLabels?.recycle()
                }
            }
        }
    }
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
                if (!dark && (gpu || visible && !failed) && backdrop != null)
                    Box(
                        Modifier.align(Alignment.Center)
                            .size(barWidth, barHeight)
                            .glassEdgeShadow(
                                GlassShadow(4.4f, 1.1f, Color.Black.copy(alpha = .033f)),
                                GlassShadow(1.1f, .55f, Color.Black.copy(alpha = .011f)),
                            )
                    )
                if (android.os.Build.VERSION.SDK_INT >= 33 && gpu && backdrop != null)
                    GlassNavigationGpu(
                        backdrop,
                        labelsLayer,
                        selectedLayer,
                        lens,
                        press,
                        dark,
                        sceneColor,
                        Modifier.fillMaxSize(),
                        onFailure = { gpuFailed = true },
                    )
                else if (view != null && backdrop != null)
                    AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
                if (backdrop == null || !gpu && (!visible || failed))
                    Surface(
                        Modifier.align(Alignment.Center).size(barWidth, barHeight),
                        shape = RoundedCornerShape(999.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHigh,
                        border =
                            BorderStroke(
                                1.dp,
                                MaterialTheme.colorScheme.outlineVariant.copy(alpha = .4f),
                            ),
                    ) {}
                GlassTabLabels(barWidth, barHeight, labelNames, icons, unselectedColor, labelsLayer, false)
                GlassTabLabels(barWidth, barHeight, labelNames, activeIcons, selectedColor, selectedLayer, true)
                if (backdrop == null || !gpu && (!visible || failed)) {
                    Box(
                        Modifier.fillMaxSize().drawWithContent {
                            val slot = (barWidth - 8.dp).toPx() / 3
                            val left = (24.dp).toPx() + selected * slot
                            drawRoundRect(
                                if (dark) Color.White.copy(alpha = 38f / 255)
                                else Color.Black.copy(alpha = 38f / 255),
                                topLeft = Offset(left, (19.dp).toPx()),
                                size = androidx.compose.ui.geometry.Size(slot, (barHeight - 8.dp).toPx()),
                                cornerRadius =
                                    androidx.compose.ui.geometry.CornerRadius((barHeight - 8.dp).toPx() / 2),
                            )
                            clipRect(right = left) { drawLayer(labelsLayer) }
                            clipRect(left = left + slot) { drawLayer(labelsLayer) }
                            clipRect(left = left, right = left + slot) { drawLayer(selectedLayer) }
                        }
                    )
                }
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
