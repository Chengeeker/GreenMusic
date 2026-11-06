@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.green.music.data.*
import kotlinx.coroutines.CancellationException

@Composable fun WebDavScreen() {
    val ui=LocalUi.current;val app=ui.app;val p=app.settings
    val service=remember {WebDavService(app.api.http)};val backup=remember {BackupService(p,app.secrets,app.auth,app.playback,app.downloads)}
    var url by remember {mutableStateOf(p.string("webdavUrl"))};var user by remember {mutableStateOf(p.string("webdavUsername"))}
    var password by remember {mutableStateOf("")};var dir by remember {mutableStateOf(p.string("webdavDirectory","GreenMusic"))}
    var full by remember {mutableStateOf(false)};var busy by remember {mutableStateOf("loading")};var invalid by remember {mutableStateOf(false)}
    LaunchedEffect(Unit){try {password=app.secrets.read("webdav_password").orEmpty()}catch(e:CancellationException){throw e}catch(_:Exception){ui.message("读取 WebDAV 密码失败，请重新填写")}finally {busy=""}}
    fun execute(action: String) {if(busy.isNotEmpty())return
        invalid=true
        if(webDavUrlError(url)!=null||user.isBlank()||password.isBlank())return
        ui.run {
            WebDavService.directoryUrl(url,dir)
            if(action=="restore" && !ui.confirm("从 WebDAV 恢复备份？","恢复会停止播放并覆盖备份内的设置、队列和历史。全量备份还会替换 QQ 音乐登录凭据和 WebDAV 密码。安全备份保留当前登录；服务器地址变化时清除本机 WebDAV 密码。"))return@run
            busy=action
            try {
                p.putAll(mapOf("webdavUrl" to url.trim(),"webdavUsername" to user.trim(),"webdavDirectory" to dir.trim().ifEmpty {"GreenMusic"}))
                app.secrets.write("webdav_password",password)
                val config=WebDavConfig(url.trim(),user.trim(),password,dir.trim())
                when(action) {
                    "test"->ui.message(if(service.test(config))"WebDAV 服务器连接成功" else "连接失败，请检查最终服务器地址和账号密码")
                    "upload"->{service.upload(config,backup.export(full));ui.message("备份已上传到 WebDAV 云盘")}
                    else->{backup.restore(service.latest(config));url=p.string("webdavUrl");user=p.string("webdavUsername");dir=p.string("webdavDirectory","GreenMusic");password=app.secrets.read("webdav_password").orEmpty();ui.message("备份已恢复；账号有效性以 QQ 音乐校验为准")}
                }
            }finally {busy=""}
        }
    }
    ReviewPage("WebDAV 云端备份与恢复") { padding -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start=16.dp,end=16.dp,top=padding.calculateTopPadding()+14.dp,bottom=padding.calculateBottomPadding()+14.dp)) {
        val c=MaterialTheme.colorScheme
        Surface(color=c.primaryContainer.copy(alpha=.4f),shape=RoundedCornerShape(16.dp),modifier=Modifier.border(1.dp,c.primary.copy(alpha=.2f),RoundedCornerShape(16.dp))) {
            Row(Modifier.padding(14.dp)){Icon(Icons.Rounded.CloudSync,null,tint=c.primary);Spacer(Modifier.width(12.dp));Column {Text("备份内容",style=MaterialTheme.typography.titleMedium,fontWeight=FontWeight((700+LocalWeightDelta.current).coerceIn(100,900)),color=c.primary);Spacer(Modifier.height(4.dp));Text("备份应用设置、播放队列和最近播放，不包含封面或歌曲缓存。",style=MaterialTheme.typography.bodyMedium.copy(lineHeight=19.6.sp),color=c.onSurfaceVariant)}}
        }
        Spacer(Modifier.height(16.dp));SectionCard {
            ChoiceRow("全量安全备份",!full,"QQ 音乐登录凭据 和 WebDAV 密码不会上传。"){if(busy.isEmpty())full=false}
            ChoiceRow("全量备份",full,"同时上传 QQ 音乐登录凭据 和 WebDAV 密码。备份文件含明文凭据，请妥善保管云盘及历史备份。"){if(busy.isEmpty())full=true}
        }
        Spacer(Modifier.height(16.dp));SectionHeading("WebDAV 服务器配置");SectionCard {Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            WebDavField(url,{url=it},Modifier.fillMaxWidth(),enabled=busy.isEmpty(),label={Text("服务器 URL")},placeholder={Text("例如: https://dav.jianguoyun.com/dav/")},leadingIcon={Icon(Icons.Rounded.Link,null)},error=if(invalid)webDavUrlError(url)else null)
            WebDavField(user,{user=it},Modifier.fillMaxWidth(),enabled=busy.isEmpty(),label={Text("账号 / 邮箱")},leadingIcon={Icon(Icons.Rounded.PersonOutline,null)},error=if(invalid&&user.isBlank())"请输入账号"else null)
            WebDavField(password,{password=it},Modifier.fillMaxWidth(),enabled=busy.isEmpty(),label={Text("应用密码 / Token")},leadingIcon={Icon(Icons.Outlined.Lock,null)},visualTransformation=PasswordVisualTransformation(),error=if(invalid&&password.isBlank())"请输入密码或授权 Token"else null)
            WebDavField(dir,{dir=it},Modifier.fillMaxWidth(),enabled=busy.isEmpty(),label={Text("备份文件夹名称")},placeholder={Text("默认: GreenMusic")},leadingIcon={Icon(Icons.Outlined.Folder,null)})
            OutlinedButton(hapticClick({execute("test")}),Modifier.fillMaxWidth().padding(top=4.dp),enabled=busy.isEmpty()){if(busy=="test")BusySpinner()else Icon(Icons.Rounded.WifiTethering,null,Modifier.size(18.dp));Spacer(Modifier.width(8.dp));Text(if(busy=="test")"正在测试连接..." else "测试服务器连接")}
        }}
        Spacer(Modifier.height(16.dp));SectionHeading("云端备份与还原操作");SectionCard {Row(Modifier.padding(16.dp),horizontalArrangement=Arrangement.spacedBy(12.dp)) {
            Button(hapticClick({execute("upload")}),Modifier.weight(1f),enabled=busy.isEmpty(),contentPadding=PaddingValues(vertical=12.dp)){if(busy=="upload")BusySpinner(androidx.compose.ui.graphics.Color.White)else Icon(Icons.Rounded.CloudUpload,null);Spacer(Modifier.width(8.dp));Text(if(busy=="upload")"正在上传..." else "立即备份到云端")}
            FilledTonalButton(hapticClick({execute("restore")}),Modifier.weight(1f),enabled=busy.isEmpty(),contentPadding=PaddingValues(vertical=12.dp)){if(busy=="restore")BusySpinner()else Icon(Icons.Rounded.CloudDownload,null);Spacer(Modifier.width(8.dp));Text(if(busy=="restore")"正在拉取..." else "从云端恢复备份")}
        }}
    } }
}

