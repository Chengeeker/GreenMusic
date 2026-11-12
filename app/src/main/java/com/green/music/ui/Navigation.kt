@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.green.music.MainActivity
import com.green.music.applyDisplayMode
import com.green.music.MusicApplication
import com.green.music.data.*
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicLong

class Screen(val kind: String, val title: String = "", val data: Any? = null,
    val loader: (suspend (Int)->Page<Song>)? = null) {
    val id = ids.incrementAndGet()
    var songs by mutableStateOf<List<Song>>(emptyList())
    var nextOffset by mutableIntStateOf(0)
    var more by mutableStateOf(true)
    var loaded by mutableStateOf(false)
    companion object { private val ids=AtomicLong() }
}
class Ui(val app: MusicApplication, val activity: androidx.activity.ComponentActivity, val scope: CoroutineScope) {
    val stack=mutableStateListOf(Screen("home"))
    internal val playerStart=mutableStateMapOf<String,androidx.compose.ui.geometry.Rect>()
    internal val playerEnd=mutableStateMapOf<String,androidx.compose.ui.geometry.Rect>()
    internal var miniTitleStyle=androidx.compose.ui.text.TextStyle.Default
    internal var playerFlight by mutableStateOf<PlayerFlight?>(null)
    internal val miniPlayerAnchors=mutableStateMapOf<Long,MiniPlayerAnchor>()
    fun openPlayer(){if(stack.lastOrNull()?.kind=="player")return
        val origin=playerStart["surface"]?.let {rect->PlayerOrigin(rect,playerStart["artwork"] ?: rect,playerStart["title"] ?: rect,miniTitleStyle)}
        playerEnd.clear()
        go(Screen("player",data=origin))
    }
    var backScreen by mutableStateOf<Long?>(null)
    var backProgress by mutableFloatStateOf(0f)
    var sheetHeight by mutableFloatStateOf(9f/16f)
    private var sheetContent by mutableStateOf<(@Composable ()->Unit)?>(null)
    var sheet: (@Composable ()->Unit)?
        get()=sheetContent
        set(value){sheetHeight=9f/16f;sheetContent=value}
    fun showSheet(height:Float=9f/16f,content:@Composable ()->Unit){sheet=content;sheetHeight=height}
    var dialog by mutableStateOf<(@Composable ()->Unit)?>(null)
    var toast by mutableStateOf<String?>(null)
    private var toastJob: Job?=null
    private var lastHaptic=0L
    fun haptic(){val now=android.os.SystemClock.uptimeMillis();if(app.settings.bool("haptics",true)&&now-lastHaptic>=40){lastHaptic=now;activity.window.decorView.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY)}}
    fun go(screen: Screen) { stack+=screen }
    fun back() { if(sheet!=null)sheet=null else if(dialog!=null)dialog=null else if(stack.size>1)stack.removeAt(stack.lastIndex) }
    fun message(text: String) { toast=text; toastJob?.cancel(); toastJob=scope.launch { delay(2600); toast=null } }
    fun run(success: String?=null, work: suspend ()->Unit): Job = scope.launch {
        try { work(); if(success!=null)message(success) }
        catch(e: CancellationException){throw e}
        catch(e: Exception){message(if(e is MusicError || e is java.io.IOException)e.message ?: "操作未完成，请重试" else "操作未完成，请重试")}
    }
    suspend fun confirm(title: String, text: String): Boolean {
        val result=CompletableDeferred<Boolean>()
        dialog={ DisposableEffect(result){onDispose{result.complete(false)}};ReviewDialog(onDismissRequest={dialog=null;result.complete(false)},title={Text(title)},text={Text(text)},
            confirmButton={Button(hapticClick({dialog=null;result.complete(true)})){Text("确认")}},dismissButton={TextButton(hapticClick({dialog=null;result.complete(false)})){Text("取消")}}) }
        return try { result.await() } finally { dialog=null }
    }
    suspend fun input(title: String, initial: String=""): String? {
        val result=CompletableDeferred<String?>()
        dialog={ DisposableEffect(result){onDispose{result.complete(null)}};var value by remember { mutableStateOf(initial) }
            ReviewDialog(onDismissRequest={dialog=null;result.complete(null)},title={Text(title)},text={val requester=remember{androidx.compose.ui.focus.FocusRequester()};LaunchedEffect(Unit){requester.requestFocus()};TextField(value,{if(it.length<=20)value=it},modifier=Modifier.focusRequester(requester),colors=flutterInputColors(),singleLine=true,label={Text("歌单名称")},supportingText={Text("${value.length}/20")})},
                confirmButton={Button(hapticClick({if(value.trim().isNotEmpty()){dialog=null;result.complete(value.trim())}})){Text("保存")}},dismissButton={TextButton(hapticClick({dialog=null;result.complete(null)})){Text("取消")}})
        }
        return try {result.await()} finally {dialog=null}
    }
    fun choose(title: String, labels: List<String>, selected: Int, height:Float=.75f, select: (Int)->Unit) {
        showSheet(height){ Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()) {
            Text(title,Modifier.padding(16.dp),style=MaterialTheme.typography.titleLarge)
            labels.forEachIndexed { index,label -> ChoiceRow(label.substringBefore('\n'),index==selected,label.substringAfter('\n',"").takeIf(String::isNotEmpty)) {sheet=null;select(index)} }
        } }
    }
    fun playlist(list: MusicList) = go(Screen("songs",list.name,list) {app.api.playlistPage(list,it)})
    fun album(album: Album) = go(Screen("songs",album.name,album) {offset-> val songs=if(offset==0)app.api.albumSongs(album) else emptyList();Page(songs,songs.size,false)})
    fun songs(title: String, songs: List<Song>) = go(Screen("songs",title,loader={Page(songs,songs.size,false)}))
}
val LocalUi = staticCompositionLocalOf<Ui> { error("GreenMusic UI not initialized") }

