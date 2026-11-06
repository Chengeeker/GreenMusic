@file:Suppress("DEPRECATION")
package com.green.music.ui

import android.graphics.Bitmap
import android.graphics.RuntimeShader
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.channels.BufferOverflow
import androidx.compose.ui.unit.IntSize
import kotlinx.coroutines.*
import kotlin.math.ceil
import java.util.concurrent.Executors

class Backdrop(val layer: GraphicsLayer, val behind: Backdrop? = null) {
    var origin by mutableStateOf(Offset.Zero)
    internal var revision = 0L
        private set
    val dirty = MutableSharedFlow<Unit>(replay = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    internal fun recorded() {
        revision++
        dirty.tryEmit(Unit)
    }
}
val LocalBackdrop = staticCompositionLocalOf<Backdrop?> { null }

internal fun DrawScope.drawBackdrop(backdrop: Backdrop, origin: Offset) {
    backdrop.behind?.let { drawBackdrop(it, origin) }
    val shift = backdrop.origin - origin
    translate(shift.x, shift.y) { drawLayer(backdrop.layer) }
}

fun Modifier.recordBackdrop(backdrop: Backdrop) =
    onGloballyPositioned { backdrop.origin = it.positionInRoot() }.drawWithContent {
        backdrop.layer.record { this@drawWithContent.drawContent() }
        drawLayer(backdrop.layer)
        backdrop.recorded()
    }

private fun glassTint(dark: Boolean, indicator: Boolean): Color = when {
    indicator && dark -> Color(0x26FFFFFF)
    indicator -> Color(0x18000000)
    dark -> Color(0x66000000)
    else -> Color(0xF0FFFFFF)
}

internal fun glassUniforms(
    width: Float, height: Float, density: Float, dark: Boolean, indicator: Boolean,
    pinch: Float, padding: Int = 0, touch: Offset? = null, glow: Float = 0f, visibility: Float = 1f,
    captureExtent: IntSize? = null, boundsOrigin: Offset = Offset(padding.toFloat(), padding.toFloat()),
): Map<String, FloatArray> {
    val scale = density / 3
    val tint = glassTint(dark, indicator)
    val captureSize = if(captureExtent!=null)floatArrayOf(captureExtent.width.toFloat(),captureExtent.height.toFloat())
        else floatArrayOf(width + 2 * padding, height + 2 * padding)
    return mapOf(
        "uSize" to captureSize,
        "uBounds" to floatArrayOf(boundsOrigin.x, boundsOrigin.y, width, height),
        "uGeometrySize" to captureSize, "uGeometryOffset" to floatArrayOf(0f, 0f),
        "uOpticalProps" to floatArrayOf(1 + (if (indicator) .18f else .19f) * visibility, (if (indicator) .025f else .008f) * visibility, (if (indicator) 20 else 10) * scale * visibility, 1f),
        "uShapeSettings" to floatArrayOf(1f, density),
        "uNativeEdge" to floatArrayOf(0f),
        "uGlassColor" to floatArrayOf(tint.red, tint.green, tint.blue, tint.alpha * visibility),
        "uLightConfig" to floatArrayOf((if (indicator) 2f else .25f) * visibility, 0f, 1 + .5f * visibility),
        "uLightDirection" to floatArrayOf(-.70710677f, -.70710677f),
        "uWhiten" to floatArrayOf(0f), "uWhitenGated" to floatArrayOf(1f),
        "uPinchStrength" to floatArrayOf(pinch),
        "uBackgroundFallback" to floatArrayOf(0f, 0f, 0f, 0f),
        "uCaptureOffset" to floatArrayOf(0f, 0f),
        "uEdgeConfig" to floatArrayOf(0f, visibility, scale, 0f),
        "uPlatformViewMode" to floatArrayOf(0f), "uBodyMode" to floatArrayOf(if (indicator) 0f else 1f),
        "uTouchPosition" to floatArrayOf((touch?.x ?: 0f) + boundsOrigin.x, (touch?.y ?: 0f) + boundsOrigin.y),
        "uTouchIntensity" to floatArrayOf(glow),
        // Flutter's AnimatedGlassIndicator merge keeps base defaults for body/rim/light.
        "uRimConfig" to floatArrayOf(0f, if (!dark && !indicator) visibility else 0f, .2f),
        "uLensModel" to floatArrayOf(0f), "uFrost" to floatArrayOf(0f, 0f, 0f, 1f),
        "uBodyShade" to floatArrayOf(0f),
    )
}

@RequiresApi(33)
internal class GlassEffect(context: android.content.Context) {
    private val geometry = RuntimeShader(context.assets.open("glass/geometry.agsl").bufferedReader().use { it.readText() })
    private val render = RuntimeShader(context.assets.open("glass/render.agsl").bufferedReader().use { it.readText() })
    private val geometryOnly = setOf("uShapeSettings", "uNativeEdge")
    private val geometryUniforms = geometryOnly + setOf("uSize", "uBounds", "uOpticalProps")

