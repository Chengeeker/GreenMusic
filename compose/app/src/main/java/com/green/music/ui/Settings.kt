@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationManagerCompat
import coil.imageLoader
import com.green.music.BuildConfig
import com.green.music.applyDisplayMode
import com.green.music.displayOptions
import com.green.music.data.*

@Composable fun SettingsBody(title:String,bottom:androidx.compose.ui.unit.Dp=12.dp,content:@Composable ColumnScope.()->Unit) {
    ReviewPage(title){insets->Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top=insets.calculateTopPadding()+12.dp,bottom=insets.calculateBottomPadding()+bottom).padding(horizontal=16.dp),content=content)}
}
@Composable fun SettingsScreen() {
    val ui=LocalUi.current;val session by ui.app.auth.session.collectAsState()
    SettingsBody("设置",bottom=24.dp) {
        Spacer(Modifier.height(24.dp));SectionHeading("外观与交互");SectionCard {
            PreferenceRow("个性化",icon=Icons.Outlined.Palette){ui.go(Screen("theme"))}
        }
        Spacer(Modifier.height(24.dp));SectionHeading("播放与歌词");SectionCard {
            PreferenceRow("播放设置",icon=Icons.Outlined.Headphones){ui.go(Screen("playbackSettings"))};SectionDivider()
            PreferenceRow("歌词界面",icon=Icons.Outlined.Lyrics){ui.go(Screen("lyricsSettings"))};SectionDivider()
            PreferenceRow("播放通知",icon=Icons.Outlined.Notifications){ui.go(Screen("notifications"))}
        }
        Spacer(Modifier.height(24.dp));SectionHeading("下载与存储");SectionCard {
            PreferenceRow("下载歌曲",icon=Icons.Outlined.Download){ui.go(Screen("downloads"))};SectionDivider()
            PreferenceRow("下载设置",icon=Icons.Outlined.Downloading){ui.go(Screen("downloadSettings"))};SectionDivider()
            PreferenceRow("存储设置",icon=Icons.Outlined.FolderOpen){ui.go(Screen("storage"))};SectionDivider()
            PreferenceRow("缓存管理",icon=Icons.Outlined.CleaningServices){ui.go(Screen("cache"))}
        }
        Spacer(Modifier.height(24.dp));SectionHeading("账号与备份");SectionCard {
            if(session==null)PreferenceRow("登录 QQ 音乐",icon=Icons.Rounded.Login){ui.go(Screen("login"))}else {
                PreferenceRow(session!!.nickname,"刷新账号与登录状态",Icons.Outlined.AccountCircle){ui.run("账号状态已更新"){ui.app.auth.ensureSession()}};SectionDivider()
                PreferenceRow("退出登录",icon=Icons.Rounded.Logout){ui.run{if(ui.confirm("退出登录","退出并停止播放，清除本机登录凭据？已下载歌曲保留，重新登录原账号后可见。")){ui.app.downloads.cancelAll();ui.app.playback.stop();ui.app.auth.logout()}}}
            }
            SectionDivider();PreferenceRow("WebDAV备份",icon=Icons.Outlined.CloudSync){ui.go(Screen("webdav"))}
        }
        Spacer(Modifier.height(24.dp));SectionHeading("关于");SectionCard {PreferenceRow("GreenMusic", "${BuildConfig.VERSION_NAME} · QQ 音乐第三方客户端",Icons.Rounded.MusicNote,trailing={}){};SectionDivider();PreferenceRow("开源许可","Lilt · AGPL-3.0 / Review · MIT",Icons.Outlined.Description){ui.go(Screen("licenses"))}}
        Text("音乐版权归各权利人所有。可播放音源与音质由 QQ 音乐账号、会员和地区权限决定。",Modifier.padding(horizontal=8.dp,vertical=24.dp),style=MaterialTheme.typography.bodySmall,textAlign=TextAlign.Center)
    }
}
@Composable fun ChoiceRow(title:String,selected:Boolean,summary:String?=null,choose:()->Unit) {
    ReviewTile(title={Text(title,fontSize=16.sp,lineHeight=21.6.sp,fontWeight=FontWeight((600+LocalWeightDelta.current).coerceIn(100,900)))},
        subtitle=summary?.let{{Text(it,fontSize=14.sp,lineHeight=19.6.sp,color=MaterialTheme.colorScheme.onSurfaceVariant)}},
        leading={Box(Modifier.size(40.dp),contentAlignment=Alignment.Center){RadioButton(selected,null)}},verticalPadding=2.dp,
        role=androidx.compose.ui.semantics.Role.RadioButton,modifier=Modifier.semantics{this.selected=selected}){if(!selected)choose()}
}

