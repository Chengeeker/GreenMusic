@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material.icons.outlined.Lyrics
import androidx.compose.material.icons.filled.Lyrics
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.positionInRoot
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.Lifecycle
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import androidx.media3.common.Player
import com.green.music.data.*
import com.green.music.player.*
import kotlinx.coroutines.*
import kotlin.math.*

@Composable fun reducedMotion(): Boolean {
    val context=LocalContext.current
    return Settings.Global.getFloat(context.contentResolver,Settings.Global.ANIMATOR_DURATION_SCALE,1f)==0f
}
@Composable fun SwipeFrame(value: Any, neighbor: (Int)->Boolean, change:(Int)->Unit, modifier:Modifier=Modifier, outgoingContent:(@Composable (Any)->Unit)?=null, retainedPane:Int?=null, content:@Composable (Int)->Unit) {
    val scope=rememberCoroutineScope();val density=LocalDensity.current;val reduced=reducedMotion()
    val progress=remember {Animatable(0f)};var distance by remember {mutableFloatStateOf(0f)};var gesture by remember {mutableStateOf(false)}
    var epoch by remember {mutableIntStateOf(0)};var settle by remember {mutableStateOf<Job?>(null)}
    val tracker=remember {VelocityTracker()};val neighborNow by rememberUpdatedState(neighbor);val changeNow by rememberUpdatedState(change)
    var outgoing by remember{mutableStateOf<Any?>(null)}
    var previousValue by remember {mutableStateOf(value)};var committed by remember{mutableStateOf(false)}
    var measuredWidth by remember{mutableFloatStateOf(0f)}
    LaunchedEffect(value){epoch++;settle?.cancel();distance=0f;gesture=false
        val old=previousValue
        val direction=when {old is Pair<*,*>&&value is Pair<*,*>&&old.first==value.first&&old.second!=value.second->if(value.second==true)1 else -1
            old is Triple<*,*,*>&&value is Triple<*,*,*>&&old.first!=value.first->if((value.third as? Int ?: 0)>(old.third as? Int ?: 0))1 else -1
            else->0}
        if(!committed&&!reduced&&direction!=0){
            outgoing=old
            val carriedOffset = if (retainedPane != null) progress.value else 0f
            progress.snapTo(direction*measuredWidth+carriedOffset)
            previousValue=value
            progress.animateTo(0f,tween(if(value is Pair<*,*>)320 else 220,easing=CubicBezierEasing(.645f,.045f,.355f,1f)))
        }else {
            progress.snapTo(0f)
            previousValue=value
        }
        outgoing=null;committed=false
    }
    BoxWithConstraints(modifier.clipToBounds()) {
        val width=with(density){maxWidth.toPx()}.coerceAtLeast(1f)
        SideEffect{measuredWidth=width}
        fun finish(commit:Boolean) {gesture=false;val own=++epoch;val step=if(distance<0)1 else -1
            settle=scope.launch {gesture=false;progress.snapTo(distance);progress.animateTo(if(commit)-step*width else 0f,tween(if(reduced)0 else (180*(if(commit)1-abs(distance)/width else abs(distance)/width)).roundToInt().coerceAtLeast(1),easing=CubicBezierEasing(.215f,.61f,.355f,1f)))
                if(own==epoch){if(commit){committed=true;changeNow(step)} else {distance=0f;progress.snapTo(0f)}}
            }
        }
        val pendingPane = retainedPane != null && previousValue != value
        val offset = when {
            pendingPane -> if (committed || reduced || (previousValue as? Pair<*, *>)?.first != (value as? Pair<*, *>)?.first) 0f
                else progress.value + if (retainedPane == 1) width else -width
            gesture -> distance
            else -> progress.value
        }
        val step=if(offset<0)1 else -1
        Box(Modifier.fillMaxSize().pointerInput(value,width,reduced){awaitEachGesture {
            val down=awaitFirstDown(requireUnconsumed=false,pass=PointerEventPass.Initial)
            var horizontal=false;var vertical=false;var moved=0f;var last=down.position
            tracker.resetTracking();tracker.addPosition(down.uptimeMillis,down.position)
            try {do {val event=awaitPointerEvent(PointerEventPass.Initial);val change=event.changes.firstOrNull{it.id==down.id} ?: break
                last=change.position;val delta=last-down.position;moved=max(moved,delta.getDistance());tracker.addPosition(change.uptimeMillis,last)
                if(!horizontal&&!vertical&&moved>18.dp.toPx()){horizontal=abs(delta.x)>abs(delta.y);vertical=!horizontal
                    if(horizontal){settle?.cancel();epoch++;gesture=true}}
                if(horizontal){change.consume();distance=if(neighborNow(if(delta.x<0)1 else -1))delta.x.coerceIn(-width,width)else 0f}
                if(!change.pressed){if(moved>6.dp.toPx())change.consume()
                    if(horizontal){val velocity=tracker.calculateVelocity().x;finish(abs(distance)>=48.dp.toPx()&&(velocity==0f||sign(velocity)==sign(distance))&&neighborNow(if(distance<0)1 else -1))};break}
                if(vertical)break
            }while(true)}finally{if(gesture)finish(false)}
        }}) {
            if (retainedPane != null) {
                // A pane keeps its composition as it moves between the resting and preview positions.
                for (pane in 0..1) key(pane) {
                    val paneStep = pane - retainedPane
                    Box(Modifier.fillMaxSize().graphicsLayer {
                        translationX = (if (reduced) 0f else offset) + paneStep * width
                    }.then(if (paneStep != 0) Modifier.clearAndSetSemantics {} else Modifier)) { content(paneStep) }
                }
            } else {
                Box(Modifier.fillMaxSize().graphicsLayer{translationX=if(reduced)0f else offset}){content(0)}
                if(offset!=0f&&(neighborNow(step)||outgoingContent!=null&&outgoing!=null)&&!reduced)Box(Modifier.fillMaxSize().graphicsLayer{translationX=offset+step*width}.clearAndSetSemantics {}){val old=outgoing;if(old!=null&&outgoingContent!=null)outgoingContent(old)else content(step)}
            }
        }
    }
}
@Composable fun PlayButton(compact:Boolean=false) {
    val ui=LocalUi.current;val state by ui.app.playback.state.collectAsState();val c=MaterialTheme.colorScheme
    Box(Modifier.size(if(compact)48.dp else 64.dp).clip(RoundedCornerShape(if(compact)24.dp else 20.dp)).background(if(compact)Color.Transparent else c.primary)
        .quietClick {ui.run {ui.app.playback.toggle()}}.semantics {contentDescription=if(state.playing)"暂停" else "播放"},contentAlignment=Alignment.Center) {
        if(state.loading)CircularProgressIndicator(Modifier.size(20.dp),color=if(compact)c.onSurface else c.onPrimary,strokeWidth=2.dp,strokeCap=androidx.compose.ui.graphics.StrokeCap.Square)
        else Icon(if(state.playing)Icons.Rounded.Pause else Icons.Rounded.PlayArrow,null,Modifier.size(if(compact)28.dp else 40.dp),tint=if(compact)c.onSurface else c.onPrimary)
    }
}
@Composable fun MiniPlayer() {
    val ui=LocalUi.current;val p=ui.app.playback;val state by p.state.collectAsState();val song=state.current ?: return
    val nextIndex=remember(song.id,state.index,state.shuffle,state.songs.size){if(state.shuffle&&state.songs.size>1)kotlin.random.Random.nextInt(state.songs.size-1).let{if(it>=state.index)it+1 else it}else Math.floorMod(state.index+1,state.songs.size)}
    val activePage=LocalPageActive.current
    val route=LocalRouteId.current
    val inFlight=LocalMiniPlayerInFlight.current
    val layer=rememberGraphicsLayer()
    if(route!=null)DisposableEffect(route,layer){onDispose {
        if(ui.miniPlayerAnchors[route]?.layer===layer)ui.miniPlayerAnchors.remove(route)
    }}
    val shared=if(route==null)Modifier else Modifier.drawWithContent {
        layer.record {this@drawWithContent.drawContent()}
        if(!inFlight)drawLayer(layer)
    }
    Surface(Modifier.padding(start=12.dp,end=12.dp,top=4.dp,bottom=6.dp).onGloballyPositioned {
        if(activePage)ui.playerStart["surface"]=it.boundsInRoot()
        if(route!=null)ui.miniPlayerAnchors[route]=MiniPlayerAnchor(layer,it.positionInRoot().y)
    }.then(shared).then(if(inFlight)Modifier.clearAndSetSemantics {}else Modifier),shape=RoundedCornerShape(24.dp),color=MaterialTheme.colorScheme.surfaceContainerHigh) {
        CompositionLocalProvider(LocalPageActive provides (activePage&&!inFlight)) {
        Column {Row(verticalAlignment=Alignment.CenterVertically) {
            val rowHeight=(maxOf(42f,36.8f*LocalDensity.current.fontScale)+24).dp
            val track:@Composable (Song,Boolean)->Unit={shown,preview->
                Row(Modifier.fillMaxSize().quietClick {ui.openPlayer()}.padding(12.dp),verticalAlignment=Alignment.CenterVertically) {
                    Cover(shown.cover,42.dp,modifier=if(!preview)Modifier.playerHero("artwork")else Modifier);Spacer(Modifier.width(12.dp));Column(Modifier.weight(1f)) {
                        Text(shown.name,modifier=if(!preview)Modifier.playerHero("title")else Modifier,style=MaterialTheme.typography.titleSmall,maxLines=1,overflow=TextOverflow.Ellipsis)
                        Box(Modifier.height(with(LocalDensity.current){(12*fontScale*1.4f).dp})){MiniLyricText(shown,single=true,preview=preview)}
                    }
                }
            }
            SwipeFrame(Triple(song,song.mid,state.index),{activePage&&!inFlight&&state.songs.size>1},{step->ui.run {p.select(if(step>0)nextIndex else Math.floorMod(state.index-1,state.songs.size))}},Modifier.weight(1f).height(rowHeight),outgoingContent={old->track((old as Triple<*,*,*>).first as Song,true)}) {step->
                track(state.songs[if(step>0)nextIndex else Math.floorMod(state.index+step,state.songs.size)],step!=0)
            }
            PlayButton(true);ActionIcon(Icons.Rounded.QueueMusic,"播放队列"){showQueue(ui)};Spacer(Modifier.width(4.dp))
        };val position by p.position.collectAsStateWithLifecycle(minActiveState=Lifecycle.State.RESUMED);val duration by p.duration.collectAsState()
            LinearProgressIndicator(progress={if(duration>0)(position.toFloat()/duration).coerceIn(0f,1f)else 0f},modifier=Modifier.fillMaxWidth().height(2.dp),trackColor=Color.Transparent,drawStopIndicator={},gapSize=0.dp,strokeCap=StrokeCap.Butt)
        }
        }
    }
}
@Composable fun PlayerScreen() {
    val ui=LocalUi.current;val p=ui.app.playback;val state by p.state.collectAsState();val song=state.current
    var lyrics by rememberSaveable {mutableStateOf(false)}
    SideEffect { if (lyrics) ui.playerEnd.remove("artwork") }
    BackHandler(lyrics&&LocalPageActive.current){lyrics=false}
    val base=MaterialTheme.colorScheme;val pure=base.surface==Color.Black;val dark=LocalReviewColors.current.dark
    var seed by remember(song?.cover){mutableStateOf<Int?>(null)};val scope=rememberCoroutineScope()
    val c=remember(seed,dark,base,pure){seed?.let {artworkScheme(it,dark).let {scheme->if(pure)scheme.copy(surface=Color.Black)else scheme}} ?: base}
    MaterialTheme(colorScheme=c) {CompositionLocalProvider(LocalContentColor provides c.onSurface,LocalTextStyle provides MaterialTheme.typography.bodyMedium){Box(Modifier.fillMaxSize().background(Brush.verticalGradient(if(pure)listOf(Color.Black,Color.Black)else listOf(c.primaryContainer.copy(alpha=.42f).compositeOver(c.surface),c.surface))).systemBarsPadding()) {
        if(song==null)EmptyPanel("选择一首歌曲开始聆听") else Column(Modifier.fillMaxSize().graphicsLayer {
            alpha=ui.playerFlight?.detailOpacity ?: 1f
        }) {
            Column(Modifier.fillMaxWidth().padding(start=24.dp,end=24.dp,top=28.dp,bottom=12.dp)) {
                Text(song.name,modifier=Modifier.playerHero("title",true),fontSize=24.sp,lineHeight=28.8.sp,fontWeight=FontWeight.Bold,maxLines=2,overflow=TextOverflow.Ellipsis)
                Spacer(Modifier.height(4.dp));Text(song.artistNames,style=MaterialTheme.typography.bodyMedium,color=c.onSurfaceVariant,maxLines=1,overflow=TextOverflow.Ellipsis)
            }
            BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal=24.dp)) {
                val wide=maxWidth>=600.dp;val height=maxHeight
                val panel:@Composable (Modifier)->Unit={mod->SwipeFrame(Pair(song.id,lyrics),{if(it>0)!lyrics else lyrics},{lyrics=it>0},mod,retainedPane=if(lyrics)1 else 0){step->
                    val show=if(step==0)lyrics else !lyrics
                    if(show)SyncedLyrics(song,preview=step!=0) else BoxWithConstraints(Modifier.fillMaxSize()) {
                        val mini=(96*LocalDensity.current.fontScale).dp;val art=minOf(maxWidth,maxOf(100.dp,maxHeight-mini-32.dp),400.dp)
                        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom=12.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                            Box(Modifier.quietClick(step==0) {lyrics=true}){Cover(song.cover,art,28.dp,modifier=if(step==0)Modifier.playerHero("artwork",true)else Modifier){bitmap->if(seed==null)scope.launch {try {seed=artworkSeed(bitmap)}catch(e:CancellationException){throw e}catch(_:Exception){}}}}
                            Spacer(Modifier.height(20.dp));Box(Modifier.fillMaxWidth().height(mini).quietClick(step==0) {lyrics=true}){MiniLyricText(song)}
                        }
                    }
                }}
                if(wide)Row(Modifier.fillMaxSize()){panel(Modifier.weight(.44f).fillMaxHeight());Spacer(Modifier.width(32.dp));Column(Modifier.weight(.56f).fillMaxHeight().verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.Bottom){PlayerControls(song,lyrics){lyrics=!lyrics};Spacer(Modifier.height(12.dp))}}
                else Column {panel(Modifier.weight(1f));Spacer(Modifier.height(12.dp));Column(Modifier.heightIn(max=height*.55f).verticalScroll(rememberScrollState()).padding(bottom=12.dp)){PlayerControls(song,lyrics){lyrics=!lyrics}}}
            }
        }
    }}
}}
@Composable private fun PlayerControls(song:Song,lyrics:Boolean,toggleLyrics:()->Unit) {
    val ui=LocalUi.current;val p=ui.app.playback;val state by p.state.collectAsState();val c=MaterialTheme.colorScheme
    state.error?.let {message->Surface(Modifier.padding(top=12.dp),color=c.errorContainer,shape=RoundedCornerShape(16.dp)){Row(Modifier.padding(start=12.dp,end=4.dp,top=8.dp,bottom=8.dp),verticalAlignment=Alignment.CenterVertically){Text(message,Modifier.weight(1f),color=c.onErrorContainer,style=MaterialTheme.typography.bodyMedium);TextButton(hapticClick({ui.run {p.toggle()}})){Text("重试")}}}}
    PlayerSeekBar(song);Spacer(Modifier.height(8.dp))
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically) {
        Surface(color=if(state.shuffle)c.secondaryContainer else Color.Transparent,shape=RoundedCornerShape(24.dp)){ActionIcon(Icons.Rounded.Shuffle,if(state.shuffle)"关闭随机播放" else "随机播放"){ui.run {p.shuffle()}}}
        ActionIcon(Icons.Rounded.SkipPrevious,"上一首",size=32.dp){ui.run {p.previous()}};PlayButton();ActionIcon(Icons.Rounded.SkipNext,"下一首",size=32.dp){ui.run {p.next()}}
        Surface(color=if(state.repeat!=Player.REPEAT_MODE_OFF)c.secondaryContainer else Color.Transparent,shape=RoundedCornerShape(24.dp)){ActionIcon(if(state.repeat==Player.REPEAT_MODE_ONE)Icons.Rounded.RepeatOne else Icons.Rounded.Repeat,when(state.repeat){Player.REPEAT_MODE_ONE->"单曲循环";Player.REPEAT_MODE_ALL->"列表循环";else->"顺序播放"}){ui.run {p.repeat()}}}
    }
    Spacer(Modifier.height(12.dp));val tasks by ui.app.downloads.tasks.collectAsState();val active=ui.app.downloads.owner==(ui.app.api.session?.id ?: "anonymous")&&tasks.any {it.song.id==song.id&&it.status in listOf(DownloadStatus.Waiting,DownloadStatus.Running)}
    val resolved by p.resolved.collectAsState();val local=resolved?.first==song.id&&android.net.Uri.parse(resolved?.second).scheme in listOf("file","content")
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceAround) {
        ActionIcon(if(lyrics)Icons.Filled.Lyrics else Icons.Outlined.Lyrics,if(lyrics)"显示封面" else "同步歌词",action=toggleLyrics)
        ActionIcon(Icons.Rounded.ChatBubbleOutline,"歌曲评论"){ui.go(Screen("comments",data=song))}
        if(active)Box(Modifier.size(48.dp).quietClick{ui.run{ui.app.downloads.cancelAll()}}.semantics{contentDescription=if(tasks.size>1)"取消全部下载"else "取消下载"},contentAlignment=Alignment.Center){CircularProgressIndicator(Modifier.size(24.dp),strokeWidth=2.dp,strokeCap=androidx.compose.ui.graphics.StrokeCap.Square);Icon(Icons.Rounded.Close,null,Modifier.size(14.dp))}
        else ActionIcon(if(local)Icons.Rounded.DownloadDone else Icons.Rounded.Download,if(local)"已下载到本机"else "下载歌曲",enabled=!local){downloadChoice(ui,song)}
        ActionIcon(Icons.Rounded.QueueMusic,"播放队列（${state.songs.size}首）"){showQueue(ui)}
        ActionIcon(Icons.Rounded.MoreHoriz,"歌曲操作"){songActions(ui,song,onQuality={choosePlaybackQuality(ui)})}
    }
}
fun choosePlaybackQuality(ui:Ui) {ui.showSheet(.75f){Column(Modifier.navigationBarsPadding().verticalScroll(rememberScrollState()).padding(top=8.dp,bottom=16.dp)) {
    Text("播放音质",Modifier.padding(start=16.dp,top=8.dp,end=16.dp,bottom=8.dp),style=MaterialTheme.typography.titleLarge)
    listOf("standard","exhigh","lossless").forEach{quality->ChoiceRow(qualityName(quality),quality==ui.app.settings.string("quality","standard")){ui.run{ui.app.settings.put("quality",quality);ui.sheet=null}}}
    Text("从下次加载生效；当前歌曲保留现有音质，权限不足时自动降级。",Modifier.padding(start=16.dp,top=8.dp,end=16.dp))
}}}
fun showQueue(ui:Ui) {ui.showSheet(.65f){val state by ui.app.playback.state.collectAsState();Column(Modifier.navigationBarsPadding().height((androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp*.65f).dp)) {
    Row(Modifier.padding(start=20.dp,end=8.dp,bottom=8.dp),verticalAlignment=Alignment.CenterVertically){Text("播放队列 · ${state.songs.size}",Modifier.weight(1f),style=MaterialTheme.typography.titleLarge);ActionIcon(Icons.Rounded.Stop,"停止播放"){ui.run {ui.app.playback.stop()}}}
    if(state.songs.isEmpty())EmptyPanel("队列里还没有歌曲")else LazyColumn(Modifier.weight(1f)) {itemsIndexed(state.songs){index,song->ReviewTile(title={Text(song.name,maxLines=1,overflow=TextOverflow.Ellipsis,style=listTitleStyle())},subtitle={Text(song.artistNames,maxLines=1,overflow=TextOverflow.Ellipsis,style=listSubtitleStyle())},leading={Cover(song.cover)},trailing={ActionIcon(Icons.Rounded.Close,"移出队列",tint=if(index==state.index)MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant){ui.run {ui.app.playback.remove(index)}}}){ui.run {ui.app.playback.select(index)}}}}
}}}

