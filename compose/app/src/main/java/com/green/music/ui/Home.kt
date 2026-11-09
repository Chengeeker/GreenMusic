@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.green.music.data.*
import kotlinx.coroutines.*

@Composable fun HomeScreen() {
    val ui=LocalUi.current; var index by rememberSaveable {mutableIntStateOf(0)}
    val player by ui.app.playback.state.collectAsState()
    val visited=remember {mutableStateListOf(index)}
    val initialPositions=remember {mutableMapOf(index to 0f)}
    val parentActive=LocalPageActive.current
    val miniInFlight=LocalMiniPlayerInFlight.current
    val reduced=reducedMotion();val density=LocalDensity.current
    var bottomHeight by remember {mutableStateOf(0.dp)}
    val floating=ui.app.settings.bool("floatingNav",true)
    val layer=rememberGraphicsLayer();val backdrop=remember {Backdrop(layer)}
    ReviewPage(listOf("发现","搜索","我的")[index],back=false) { insets ->
        BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
            val width=constraints.maxWidth.toFloat()
            Box(Modifier.fillMaxSize().padding(bottom=if(floating)0.dp else bottomHeight).recordBackdrop(backdrop)){visited.forEach {tab->key(tab) {
                val position=remember {Animatable(initialPositions[tab] ?: 0f)}
                LaunchedEffect(index) {position.animateTo(if(tab==index)0f else if(tab<index)-1f else 1f,tween(if(reduced)0 else 260,easing=CubicBezierEasing(.215f,.61f,.355f,1f)))}
                Box(Modifier.fillMaxSize().graphicsLayer {translationX=position.value*width}.then(if(tab!=index)Modifier.clearAndSetSemantics {}else Modifier)) {
                    PageLifecycle(parentActive&&tab==index) {
                        val padding=PaddingValues(top=insets.calculateTopPadding()+16.dp,bottom=(if(floating)bottomHeight else insets.calculateBottomPadding())+16.dp)
                        when(tab){0->DiscoverScreen(padding);1->SearchScreen(padding);else->LibraryScreen(padding)}
                    }
                }
            }}
            }
            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().onSizeChanged {bottomHeight=with(density){it.height.toDp()}}.then(if(floating||miniInFlight)Modifier else Modifier.background(LocalReviewColors.current.nav))) {
                MiniPlayer()
                Box(Modifier.graphicsLayer {alpha=if(miniInFlight)0f else 1f}.then(if(miniInFlight)Modifier.clearAndSetSemantics {}else Modifier)) {
                    CompositionLocalProvider(LocalBackdrop provides backdrop,LocalPageActive provides (parentActive&&!miniInFlight)) {
                        ReviewNavigation(index){if(it !in visited){initialPositions[it]=if(it>index)1f else -1f;visited+=it};index=it}
                    }
                }
            }
        }
    }
}

