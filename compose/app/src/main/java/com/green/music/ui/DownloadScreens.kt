@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.green.music.data.*
import com.green.music.player.*
import kotlinx.coroutines.CancellationException

@Composable fun DownloadQueueCard() {
    val ui=LocalUi.current; val d=ui.app.downloads; val tasks by d.tasks.collectAsState()
    if(tasks.isEmpty() || d.owner!=(ui.app.api.session?.id ?: "anonymous"))return
    val active=tasks.any {it.status==DownloadStatus.Waiting || it.status==DownloadStatus.Running}
    val cancelling by d.cancelling.collectAsState();val stopReason by d.stopReason.collectAsState()
    val finished=tasks.count {it.status !in listOf(DownloadStatus.Waiting,DownloadStatus.Running)}
    SectionCard(Modifier.padding(top=16.dp)) { Column(Modifier.padding(16.dp)) {
        Text("${d.title} · ${if(active)if(cancelling)"正在取消" else "下载中" else "任务已结束"}",style=MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(8.dp))
        Text("$finished / ${tasks.size} 首 · 已保存 ${tasks.count {it.status==DownloadStatus.Done}} · 跳过 ${tasks.count {it.status==DownloadStatus.Skipped}} · 失败 ${tasks.count {it.status==DownloadStatus.Failed}} · 取消 ${tasks.count {it.status==DownloadStatus.Cancelled}}")
        Spacer(Modifier.height(8.dp));stopReason?.let{Text(it)}; LinearProgressIndicator(progress={finished.toFloat()/tasks.size},modifier=Modifier.fillMaxWidth(),strokeCap=androidx.compose.ui.graphics.StrokeCap.Butt,gapSize=0.dp,drawStopIndicator={},trackColor=MaterialTheme.colorScheme.secondaryContainer)
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) { TextButton(hapticClick({ui.go(Screen("downloadTasks"))})){Text("查看任务")}
            if(active)TextButton(hapticClick({ui.run {d.cancelAll()}}),enabled=!cancelling){Text("取消全部")}
            else if(tasks.any {it.status in listOf(DownloadStatus.Failed,DownloadStatus.Cancelled)})TextButton(hapticClick({ui.run {d.retry()}})){Text("重试未完成")}
        }
    } }
}
@Composable fun ActiveDownloads() {
    val ui=LocalUi.current; val d=ui.app.downloads; val tasks by d.tasks.collectAsState()
    if(d.owner!=(ui.app.api.session?.id ?: "anonymous"))return
    tasks.filter {it.status==DownloadStatus.Running}.forEach {task ->
        SectionCard(Modifier.padding(vertical=8.dp)) {
            ListRow("${task.stage}：${task.song.name}","${downloadSize(task.received)}${if(task.total>0)" / ${downloadSize(task.total)}" else ""}${if(task.speed>0)" · ${downloadSize(task.speed.toLong())}/s" else ""}",
                trailing={ActionIcon(Icons.Rounded.Close,if(tasks.size>1)"取消全部下载" else "取消下载"){ui.run {d.cancelAll()}}})
            if(task.total>0)LinearProgressIndicator(progress={(task.received.toFloat()/task.total).coerceIn(0f,1f)},modifier=Modifier.fillMaxWidth(),strokeCap=androidx.compose.ui.graphics.StrokeCap.Butt,gapSize=0.dp,drawStopIndicator={},trackColor=MaterialTheme.colorScheme.secondaryContainer)
            else LinearProgressIndicator(Modifier.fillMaxWidth(),strokeCap=androidx.compose.ui.graphics.StrokeCap.Butt,gapSize=0.dp,trackColor=MaterialTheme.colorScheme.secondaryContainer)
        }
    }
}
@Composable fun DownloadsScreen() {
    val ui=LocalUi.current; val d=ui.app.downloads; val session by ui.app.auth.session.collectAsState(); val revision by d.revision.collectAsState()
    var refresh by remember {mutableIntStateOf(0)}; var loading by remember {mutableStateOf(true)}; var error by remember {mutableStateOf<String?>(null)}
    var entries by remember {mutableStateOf(emptyList<DownloadedSong>())}; var busy by remember {mutableStateOf(false)}
    LaunchedEffect(session?.id,revision,refresh) {loading=true;error=null;try {entries=d.entries(session?.id ?: "anonymous")}catch(e:CancellationException){throw e}catch(e:Exception){error=e.message}finally {loading=false}}
    MusicPage("下载歌曲") { padding -> Box(Modifier.fillMaxSize()) {
        PullToRefreshBox(loading,{refresh++}) {LazyColumn(contentPadding=PaddingValues(start=16.dp,end=16.dp,top=padding.calculateTopPadding()+16.dp,bottom=padding.calculateBottomPadding()+24.dp)) {
            item {SectionCard {
                PreferenceRow("${entries.size} 首 · ${downloadSize(entries.sumOf {it.bytes})}","仅当前账号可见，支持断网播放；文件位置以下载时设置为准。",Icons.Rounded.DownloadDone,enabled=false)
                SectionDivider();PreferenceRow("下载设置","下载音质、保存位置、歌曲标签与 LRC 歌词",Icons.Rounded.Tune){ui.go(Screen("downloadSettings"))}
            }}
            item {DownloadQueueCard()};item {ActiveDownloads()}
            item {when {error!=null->ErrorPanel(error!!){refresh++};loading->Loading();entries.isEmpty()->EmptyPanel("还没有下载歌曲，可在歌曲操作菜单或播放页点击下载",Icons.Outlined.Download)}}
            items(entries,key={it.file.path}) {entry -> ReviewTile(
                title={Text(entry.song.name,maxLines=2,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis,style=listTitleStyle())},
                subtitle={Text("${if(entry.song.artistNames.isEmpty())"" else entry.song.artistNames+"\n"}${qualityName(entry.quality)} · ${downloadSize(entry.bytes)}",style=listSubtitleStyle())},
                leading={Cover(entry.song.cover,44.dp)},horizontalPadding=8.dp,verticalPadding=8.dp,enabled=!busy,
                trailing={ActionIcon(Icons.Rounded.DeleteOutline,"删除${entry.song.name}的下载",!busy){ui.run {
                    if(ui.confirm("删除下载","删除《${entry.song.name}》的${qualityName(entry.quality)}下载文件？")){busy=true;try {if(ui.app.playback.state.value.current?.id==entry.song.id)ui.app.playback.stop();d.delete(entry);ui.message("下载已删除")}finally {busy=false}}
                }}}
            ){ui.run {ui.app.playback.playDownloaded(entry.song,entry.uri)}}}

        }}

    } }
}
@Composable fun DownloadTasksScreen() {
    val ui=LocalUi.current; val d=ui.app.downloads; val tasks by d.tasks.collectAsState(); val session by ui.app.auth.session.collectAsState()
    MusicPage("下载任务") { padding -> Box(Modifier.fillMaxSize()) {
        if(d.owner!=(session?.id ?: "anonymous"))Box(Modifier.padding(padding)){EmptyPanel("请切回原账号查看下载任务")}
        else LazyColumn(contentPadding=PaddingValues(start=16.dp,end=16.dp,top=padding.calculateTopPadding()+16.dp,bottom=padding.calculateBottomPadding()+24.dp)) {
            items(tasks,key={it.song.id}) {t -> ListRow(t.song.name,listOf(t.song.artistNames,downloadStatusLabel(t.status),if(t.attempt>0)"第 ${t.attempt} 次重试" else "",t.error.orEmpty()).filter(String::isNotEmpty).joinToString("\n"),
                when(t.status){DownloadStatus.Done,DownloadStatus.Skipped->Icons.Rounded.CheckCircleOutline;DownloadStatus.Failed->Icons.Rounded.ErrorOutline;DownloadStatus.Cancelled->Icons.Outlined.Cancel;else->Icons.Rounded.Downloading},trailing={})}
        }

    }}
}