@Composable fun GreenMusicRoot(app: MusicApplication, activity: androidx.activity.ComponentActivity) {
    val scope=rememberCoroutineScope(); val ui=remember {Ui(app,activity,scope)}
    val initialized by app.initialized.collectAsState()
    val startupError by app.startupError.collectAsState()
    val player by app.playback.state.collectAsState()
    val displayMode=app.settings.int("screenRefreshRateMode")
    LaunchedEffect(initialized,displayMode){if(initialized)try {activity.applyDisplayMode(displayMode)}catch(_:Exception){app.settings.put("screenRefreshRateMode",0)}}
    LaunchedEffect(startupError){startupError?.let(ui::message)}
    LaunchedEffect(player.error){player.error?.let(ui::message)}
    val holder=rememberSaveableStateHolder()
    GreenMusicTheme(app.settings) {
        val dark=LocalReviewColors.current.dark
        SideEffect{androidx.core.view.WindowCompat.getInsetsController(activity.window,activity.window.decorView).apply{isAppearanceLightStatusBars=!dark;isAppearanceLightNavigationBars=!dark}}
        CompositionLocalProvider(LocalUi provides ui, LocalRippleConfiguration provides null) {
            Surface(color=LocalReviewColors.current.background,contentColor=MaterialTheme.colorScheme.onSurface,modifier=Modifier.fillMaxSize()) {
                BackHandler(ui.sheet!=null || ui.dialog!=null){ui.back()}
                PredictiveBackHandler(ui.stack.size>1&&ui.sheet==null&&ui.dialog==null){events->
                    ui.backScreen=ui.stack.last().id
                    try {events.collect{ui.backProgress=it.progress};ui.back()}
                    catch(e:CancellationException){withContext(NonCancellable){animate(ui.backProgress,0f,animationSpec=tween(220)){v,_->ui.backProgress=v}};ui.backScreen=null}
                }
                Box(Modifier.fillMaxSize()) {
                    if(!initialized)Loading() else {
                        RetainedRoutes(ui) { current ->
                            when(current.kind) {
                                "home"->HomeScreen()
                                "songs"->SongsScreen(current)
                                "charts"->ChartsScreen()
                                "artist"->ArtistScreen(current.data as Artist)
                                "albums"->AlbumsScreen(current)
                                "comments"->CommentsScreen(current.data as Song)
                                "login"->LoginScreen()
                                "webLogin"->WebLoginScreen()
                                "player"->PlayerScreen()
                                "settings"->SettingsScreen()
                                "theme"->ThemeSettingsScreen()
                                "lyricsSettings"->LyricsSettingsScreen()
                                "playbackSettings"->PlaybackSettingsScreen()
                                "downloadSettings"->DownloadSettingsScreen()
                                "downloads"->DownloadsScreen()
                                "downloadTasks"->DownloadTasksScreen()
                                "batch"->BatchDownloadScreen(current)
                                "storage"->StorageSettingsScreen()
                                "cache"->CacheSettingsScreen()
                                "notifications"->NotificationSettingsScreen()
                                "refreshRate"->RefreshRateScreen()
                                "webdav"->WebDavScreen()
                                "licenses"->LicensesScreen()
                                "licenseText"->LicenseTextScreen(current)
                            }
                        }

                    }
                    ui.playerFlight?.let{PlayerFlightOverlay(it)}
                    AnimatedVisibility(ui.toast!=null,Modifier.align(Alignment.BottomCenter).imePadding().navigationBarsPadding().padding(horizontal=24.dp).padding(bottom=84.dp),enter=fadeIn(tween(100)),exit=fadeOut(tween(100))) {
                        var message by remember {mutableStateOf(ui.toast.orEmpty())};ui.toast?.let{message=it}
                        Surface(Modifier.widthIn(max=340.dp).semantics{liveRegion=LiveRegionMode.Polite},color=if(LocalReviewColors.current.dark)Color(0xFF2C2D35).copy(alpha=.96f)else Color(0xFF1E1E24).copy(alpha=.94f),shape=RoundedCornerShape(24.dp),shadowElevation=8.dp){Text(message,Modifier.padding(horizontal=18.dp,vertical=10.dp),color=Color.White,fontSize=13.5.sp,lineHeight=16.875.sp,fontWeight=FontWeight.W500,textAlign=TextAlign.Center)}
                    }
                }
            }
            ui.sheet?.let {ReviewBottomSheet(ui,it)}
            ui.dialog?.invoke()
        }
    }
}