fun durationText(ms:Long)="${ms.coerceAtLeast(0)/60000}:${(ms.coerceAtLeast(0)/1000%60).toString().padStart(2,'0')}"
@Composable private fun PlayerSeekBar(song:Song) {
    val ui=LocalUi.current;val p=ui.app.playback;val position by p.position.collectAsStateWithLifecycle(minActiveState=Lifecycle.State.RESUMED);val duration by p.duration.collectAsState();val state by p.state.collectAsState()
    var drag by remember(song.id){mutableStateOf<Float?>(null)};var phase by remember {mutableFloatStateOf(0f)};val reduced=reducedMotion()
    val active=LocalPageActive.current
    LaunchedEffect(state.playing,state.loading,drag!=null,reduced,active){if(state.playing&&!state.loading&&drag==null&&!reduced&&active){val start=withFrameNanos{it};while(isActive){withFrameNanos{phase=((it-start)%1_800_000_000L)/1_800_000_000f}}}}
    val total=duration.coerceAtLeast(1);val value=drag ?: (position.toFloat()/total).coerceIn(0f,1f);val c=MaterialTheme.colorScheme
    Slider(value,{drag=it},onValueChangeFinished={val next=drag;drag=null;if(next!=null)ui.run {p.seek((next*total).toLong())}},enabled=duration>0,
        thumb={Canvas(Modifier.size(width=0.dp,height=12.dp)){drawCircle(if(duration>0)c.primary else c.onSurface.copy(alpha=.38f),radius=6.dp.toPx())}},track={slider->Canvas(Modifier.fillMaxWidth().height(16.dp)) {
            val thumb=size.width*slider.value;val y=size.height/2;val gap=7.dp.toPx();val end=(thumb-gap).coerceAtLeast(0f)
            if(thumb+gap<size.width)drawLine(if(duration>0)c.surfaceContainerHighest else c.onSurface.copy(alpha=.12f),Offset(thumb+gap,y),Offset(size.width,y),3.dp.toPx(),StrokeCap.Round)
            val path=Path();path.moveTo(0f,y);var x=2.dp.toPx();val sample=x
            while(x<end+sample){val at=min(x,end);val taper=min(1f,min(at/8.dp.toPx(),(end-at)/8.dp.toPx()));path.lineTo(at,y+sin((at/24.dp.toPx()-phase)*PI*2).toFloat()*2.5.dp.toPx()*taper);x+=sample}
            drawPath(path,if(duration>0)c.primary else c.onSurface.copy(alpha=.38f),style=Stroke(3.dp.toPx(),cap=StrokeCap.Round))
        }})
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){Text(durationText((value*total).toLong()),style=MaterialTheme.typography.bodySmall);Text(durationText(duration),style=MaterialTheme.typography.bodySmall)}
}