@Composable fun BatchDownloadScreen(screen: Screen) {
    val ui=LocalUi.current; val owner=remember {ui.app.api.session?.id ?: "anonymous"}; val p=ui.app.settings;
    val selected=remember {mutableStateMapOf<Long,Boolean>()}; var songs by remember {mutableStateOf(emptyList<Song>())}
    var error by remember {mutableStateOf<String?>(null)};var loading by remember {mutableStateOf(true)};var attempt by remember {mutableIntStateOf(0)}
    val tasks by ui.app.downloads.tasks.collectAsState();val active=tasks.any {it.status in listOf(DownloadStatus.Waiting,DownloadStatus.Running)}
    val density=LocalDensity.current
    var footerHeight by remember {mutableIntStateOf(0)}
    LaunchedEffect(attempt) {
        loading=true;error=null
        try {val found=linkedMapOf<Long,Song>();var offset=0
            do {if(owner!=(ui.app.api.session?.id ?: "anonymous"))throw MusicError("账号已切换，请重新打开歌单")
                val page=screen.loader!!(offset);val previous=found.size;page.items.forEach {if(it.valid)found[it.id]=it}
                if(page.more && (page.nextOffset<=offset || previous==found.size))throw MusicError("歌单分页未前进，未开始下载")
                offset=page.nextOffset
            }while(page.more)
            songs=found.values.toList();selected.clear();songs.forEach {selected[it.id]=true}
        }catch(e:CancellationException){throw e}catch(e:Exception){error=e.message ?: "歌单读取失败"}finally {loading=false}
    }
    MusicPage("批量下载") { padding -> when {
        loading->Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center){Column(horizontalAlignment=Alignment.CenterHorizontally){CircularProgressIndicator(Modifier.size(36.dp),strokeWidth=4.dp,strokeCap=androidx.compose.ui.graphics.StrokeCap.Square);Spacer(Modifier.height(16.dp));Text("正在读取完整歌单…")}}
        error!=null->Box(Modifier.padding(padding)){ErrorPanel(error!!){attempt++}}
        songs.isEmpty()->Box(Modifier.padding(padding)){EmptyPanel("歌单里没有可下载的歌曲")}
        else->Box(Modifier.fillMaxSize()) {
            LazyColumn(Modifier.align(Alignment.TopCenter).widthIn(max=680.dp).fillMaxSize(),
                contentPadding=PaddingValues(start=16.dp,end=16.dp,top=padding.calculateTopPadding()+16.dp,
                    bottom=padding.calculateBottomPadding()+with(density){footerHeight.toDp()}+12.dp)) {
                item {
                    Text(screen.title,style=MaterialTheme.typography.headlineSmall,maxLines=2,overflow=TextOverflow.Ellipsis)
                    Spacer(Modifier.height(12.dp))
                    SectionCard {
                        val summary = listOfNotNull(
                            qualityName(p.string("downloadQuality",p.string("quality","standard"))),
                            "写入标签".takeIf { p.bool("downloadTags") },
                            "保存 LRC".takeIf { p.bool("downloadLyrics") },
                        ).joinToString(" · ")
                        PreferenceRow("下载设置",summary,Icons.Rounded.Tune){ui.go(Screen("downloadSettings"))}
                        SectionDivider()
                        val privateDirectory = p.string("downloadTree").isEmpty()
                        val limitMb = p.int("cacheLimitMb",256)
                        val limit = if(limitMb<1024)"$limitMb MB" else "${limitMb/1024} GB"
                        PreferenceRow(if(privateDirectory)"私有目录" else "公有目录",
                            if(privateDirectory)"上限 $limit" else "仅受实际可用空间限制",
                            Icons.Outlined.Storage){ui.go(Screen("storage"))}
                    }
                    Spacer(Modifier.height(20.dp))
                    SectionHeading("选择歌曲")
                    val allState=if(selected.size==songs.size)ToggleableState.On else if(selected.isEmpty())ToggleableState.Off else ToggleableState.Indeterminate
                    SectionCard(shape=RoundedCornerShape(topStart=24.dp,topEnd=24.dp)) {
                        ReviewTile(role=Role.Checkbox,modifier=Modifier.semantics{toggleableState=allState},
                            title={Text("全选",style=listTitleStyle())},
                            subtitle={Text("已选 ${selected.size} / ${songs.size} 首",style=listSubtitleStyle())},
                            trailing={Box(Modifier.size(40.dp),contentAlignment=Alignment.Center){TriStateCheckbox(allState,null)}}){
                            val all=selected.size!=songs.size
                            selected.clear()
                            if(all)songs.forEach {selected[it.id]=true}
                        }
                    }
                }
                itemsIndexed(songs,key={_,song->song.id}) {index,song ->
                    SectionCard(shape=if(index==songs.lastIndex)RoundedCornerShape(bottomStart=24.dp,bottomEnd=24.dp) else RectangleShape) {
                        SectionDivider(16.dp,16.dp)
                        val checked = selected.containsKey(song.id)
                        ReviewTile(
                            title={Text(song.name,maxLines=2,overflow=TextOverflow.Ellipsis,style=listTitleStyle())},
                            subtitle=song.artistNames.takeIf(String::isNotBlank)?.let{artist->{Text(artist,maxLines=1,overflow=TextOverflow.Ellipsis,style=listSubtitleStyle())}},
                            role=Role.Checkbox,modifier=Modifier.semantics{toggleableState=if(checked)ToggleableState.On else ToggleableState.Off},
                            trailing={Box(Modifier.size(40.dp),contentAlignment=Alignment.Center){Checkbox(checked,null)}},
                        ){if(selected.remove(song.id)==null)selected[song.id]=true}
                    }
                }
            }
            Button(hapticClick({ui.run {
                if(owner!=(ui.app.api.session?.id ?: "anonymous"))throw MusicError("账号已切换，请重新打开歌单")
                ui.app.downloads.start(songs.filter {selected.containsKey(it.id)},title=screen.title);ui.go(Screen("downloads"))
            }}),modifier=Modifier.align(Alignment.BottomCenter).padding(bottom=padding.calculateBottomPadding())
                .onSizeChanged {footerHeight=it.height}.widthIn(max=680.dp).fillMaxWidth()
                .padding(horizontal=16.dp,vertical=8.dp).heightIn(min=48.dp),
                enabled=selected.isNotEmpty()&&!active){
                Icon(Icons.Rounded.Download,null);Spacer(Modifier.width(8.dp))
                Text(if(active)"已有下载任务进行中" else "下载所选 ${selected.size} 首")
            }
        }
    } }
}

internal fun downloadStatusLabel(status:DownloadStatus)=when(status){
    DownloadStatus.Waiting->"等待下载";DownloadStatus.Running->"正在下载";DownloadStatus.Done->"已保存"
    DownloadStatus.Skipped->"已有下载，已跳过";DownloadStatus.Failed->"失败";DownloadStatus.Cancelled->"已取消"
}