val LocalPageActive=staticCompositionLocalOf {true}
internal data class MiniPlayerAnchor(val layer:GraphicsLayer,val top:Float)
internal val LocalRouteId=staticCompositionLocalOf<Long?> {null}
internal val LocalMiniPlayerInFlight=compositionLocalOf {false}

@Composable fun PageLifecycle(active:Boolean,content:@Composable ()->Unit) {
    val parent=LocalLifecycleOwner.current
    val owner=remember {object:LifecycleOwner {val registry=LifecycleRegistry(this);override val lifecycle:Lifecycle get()=registry}}
    DisposableEffect(parent,active) {
        fun sync(){val state=parent.lifecycle.currentState;owner.registry.currentState=if(state==Lifecycle.State.DESTROYED)state else if(active)state else minOf(state,Lifecycle.State.STARTED)}
        val observer=LifecycleEventObserver{_,_->sync()};parent.lifecycle.addObserver(observer);sync()
        onDispose {parent.lifecycle.removeObserver(observer)}
    }
    DisposableEffect(Unit){onDispose {owner.registry.currentState=Lifecycle.State.DESTROYED}}
    CompositionLocalProvider(LocalLifecycleOwner provides owner,LocalPageActive provides active,content=content)
}

private class RetainedRoute(val screen:Screen) {
    val offset=Animatable(if(screen.kind=="home")0f else 1f)
}