    private fun shader(values: Map<String, FloatArray>): RuntimeShader {
        values.forEach { (name, value) ->
            if (name in geometryUniforms) geometry.setFloatUniform(name, value)
            if (name !in geometryOnly) render.setFloatUniform(name, value)
        }
        render.setInputShader("uGeometryTexture", geometry)
        return render
    }

    fun effect(values: Map<String, FloatArray>, blur: Float): RenderEffect {
        val glass = android.graphics.RenderEffect.createRuntimeShaderEffect(shader(values), "uBackgroundTexture")
        if (blur <= .01f) return glass.asComposeRenderEffect()
        return android.graphics.RenderEffect.createChainEffect(
            glass,
            android.graphics.RenderEffect.createBlurEffect(blur, blur, android.graphics.Shader.TileMode.CLAMP),
        ).asComposeRenderEffect()
    }
}

/** Capture beyond the capsule so refraction and blur can reach neighboring pixels. */
@Composable
fun BackdropSurface(
    modifier: Modifier = Modifier, backdrop: Backdrop? = LocalBackdrop.current,
    blur: Float = 20f, glass: Boolean = false, indicator: Boolean = false, pinch: Float = 0f,
    touch: Offset? = null, glow: Float = 0f, visibility: Float = 1f,
    forceLegacy: Boolean = false,
) {
    if (backdrop == null) return
    val context = LocalContext.current
    val layoutDensity = LocalDensity.current
    val density = layoutDensity.density
    val direction = LocalLayoutDirection.current
    val dark = LocalReviewColors.current.dark
    val background = LocalReviewColors.current.background
    var origin by remember { mutableStateOf(Offset.Zero) }
    var extent by remember { mutableStateOf(IntSize.Zero) }
    val layer = rememberGraphicsLayer()
    val physicalBlur = blur * density
    val padding = ceil(maxOf(if (glass) 26 * density else 0f, 3 * physicalBlur)).toInt()
    val paddingOffset = Offset(padding.toFloat(), padding.toFloat())
    val captureSize = IntSize(extent.width + 2 * padding, extent.height + 2 * padding)
    val canvasModifier = modifier.then(if (glass) Modifier else Modifier.clipToBounds())
        .onGloballyPositioned { origin = it.positionInRoot(); extent = it.size }
    val values = remember(extent, density, dark, indicator, pinch, padding, touch, glow, visibility) {
        glassUniforms(extent.width.toFloat(), extent.height.toFloat(), density, dark, indicator, pinch, padding, touch, glow, visibility)
    }

    if (!forceLegacy && Build.VERSION.SDK_INT >= 31 && (!glass || Build.VERSION.SDK_INT >= 33)) {
        val effect = if (Build.VERSION.SDK_INT >= 33 && glass) {
            val shader = remember(context) { GlassEffect(context) }
            remember(values, physicalBlur) { shader.effect(values, physicalBlur) }
        } else remember(physicalBlur) { if (physicalBlur > .01f) BlurEffect(physicalBlur, physicalBlur, TileMode.Clamp) else null }
        Canvas(canvasModifier) {
            if (extent.width <= 0 || extent.height <= 0) return@Canvas
            layer.renderEffect = effect
            layer.clip = true
            layer.record(layoutDensity, direction, captureSize) {
                drawRect(background)
                drawBackdrop(backdrop, origin - paddingOffset)
            }
            translate(-paddingOffset.x, -paddingOffset.y) { drawLayer(layer) }
        }
    } else {
        val active = LocalPageActive.current
        var bitmap by remember { mutableStateOf<ImageBitmap?>(null) }
        val worker = remember { Executors.newSingleThreadExecutor { r -> Thread(r, "GreenMusic-glass").apply { isDaemon = true } }.asCoroutineDispatcher() }
        val renderer = remember(context, glass) { if (glass) LegacyGlass(context) else null }
        val latestValues by rememberUpdatedState(values)
        val latestBackground by rememberUpdatedState(background)
        DisposableEffect(renderer, worker) {
            onDispose { CoroutineScope(worker).launch { try { renderer?.close() } finally { worker.close() } } }
        }
        LaunchedEffect(backdrop, active, physicalBlur, padding, renderer) {
            if (!active) return@LaunchedEffect
            try {
                combine(backdrop.dirty, snapshotFlow { Triple(origin, extent, latestValues) }) { _, request -> request }
                    .conflate().collect { (position, size, uniforms) ->
                        if (size.width <= 0 || size.height <= 0) return@collect
                        val frameSize = IntSize(size.width + 2 * padding, size.height + 2 * padding)
                        layer.clip = true
                        layer.record(layoutDensity, direction, frameSize) {
                            drawRect(latestBackground)
                            drawBackdrop(backdrop, position - paddingOffset)
                        }
                        val captured = layer.toImageBitmap().asAndroidBitmap()
                        val output = withContext(worker) {
                            val input = captured.copy(Bitmap.Config.ARGB_8888, false)
                            val blurred = if(physicalBlur<=.01f)input else try { blurBitmap(input, physicalBlur) } finally { input.recycle() }
                            if (renderer == null) blurred else try { renderer.render(blurred, uniforms) } finally { blurred.recycle() }
                        }
                        bitmap = output.asImageBitmap()
                        delay(33)
                    }
            } catch (e: RuntimeException) {
                if (e is CancellationException) throw e
                android.util.Log.w("GreenMusic", "Backdrop rendering unavailable", e)
                bitmap = null
            }
        }
        Canvas(canvasModifier) {
            val frame = bitmap
            if (frame != null) translate(-paddingOffset.x, -paddingOffset.y) { drawImage(frame) }
            else if (glass) drawRoundRect(
                glassTint(dark, indicator),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2),
            )
        }
    }
}