@Composable fun ThemeSettingsScreen() {
    val ui=LocalUi.current;val p=ui.app.settings;val c=MaterialTheme.colorScheme
    DisposableEffect(Unit){onDispose{p.clearPreview()}}
    val weightNames=listOf("偏细","默认","中等","偏粗","加粗")
    fun weightName()=weightNames[(p.int("fontWeightDelta")/100+1).coerceIn(0,4)]
    fun weightDialog() {ui.dialog={ReviewDialog(onDismissRequest={ui.dialog=null},title={Text("选择字体粗细")},text={Column(Modifier.verticalScroll(rememberScrollState())) {
        val descriptions=listOf("轻盈精炼视觉，适合大字号阅读","官方标准字重，最佳均衡排版","适度加深笔触，更清晰明朗","粗体质感，信息层级更醒目","极致浓郁，强视觉冲击力")
        weightNames.forEachIndexed {i,label->ChoiceRow(label,p.bool("customFontWeight")&&p.int("fontWeightDelta")== (i-1)*100,descriptions[i]){ui.dialog=null;ui.run {p.putAll(mapOf("customFontWeight" to true,"fontWeightDelta" to (i-1)*100))}}}
    }},confirmButton={TextButton(hapticClick({ui.dialog=null;ui.run {p.put("customFontWeight",false)}})){Text("跟随系统字重")}},dismissButton={TextButton(hapticClick({ui.dialog=null})){Text("取消")}})}}
    SettingsBody("个性化") {
        SectionHeading("明暗模式");SectionCard {
            listOf("跟随系统","浅色模式","深色模式").forEachIndexed{i,label->
                ChoiceRow(label,p.int("themeMode")==i,if(i==0)"自动匹配系统深色/浅色设置" else null){ui.run{p.put("themeMode",i)}}
                if(i<2)SectionDivider(72.dp)
            }
            SectionDivider(16.dp,16.dp)
            ToggleRow("纯黑深色模式",value=p.bool("pureBlack"),icon=Icons.Rounded.Contrast,iconTint=MaterialTheme.colorScheme.primary){ui.run{p.put("pureBlack",it)}}
        }
        Spacer(Modifier.height(16.dp));SectionHeading("色彩方案");SectionCard {
            Spacer(Modifier.height(8.dp))
            ToggleRow("动态取色",value=p.bool("dynamicColor",true),icon=Icons.Outlined.AutoAwesome,iconTint=MaterialTheme.colorScheme.primary){ui.run{p.put("dynamicColor",it)}}
            if(!p.bool("dynamicColor",true)) {
                SectionDivider(16.dp,16.dp);Text("Material 3 预置主题色",Modifier.padding(start=16.dp,top=14.dp,bottom=10.dp),fontSize=14.sp,lineHeight=18.9.sp,color=c.onSurfaceVariant)
                val names=listOf("经典红","活力橙","极光蓝","翡翠绿","优雅紫","樱花粉","青碧色","经典黑灰")
                val colors=listOf(0xFFFA2F3A,0xFFFF8200,0xFF1976D2,0xFF2E7D32,0xFF7B1FA2,0xFFE91E63,0xFF00897B,0xFF455A64)
                FlowRow(Modifier.padding(horizontal=12.dp),horizontalArrangement=Arrangement.spacedBy(12.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {names.forEachIndexed {i,label->FilterChip(p.int("colorIndex",3)==i,hapticClick({ui.run{p.put("colorIndex",i)}}),label={Text(label)},leadingIcon={Box(Modifier.size(20.dp).background(androidx.compose.ui.graphics.Color(colors[i]),androidx.compose.foundation.shape.CircleShape),contentAlignment=Alignment.Center){if(p.int("colorIndex",3)==i)Icon(Icons.Rounded.Check,null,Modifier.size(18.dp),tint=c.onSecondaryContainer)}})}}
            }
            Spacer(Modifier.height(8.dp))
        }
        Spacer(Modifier.height(16.dp));SectionHeading("字体粗细");SectionCard {
            PreferenceRow("自定义应用字体粗细","当前：${if(p.bool("customFontWeight"))weightName() else "跟随系统"}",Icons.Rounded.FormatBold,iconTint=c.primary,action=::weightDialog)
            SectionDivider(16.dp,16.dp);Surface(Modifier.padding(start=16.dp,end=16.dp,top=12.dp,bottom=14.dp),color=c.surfaceContainerHighest.copy(alpha=.3f),shape=androidx.compose.foundation.shape.RoundedCornerShape(12.dp)) {
                Column(Modifier.padding(12.dp)) {Text("效果预览 (${weightName()})",fontSize=11.5.sp,fontWeight=FontWeight.W600,color=c.primary);Spacer(Modifier.height(4.dp));Text("GreenMusic：音乐、歌词与歌单的字体效果预览。",fontSize=14.sp,lineHeight=19.6.sp)}
            }
        }
        Spacer(Modifier.height(16.dp));SectionHeading("字体大小");SectionCard {
            Row(Modifier.padding(16.dp),verticalAlignment=Alignment.CenterVertically){Icon(Icons.Rounded.FormatSize,null,tint=c.primary);Spacer(Modifier.width(16.dp));Column(Modifier.weight(1f)) {
                Text("应用字体大小");Text("${kotlin.math.round(p.float("appTextScale")*100).toInt()}%",style=MaterialTheme.typography.bodyMedium)
                FlutterSlider(p.float("appTextScale"),{p.previewTextScale(it)},valueRange=.8f..1.4f,steps=11,label="${kotlin.math.round(p.float("appTextScale")*100).toInt()}%",onValueChangeFinished={ui.run {try {p.put("appTextScale",p.float("appTextScale"))}catch(e:Exception){p.clearPreview();throw e}}})
            }}
        }
        Spacer(Modifier.height(16.dp));SectionHeading("底部导航");SectionCard {ToggleRow("使用悬浮底栏","居中显示悬浮式导航栏",p.bool("floatingNav",true),icon=Icons.Rounded.Dock,iconTint=MaterialTheme.colorScheme.primary){ui.run{p.put("floatingNav",it)}}}
        Spacer(Modifier.height(16.dp));SectionHeading("显示效果");SectionCard {ToggleRow("使用液态玻璃效果","控制液态玻璃控件；当前应用于悬浮底栏",p.bool("liquidGlass"),icon=Icons.Rounded.BlurOn,iconTint=MaterialTheme.colorScheme.primary){ui.run{p.put("liquidGlass",it)}}}
        Spacer(Modifier.height(16.dp));SectionHeading("屏幕显示");SectionCard {PreferenceRow("屏幕帧率设置",displayModeLabel(p.int("screenRefreshRateMode")),Icons.Rounded.Speed){ui.go(Screen("refreshRate"))}}
        Spacer(Modifier.height(16.dp));SectionHeading("触感与震动");SectionCard {ToggleRow("触感与震动反馈","按键、卡片点击、手势滑动与底栏切换的触感反馈",p.bool("haptics",true),icon=Icons.Rounded.Vibration,iconTint=MaterialTheme.colorScheme.primary){ui.run{p.put("haptics",it)}}}
    }
}
fun displayModeLabel(mode:Int)=if(mode==0)"跟随系统" else "${if(mode<=4)"原生分辨率" else "1080P"} ${listOf(120,90,72,60)[(mode-1).coerceIn(0,7)%4]}Hz"
@Composable fun LyricsSettingsScreen() {
    val ui=LocalUi.current;val p=ui.app.settings;val revision=p.revision;val settings=p.lyrics()
    var size by remember(revision){mutableIntStateOf(settings.fontSize)};var weight by remember(revision){mutableIntStateOf(settings.weight)}
    SettingsBody("歌词界面") {
        Text("设置应用于完整歌词页面，迷你歌词保持原有布局。",Modifier.padding(12.dp));SectionHeading("文字与动效")
        SectionCard {
            SettingsSlider("歌词视图字体大小",size,16,40,1,{size=it}){ui.run{p.put("lyricFontSize",size)}}
            ToggleRow("歌词视图文本居中对齐","关闭后左对齐",settings.center){ui.run{p.put("lyricCenter",it)}}
            SettingsSlider("字体粗细",weight,100,900,100,{weight=it}){ui.run{p.put("lyricFontWeight",weight)}}
            ToggleRow("歌词视图模糊","轻微模糊非当前行；高对比度模式下自动关闭",settings.blur){ui.run{p.put("lyricBlur",it)}}
            ToggleRow("交错滚动效果","自动换行时，各行错开节奏跟随；手动滚动不受影响",settings.stagger){ui.run{p.put("lyricStagger",it)}}
        }
        Spacer(Modifier.height(24.dp));SectionCard {PreferenceRow("卡拉 OK（逐字）歌词动画兼容策略",settings.karaoke.label,Icons.Outlined.Lyrics){
            ui.choose("逐字动画兼容策略",KaraokeMode.entries.map{"${it.label}\n${it.detail}"},settings.karaoke.ordinal,height=.8f){i->ui.run{p.put("lyricKaraoke",i)}}
        }}
        Text("${settings.karaoke.detail}。估算动画不代表真实演唱时间；系统减少动态效果时停用逐字与交错动画。",Modifier.padding(16.dp))
        SectionHeading("文字预览");SectionCard {Text("让每一句歌词\n跟随音乐流动",Modifier.fillMaxWidth().padding(20.dp),fontSize=size.sp,lineHeight=(size*1.35f).sp,fontWeight=FontWeight(weight),textAlign=if(settings.center)TextAlign.Center else TextAlign.Left)}
    }
}
@Composable private fun SettingsSlider(title:String,value:Int,min:Int,max:Int,step:Int,change:(Int)->Unit,save:()->Unit) {
    Column(Modifier.padding(start=16.dp,end=16.dp,top=20.dp,bottom=8.dp)){Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){Text(title,Modifier.weight(1f),style=MaterialTheme.typography.titleMedium);Text("$value",style=MaterialTheme.typography.titleMedium)}
        FlutterSlider(value.toFloat(),{change(kotlin.math.round(it/step).toInt()*step)},valueRange=min.toFloat()..max.toFloat(),steps=(max-min)/step-1,onValueChangeFinished=save)}
}
@Composable fun PlaybackSettingsScreen() {
    val ui=LocalUi.current;
    SettingsBody("播放设置") {SectionCard {listOf("standard","exhigh","lossless").forEach{quality->ChoiceRow(qualityName(quality),ui.app.settings.string("quality","standard")==quality,if(quality=="standard")"匿名可用音源优先" else "需要账号及相应权限；不可用时降级"){ui.run{ui.app.settings.put("quality",quality)}}}}}
}
@Composable fun DownloadSettingsScreen() {
    val ui=LocalUi.current;val p=ui.app.settings
    val choose=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()){uri->if(uri!=null)ui.run {
        ui.activity.contentResolver.takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        p.putAll(mapOf("downloadTree" to uri.toString(),"downloadTreeLabel" to (runCatching {val document=android.provider.DocumentsContract.buildDocumentUriUsingTree(uri,android.provider.DocumentsContract.getTreeDocumentId(uri));ui.activity.contentResolver.query(document,arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME),null,null,null)?.use{if(it.moveToFirst())it.getString(0)else null}}.getOrNull() ?: "所选文件夹")))
    }}
    fun options(key:String,title:String,values:List<Int>,default:Int,label:(Int)->String){ui.choose(title,values.map(label),values.indexOf(p.int(key,default))){i->ui.run{p.put(key,values[i])}}}
    SettingsBody("下载设置") {
        SectionHeading("下载任务");SectionCard {
            PreferenceRow("同时下载歌曲数","${p.int("downloadConcurrent",3)} 首",Icons.Rounded.QueueMusic){options("downloadConcurrent","同时下载歌曲数",(1..5).toList(),3){"$it 首"}}
            PreferenceRow("每首下载连接数","${p.int("downloadConnections",1)} 个连接",Icons.Rounded.CallSplit){options("downloadConnections","每首下载连接数",listOf(1,2,4),1){"$it 个连接"}}
            PreferenceRow("下载总限速",speedLabel(p.int("downloadSpeedKiB")),Icons.Rounded.Speed){options("downloadSpeedKiB","下载总限速",listOf(0,128,256,512,1024,2048,5120,10240),0,::speedLabel)}
            PreferenceRow("网络失败自动重试","${p.int("downloadRetries",2)} 次",Icons.Rounded.Refresh){options("downloadRetries","网络失败自动重试",(0..3).toList(),2){if(it==0)"不自动重试" else "$it 次"}}
        }
        Text("设置从下次任务生效。总限速由所有音频连接共享；小文件或不支持可靠分段的音源自动改单连接。更多连接不一定更快。",Modifier.padding(16.dp))
        SectionHeading("下载音质");SectionCard {listOf("standard","exhigh","lossless").forEach{quality->ChoiceRow(qualityName(quality),p.string("downloadQuality",p.string("quality","standard"))==quality,if(quality=="standard")null else "需要相应账号权限；不可用时降级"){ui.run{p.put("downloadQuality",quality)}}}}
        Spacer(Modifier.height(24.dp));SectionHeading("保存位置");SectionCard {
            PreferenceRow("歌曲保存文件夹",p.string("downloadTreeLabel","应用专用目录"),Icons.Outlined.FolderOpen){choose.launch(null)}
            if(p.string("downloadTree").isNotEmpty())PreferenceRow("恢复应用专用目录",icon=Icons.Rounded.Restore){ui.run{p.putAll(mapOf("downloadTree" to null,"downloadTreeLabel" to null))}}
        }
        Text(if(p.string("downloadTree").isEmpty())"选择文件夹时由系统授予读写权限。应用专用目录中的歌曲会随卸载删除。修改位置只影响新下载，已有歌曲仍可在下载列表中管理。" else "新歌曲及歌词保存到所选文件夹，卸载后仍保留。请保持文件夹授权；修改位置只影响新下载，已有歌曲仍在原位置。",Modifier.padding(16.dp))
        SectionHeading("歌词");SectionCard {ToggleRow("同时下载 LRC 歌词","新下载包含时间标签和可用翻译；没有歌词的歌曲仅保存音频",p.bool("downloadLyrics"),icon=Icons.Outlined.Lyrics){ui.run{p.put("downloadLyrics",it)}}}
        Spacer(Modifier.height(24.dp));SectionHeading("歌曲信息");SectionCard {ToggleRow("写入歌曲标签", "将封面、标题、艺术家、专辑、发行年份和歌词写入新下载的 MP3 / FLAC；缺失信息留空，不修改已有下载",p.bool("downloadTags"),icon=Icons.Outlined.LibraryMusic){ui.run{p.put("downloadTags",it)}}}
    }
}
internal fun speedLabel(value:Int)=if(value==0)"不限速" else if(value<1024)"$value KB/s" else "${value/1024} MB/s"
@Composable fun StorageSettingsScreen() {
    val ui=LocalUi.current;val p=ui.app.settings
    SettingsBody("存储设置") {
        Text("空间上限仅计算所有账号在应用私有目录内的下载歌曲。自选公有文件夹不受此上限限制，仅受实际可用空间限制。",Modifier.padding(12.dp))
        SectionHeading("私有存储空间上限");SectionCard{listOf(128,256,512,1024,2048,4096,8192,16384).forEach{v->ChoiceRow(if(v<1024)"$v MB" else "${v/1024} GB",p.int("cacheLimitMb",256)==v){ui.run{p.put("cacheLimitMb",v)}}}}
        Text("私有存储达到上限时停止新增下载，不会自动删除已有歌曲。公有目录下载仍需私有目录提供临时空间。",Modifier.padding(16.dp))
    }
}
@Composable fun CacheSettingsScreen() {
    val ui=LocalUi.current;var size by remember{mutableStateOf<Long?>(null)};var error by remember{mutableStateOf(false)}
    var memory by remember{mutableLongStateOf(ui.activity.imageLoader.memoryCache?.size?.toLong() ?: 0)}
    val active=LocalPageActive.current
    LaunchedEffect(active){if(active)try{size=ui.app.downloads.totalSize();error=false}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(_:Exception){error=true}}
    SettingsBody("缓存管理") {
        SectionCard{PreferenceRow("下载歌曲",if(error)"暂时无法统计"else size?.let(::downloadSize) ?: "正在统计…",Icons.Outlined.MusicNote){ui.go(Screen("downloads"))}}
        Spacer(Modifier.height(16.dp));SectionCard{PreferenceRow("封面内存缓存",downloadSize(memory),Icons.Outlined.Image){ui.activity.imageLoader.memoryCache?.clear();memory=0}}
    }
}
@Composable fun NotificationSettingsScreen() {
    val ui=LocalUi.current;var enabled by remember{mutableStateOf(NotificationManagerCompat.from(ui.activity).areNotificationsEnabled())}
    val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle){val observer=androidx.lifecycle.LifecycleEventObserver{_,event->if(event==androidx.lifecycle.Lifecycle.Event.ON_RESUME)enabled=NotificationManagerCompat.from(ui.activity).areNotificationsEnabled()};lifecycle.addObserver(observer);onDispose{lifecycle.removeObserver(observer)}}
    val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){enabled=NotificationManagerCompat.from(ui.activity).areNotificationsEnabled()}
    SettingsBody("播放通知") {SectionHeading("通知权限");SectionCard{PreferenceRow(if(enabled)"通知已开启" else "开启播放通知","显示系统原生媒体卡片、专辑封面和播放控制",Icons.Outlined.Notifications){
        if(Build.VERSION.SDK_INT>=33 && ui.activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)permission.launch(Manifest.permission.POST_NOTIFICATIONS)
        else {val details=Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,android.net.Uri.parse("package:${ui.activity.packageName}"));val intent=if(Build.VERSION.SDK_INT>=26)Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,ui.activity.packageName)else details
            try{ui.activity.startActivity(intent)}catch(_:android.content.ActivityNotFoundException){ui.activity.startActivity(details)}}
    }}}
}
@Composable fun RefreshRateScreen() {
    val ui=LocalUi.current;val p=ui.app.settings;val modes=remember {ui.activity.displayOptions()}
    SettingsBody("屏幕帧率设置",bottom=24.dp) {
        Text("仅列出设备报告支持的显示模式，实际刷新率由系统决定。",Modifier.padding(8.dp));SectionCard {
            ChoiceRow("自动 · 跟随系统",p.int("screenRefreshRateMode")==0){ui.run("已提交显示模式请求"){ui.activity.applyDisplayMode(0);p.put("screenRefreshRateMode",0)}}
            modes.forEach {(index,mode)->ChoiceRow("${mode.physicalWidth}×${mode.physicalHeight} @ ${listOf(120,90,72,60)[(index-1)%4]} Hz",p.int("screenRefreshRateMode")==index){ui.run("已提交显示模式请求"){ui.activity.applyDisplayMode(index);p.put("screenRefreshRateMode",index)}}}
        }
    }
}
