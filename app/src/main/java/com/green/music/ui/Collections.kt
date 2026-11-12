@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.green.music.data.*
import kotlinx.coroutines.*

@Composable fun SongsScreen(screen: Screen) {
    val ui=LocalUi.current;val scope=rememberCoroutineScope();val player by ui.app.playback.state.collectAsState()
    var title by remember {mutableStateOf(screen.title)};var busy by remember {mutableStateOf(false)};var error by remember {mutableStateOf<String?>(null)}
    var job by remember {mutableStateOf<Job?>(null)};var epoch by remember {mutableIntStateOf(0)}
    val list=screen.data as? MusicList;val album=screen.data as? Album;val scroll=rememberLazyListState()
    fun load(refresh:Boolean=false) {
        if(busy&&!refresh || !screen.more&&!refresh)return
        if(refresh){job?.cancel();epoch++;screen.songs=emptyList();screen.nextOffset=0;screen.more=true}
        val generation=epoch
        job=scope.launch {
            busy=true;error=null
            try {
                val page=screen.loader!!.invoke(screen.nextOffset)
                if(generation!=epoch)return@launch
                val fresh=page.items.filter{song->screen.songs.none{it.id==song.id}}
                if(page.more&&(page.nextOffset<=screen.nextOffset || fresh.isEmpty()))throw MusicError("歌曲分页未前进，请重新加载完整歌单")
                screen.songs+=fresh;screen.nextOffset=page.nextOffset;screen.more=page.more;screen.loaded=true
            }catch(e:CancellationException){throw e}catch(e:Exception){error=e.message ?: "加载失败"}finally{if(generation==epoch)busy=false}
        }
    }
    LaunchedEffect(Unit){if(!screen.loaded)load()}
    LaunchedEffect(scroll){snapshotFlow{scroll.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0}.collect{if(it>=scroll.layoutInfo.totalItemsCount-4 && !busy && error==null && screen.loaded)load()}}
    DisposableEffect(Unit){onDispose{job?.cancel()}}
    var writing by remember {mutableStateOf(false)}
    fun action(name:String) {
        if(writing)return
        ui.sheet=null;writing=true
        ui.run {try {
            when(name) {
                "rename"->ui.input("重命名歌单",title)?.let{ui.app.api.renamePlaylist(list!!.id,it);title=it}
                "delete"->if(ui.confirm("删除歌单","删除“$title”及其歌单记录？此操作无法在应用内撤销。")){ui.app.api.deletePlaylist(list!!.id);ui.back()}
                "unfavorite"->if(ui.confirm("取消收藏","取消收藏“$title”？")){ui.app.api.unfavoritePlaylist(list!!.id);ui.back()}
                else->{val liked=ui.app.api.albumLiked(album!!);ui.app.api.likeAlbum(album,!liked);ui.message(if(liked)"已取消收藏专辑" else "已收藏专辑")}
            }
        }finally{writing=false}}
    }
    fun menu() {
        ui.sheet={Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
            if(list?.editable==true){
                ListRow("重命名歌单",icon=Icons.Outlined.Edit,trailing={}){action("rename")}
                ListRow("删除歌单",icon=Icons.Rounded.DeleteOutline,trailing={}){action("delete")}
            }
            if(list?.saved==true)ListRow("取消收藏歌单",icon=Icons.Outlined.BookmarkRemove,trailing={}){action("unfavorite")}
            if(album!=null)ListRow("收藏 / 取消收藏专辑",icon=Icons.Rounded.FavoriteBorder,trailing={}){action("album")}
        }}
    }
    MusicPage(title,actions={if(list?.editable==true||list?.saved==true||album!=null)ActionIcon(Icons.Rounded.MoreHoriz,"歌单操作",!writing,action=::menu)}) {insets->
        Box(Modifier.fillMaxSize()) {
            PullToRefreshBox(busy,{load(true)}) {
                LazyColumn(state=scroll,contentPadding=PaddingValues(top=insets.calculateTopPadding()+16.dp,bottom=insets.calculateBottomPadding())) {
                    item {Column(Modifier.padding(horizontal=16.dp)) {
                        Row(verticalAlignment=Alignment.CenterVertically){Cover(list?.cover ?: album?.cover ?: (screen.data as? Artist)?.cover.orEmpty(),104.dp,22.dp);Spacer(Modifier.width(20.dp));Column(Modifier.weight(1f)){
                            Text(title,style=MaterialTheme.typography.titleLarge);Spacer(Modifier.height(8.dp));Text("${screen.songs.size} 首${if(screen.more)" · 可继续加载" else ""}",style=MaterialTheme.typography.bodySmall)
                        }}
                        if(!list?.description.isNullOrEmpty())Text(android.text.Html.fromHtml(list!!.description,0).toString(),Modifier.padding(top=16.dp),maxLines=5,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                        Spacer(Modifier.height(16.dp))
                        FlowRow(horizontalArrangement=Arrangement.spacedBy(12.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                            Button(hapticClick({ui.run{ui.app.playback.playSongs(screen.songs)}}),enabled=screen.songs.isNotEmpty()){
                                Icon(Icons.Rounded.PlayArrow,null);Spacer(Modifier.width(8.dp));Text("播放全部")
                            }
                            OutlinedButton(hapticClick({ui.go(Screen("batch",title,loader=screen.loader))})){
                                Icon(Icons.Outlined.Download,null);Spacer(Modifier.width(8.dp));Text("批量下载")
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                    }}
                    itemsIndexed(screen.songs,key={_,s->s.id}){i,song->SongRow(song,player.current?.id==song.id,more={songActions(ui,song,list){load(true)}}){ui.run{ui.app.playback.playSongs(screen.songs,i)}}}
                    item {when{error!=null->ErrorPanel(error!!){load()};busy->Loading();screen.songs.isEmpty()->EmptyPanel("这里还没有歌曲");screen.more->OutlinedButton(hapticClick({load()}),Modifier.fillMaxWidth().padding(16.dp)){Text("加载更多")};else->Spacer(Modifier.height(24.dp))}}
                }
            }

        }
    }
}
@Composable fun ChartsScreen() {
    val ui=LocalUi.current;var lists by remember{mutableStateOf<List<MusicList>?>(null)};var error by remember{mutableStateOf<String?>(null)};var retry by remember{mutableIntStateOf(0)}
    LaunchedEffect(retry){error=null;try{lists=ui.app.api.charts()}catch(e:CancellationException){throw e}catch(e:Exception){error=e.message}}
    MusicPage("排行榜"){insets->PullToRefreshBox(false,{retry++},Modifier.fillMaxSize()) {
        when {
            error!=null->Box(Modifier.fillMaxSize().padding(insets),contentAlignment=Alignment.Center){ErrorPanel(error!!){retry++}}
            lists==null->Box(Modifier.fillMaxSize().padding(insets),contentAlignment=Alignment.Center){Loading()}
            lists!!.isEmpty()->Box(Modifier.fillMaxSize().padding(insets),contentAlignment=Alignment.Center){EmptyPanel("暂时没有歌单")}
            else->LazyColumn(contentPadding=PaddingValues(top=insets.calculateTopPadding()+16.dp,bottom=insets.calculateBottomPadding()+24.dp)){item{PlaylistRows(lists!!)}}
        }
    }}
}
@Composable fun ArtistScreen(artist: Artist) {
    val ui=LocalUi.current
    val screen=remember(artist.id,artist.mid){Screen("songs",artist.name,artist,loader={offset->val songs=ui.app.api.artistSongs(artist,offset);Page(songs,offset+songs.size,songs.size>=50)})}
    SongsScreen(screen)
}
@Composable fun AlbumsScreen(screen: Screen) {
    val ui=LocalUi.current;val scope=rememberCoroutineScope();var albums by remember{mutableStateOf<List<Album>>(emptyList())};var offset by remember{mutableIntStateOf(0)}
    var more by remember{mutableStateOf(true)};var busy by remember{mutableStateOf(false)};var error by remember{mutableStateOf<String?>(null)}
    val session by ui.app.auth.session.collectAsState();var epoch by remember{mutableIntStateOf(0)};var job by remember{mutableStateOf<Job?>(null)};val scroll=rememberLazyListState()
    fun load(){if(busy||!more)return;busy=true;error=null;val own=epoch
        job=scope.launch {try{
            val page=when(val data=screen.data){is Artist->ui.app.api.artistAlbums(data,offset).let{Page(it,offset+it.size,it.size>=30)};true->ui.app.api.purchasedPage(true,offset).let{Page(it.items.map(Album::parse),it.nextOffset,it.more)};else->ui.app.api.likedAlbums(offset)}
            if(own==epoch){val seen=albums.map{it.id}.toMutableSet();val fresh=page.items.filter{seen.add(it.id)};albums+=fresh;more=page.more&&page.nextOffset>offset&&fresh.isNotEmpty();offset=page.nextOffset}
        }catch(e:CancellationException){throw e}catch(e:Exception){if(own==epoch)error=e.message}finally{if(own==epoch)busy=false}}
    }
    LaunchedEffect(session?.id){job?.cancel();epoch++;albums=emptyList();offset=0;more=true;busy=false;load()}
    DisposableEffect(Unit){onDispose{job?.cancel()}}
    LaunchedEffect(scroll){snapshotFlow{Triple(scroll.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0,scroll.layoutInfo.totalItemsCount,busy)}.collect{(last,count,_)->if(count>1&&last>=count-4&&!busy&&error==null)load()}}
    MusicPage(screen.title){insets->Box(Modifier.fillMaxSize()){
        LazyColumn(state=scroll,contentPadding=PaddingValues(start=8.dp,end=8.dp,top=insets.calculateTopPadding()+16.dp,bottom=insets.calculateBottomPadding()+24.dp)){
            items(albums,key={it.id}){album->ListRow(album.name,leading={Cover(album.cover)},trailing={Icon(Icons.Rounded.ChevronRight,null)}){ui.album(album)}}
            item{when{error!=null->ErrorPanel(error!!){load()};busy->Loading();albums.isEmpty()->EmptyPanel("这里还没有专辑");more->TextButton(hapticClick({load()}),Modifier.fillMaxWidth()){Text("加载更多")};else->Spacer(Modifier.height(24.dp))}}
        }
    }}
}
@Composable fun CommentsScreen(song: Song) {
    val ui=LocalUi.current;val scope=rememberCoroutineScope();var hot by remember{mutableStateOf(false)}
    var entries by remember{mutableStateOf<List<Json>>(emptyList())};var cursor by remember{mutableStateOf<Json?>(null)};var total by remember{mutableIntStateOf(0)}
    var more by remember{mutableStateOf(true)};var busy by remember{mutableStateOf(false)};var error by remember{mutableStateOf<String?>(null)}
    var epoch by remember {mutableIntStateOf(0)};var job by remember {mutableStateOf<Job?>(null)};val scroll=rememberLazyListState()
    fun load(reset:Boolean=false) {
        if(!reset&&(busy||!more))return
        if(reset){job?.cancel();epoch++;entries=emptyList();cursor=null;more=true}
        val generation=epoch;val requestedHot=hot
        busy=true;error=null
        job=scope.launch {try {
            val page=ui.app.api.comments(song,cursor,requestedHot)
            if(generation!=epoch)return@launch
            val seen=entries.map {it.text("CmId")}.toSet();val fresh=page.items.filter {it.text("CmId") !in seen}
            entries+=fresh;cursor=page.cursor;more=!requestedHot&&cursor!=null&&fresh.isNotEmpty();if(!requestedHot)total=page.total
        }catch(e:CancellationException){throw e}catch(e:Exception){if(generation==epoch)error=e.message}finally{if(generation==epoch)busy=false}}
    }
    LaunchedEffect(hot){load(true)};DisposableEffect(Unit){onDispose{job?.cancel()}}
    LaunchedEffect(scroll){snapshotFlow {Triple(scroll.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0,scroll.layoutInfo.totalItemsCount,busy)}.collect {(last,count,_)->if(count>2&&last>=count-4&&!busy&&error==null)load()}}
    MusicPage("歌曲评论"){insets->Box(Modifier.fillMaxSize()) {LazyColumn(state=scroll,contentPadding=PaddingValues(top=insets.calculateTopPadding()+16.dp,bottom=insets.calculateBottomPadding())){
        item{Column(Modifier.padding(horizontal=16.dp)){Text(song.name,style=MaterialTheme.typography.headlineSmall);Spacer(Modifier.height(12.dp))
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)){FilterChip(!hot,hapticClick({if(hot)hot=false}),label={Text("最新评论 · $total")},leadingIcon=if(!hot)({Icon(Icons.Rounded.Check,null,Modifier.size(18.dp))})else null);FilterChip(hot,hapticClick({if(!hot)hot=true}),label={Text("热门评论")},leadingIcon=if(hot)({Icon(Icons.Rounded.Check,null,Modifier.size(18.dp))})else null)};Spacer(Modifier.height(12.dp))}}
        items(entries){entry->Row(Modifier.padding(horizontal=16.dp,vertical=12.dp),verticalAlignment=Alignment.Top){
            Cover(entry.text("Avatar"),36.dp,18.dp);Spacer(Modifier.width(12.dp));Column(Modifier.weight(1f)) {
                Text(entry.text("Nick"),style=MaterialTheme.typography.titleSmall);Spacer(Modifier.height(6.dp))
                Text(android.text.Html.fromHtml(entry.text("Content"),0).toString());Spacer(Modifier.height(8.dp))
                val date=java.util.Calendar.getInstance().apply {timeInMillis=entry.number("PubTime")*1000}
                Text("${date.get(java.util.Calendar.YEAR)}-${date.get(java.util.Calendar.MONTH)+1}-${date.get(java.util.Calendar.DAY_OF_MONTH)} · ${entry.number("PraiseNum")} 赞",style=MaterialTheme.typography.bodySmall)
            }
        }}
        item{when{error!=null->ErrorPanel(error!!){load()};busy->Loading();entries.isEmpty()->EmptyPanel("还没有评论");more->TextButton(hapticClick({load()}),Modifier.fillMaxWidth()){Text("加载更多评论")}}}
        if(error==null&&!busy&&entries.isNotEmpty()&&!more)item{Spacer(Modifier.height(32.dp))}
    }}}
}

fun songActions(ui: Ui, song: Song, list: MusicList?=null, onQuality:(()->Unit)?=null, changed: ()->Unit={}) {
    ui.showSheet(1f){Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()) {
        ListRow(song.name,song.artistNames,enabled=false,leading={Cover(song.cover)})
        if(onQuality!=null)ListRow("播放音质",icon=Icons.Outlined.HighQuality,trailing={}){ui.sheet=null;onQuality()}
        ListRow("加入播放队列",icon=Icons.Rounded.PlaylistAdd,trailing={}){ui.sheet=null;ui.run("已加入播放队列"){ui.app.playback.add(song)}}
        ListRow("下载歌曲",icon=Icons.Outlined.Download,trailing={}){ui.sheet=null;downloadChoice(ui,song)}
        ListRow("喜欢 / 取消喜欢",icon=Icons.Rounded.FavoriteBorder,trailing={}){ui.sheet=null;ui.run("喜欢状态已更新"){val liked=ui.app.api.songLiked(song);ui.app.api.likeSong(song,!liked);changed()}}
        ListRow("添加到歌单",icon=Icons.Outlined.LibraryAdd,trailing={}){ui.sheet=null;ui.run {
            val lists=ui.app.api.ownedLists().filter{it.editable}
            ui.sheet={if(lists.isEmpty())EmptyPanel("请先在“我的”中创建歌单")else LazyColumn(Modifier.navigationBarsPadding()) {items(lists){target->ListRow(target.name,leading={Cover(target.cover)}){ui.sheet=null;ui.run {ui.app.api.editPlaylistSongs(target.id,listOf(song.id))}}}}}
        }}
        if(song.album.mid.isNotEmpty())ListRow("查看专辑",icon=Icons.Outlined.Album,trailing={}){ui.sheet=null;ui.album(song.album)}
        if(song.artists.isNotEmpty())ListRow("查看歌手",icon=Icons.Rounded.PersonOutline,trailing={}){ui.sheet=null
            if(song.artists.size==1)ui.go(Screen("artist",song.artists.first().name,song.artists.first()))
            else ui.sheet={Column(Modifier.verticalScroll(rememberScrollState()).navigationBarsPadding()) {song.artists.forEach {artist->ListRow(artist.name,trailing={}){ui.sheet=null;ui.go(Screen("artist",artist.name,artist))}}}}
        }
        if(list?.editable==true)ListRow("从歌单移除",icon=Icons.Rounded.PlaylistRemove,trailing={}){ui.sheet=null;ui.run {if(ui.confirm("从歌单移除","将《${song.name}》从此歌单移除？")){ui.app.api.editPlaylistSongs(list.id,listOf(song.id),false);changed()}}}
    }}
}