internal fun webDavUrlError(url:String):String? = when {
    url.isBlank()->"请输入 WebDAV 服务器地址"
    !runCatching{val uri=java.net.URI(url.trim());uri.scheme.equals("https",true)&&!uri.host.isNullOrBlank()&&uri.rawUserInfo==null}.getOrDefault(false)->"WebDAV 请使用 HTTPS 地址"
    else->null
}
@Composable private fun BusySpinner(color:androidx.compose.ui.graphics.Color=MaterialTheme.colorScheme.primary){CircularProgressIndicator(Modifier.size(16.dp),strokeWidth=2.dp,color=color,strokeCap=androidx.compose.ui.graphics.StrokeCap.Square)}
@Composable private fun WebDavField(value:String,change:(String)->Unit,modifier:Modifier=Modifier,enabled:Boolean=true,
    label:@Composable ()->Unit,placeholder:(@Composable ()->Unit)?=null,leadingIcon:@Composable ()->Unit,
    visualTransformation:androidx.compose.ui.text.input.VisualTransformation=androidx.compose.ui.text.input.VisualTransformation.None,error:String?=null){
    val interaction=remember{androidx.compose.foundation.interaction.MutableInteractionSource()}
    Column(modifier){
        androidx.compose.foundation.text.BasicTextField(value,change,Modifier.fillMaxWidth().heightIn(min=48.dp),enabled=enabled,
            textStyle=MaterialTheme.typography.bodyLarge.copy(color=if(enabled)MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha=.38f)),
            singleLine=true,visualTransformation=visualTransformation,interactionSource=interaction,
            keyboardOptions=if(visualTransformation is PasswordVisualTransformation)androidx.compose.foundation.text.KeyboardOptions(autoCorrectEnabled=false,keyboardType=androidx.compose.ui.text.input.KeyboardType.Password)else androidx.compose.foundation.text.KeyboardOptions.Default,
            cursorBrush=androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.primary),
            decorationBox={inner->OutlinedTextFieldDefaults.DecorationBox(value,inner,enabled,true,visualTransformation,interaction,
                isError=error!=null,label=label,placeholder=placeholder,leadingIcon=leadingIcon,contentPadding=PaddingValues(horizontal=12.dp,vertical=8.dp),
                container={OutlinedTextFieldDefaults.Container(enabled,error!=null,interaction,shape=RoundedCornerShape(4.dp))})})
        error?.let{Text(it,Modifier.padding(start=12.dp,top=4.dp),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.error)}
    }
}
