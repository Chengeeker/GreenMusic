package com.green.music.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material.icons.outlined.LibraryMusic
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import coil.compose.SubcomposeAsyncImage
import coil.request.ImageRequest
import com.green.music.data.Song
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

fun Modifier.quietClick(enabled: Boolean = true, role: Role? = null, onClick: () -> Unit): Modifier = composedQuietClick(enabled, role, onClick)
private fun Modifier.composedQuietClick(enabled: Boolean, role: Role?, onClick: () -> Unit): Modifier = composed {
    val ui = LocalUi.current
    val active=LocalPageActive.current
    clickable(remember { MutableInteractionSource() }, indication = null, enabled = enabled&&active, role = role) {
        ui.haptic()
        onClick()
    }
}
@Composable fun hapticClick(action:()->Unit):()->Unit {
    val ui=LocalUi.current;val active=LocalPageActive.current
    return {if(active){ui.haptic();action()}}
}
@Composable fun ActionIcon(icon: ImageVector, label: String, enabled: Boolean = true, tint: Color = LocalContentColor.current, size:Dp=24.dp, action: () -> Unit) {
    Box(Modifier.size(48.dp).clip(RoundedCornerShape(24.dp)).quietClick(enabled, Role.Button, action).semantics { contentDescription=label }, contentAlignment=Alignment.Center) {
        Icon(icon, null, Modifier.size(size), tint=if (enabled) tint else tint.copy(alpha=.38f))
    }
}
@Composable fun SectionHeading(title: String) { Text(title, Modifier.padding(start=16.dp,end=16.dp,bottom=12.dp), style=MaterialTheme.typography.titleSmall, color=MaterialTheme.colorScheme.primary) }
@Composable fun SectionCard(modifier: Modifier = Modifier, shape: Shape = RoundedCornerShape(24.dp), content: @Composable ColumnScope.() -> Unit) {
    val c=MaterialTheme.colorScheme
    Column(modifier.fillMaxWidth().clip(shape).background(if(c.surface==Color.Black)c.surfaceContainer else c.surfaceContainerLow), content=content)
}
internal fun Modifier.floatingBarShadow(dark:Boolean)=drawWithCache {
    val blur=16.dp.toPx();val pad=kotlin.math.ceil(3*(blur*.57735f+.5f)).toInt()
    val bitmap=android.graphics.Bitmap.createBitmap(size.width.toInt().coerceAtLeast(1)+2*pad,size.height.toInt().coerceAtLeast(1)+2*pad,android.graphics.Bitmap.Config.ARGB_8888)
    val paint=android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply{color=Color.Black.copy(alpha=if(dark).35f else .12f).toArgb();maskFilter=android.graphics.BlurMaskFilter(blur,android.graphics.BlurMaskFilter.Blur.NORMAL)}
    android.graphics.Canvas(bitmap).drawRoundRect(pad.toFloat(),pad.toFloat(),pad+size.width,pad+size.height,32.dp.toPx(),32.dp.toPx(),paint)
    val shadow=bitmap.asImageBitmap()
    onDrawBehind{drawImage(shadow,androidx.compose.ui.geometry.Offset(-pad.toFloat(),-pad+4.dp.toPx()))}
}
@Composable fun SectionDivider(indent: Dp = 56.dp, endIndent: Dp = 0.dp) { Box(Modifier.height(1.dp),contentAlignment=Alignment.Center) {HorizontalDivider(Modifier.padding(start=indent,end=endIndent), thickness=.5.dp, color=MaterialTheme.colorScheme.outlineVariant.copy(alpha=.3f))} }
@Composable fun PreferenceRow(title: String, subtitle: String? = null, icon: ImageVector? = null, enabled: Boolean = true,
    trailing: (@Composable () -> Unit)? = null, leading:(@Composable ()->Unit)?=null,
    titleStyle:TextStyle=MaterialTheme.typography.titleMedium, subtitleStyle:TextStyle=MaterialTheme.typography.bodyMedium,
    iconTint:Color=MaterialTheme.colorScheme.onSurfaceVariant, extraVerticalPadding:Dp=0.dp, action: () -> Unit = {}) {
    ReviewTile(title={Text(title,style=titleStyle)},subtitle=subtitle?.let{{Text(it,style=subtitleStyle,color=MaterialTheme.colorScheme.onSurfaceVariant)}},
        leading=leading ?: icon?.let{{Icon(it,null,Modifier.size(24.dp),tint=iconTint)}},
        trailing=trailing ?: {Icon(Icons.Rounded.ChevronRight,null,Modifier.size(24.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)},
        verticalPadding=extraVerticalPadding,enabled=enabled,action=action)
}
// Flutter ListTile uses text baselines and pads text independently of its leading/trailing controls.
@Composable internal fun ReviewTile(title:@Composable ()->Unit,subtitle:(@Composable ()->Unit)?=null,
    leading:(@Composable ()->Unit)?=null,trailing:(@Composable ()->Unit)?=null,
    horizontalPadding:Dp=16.dp,verticalPadding:Dp=3.dp,enabled:Boolean=true,role:Role=Role.Button,modifier:Modifier=Modifier,action:()->Unit={}) {
    androidx.compose.ui.layout.Layout(content={
        Box{title()};Box{subtitle?.invoke()};Box{leading?.invoke()};Box{trailing?.invoke()}
    },modifier=modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).quietClick(enabled,role,action).padding(horizontal=horizontalPadding,vertical=verticalPadding)) {nodes,constraints->
        val loose=constraints.copy(minWidth=0,minHeight=0)
        val lead=nodes[2].measure(loose);val trail=nodes[3].measure(loose)
        val start=if(lead.width>0)maxOf(24.dp.roundToPx(),lead.width)+16.dp.roundToPx()else 0
        val end=if(trail.width>0)maxOf(trail.width+16.dp.roundToPx(),32.dp.roundToPx())else 0
        val textWidth=(constraints.maxWidth-start-end).coerceAtLeast(0)
        val textConstraints=loose.copy(minWidth=textWidth,maxWidth=textWidth)
        val t=nodes[0].measure(textConstraints);val sub=nodes[1].measure(textConstraints)
        val pad=8.dp.roundToPx();val target=(if(subtitle==null)56.dp else 72.dp).roundToPx()
        var height:Int;var ty:Int;var sy=0
        if(subtitle==null){height=maxOf(target,t.height+pad*2);ty=(height-t.height)/2}
        else {
            fun baseline(p:androidx.compose.ui.layout.Placeable)=p[androidx.compose.ui.layout.FirstBaseline].takeIf{it!=androidx.compose.ui.layout.AlignmentLine.Unspecified} ?: p.height
            ty=32.dp.roundToPx()-baseline(t);sy=52.dp.roundToPx()-baseline(sub)
            val overlap=maxOf(ty+t.height-sy,0)/2;ty-=overlap;sy+=overlap
            if(ty<pad||sy+sub.height+pad>target){height=pad*2+t.height+sub.height;ty=pad;sy=pad+t.height}else height=target
        }
        height=constraints.constrainHeight(height)
        layout(constraints.maxWidth,height){t.placeRelative(start,ty);sub.placeRelative(start,sy);lead.placeRelative(0,(height-lead.height)/2);trail.placeRelative(constraints.maxWidth-trail.width,(height-trail.height)/2)}
    }
}
@Composable internal fun listTitleStyle()=MaterialTheme.typography.titleMedium.copy(fontSize=15.sp,lineHeight=20.25.sp)
@Composable internal fun listSubtitleStyle()=MaterialTheme.typography.bodyMedium.copy(fontSize=12.5.sp,lineHeight=17.5.sp,color=MaterialTheme.colorScheme.onSurfaceVariant)
@Composable internal fun ListRow(title:String,subtitle:String?=null,icon:ImageVector?=null,enabled:Boolean=true,
    trailing:(@Composable ()->Unit)?=null,leading:(@Composable ()->Unit)?=null,action:()->Unit={}) {
    PreferenceRow(title,subtitle,icon,enabled,trailing ?: {},leading,titleStyle=listTitleStyle(),subtitleStyle=listSubtitleStyle(),extraVerticalPadding=3.dp,action=action)
}
@Composable fun ToggleRow(title: String, summary: String?=null, value: Boolean, enabled: Boolean=true, icon:ImageVector?=null, iconTint:Color=MaterialTheme.colorScheme.onSurfaceVariant, change: (Boolean)->Unit) {
    val ui=LocalUi.current;val active=LocalPageActive.current
    PreferenceRow(title,summary,icon,enabled=enabled,iconTint=iconTint,extraVerticalPadding=3.dp,
        titleStyle=MaterialTheme.typography.titleMedium.copy(lineHeight=21.6.sp),subtitleStyle=MaterialTheme.typography.bodyMedium.copy(lineHeight=19.6.sp),
        trailing={Switch(value,{if(active){ui.haptic();change(it)}},Modifier.padding(horizontal=4.dp),enabled=enabled&&active)},action={change(!value)})
}
@Composable internal fun ReviewDialog(onDismissRequest:()->Unit, confirmButton:@Composable ()->Unit,
    dismissButton:(@Composable ()->Unit)?=null, title:@Composable ()->Unit, text:@Composable ()->Unit) {
    AlertDialog(onDismissRequest,confirmButton,dismissButton=dismissButton,
        modifier=Modifier.padding(horizontal=40.dp).widthIn(min=280.dp,max=560.dp),properties=DialogProperties(usePlatformDefaultWidth=false),
        title={
            val window=(LocalView.current.parent as? DialogWindowProvider)?.window
            DisposableEffect(window){window?.setWindowAnimations(com.green.music.R.style.ReviewDialogAnimation);window?.setDimAmount(.5f);onDispose{}}
            CompositionLocalProvider(LocalTextStyle provides MaterialTheme.typography.titleLarge.copy(fontSize=18.sp,lineHeight=24.sp)){title()}
        },
        text={CompositionLocalProvider(LocalTextStyle provides MaterialTheme.typography.bodyMedium.copy(color=MaterialTheme.colorScheme.onSurfaceVariant)){text()}},
        shape=RoundedCornerShape(28.dp))
}
internal fun coverImageUrl(value: String): String {
    val raw = value.trim()
    if (raw.startsWith("//")) return "https:$raw"
    if (!raw.startsWith("http://", ignoreCase = true)) return raw
    val url = raw.toHttpUrlOrNull() ?: return raw
    // The playlist APIs still send cleartext URLs for these HTTPS-capable CDNs.
    if (url.host.endsWith(".y.qq.com") || url.host in listOf("y.qq.com", "y.gtimg.cn")) {
        return url.newBuilder().scheme("https").build().toString()
    }
    return raw
}