fun downloadChoice(ui: Ui,song: Song) {
    if(ui.app.downloads.active){ui.message("已有歌曲正在下载，请稍候");return}
    ui.showSheet(.75f){var detail by remember{mutableStateOf<Song?>(null)};var loaded by remember{mutableStateOf(false)}
        LaunchedEffect(song.id){try{detail=ui.app.api.songDetail(song)}catch(e:CancellationException){throw e}catch(_:Exception){}finally{loaded=true}}
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(top=8.dp,bottom=16.dp)) {
            Text("下载音质",Modifier.padding(horizontal=16.dp,vertical=8.dp),style=MaterialTheme.typography.titleLarge)
            listOf("standard","exhigh","lossless").forEach{quality->val size=(detail ?: song).downloadBytes(quality)
                PreferenceRow(qualityName(quality),if(quality==ui.app.settings.string("downloadQuality",ui.app.settings.string("quality","standard")))"默认下载音质" else null,
                    icon=if(quality==ui.app.settings.string("downloadQuality",ui.app.settings.string("quality","standard")))Icons.Rounded.RadioButtonChecked else Icons.Rounded.RadioButtonUnchecked,
                    trailing={Text(if(size>0)downloadSize(size)else if(loaded)"大小未知" else "读取中…")}){ui.sheet=null;ui.run{ui.app.downloads.start(listOf(detail ?: song),quality);ui.message("已加入下载任务")}}
            }
            Text("本次选择不会更改默认设置。大小对应所选版本，不可用时会使用可下载的音质。",Modifier.padding(start=16.dp,end=16.dp,top=8.dp))
        }
    }
}
fun downloadSize(bytes: Long) = "%.1f MB".format(java.util.Locale.ROOT,bytes/1048576.0)