/** Three box passes approximate the same Gaussian kernel without an API-31 requirement. */
internal fun blurBitmap(source:Bitmap,sigma:Float):Bitmap {
    val w=source.width;val h=source.height;val pixels=IntArray(w*h);source.getPixels(pixels,0,w,0,0,w,h)
    if(sigma<=.01f)return source.copy(Bitmap.Config.ARGB_8888,false)
    for(i in pixels.indices){val p=pixels[i];val a=p ushr 24;pixels[i]=(a shl 24)or((((p ushr 16)and 255)*a/255)shl 16)or((((p ushr 8)and 255)*a/255)shl 8)or((p and 255)*a/255)}
    val temp=IntArray(pixels.size);var low=kotlin.math.sqrt(4*sigma*sigma+1).toInt().coerceAtLeast(1);if(low%2==0)low--
    val countLow=kotlin.math.round((12*sigma*sigma-3*low*low-12*low-9)/(-4*low-4)).toInt().coerceIn(0,3)
    fun pass(input:IntArray,output:IntArray,horizontal:Boolean,radius:Int) {
        val length=if(horizontal)w else h;val rows=if(horizontal)h else w;val count=2*radius+1
        for(row in 0 until rows){var a=0L;var r=0L;var g=0L;var b=0L
            fun at(i:Int):Int=if(horizontal)row*w+i.coerceIn(0,w-1)else i.coerceIn(0,h-1)*w+row
            fun add(pixel:Int,sign:Int){a+=(pixel ushr 24)*sign;r+=((pixel ushr 16)and 255)*sign;g+=((pixel ushr 8)and 255)*sign;b+=(pixel and 255)*sign}
            for(i in -radius..radius)add(input[at(i)],1)
            for(i in 0 until length){output[at(i)]=((a/count).toInt() shl 24)or((r/count).toInt() shl 16)or((g/count).toInt() shl 8)or(b/count).toInt();add(input[at(i-radius)],-1);add(input[at(i+radius+1)],1)}
        }
    }
    repeat(3){val radius=((if(it<countLow)low else low+2)-1)/2;pass(pixels,temp,true,radius);pass(temp,pixels,false,radius)}
    for(i in pixels.indices){val p=pixels[i];val a=p ushr 24;if(a>0)pixels[i]=(a shl 24)or((((p ushr 16)and 255)*255/a).coerceAtMost(255)shl 16)or((((p ushr 8)and 255)*255/a).coerceAtMost(255)shl 8)or((p and 255)*255/a).coerceAtMost(255)}
    return Bitmap.createBitmap(pixels,w,h,Bitmap.Config.ARGB_8888)
}

fun Modifier.lyricBlur(radius:androidx.compose.ui.unit.Dp,cacheKey:Any):Modifier=composed {
    if(radius.value<=.01f)return@composed this
    if(Build.VERSION.SDK_INT>=31)return@composed this.then(Modifier.graphicsLayer {renderEffect=BlurEffect(radius.toPx(),radius.toPx(),TileMode.Decal)})
    val density=LocalDensity.current;val layer=rememberGraphicsLayer();var extent by remember {mutableStateOf(IntSize.Zero)}
    var raster by remember(cacheKey,radius){mutableStateOf<ImageBitmap?>(null)}
    val recorded=remember(cacheKey,radius,extent){CompletableDeferred<Unit>()}
    LaunchedEffect(cacheKey,radius,extent){if(extent.width>0&&extent.height>0){recorded.await();withFrameNanos{};if(layer.size.width<=0||layer.size.height<=0)return@LaunchedEffect;val source=layer.toImageBitmap().asAndroidBitmap().copy(Bitmap.Config.ARGB_8888,false)
        raster=withContext(Dispatchers.Default){blurBitmap(source,with(density){radius.toPx()}).also{source.recycle()}}.asImageBitmap()}}
    this.then(Modifier.onGloballyPositioned{extent=it.size}.drawWithContent {layer.record {this@drawWithContent.drawContent()};recorded.complete(Unit);val image=raster;if(image==null)drawLayer(layer)else drawImage(image)})
}