@Composable fun ReviewNavigation(selected: Int, select: (Int)->Unit) {
    val ui=LocalUi.current; val c=MaterialTheme.colorScheme
    val labels=listOf("发现","搜索","我的"); val icons=listOf(Icons.Rounded.Explore,Icons.Rounded.Search,Icons.Rounded.LibraryMusic)
    val inactiveIcons=listOf(Icons.Outlined.Explore,Icons.Outlined.Search,Icons.Outlined.LibraryMusic)
    val density=LocalDensity.current
    if(!ui.app.settings.bool("floatingNav",true)) {
        NavigationBar(Modifier.height(maxOf(68f,12*density.fontScale*1.6f+48).dp+WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()),containerColor=LocalReviewColors.current.nav,tonalElevation=0.dp,windowInsets=WindowInsets.navigationBars) {
            labels.forEachIndexed { i,label->NavigationBarItem(selected==i,hapticClick({select(i)}),icon={Icon(if(i==selected)icons[i]else inactiveIcons[i],null)},
                colors=NavigationBarItemDefaults.colors(selectedIconColor=c.onPrimaryContainer,selectedTextColor=c.primary,indicatorColor=c.primaryContainer,unselectedIconColor=c.onSurfaceVariant,unselectedTextColor=c.onSurfaceVariant),
                label={Text(label,fontSize=12.sp,fontWeight=FontWeight(((if(i==selected)700 else 500)+LocalWeightDelta.current).coerceIn(100,900)))}) }
        }
        return
    }
    val width=minOf(440,LocalConfiguration.current.screenWidthDp-40).dp*2/3
    val height=maxOf(56f,11.5f*density.fontScale*1.6f+32).dp
    val glass=ui.app.settings.bool("liquidGlass")
    if(glass){GlassNavigation(selected,select,width,height,labels,icons,inactiveIcons);return}
    val offset by animateDpAsState((width-8.dp)/3*selected,tween(240,easing=CubicBezierEasing(.215f,.61f,.355f,1f)),label="selected-tab")
    Box(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom=if(WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()>0.dp)6.dp else 14.dp),contentAlignment=Alignment.Center) {
        Box(Modifier.width(width).height(height).floatingBarShadow(LocalReviewColors.current.dark).clip(RoundedCornerShape(32.dp)).background(c.surfaceContainerHigh).padding(4.dp)) {
            Box(Modifier.offset(x=offset).width((width-8.dp)/3).fillMaxHeight().clip(RoundedCornerShape(28.dp)).background(c.secondaryContainer))
            Row(Modifier.fillMaxSize()) {
                labels.forEachIndexed { i,label -> Column(Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(28.dp)).quietClick{select(i)},horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.Center) {
                    AnimatedContent(i==selected,transitionSpec={fadeIn(tween(150,easing=CubicBezierEasing(0f,0f,.58f,1f))) togetherWith fadeOut(tween(150,easing=CubicBezierEasing(.42f,0f,1f,1f)))},label="tab icon") {chosen->Icon(if(chosen)icons[i]else inactiveIcons[i],label,Modifier.size(22.dp),tint=if(chosen)c.onSecondaryContainer else c.onSurfaceVariant)}
                    val color by animateColorAsState(if(i==selected)c.onSecondaryContainer else c.onSurfaceVariant,tween(150,easing=CubicBezierEasing(0f,0f,.58f,1f)),label="tab label")
                    val weight by animateIntAsState(((if(i==selected)600 else 400)+LocalWeightDelta.current).coerceIn(100,900),tween(150,easing=CubicBezierEasing(0f,0f,.58f,1f)),label="tab weight")
                    Spacer(Modifier.height(2.dp));Text(label,fontSize=11.5.sp,fontWeight=FontWeight((kotlin.math.round(weight/100f).toInt()*100).coerceIn(100,900)),color=color)
                } }
            }
        }
    }
}
@Composable fun PlaylistRows(lists: List<MusicList>) {
    val ui=LocalUi.current
    BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal=16.dp)) {
        val columns=(maxWidth.value/170).toInt().coerceIn(2,6)
        val width=(maxWidth-12.dp*(columns-1))/columns
        Column(verticalArrangement=Arrangement.spacedBy(16.dp)) {
            lists.chunked(columns).forEach { row->Row(horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                row.forEach { list->Column(Modifier.width(width).height(width+(48*LocalDensity.current.fontScale).dp+8.dp).quietClick{ui.playlist(list)}) {
                    Cover(list.cover,width,18.dp);Spacer(Modifier.height(8.dp));Text(list.name,Modifier.padding(horizontal=4.dp),maxLines=2,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis,style=MaterialTheme.typography.titleSmall)
                } }
            } }
        }
    }
}
@Composable fun DiscoverScreen(padding: PaddingValues) {
    val ui=LocalUi.current; val session by ui.app.auth.session.collectAsState(); val scope=rememberCoroutineScope();val playback by ui.app.playback.state.collectAsState()
    var featured by remember {mutableStateOf<List<MusicList>?>(null)};var personal by remember {mutableStateOf<List<MusicList>?>(null)}
    var error by remember {mutableStateOf<String?>(null)};var personalError by remember {mutableStateOf<String?>(null)}
    var refreshing by remember {mutableStateOf(false)};var generation by remember {mutableIntStateOf(0)}
    var shelves by remember {mutableStateOf<List<SongShelf>?>(null)};var shelfError by remember {mutableStateOf<String?>(null)}
    LaunchedEffect(generation) { refreshing=true;error=null;try {featured=ui.app.api.featured()}catch(e:CancellationException){throw e}catch(e:Exception){error=e.message ?: "加载失败"}finally{refreshing=false} }
    LaunchedEffect(session?.id,generation) {personal=null;personalError=null;if(session!=null)try{personal=ui.app.api.recommended()}catch(e:CancellationException){throw e}catch(e:Exception){personalError=e.message ?: "加载失败"} }
    LaunchedEffect(session?.id,generation) {shelves=null;shelfError=null;if(session!=null)try{shelves=ui.app.api.songShelves()}catch(e:CancellationException){throw e}catch(e:Exception){shelfError=e.message ?: "加载失败"}}
    PullToRefreshBox(refreshing,{generation++},Modifier.fillMaxSize()) {
        LazyColumn(contentPadding=padding) {
            item {Column(Modifier.padding(horizontal=16.dp)) {
                Text("今天，听点什么",style=MaterialTheme.typography.headlineMedium);Spacer(Modifier.height(8.dp))
                Text(session?.let{"${it.nickname}，欢迎回来"} ?: "发现喜欢的旋律",style=MaterialTheme.typography.bodyLarge,color=MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(24.dp));Row(horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                    val labels=listOf("每日推荐","个性电台","排行榜");val icons=listOf(Icons.Rounded.Today,Icons.Rounded.Radio,Icons.Rounded.BarChart)
                    labels.forEachIndexed { i,label -> Column(Modifier.weight(1f).clip(RoundedCornerShape(18.dp)).background(MaterialTheme.colorScheme.secondaryContainer).quietClick {
                        if(i==2)ui.go(Screen("charts","排行榜")) else if(session==null)ui.go(Screen("login")) else ui.go(Screen("songs",label,loader={ val songs=if(i==0)ui.app.api.daily() else ui.app.api.radio();Page(songs,songs.size,false) }))
                    }.padding(horizontal=8.dp,vertical=12.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                        Icon(icons[i],null,Modifier.size(24.dp),tint=MaterialTheme.colorScheme.onSecondaryContainer);Spacer(Modifier.height(6.dp))
                        Text(label,style=MaterialTheme.typography.labelMedium,fontWeight=FontWeight.W600,textAlign=TextAlign.Center,color=MaterialTheme.colorScheme.onSecondaryContainer)
                    } }
                }
                if(session==null)TextButton(hapticClick({ui.go(Screen("login"))}),Modifier.padding(top=20.dp)){Icon(Icons.Rounded.PersonOutline,null);Spacer(Modifier.width(8.dp));Text("登录，找回你的音乐")}
                Spacer(Modifier.height(24.dp))
            } }
            if(session!=null) {
                if(shelfError!=null)item {ErrorPanel(shelfError!!){generation++}} else if(shelves==null)item {Loading()} else shelves!!.forEach {shelf->
                    item {Row(Modifier.padding(start=20.dp,end=16.dp,top=8.dp,bottom=8.dp),verticalAlignment=Alignment.CenterVertically){Text(shelf.title,Modifier.weight(1f),style=MaterialTheme.typography.titleLarge);ActionIcon(Icons.Rounded.PlayCircleOutline,"播放${shelf.title}"){ui.run {ui.app.playback.playSongs(shelf.songs)}}}}
                    itemsIndexed(shelf.songs.take(5)){i,song->SongRow(song,selected=playback.current?.id==song.id,more={songActions(ui,song)}){ui.run {ui.app.playback.playSongs(shelf.songs,i)}}}
                    item {Box(Modifier.fillMaxWidth(),contentAlignment=Alignment.CenterEnd){TextButton(hapticClick({ui.songs(shelf.title,shelf.songs)})){Text("查看全部")}}}
                }
                item { Text("为你推荐",Modifier.padding(start=20.dp,top=20.dp,end=16.dp,bottom=16.dp),style=MaterialTheme.typography.titleLarge) }
                item { when {personalError!=null->ErrorPanel(personalError!!){generation++};personal==null->Loading();personal!!.isEmpty()->EmptyPanel("QQ 音乐暂未返回个性化歌单");else->PlaylistRows(personal!!)} }
            }
            item {Text("推荐歌单",Modifier.padding(start=20.dp,top=24.dp,end=16.dp,bottom=16.dp),style=MaterialTheme.typography.titleLarge)}
            item {when {error!=null->ErrorPanel(error!!){generation++};featured==null->Loading();featured!!.isEmpty()->EmptyPanel("暂时没有推荐歌单");else->PlaylistRows(featured!!)}}
            if(featured!=null&&error==null)item{Spacer(Modifier.height(32.dp))}
        }
    }
}
@Composable fun LibraryScreen(padding: PaddingValues) {
    val ui=LocalUi.current;val session by ui.app.auth.session.collectAsState()
    var saved by rememberSaveable {mutableStateOf(false)};var generation by remember {mutableIntStateOf(0)}
    var lists by remember {mutableStateOf<List<MusicList>>(emptyList())};var error by remember {mutableStateOf<String?>(null)}
    var busy by remember {mutableStateOf(false)};var offset by remember {mutableIntStateOf(0)};var more by remember {mutableStateOf(true)}
    var epoch by remember {mutableIntStateOf(0)}
    val restoreError by ui.app.auth.restoreError.collectAsState()
    val scope=rememberCoroutineScope();val scroll=rememberLazyListState()
    var openedList by remember {mutableStateOf(false)};var creating by remember{mutableStateOf(false)}
    val pageActive=LocalPageActive.current
    LaunchedEffect(pageActive){if(pageActive&&openedList){openedList=false;generation++}}
    suspend fun load(refresh:Boolean=false) {
        if(busy && !refresh)return
        busy=true;error=null
        if(refresh)epoch++
        val own=epoch;val account=session?.id;val selectedSaved=saved
        try {
            if(refresh){offset=0;lists=emptyList();more=true}
            val page = if (selectedSaved) {
                ui.app.auth.ensurePlaylistIdentity()
                ui.app.api.savedLists(offset)
            } else ui.app.api.ownedLists().let { Page(it, it.size, false) }
            if(own!=epoch||account!=ui.app.api.session?.id||selectedSaved!=saved)return
            val combined=(lists+page.items).distinctBy{it.id};more=page.more&&page.nextOffset>offset&&combined.size>lists.size;lists=combined;offset=page.nextOffset
        }catch(e:CancellationException){throw e}catch(e:Exception){if(own==epoch)error=e.message ?: "加载失败"}finally{if(own==epoch)busy=false}
    }
    LaunchedEffect(session?.id,saved,generation){if(session!=null)load(true) else {epoch++;lists=emptyList();more=false;busy=false}}
    LaunchedEffect(scroll){snapshotFlow{Triple(scroll.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0,scroll.layoutInfo.totalItemsCount,busy)}.collect{(last,count,_)->if(count>2&&last>=count-4&&!busy&&more&&error==null&&session!=null)load()}}
    PullToRefreshBox(busy,{generation++},Modifier.fillMaxSize()) {
        LazyColumn(state=scroll,contentPadding=padding) {
            item { Column(Modifier.padding(horizontal=16.dp)) {
                SectionCard { PreferenceRow(session?.nickname ?: "登录 QQ 音乐",session?.let{"${if(it.loginType==1)"微信" else "QQ"}账号 · ${it.id}"} ?: "同步歌单与收藏",leading={if(!session?.avatar.isNullOrEmpty())Cover(session!!.avatar,48.dp,24.dp)else Icon(Icons.Outlined.AccountCircle,null,Modifier.size(40.dp))}) {
                    if(session==null)ui.go(Screen("login"))else ui.run("账号状态已更新"){ui.app.auth.ensureSession()}
                } }
                restoreError?.let {Text(it,Modifier.padding(top=12.dp),color=MaterialTheme.colorScheme.error)}
                Spacer(Modifier.height(24.dp));SectionCard {
                    PreferenceRow("下载歌曲",icon=Icons.Outlined.Download){ui.go(Screen("downloads"))};SectionDivider()
                    PreferenceRow("最近播放",icon=Icons.Rounded.History){ui.songs("最近播放",ui.app.playback.savedSongs("history"))}
                    if(session!=null) {
                        SectionDivider();PreferenceRow("收藏专辑",icon=Icons.Outlined.Album){ui.go(Screen("albums","收藏专辑",false))}
                        SectionDivider();PreferenceRow("已购单曲",icon=Icons.Outlined.MusicNote){ui.go(Screen("songs","已购单曲",loader={ val p=ui.app.api.purchasedPage(false,it);Page(p.items.songs(),p.nextOffset,p.more) }))}
                        SectionDivider();PreferenceRow("已购数字专辑",icon=Icons.Outlined.ShoppingBag){ui.go(Screen("albums","已购数字专辑",true))}
                    }
                    SectionDivider();PreferenceRow("设置",icon=Icons.Outlined.Settings){ui.go(Screen("settings"))}
                }
                if(session!=null) {Spacer(Modifier.height(28.dp));Row(verticalAlignment=Alignment.CenterVertically) {
                    FlowRow(Modifier.weight(1f),horizontalArrangement=Arrangement.spacedBy(8.dp)){FilterChip(!saved,hapticClick({saved=false;generation++}),label={Text("自建歌单")},leadingIcon=if(!saved)({Icon(Icons.Rounded.Check,null,Modifier.size(18.dp))})else null)
                    FilterChip(saved,hapticClick({saved=true;generation++}),label={Text("收藏歌单")},leadingIcon=if(saved)({Icon(Icons.Rounded.Check,null,Modifier.size(18.dp))})else null)}
                    ActionIcon(Icons.Rounded.Add,"创建歌单",enabled=!creating){creating=true;ui.run {try{ui.input("创建歌单")?.let{ui.app.api.createPlaylist(it);saved=false;generation++}}finally{creating=false}}}
                };Spacer(Modifier.height(24.dp))}
            } }
            items(lists,key={it.id}) {list->ListRow(list.name,"${list.count} 首${if(list.dirId==201)" · 我喜欢的音乐" else ""}",leading={Cover(list.cover)}){openedList=true;ui.playlist(list)}}
            item {when {error!=null->ErrorPanel(error!!){scope.launch{load()}};busy->Loading();more&&session!=null->TextButton(hapticClick({scope.launch{load()}}),Modifier.fillMaxWidth().padding(16.dp)){Text("加载更多歌单")};session!=null&&lists.isEmpty()->EmptyPanel("这里还没有歌单")}}
            if(session!=null&&!busy&&error==null&&lists.isNotEmpty()&&!more)item{Spacer(Modifier.height(32.dp))}
        }
    }
}
