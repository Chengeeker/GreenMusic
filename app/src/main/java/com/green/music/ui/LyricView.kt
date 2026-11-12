@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui
import androidx.compose.material.icons.outlined.Lyrics

import android.content.Context
import android.os.SystemClock
import android.view.accessibility.AccessibilityManager
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.Lifecycle
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.platform.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.*
import androidx.compose.ui.unit.*
import com.green.music.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlin.math.*

fun lyricIndex(lines:List<LyricLine>,time:Long):Int {var lo=0;var hi=lines.size;while(lo<hi){val mid=(lo+hi)/2;if(lines[mid].timeMs<=time)lo=mid+1 else hi=mid};return lo-1}
internal fun lyricWheelProjection(height:Float,density:Float,distance:Float,single:Boolean):android.graphics.Matrix {
    val angle=-distance/(if(single)1 else 3)*2*asin(1f/2.6f)
    val radius=height*2.6f/2;val perspective=.0015f/density
    return android.graphics.Matrix().apply {setValues(floatArrayOf(1f,0f,0f,0f,cos(angle),-radius*sin(angle),0f,-perspective*sin(angle),1+perspective*radius*(1-cos(angle))))}
}
@Composable fun MiniLyricText(song:Song,single:Boolean=false,preview:Boolean=false) {
    val ui=LocalUi.current;val p=ui.app.playback;val state by p.state.collectAsState();val pos by p.position.collectAsStateWithLifecycle(minActiveState=Lifecycle.State.RESUMED)
    var data by remember(song.id){mutableStateOf<List<LyricLine>?>(null)};var error by remember(song.id){mutableStateOf(false)};var retry by remember {mutableIntStateOf(0)}
    LaunchedEffect(song.id,song.mid,retry){error=false;try {data=p.lyrics(song,retry>0).filter{it.text.isNotBlank()}}catch(e:CancellationException){throw e}catch(_:Exception){error=true}}
    val lines=data;val status=when{state.loading&&!preview->"正在加载歌曲…";error->if(single)"歌词暂不可用" else "歌词加载失败，点按重试";lines==null->"正在加载歌词…";lines.isEmpty()->"暂无同步歌词";else->null}
    if(status!=null){Box(Modifier.fillMaxSize().then(if(error&&!single)Modifier.quietClick{retry++}else Modifier),contentAlignment=if(single)Alignment.CenterStart else Alignment.Center){Text(status,style=if(single)MaterialTheme.typography.bodySmall else MaterialTheme.typography.bodyLarge,maxLines=1,overflow=TextOverflow.Ellipsis)};return}
    val index=lyricIndex(lines!!,if(preview)0 else pos);val reduced=reducedMotion();val translated=lines.any {it.translation.isNotEmpty()}
    val context=LocalContext.current;val highContrast=android.provider.Settings.Secure.getInt(context.contentResolver,"high_text_contrast_enabled",0)==1
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
        val height=maxHeight/(if(single)1 else 3)
        val focus=remember(lines,single){Animatable((index+1).toFloat())};var previous by remember(lines,single){mutableIntStateOf(index)}
        LaunchedEffect(index,reduced,preview){val adjacent=abs(index-previous)==1;previous=index
            if(reduced||preview||!adjacent)focus.snapTo((index+1).toFloat()) else focus.animateTo((index+1).toFloat(),tween(280,easing=CubicBezierEasing(.645f,.045f,.355f,1f)))}
        for(i in max(-1,index-2)..min(lines.size,index+2)) key(i) {
            val distance=i+1-focus.value;val amount by animateFloatAsState(if(i==index)1f else 0f,tween(if(reduced||preview)0 else 280,easing=CubicBezierEasing(.645f,.045f,.355f,1f)),label="lyric emphasis")
            val line=lines.getOrNull(i);val text=line?.text ?: if(i==-1&&index==-1)"前奏"else ""
            val density=LocalDensity.current.density
            val projection=remember(maxHeight,density,distance,single){lyricWheelProjection(maxHeight.value*density,density,distance,single)}
            Box(Modifier.fillMaxWidth().height(height).drawWithContent {
                val canvas=drawContext.canvas.nativeCanvas;canvas.save()
                canvas.translate(size.width/2,maxHeight.toPx()/2);canvas.concat(projection);canvas.translate(-size.width/2,-size.height/2)
                drawContent();canvas.restore()
            }.then(if(!single&&!highContrast)Modifier.lyricBlur((.7f*(1-amount)).dp,Triple(line?.text,amount,LocalContentColor.current))else Modifier),contentAlignment=Alignment.CenterStart) {
                Column {Text(text,maxLines=1,overflow=TextOverflow.Ellipsis,fontSize=(if(single)12f else 14+2*amount).sp,lineHeight=(if(single)16.8f else (14+2*amount)*(if(translated)1.2f else 1.5f)).sp,
                    fontWeight=FontWeight(if(single)(400+LocalWeightDelta.current).coerceIn(100,900) else ((400+LocalWeightDelta.current).coerceIn(100,900)*(1-amount)+600*amount).roundToInt()),color=if(single)MaterialTheme.colorScheme.onSurfaceVariant else lerp(MaterialTheme.colorScheme.onSurfaceVariant,MaterialTheme.colorScheme.onSurface,amount))
                    if(!single&&translated)Text(line?.translation.orEmpty(),maxLines=1,overflow=TextOverflow.Ellipsis,fontSize=12.sp,lineHeight=12.sp,color=MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=amount))
                }
            }
        }
    }
}
@Composable fun SyncedLyrics(song:Song,preview:Boolean=false) {
    val ui=LocalUi.current;val p=ui.app.playback;val settings=ui.app.settings.lyrics()
    var lines by remember(song.id){mutableStateOf<List<LyricLine>?>(null)};var error by remember(song.id){mutableStateOf<String?>(null)};var retry by remember {mutableIntStateOf(0)}
    LaunchedEffect(song.id,song.mid,retry){lines=null;error=null;try {lines=p.lyrics(song,retry>0)}catch(e:CancellationException){throw e}catch(e:Exception){error=e.message ?: "歌词加载失败"}}
    when {error!=null->ErrorPanel(error!!){retry++};lines==null->Loading();lines!!.isEmpty()->EmptyPanel("这首歌暂时没有同步歌词",androidx.compose.material.icons.Icons.Outlined.Lyrics);else->LyricRows(lines!!,settings,preview)}
}
@Composable private fun LyricRows(lines:List<LyricLine>,settings:LyricsSettings,preview:Boolean) {
    val ui=LocalUi.current;val p=ui.app.playback;val reduced=reducedMotion();val density=LocalDensity.current;val measurer=rememberTextMeasurer(cacheSize=0)
    val context=LocalContext.current;val highContrast=android.provider.Settings.Secure.getInt(context.contentResolver,"high_text_contrast_enabled",0)==1
    val bold=systemWeightAdjustment(androidx.compose.ui.platform.LocalConfiguration.current,context)>0
    val c=MaterialTheme.colorScheme;val align=if(settings.center)TextAlign.Center else TextAlign.Start
    val style=TextStyle(fontSize=settings.fontSize.sp,lineHeight=(settings.fontSize*1.35f).sp,fontWeight=FontWeight(if(bold)700 else settings.weight),textAlign=align,letterSpacing=0.sp)
    val translated=TextStyle(fontSize=(settings.fontSize*.65f).sp,lineHeight=(settings.fontSize*.65f*1.35f).sp,textAlign=align,fontWeight=if(bold)FontWeight.Bold else null)
    val position = remember(lines) { mutableLongStateOf(p.currentPosition()) }
    val active by remember(lines) { derivedStateOf { lyricIndex(lines, position.longValue) } }
    var manual by remember {mutableLongStateOf(0)}
    val visible=LocalPageActive.current
    val playing by p.state.collectAsState()
    LaunchedEffect(lines,visible) {
        if (visible) p.position.collect { position.longValue = p.currentPosition() }
    }
    LaunchedEffect(lines,preview,visible,playing.playing,reduced,settings.karaoke) {
        position.longValue = p.currentPosition()
        if (visible && !preview && !reduced && playing.playing && settings.karaoke != KaraokeMode.Off) {
            while (isActive) withFrameNanos { position.longValue = p.currentPosition() }
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width=with(density){(maxWidth-32.dp).toPx().toInt().coerceAtLeast(1)};val height=with(density){maxHeight.toPx()};val pad=with(density){24.dp.toPx()}
        val layouts=remember(lines,style,translated,width,density){lines.map {line->
            val main=measurer.measure(AnnotatedString(line.text.ifEmpty {" "}),style,constraints=Constraints(minWidth=width,maxWidth=width))
            val trans=line.translation.takeIf(String::isNotEmpty)?.let {measurer.measure(AnnotatedString(it),translated,constraints=Constraints(minWidth=width,maxWidth=width))}
            main to trans
        }}
        val heights=remember(layouts){layouts.map {(main,trans)->max(with(density){48.dp.toPx()},main.size.height+pad+(trans?.size?.height?.plus(with(density){4.dp.toPx()}) ?: 0f))}}
        val offsets=remember(heights){heights.runningFold(0f){a,b->a+b}}
        val anchor=(height*.47f).coerceIn(min(pad,height/2),max(height-pad,height/2))
        val topPad=max(pad,anchor-heights.first()/2)
        val bottomPad=max(pad,height-anchor-heights.last()/2)
        fun target(index:Int):Float=if(index<0)0f else (topPad+offsets[index]+min(heights[index]/2,max(0f,anchor-with(density){12.dp.toPx()}))-anchor).coerceIn(0f,max(0f,offsets.last()+topPad+bottomPad-height))
        fun itemAt(y:Float):Int=(offsets.indexOfLast {it<=y}).coerceIn(0,lines.lastIndex)
        val initial=remember(layouts,height,anchor){target(active)};val start=itemAt(initial)
        val list=rememberLazyListState(start,(initial-offsets[start]).roundToInt())
        val dragged by list.interactionSource.collectIsDraggedAsState()
        LaunchedEffect(dragged){if(dragged)manual=SystemClock.uptimeMillis()}
        LaunchedEffect(list){snapshotFlow {list.isScrollInProgress}.distinctUntilChanged().collect {if(!it&&manual>0)manual=SystemClock.uptimeMillis()}}
        val motion=remember {Animatable(1f)};var scrollStart by remember {mutableFloatStateOf(0f)};var scrollDelta by remember {mutableFloatStateOf(0f)};var previous by remember {mutableIntStateOf(active)}
        LaunchedEffect(active,layouts,height,anchor){val adjacent=active==previous+1;previous=active
            if(active>=0&&(manual==0L||SystemClock.uptimeMillis()-manual>=4000)&&!dragged){manual=0;val to=target(active);val from=offsets[list.firstVisibleItemIndex]+list.firstVisibleItemScrollOffset;scrollStart=from;scrollDelta=to-from
                if(reduced||preview||!adjacent){val index=itemAt(to);list.scrollToItem(index,(to-offsets[index]).roundToInt());motion.snapTo(1f)}
                else coroutineScope {if(settings.stagger)launch {motion.snapTo(0f);motion.animateTo(1f,tween(420,easing=LinearEasing))};list.animateScrollBy(to-from,tween(260,easing=CubicBezierEasing(.215f,.61f,.355f,1f)))}
            }
        }
        val duration by p.duration.collectAsState()
        LazyColumn(Modifier.fillMaxSize(),state=list,contentPadding=with(density){PaddingValues(top=topPad.toDp(),bottom=bottomPad.toDp())}) {
            itemsIndexed(lines,key={i,_->i}) {i,line->val selected=i==active;val pair=layouts[i];val words=remember(lines,i,selected,duration,settings.karaoke,reduced){if(selected&&!reduced)karaokeWords(lines,i,duration,settings.karaoke).mapIndexed {j,w->w.copy(endMs=w.endMs ?: lines[i].words.getOrNull(j+1)?.timeMs ?: lines.getOrNull(i+1)?.timeMs ?: min(duration.takeIf{it>0} ?: Long.MAX_VALUE,w.timeMs+8000))}else emptyList()}
                Column(Modifier.fillMaxWidth().height(with(density){heights[i].toDp()}).graphicsLayer {
                    if(settings.stagger&&!reduced&&motion.value<1f){val delayed=((motion.value*420-(i-active+2).coerceIn(0,6)*18)/300).coerceIn(0f,1f);translationY=offsets[list.firstVisibleItemIndex]+list.firstVisibleItemScrollOffset-scrollStart-scrollDelta*CubicBezierEasing(.215f,.61f,.355f,1f).transform(delayed)}
                }.then(if(settings.blur&&!selected&&!highContrast)Modifier.lyricBlur((.6f+abs(i-active).coerceAtMost(4)*.25f).dp,Triple(pair,c,selected))else Modifier)
                    .quietClick(!preview) {manual=0;ui.run {p.seek(line.timeMs)}}.semantics {this.selected=selected;contentDescription=listOf(line.text,line.translation).filter(String::isNotEmpty).joinToString("\n")}.padding(horizontal=16.dp,vertical=12.dp),verticalArrangement=Arrangement.Center) {
                    KaraokeLine(pair.first,words,position,if(words.isNotEmpty())c.primary else if(selected)c.onSurface else c.onSurfaceVariant,
                        if(highContrast)c.onSurfaceVariant else c.onSurfaceVariant.copy(alpha=.55f))
                    pair.second?.let {layout->Spacer(Modifier.height(4.dp));Canvas(Modifier.fillMaxWidth().height(with(density){layout.size.height.toDp()})){drawText(layout,color=c.onSurfaceVariant)}}
                }
            }
        }
    }
}
@Composable private fun KaraokeLine(layout:TextLayoutResult,words:List<LyricWord>,position:LongState,color:Color,dim:Color) {
    val density=LocalDensity.current
    val ranges=remember(layout,words){var start=0;words.map {w->val begin=start;start+=w.text.length;begin until min(start,layout.layoutInput.text.length)}}
    Canvas(Modifier.fillMaxWidth().height(with(density){layout.size.height.toDp()})) {
        drawText(layout,color=if(words.isEmpty())color else dim)
        if(words.isNotEmpty()){val now=position.longValue;val path=Path()
            words.forEachIndexed {i,w->val end=w.endMs ?: w.timeMs;val progress=if(now<=w.timeMs)0f else if(end<=w.timeMs)1f else ((now-w.timeMs).toFloat()/(end-w.timeMs)).coerceIn(0f,1f)
                if(progress>0f){val range=ranges[i];if(progress==1f&&!range.isEmpty())path.addPath(layout.getPathForRange(range.first,range.last+1))
                    else {val boxes=range.map {layout.getBoundingBox(it)}.distinct();var remaining=boxes.sumOf {it.width.toDouble()}.toFloat()*progress
                        boxes.forEachIndexed {j,b->val fill=min(remaining,b.width).coerceAtLeast(0f);if(fill>0){val rtl=layout.getBidiRunDirection((range.first+j).coerceAtMost(layout.layoutInput.text.lastIndex))==ResolvedTextDirection.Rtl;path.addRect(Rect(if(rtl)b.right-fill else b.left,b.top,if(rtl)b.right else b.left+fill,b.bottom))};remaining-=fill}
                    }
                }
            };clipPath(path){drawText(layout,color=color)}
        }
    }
}
