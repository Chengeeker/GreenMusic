@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.webkit.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.green.music.data.*
import kotlinx.coroutines.*

@Composable fun LoginScreen() {
    val ui=LocalUi.current;val auth=ui.app.auth;val owner=LocalLifecycleOwner.current
    var wechat by remember{mutableStateOf(false)};var generation by remember{mutableIntStateOf(0)};var qr by remember{mutableStateOf<QrLogin?>(null)}
    var loading by remember{mutableStateOf(true)};var error by remember{mutableStateOf<String?>(null)};var status by remember{mutableStateOf("")}
    var returningFromWeb by remember{mutableStateOf(false)};val active=LocalPageActive.current
    LaunchedEffect(active){if(active&&returningFromWeb){returningFromWeb=false;generation++}}
    LaunchedEffect(wechat,generation) {
        loading=true;error=null;qr=null
        try {
            val q=auth.startLogin(wechat);qr=q;status=q.status;loading=false
            owner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                while(q.active) {
                    delay(2000)
                    try {if(auth.poll(q)){ui.back();return@repeatOnLifecycle};error=null}
                    catch(e:CancellationException){throw e}catch(e:Exception){error=e.message ?: "登录失败";if(q.scanned){q.active=false;status="本次登录未完成，请刷新二维码或使用网页登录"}}
                    if(q.active || status.isEmpty())status=q.status
                }
            }
        }catch(e:CancellationException){throw e}catch(e:Exception){error=e.message ?: "二维码加载失败"}finally{loading=false}
    }
    DisposableEffect(qr?.epoch){val epoch=qr?.epoch;onDispose{if(epoch!=null)auth.cancelLogin(epoch)}}
    ReviewPage("登录 QQ 音乐"){insets->Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start=24.dp,end=24.dp,top=insets.calculateTopPadding()+24.dp,bottom=insets.calculateBottomPadding()+24.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        Column(Modifier.widthIn(max=460.dp),horizontalAlignment=Alignment.CenterHorizontally) {
            Text("让你的音乐继续",style=MaterialTheme.typography.headlineSmall);Spacer(Modifier.height(12.dp));Text("使用 QQ 音乐对应的 QQ 或微信账号登录",textAlign=TextAlign.Center)
            Spacer(Modifier.height(16.dp));FilledTonalButton(hapticClick({returningFromWeb=true;auth.cancelLogin();ui.go(Screen("webLogin"))})){Icon(Icons.Rounded.Language,null);Spacer(Modifier.width(8.dp));Text("网页登录 / 导入 Cookie")}
            Spacer(Modifier.height(24.dp));SingleChoiceSegmentedButtonRow {
                listOf(false,true).forEachIndexed{i,value->SegmentedButton(wechat==value,hapticClick({wechat=value;generation++}),shape=SegmentedButtonDefaults.itemShape(i,2)){Text(if(value)"微信扫码" else "QQ 扫码")}}
            }
            Spacer(Modifier.height(24.dp));Box(Modifier.size(264.dp).background(Color.White,RoundedCornerShape(24.dp)).padding(12.dp),contentAlignment=Alignment.Center) {
                val image=remember(qr){qr?.image?.let{BitmapFactory.decodeByteArray(it,0,it.size)?.asImageBitmap()}}
                if(loading)CircularProgressIndicator(Modifier.size(36.dp),strokeWidth=4.dp,strokeCap=androidx.compose.ui.graphics.StrokeCap.Square)else if(image!=null)Image(image,if(wechat)"微信登录二维码" else "QQ 登录二维码",Modifier.fillMaxSize()) else if(qr?.image!=null)Text("二维码图片加载失败",color=Color.Black)else Icon(Icons.Rounded.QrCode2,null,Modifier.size(120.dp),tint=Color.Black)
            }
            Spacer(Modifier.height(20.dp));Text(if(loading)"正在获取二维码…" else status.ifEmpty{"二维码未加载"},textAlign=TextAlign.Center)
            if(error!=null)Text(error!!,Modifier.padding(top=12.dp),color=MaterialTheme.colorScheme.error,textAlign=TextAlign.Center)
            Spacer(Modifier.height(12.dp));OutlinedButton(hapticClick({generation++}),enabled=!loading){Icon(Icons.Rounded.Refresh,null);Spacer(Modifier.width(8.dp));Text("刷新二维码")}
            Spacer(Modifier.height(20.dp));Text("也可把二维码截图传到电脑显示，再用手机 QQ 或微信扫码并确认。二维码约 2 分钟后失效。",textAlign=TextAlign.Center)
            Spacer(Modifier.height(12.dp));Text("登录仅保存在本机，会员与版权权限由 QQ 音乐决定。",textAlign=TextAlign.Center,style=MaterialTheme.typography.bodySmall)
        }
    }}
}
@Composable fun WebLoginScreen() {
    val ui=LocalUi.current;val context=LocalContext.current;val scope=rememberCoroutineScope();val lifecycle=LocalLifecycleOwner.current
    val generation=remember{ui.app.auth.beginWebLogin()}
    var webUnavailable by remember{mutableStateOf(false)}
    var web by remember{mutableStateOf<WebView?>(null)};var error by remember{mutableStateOf<String?>(null)};var loading by remember{mutableStateOf(true)}
    var checking by remember{mutableStateOf(false)};var qqPending by remember{mutableStateOf(false)};var closing by remember{mutableStateOf(false)};var lastCookie by remember{mutableStateOf("")}
    suspend fun check(raw:String?=null,manual:Boolean=false) {
        if(checking||closing)return
        if(raw==null&&!isMusicWebUrl(web?.url.orEmpty())){if(manual)error="请先在 QQ 音乐官网完成登录；电脑已有登录态可点右上角导入 Cookie";return}
        val cookie=raw ?: CookieManager.getInstance().getCookie("https://y.qq.com/").orEmpty()
        if(!manual&&cookie==lastCookie)return
        try{musicSessionFromWebCookies(cookie)}catch(e:MusicError){if(manual)error=e.message;return}
        checking=true;lastCookie=cookie
        try{if(ui.app.auth.importWebLoginCookies(cookie,generation)){closing=true;ui.back();if(ui.stack.lastOrNull()?.kind=="login")ui.back()}}
        catch(e:CancellationException){throw e}catch(e:Exception){error=e.message ?: "登录验证失败"}finally{checking=false}
    }
    fun importCookie(){ui.dialog={var value by remember{mutableStateOf("")};ReviewDialog(onDismissRequest={ui.dialog=null},title={Text("导入 QQ 音乐 Cookie")},text={Column(Modifier.verticalScroll(rememberScrollState())){
        Text("在电脑 QQ 音乐网页登录后，从开发者工具 Network 中复制 QQ 音乐请求头的 Cookie 值。验证通过后，仅加密保存音乐登录凭据。")
        Spacer(Modifier.height(16.dp));TextField(value,{if(it.length<=65536)value=it},Modifier.fillMaxWidth(),colors=flutterInputColors(),label={Text("Cookie")},placeholder={Text("粘贴 QQ 音乐网页 Cookie")},visualTransformation=PasswordVisualTransformation(),singleLine=true,keyboardOptions=KeyboardOptions(autoCorrectEnabled=false,keyboardType=KeyboardType.Password))
    }},confirmButton={Button(hapticClick({ui.dialog=null;scope.launch{check(value.trim(),true)}})){Text("验证并导入")}},dismissButton={TextButton(hapticClick({ui.dialog=null})){Text("取消")}})} }
    val active=LocalPageActive.current
    LaunchedEffect(active){if(!active){closing=true;ui.app.auth.cancelLogin(generation);web?.stopLoading()}}
    val callbacks=remember {(ui.activity as? com.green.music.MainActivity)?.loginCallback ?: kotlinx.coroutines.flow.MutableStateFlow<String?>(null)}
    val callback by callbacks.collectAsState()
    LaunchedEffect(callback){if(qqPending&&callback!=null){qqPending=false;qqWebCallbackUrl(callback!!)?.let{web?.loadUrl(it)};callbacks.value=null}}
    LaunchedEffect(Unit){lifecycle.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED){while(true){delay(2000);check()}}}
    DisposableEffect(Unit){onDispose{closing=true;ui.app.auth.cancelLogin(generation);web?.apply{stopLoading();loadUrl("about:blank");clearHistory();destroy()};runCatching{CookieManager.getInstance().removeAllCookies(null);WebStorage.getInstance().deleteAllData()}}}
    ReviewPage("网页登录",actions={ActionIcon(Icons.Rounded.Input,"导入 Cookie",!checking,action=::importCookie)}) {insets->Column(Modifier.fillMaxSize().padding(insets)) {
        Column(Modifier.heightIn(max=LocalConfiguration.current.screenHeightDp.dp*.28f).verticalScroll(rememberScrollState()).padding(start=16.dp,end=16.dp,top=12.dp,bottom=8.dp)){
            Text("在 QQ 音乐官网点击“登录”。电脑端已登录，可从右上角导入 Cookie。")
            error?.let{Text(it,Modifier.padding(top=8.dp),color=MaterialTheme.colorScheme.error)}
        }
        if(loading||checking)LinearProgressIndicator(Modifier.fillMaxWidth(),strokeCap=androidx.compose.ui.graphics.StrokeCap.Butt,gapSize=0.dp,trackColor=MaterialTheme.colorScheme.secondaryContainer)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if(webUnavailable)Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center){Text("可导入电脑端 Cookie，或返回使用二维码登录",textAlign=TextAlign.Center)}
            else AndroidView(factory={ctx->try{WebView(ctx).also {view->web=view
                view.settings.apply{javaScriptEnabled=true;domStorageEnabled=true;allowFileAccess=false;allowContentAccess=false;mixedContentMode=WebSettings.MIXED_CONTENT_NEVER_ALLOW;useWideViewPort=true;loadWithOverviewMode=true;setSupportZoom(true)
                    userAgentString="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"}
                CookieManager.getInstance().setAcceptThirdPartyCookies(view,true)
                view.webViewClient=object:WebViewClient(){
                    override fun shouldOverrideUrlLoading(v:WebView,request:WebResourceRequest):Boolean {
                        val url=request.url.toString()
                        if(closing)return true
                        if(url=="about:blank")return false
                        if(isQqAppLoginUrl(url)) {
                            if(!qqPending&&!checking&&isTrustedWebLoginUrl(v.url.orEmpty()))try {
                                val uri=Uri.parse(url);val target=uri.buildUpon().clearQuery()
                                uri.queryParameterNames.filter{it !in setOf("schemacallback","encode_jump_url","replace_https")}.forEach{name->uri.getQueryParameters(name).forEach{target.appendQueryParameter(name,it)}}
                                target.appendQueryParameter("schemacallback","com.green.music.login://qq/").appendQueryParameter("encode_jump_url","1")
                                qqPending=true;ui.activity.startActivity(Intent(Intent.ACTION_VIEW,target.build()).setPackage("com.tencent.mobileqq"))
                            }catch(_:Exception){qqPending=false;error="未能打开手机 QQ，可在官网选择账号密码登录，或从右上角导入 Cookie"}
                            return true
                        }
                        if(!request.isForMainFrame&&request.url.scheme=="https")return false
                        if(isTrustedWebLoginUrl(url))return false
                        error="暂不支持此跳转，请在 QQ 音乐官网完成登录，或从右上角导入 Cookie";return true
                    }
                    override fun onPageStarted(v:WebView,url:String,favicon:android.graphics.Bitmap?){loading=true}
                    override fun onPageFinished(v:WebView,url:String){loading=false;scope.launch{check()}}
                    override fun onReceivedError(v:WebView,request:WebResourceRequest,e:WebResourceError){if(request.isForMainFrame){loading=false;error="网页登录加载失败，可刷新重试或导入电脑端 Cookie"}}
                }
                CookieManager.getInstance().removeAllCookies{if(!closing)view.loadUrl("https://y.qq.com/")};WebStorage.getInstance().deleteAllData()
            }}catch(_:Exception){loading=false;webUnavailable=true;error="网页组件暂不可用，仍可使用右上角导入 Cookie";android.view.View(ctx)}},modifier=Modifier.fillMaxSize())
        }
        Row(Modifier.fillMaxWidth().padding(12.dp),horizontalArrangement=Arrangement.spacedBy(12.dp)) {
            OutlinedButton(hapticClick({qqPending=false;lastCookie="";error=null;if(webUnavailable){webUnavailable=false;loading=true}else CookieManager.getInstance().removeAllCookies{if(!closing)web?.loadUrl("https://y.qq.com/")}}),enabled=!checking){Icon(Icons.Rounded.Refresh,null);Spacer(Modifier.width(8.dp));Text("刷新")}
            Button(hapticClick({scope.launch{check(manual=true)}}),Modifier.weight(1f),enabled=!checking){Text(if(checking)"正在验证…" else "完成登录")}
        }
    }}
}
