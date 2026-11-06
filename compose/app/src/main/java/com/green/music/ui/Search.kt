@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.green.music.data.*
import kotlinx.coroutines.*

@Composable fun SearchScreen(padding: PaddingValues) {
    val ui=LocalUi.current; val scope=rememberCoroutineScope()
    var query by rememberSaveable {mutableStateOf("")};var submitted by rememberSaveable {mutableStateOf("")};var kind by rememberSaveable {mutableIntStateOf(0)}
    var page by remember {mutableStateOf<SearchPage?>(null)};var busy by remember {mutableStateOf(false)};var error by remember {mutableStateOf<String?>(null)}
    var songs by remember {mutableStateOf<List<Song>>(emptyList())};var artists by remember {mutableStateOf<List<Artist>>(emptyList())};var albums by remember {mutableStateOf<List<Album>>(emptyList())}
    var suggestions by remember {mutableStateOf<List<String>>(emptyList())};var job by remember {mutableStateOf<Job?>(null)}
    var epoch by remember {mutableIntStateOf(0)}
    val player by ui.app.playback.state.collectAsState()
    val scroll=rememberLazyListState();val focus=androidx.compose.ui.platform.LocalFocusManager.current
    fun load(reset:Boolean=false,value:String=query) {
        if(busy&&!reset)return
        if(reset){job?.cancel();epoch++;busy=false;error=null;submitted=value.trim();query=value;page=null;songs=emptyList();artists=emptyList();albums=emptyList();suggestions=emptyList();focus.clearFocus();scope.launch{scroll.scrollToItem(0)}}
        if(submitted.isEmpty())return
        val generation=epoch;val submittedKind=kind
        job=scope.launch {
            busy=true;error=null
            try {val result=ui.app.api.search(submitted,submittedKind,page?.nextOffset ?: 0,page?.source.orEmpty())
                if(generation!=epoch)return@launch
                page=result;songs=(songs+result.songs).distinctBy{it.id};artists=(artists+result.artists).distinctBy{it.mid};albums=(albums+result.albums).distinctBy{it.mid}
            }catch(e:CancellationException){throw e}catch(e:Exception){if(generation==epoch)error=e.message ?: "搜索失败"}finally{if(generation==epoch)busy=false}
        }
    }
    LaunchedEffect(query){if(query.trim()!=submitted&&query.isNotBlank()){delay(350);try{suggestions=ui.app.api.suggestions(query)}catch(e:CancellationException){throw e}catch(_:Exception){suggestions=emptyList()}}else suggestions=emptyList()}
    DisposableEffect(Unit){onDispose{job?.cancel()}}
    LaunchedEffect(scroll){snapshotFlow{Triple(scroll.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0,scroll.layoutInfo.totalItemsCount,busy)}.collect{(last,total,_)->if(total>2&&last>=total-4&&!busy&&error==null&&suggestions.isEmpty()&&page?.more==true)load()}}
    val dragged by scroll.interactionSource.collectIsDraggedAsState()
    LaunchedEffect(dragged){if(dragged)focus.clearFocus();scope.launch{scroll.scrollToItem(0)}}
    LazyColumn(state=scroll,contentPadding=padding) {
        item {Column(Modifier.padding(horizontal=16.dp)) {
            Surface(shape=RoundedCornerShape(28.dp),color=if(MaterialTheme.colorScheme.surface==androidx.compose.ui.graphics.Color.Black)androidx.compose.ui.graphics.Color(0xFF1C1C1E)else MaterialTheme.colorScheme.surfaceContainerHigh,shadowElevation=0.dp) {
                Row(Modifier.fillMaxWidth().heightIn(min=56.dp).padding(start=16.dp,end=4.dp),verticalAlignment=Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Search,null);Spacer(Modifier.width(16.dp))
                    BasicTextField(query,{query=it},Modifier.weight(1f),textStyle=MaterialTheme.typography.bodyLarge.copy(color=MaterialTheme.colorScheme.onSurface),singleLine=true,
                        cursorBrush=androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.primary),keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={load(true)}),
                        decorationBox={inner->Box {if(query.isEmpty())Text("歌曲、歌手、专辑",style=MaterialTheme.typography.bodyLarge,color=MaterialTheme.colorScheme.onSurfaceVariant);inner()}})
                    ActionIcon(Icons.AutoMirrored.Rounded.ArrowForward,"开始搜索"){load(true)}
                }
            }
            Spacer(Modifier.height(16.dp));FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                listOf("歌曲","歌手","专辑").forEachIndexed { i,label->FilterChip(kind==i,hapticClick({kind=i;if(submitted.isNotEmpty())load(true,submitted)}),label={Text(label)},leadingIcon=if(kind==i)({Icon(Icons.Rounded.Check,null,Modifier.size(18.dp))})else null) }
            }
            if(submitted.isNotEmpty())Text("“$submitted” · 共 ${page?.total ?: 0} 项",Modifier.padding(top=16.dp),style=MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(12.dp))
        } }
        if(suggestions.isNotEmpty())items(suggestions){suggestion->ListRow(suggestion,icon=Icons.Rounded.Search,trailing={}){load(true,suggestion)}}
        else when(kind) {
            0->itemsIndexed(songs,key={_,s->s.id}){index,song->SongRow(song,player.current?.id==song.id,more={songActions(ui,song)}){ui.run{ui.app.playback.playSongs(songs,index)}}}
            1->items(artists,key={it.mid}){artist->ListRow(artist.name,leading={Cover(artist.cover,radius=24.dp)}){ui.go(Screen("artist",artist.name,artist))}}
            2->items(albums,key={it.mid}){album->ListRow(album.name,leading={Cover(album.cover)}){ui.album(album)}}
        }
        item {when {
            error!=null->ErrorPanel(error!!){load()};busy->Loading();submitted.isEmpty()->EmptyPanel("搜索你想听的音乐",Icons.Rounded.Search)
            songs.size+artists.size+albums.size==0->EmptyPanel("没有找到结果，换个关键词试试")
            page?.more==true->OutlinedButton(hapticClick({load()}),Modifier.fillMaxWidth().padding(16.dp)){Text("加载更多")}
        }}
        if(error==null&&!busy&&submitted.isNotEmpty()&&songs.size+artists.size+albums.size>0&&page?.more!=true)item{Spacer(Modifier.height(24.dp))}
    }
}