@Composable fun Cover(url: String, size: Dp=48.dp, radius: Dp=12.dp, modifier:Modifier=Modifier, onBitmap:((android.graphics.Bitmap)->Unit)?=null) {
    val c=MaterialTheme.colorScheme
    val imageUrl = remember(url) { coverImageUrl(url) }
    val context = LocalContext.current
    val pixels = (size.value * context.resources.displayMetrics.density).toInt().coerceIn(1,1200)
    val allowHardware = onBitmap == null
    val request = remember(context, imageUrl, pixels, allowHardware) {
        ImageRequest.Builder(context).data(imageUrl).allowHardware(allowHardware)
            .setHeader("Referer","https://y.qq.com/").size(pixels).build()
    }
    val fallback: @Composable ()->Unit = { Box(Modifier.fillMaxSize().background(c.secondaryContainer),contentAlignment=Alignment.Center) { Icon(Icons.Rounded.MusicNote,null,Modifier.size(size*.4f),tint=c.onSecondaryContainer) } }
    Box(modifier.size(size).clip(RoundedCornerShape(radius))) {
        if(imageUrl.isEmpty()) fallback() else SubcomposeAsyncImage(
            model=request,
            contentDescription=null,modifier=Modifier.fillMaxSize(),contentScale=androidx.compose.ui.layout.ContentScale.Crop,loading={fallback()},error={fallback()},onSuccess={state->(state.result.drawable as? android.graphics.drawable.BitmapDrawable)?.bitmap?.let {onBitmap?.invoke(it)}})
    }
}
@Composable fun SongRow(song: Song, selected: Boolean=false, more: ()->Unit, play: ()->Unit) {
    val c=MaterialTheme.colorScheme
    ReviewTile(title={Text(song.name,maxLines=1,overflow=TextOverflow.Ellipsis,style=listTitleStyle(),color=c.onSurface)},
        subtitle={Text("${song.artistNames} · ${song.album.name}",maxLines=1,overflow=TextOverflow.Ellipsis,style=listSubtitleStyle())},
        leading={Cover(song.cover)},trailing={ActionIcon(Icons.Rounded.MoreHoriz,"${song.name}的更多操作",tint=if(selected)c.primary else c.onSurfaceVariant,action=more)},action=play)
}
@Composable fun ErrorPanel(message: String, retry: ()->Unit) {
    Column(Modifier.fillMaxWidth().padding(24.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        Icon(Icons.Rounded.CloudOff,null,Modifier.size(36.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(12.dp)); Text(message,textAlign=TextAlign.Center); Spacer(Modifier.height(12.dp))
        OutlinedButton(hapticClick(retry)) { Icon(Icons.Rounded.Refresh,null); Spacer(Modifier.width(8.dp)); Text("重试") }
    }
}
@Composable fun EmptyPanel(message: String, icon: ImageVector=Icons.Outlined.LibraryMusic) {
    Column(Modifier.fillMaxWidth().padding(32.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        Icon(icon,null,Modifier.size(48.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant); Spacer(Modifier.height(16.dp)); Text(message,textAlign=TextAlign.Center)
    }
}
@Composable fun Loading() { Box(Modifier.fillMaxWidth().padding(24.dp),contentAlignment=Alignment.Center) { CircularProgressIndicator(Modifier.size(36.dp),strokeWidth=4.dp,strokeCap=androidx.compose.ui.graphics.StrokeCap.Square) } }
@Composable fun ReviewPage(title: String, back: Boolean=true, actions: @Composable RowScope.()->Unit={}, content: @Composable (PaddingValues)->Unit) {
    val ui=LocalUi.current
    val layer=rememberGraphicsLayer();val backdrop=remember {Backdrop(layer)}
    Box(Modifier.fillMaxSize().background(LocalReviewColors.current.background)) {
        val top=WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
        Box(Modifier.fillMaxSize().recordBackdrop(backdrop)) {CompositionLocalProvider(LocalBackdrop provides backdrop){content(PaddingValues(top=top+56.dp,bottom=WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()))}}
        BackdropSurface(Modifier.fillMaxWidth().height(top+56.dp),backdrop)
        Column(Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(LocalReviewColors.current.appBar.copy(alpha=.95f),LocalReviewColors.current.appBar.copy(alpha=0f)))).background(LocalReviewColors.current.appBar.copy(alpha=.45f)).statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().height(56.dp),verticalAlignment=Alignment.CenterVertically) {
                if(back) Box(Modifier.width(56.dp),contentAlignment=Alignment.Center){ActionIcon(Icons.AutoMirrored.Rounded.ArrowBack,"返回",action=ui::back)} else Spacer(Modifier.width(16.dp))
                Text(title,Modifier.weight(1f).padding(start=if(back)16.dp else 0.dp),fontSize=18.sp,fontWeight=FontWeight((700+LocalWeightDelta.current).coerceIn(100,900)),maxLines=1,overflow=TextOverflow.Ellipsis)
                actions()
                Spacer(Modifier.width(4.dp))
            }
            HorizontalDivider(thickness=.5.dp,color=MaterialTheme.colorScheme.outlineVariant.copy(alpha=.24f))
        }
    }
}
fun qualityName(value: String) = when(value) {"lossless"->"无损 FLAC";"exhigh"->"高品质 MP3";else->"标准 MP3"}

@Composable fun MusicPage(title:String,actions:@Composable RowScope.()->Unit={},content:@Composable (PaddingValues)->Unit) {
    val density=LocalDensity.current
    var miniHeight by remember {mutableIntStateOf(0)}
    ReviewPage(title,actions=actions){insets->Box(Modifier.fillMaxSize()) {
        content(PaddingValues(top=insets.calculateTopPadding(),bottom=insets.calculateBottomPadding()+with(density){miniHeight.toDp()}))
        Box(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().onSizeChanged {miniHeight=it.height}) {MiniPlayer()}
    }}
}
@Composable internal fun flutterInputColors()=TextFieldDefaults.colors(focusedContainerColor=Color.Transparent,unfocusedContainerColor=Color.Transparent,disabledContainerColor=Color.Transparent)