@Composable internal fun RetainedRoutes(ui:Ui, content:@Composable (Screen)->Unit) {
    val retained=remember {mutableStateListOf<RetainedRoute>().apply {addAll(ui.stack.map(::RetainedRoute))}}
    val reduced=reducedMotion();val direction=if(LocalLayoutDirection.current==LayoutDirection.Rtl)-1 else 1
    LaunchedEffect(ui.stack.toList()) {ui.stack.forEach {screen->if(retained.none {it.screen==screen})retained+=RetainedRoute(screen)}}
    val foregroundScreen=ui.stack.last()
    val upper=retained.last()
    val closing=upper.screen !in ui.stack || ui.backScreen==upper.screen.id
    val moving by remember(upper) {derivedStateOf {upper.offset.value>0f}}
    val lower=when {
        reduced->null
        upper.screen !in ui.stack->foregroundScreen
        upper.screen==foregroundScreen&&(moving||closing)->ui.stack.getOrNull(ui.stack.lastIndex-1)
        else->null
    }
    val upperAnchor=ui.miniPlayerAnchors[upper.screen.id]
    val lowerAnchor=lower?.let {ui.miniPlayerAnchors[it.id]}
    val shared=upperAnchor!=null&&lowerAnchor!=null
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width=constraints.maxWidth
        retained.forEach {route->key(route.screen.id) {
            val screen=route.screen
            val present=screen in ui.stack;val foreground=ui.stack.lastOrNull()==screen
            val offset=route.offset
            val origin=screen.data as? PlayerOrigin
            LaunchedEffect(present){
                if(screen.kind=="player"&&!reduced&&origin!=null)ui.app.playback.state.value.current?.let{ui.playerFlight=PlayerFlight(origin,offset,it,closing=!present)}
                if(!present&&ui.backScreen==screen.id)offset.snapTo(ui.backProgress)
                offset.animateTo(if(present)0f else 1f,tween(if(reduced)0 else if(present)if(origin!=null)360 else 320 else ((if(origin!=null)320 else 220)*(1-offset.value)).toInt(),easing=if(origin!=null)LinearEasing else if(present)CubicBezierEasing(.215f,.61f,.355f,1f)else CubicBezierEasing(.55f,.055f,.675f,.19f)))
                if(ui.playerFlight?.offset===offset)ui.playerFlight=null
                if(!present){retained.remove(route);if(ui.backScreen==screen.id){ui.backScreen=null;ui.backProgress=0f}}
            }
            val progress={if(ui.backScreen==screen.id)maxOf(ui.backProgress,offset.value)else offset.value}
            val inFlight=shared&&(route==upper||screen==lower)
            Box(Modifier.fillMaxSize().then(if(origin!=null&&!reduced)Modifier.playerSurface(origin,offset)else Modifier).graphicsLayer{translationX=if(reduced||origin!=null)0f else direction*width*progress()}.then(if(!foreground)Modifier.clearAndSetSemantics {}else Modifier)) {
                CompositionLocalProvider(LocalRouteId provides screen.id,LocalMiniPlayerInFlight provides inFlight) {
                    PageLifecycle(foreground){content(screen)}
                }
            }
            if(route==upper&&upperAnchor!=null&&lowerAnchor!=null) {
                val layer=if(closing)upperAnchor.layer else lowerAnchor.layer
                Canvas(Modifier.matchParentSize()) {
                    val top=upperAnchor.top+(lowerAnchor.top-upperAnchor.top)*progress()
                    translate(left=(size.width-layer.size.width)/2f,top=top) {drawLayer(layer)}
                }
            }
        }}
    }
}

@Composable internal fun ReviewBottomSheet(ui:Ui,content:@Composable ()->Unit) {
    val height=androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp
    val bottom=WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val maximum=if(ui.sheetHeight==9f/16f||ui.sheetHeight==1f)height*ui.sheetHeight-48.dp else height*ui.sheetHeight+bottom
    ModalBottomSheet(onDismissRequest={ui.sheet=null},sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),
        containerColor=if(MaterialTheme.colorScheme.surface==Color.Black)Color(0xFF141414)else MaterialTheme.colorScheme.surfaceContainerLow,
        scrimColor=Color.Black.copy(alpha=.54f),shape=RoundedCornerShape(topStart=28.dp,topEnd=28.dp),
        dragHandle={Box(Modifier.fillMaxWidth().height(48.dp),contentAlignment=Alignment.Center){Box(Modifier.size(38.dp,4.5.dp).background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=.4f),RoundedCornerShape(50)))}}) {
        Box(Modifier.heightIn(max=maximum.coerceAtLeast(0.dp))){content()}
    }
}
