package com.green.music.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.SocketTimeoutException
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

data class QrLogin(val wechat: Boolean, val epoch: Int, var image: ByteArray = byteArrayOf(), var key: String = "",
    var status: String = "等待扫码", var scanned: Boolean = false, var active: Boolean = true,
    val expires: Long = System.currentTimeMillis() + 120000, var device: Json = Json(), val cookies: MutableList<Cookie> = mutableListOf())
private data class LoginResponse(val code: Int, val headers: Headers, val bytes: ByteArray) {
    fun body(limit: Int = 262144): String {
        if (bytes.size > limit) throw MusicError("登录服务返回的数据过大")
        return try { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString() }
        catch (_: Exception) { throw MusicError("登录服务响应编码异常") }
    }
}
class AuthService(val api: MusicApi, private val secrets: SecretStore) {
    private val client = api.http.newBuilder().followRedirects(false).followSslRedirects(false).build()
    private val identity = MutableStateFlow<MusicSession?>(null)
    val session = identity.asStateFlow()
    val restoreError = MutableStateFlow<String?>(null)
    private val writes = Mutex()
    private val refresh = Mutex()
    private var epoch = 0
    private var qr: QrLogin? = null
    private var loginWork: Job? = null

    suspend fun restore() {
        val generation = epoch
        try {
            val encoded = secrets.read("qqmusic_session") ?: return
            val s = MusicSession(MusicApi.decode(encoded))
            if (generation != epoch) return
            if (!s.validIdentity || s.expired && !s.canRefresh) { logout(); return }
            api.session = s; identity.value = s
            ensureSession()
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { restoreError.value = if (e is MusicError) e.message else "恢复登录失败，请检查网络后刷新账号" }
    }
    fun cancelLogin(expectedEpoch: Int? = null) {
        if (expectedEpoch != null && expectedEpoch != epoch) return
        epoch++; qr?.active = false; qr = null
        loginWork?.cancel(); loginWork = null
    }
    fun beginWebLogin(): Int { cancelLogin(); return epoch }
    suspend fun logout() {
        cancelLogin()
        val generation = epoch
        api.session = null; identity.value = null; restoreError.value = null
        save(null, generation)
    }
    private suspend fun save(value: MusicSession?, generation: Int): Boolean = writes.withLock {
        if (generation != epoch) return@withLock false
        secrets.write("qqmusic_session", value?.raw?.toString())
        if (generation != epoch) { secrets.write("qqmusic_session", null); return@withLock false }
        true
    }
    suspend fun replaceFromBackup(value: MusicSession?) {
        if (value != null && !value.validIdentity) throw MusicError("备份登录凭据无效")
        cancelLogin(); val generation = epoch
        if (!save(value, generation)) throw MusicError("账号状态已改变，请重新恢复")
        api.session = value; identity.value = value; restoreError.value = null
    }
    suspend fun importWebLoginCookies(raw: String, generation: Int): Boolean {
        if (generation != epoch) throw MusicError("本次网页登录已结束")
        loginWork = currentCoroutineContext()[Job]
        val candidate = musicSessionFromWebCookies(raw)
        val verified = profile(candidate)
        if (generation != epoch || !save(verified, generation)) return false
        api.session = verified; identity.value = verified; restoreError.value = null
        loginWork = null
        return true
    }
    private suspend fun profile(candidate: MusicSession): MusicSession {
        val info = api.rpc("music.UserInfo.userInfoServer", "GetLoginUserInfo", json(), candidate.comm,
            mapOf("Cookie" to candidate.cookie)).obj("info")
        if (info.length() == 0) throw MusicError("QQ 音乐尚未验证登录，请完成授权后重试")
        val verifiedId = info.text("musicid", "uin")
        if (Regex("^[1-9]\\d*$").matches(verifiedId) && verifiedId != candidate.id) throw MusicError("登录的账号不匹配，请刷新后重试")
        val raw = Json(candidate.raw.toString())
        mapOf("nick" to info.text("nick", "nickname"), "logo" to info.text("headurl", "logo", "avatarUrl", "avatar"),
            "encryptUin" to info.text("encryptUin", "encrypt_uin")).forEach { (k, v) -> if (v.isNotEmpty()) raw.put(k, v) }
        return MusicSession(raw)
    }
    suspend fun ensureSession() = refresh.withLock {
        var s = api.session ?: return@withLock
        val generation = epoch
        try {
            if (s.expired) {
                if (!s.canRefresh) { logout(); throw MusicError("登录已过期，请重新扫码") }
                s = refreshSession(s)
            }
            s = try { profile(s) } catch (e: MusicError) {
                if (e.code !in listOf(1000, 104400, 104401) || !s.canRefresh) throw e
                profile(refreshSession(s))
            }
            if (generation != epoch || !save(s, generation)) return@withLock
            api.session = s; identity.value = s; restoreError.value = null
        } catch (e: MusicError) {
            if (e.code in listOf(1000, 104400, 104401) && generation == epoch) logout()
            throw e
        }
    }
    suspend fun ensurePlaylistIdentity() = refresh.withLock {
        val current = api.requireSession()
        if (current.encryptUin.isNotEmpty()) return@withLock
        val generation = epoch
        val encryptUin = api.lookupPlaylistEncryptUin(current.id)
        if (generation != epoch || api.session !== current) throw CancellationException()

        val updated = MusicSession(Json(current.raw.toString()).put("encryptUin", encryptUin))
        if (!save(updated, generation)) throw CancellationException()
        api.session = updated
        identity.value = updated
    }
    private suspend fun refreshSession(s: MusicSession): MusicSession {
        val device = s.raw.obj("device").takeIf { it.length() > 0 } ?: bootstrapDevice()
        val next = wechatSession(json("openid" to s.raw.text("openid"), "refresh_token" to s.raw.text("refresh_token"),
            "str_musicid" to s.id, "musickey" to s.key, "unionid" to s.raw.text("unionid"), "refresh_key" to s.raw.text("refresh_key"), "loginMode" to 2), device, s)
        if (next.id != s.id) throw MusicError("刷新后的账号不匹配，请重新扫码")
        val merged = Json(s.raw.toString())
        next.raw.keys().forEach { key ->
            if (next.raw.opt(key).toString().isNotEmpty()) merged.put(key, next.raw.get(key))
        }
        return MusicSession(merged)
    }
    private suspend fun request(url: String, body: RequestBody? = null, headers: Map<String, String> = emptyMap(), limit: Long = 262144): LoginResponse {
        val builder = Request.Builder().url(url).header("User-Agent", "Mozilla/5.0")
        if (body != null) builder.post(body)
        headers.forEach { (k, v) -> builder.header(k, v) }
        return client.newCall(builder.build()).consume { r ->
            if (r.code !in 200..399) throw MusicError("登录服务请求失败（HTTP ${r.code}）")
            val source = r.body?.source() ?: throw MusicError("登录服务未返回数据")
            source.request(limit + 1)
            if (source.buffer.size > limit) throw MusicError("登录服务返回的数据过大")
            LoginResponse(r.code, r.headers, source.readByteArray())
        }
    }
    private fun cookie(r: LoginResponse, name: String, domain: String): String {
        var value = ""
        for (raw in r.headers.values("set-cookie")) {
            val c = Cookie.parse("https://$domain/".toHttpUrl(), raw) ?: continue
            if (c.name == name && c.domain == domain) value = if (c.expiresAt <= System.currentTimeMillis()) "" else c.value
        }
        return value
    }
    private suspend fun wechatGet(q: QrLogin, url: String, referer: String = ""): LoginResponse {
        val uri = url.toHttpUrl()
        val r = request(url, headers = mapOf("Referer" to referer, "Cookie" to q.cookies.filter { it.matches(uri) && it.expiresAt > System.currentTimeMillis() }
            .joinToString("; ") { "${it.name}=${it.value}" }))
        for (raw in r.headers.values("set-cookie")) {
            val c = Cookie.parse(uri, raw) ?: continue
            if ((c.domain == "weixin.qq.com" || c.domain.endsWith(".weixin.qq.com")) &&
                (uri.host == c.domain || uri.host.endsWith(".${c.domain}"))) {
                q.cookies.removeAll { it.name == c.name && it.domain == c.domain && it.path == c.path }
                if (c.expiresAt > System.currentTimeMillis()) q.cookies += c
            }
        }
        if (r.code != 200) throw MusicError("微信登录服务暂不可用")
        return r
    }
    suspend fun startLogin(wechat: Boolean): QrLogin {
        cancelLogin()
        loginWork = currentCoroutineContext()[Job]
        val q = QrLogin(wechat, epoch); qr = q
        try {
            if (wechat) {
                q.device = bootstrapDevice()
                val url = query("https://open.weixin.qq.com/connect/qrconnect", mapOf("appid" to WECHAT_APP_ID,
                    "redirect_uri" to "https://y.qq.com/portal/wx_redirect.html?login_type=2&surl=https://y.qq.com/", "response_type" to "code",
                    "scope" to "snsapi_login", "state" to "STATE", "href" to "https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css#wechat_redirect"))
                val page = wechatGet(q, url).body()
                q.key = Regex("(?:uuid=|/connect/qrcode/)([A-Za-z0-9_-]+)").find(page)?.groupValues?.get(1) ?: throw MusicError("微信未返回二维码标识")
                q.image = wechatGet(q, "https://open.weixin.qq.com/connect/qrcode/${q.key}", "https://open.weixin.qq.com/connect/qrconnect").bytes
            } else {
                val r = request(query("https://xui.ptlogin2.qq.com/ssl/ptqrshow", mapOf("appid" to "716027609", "e" to "2", "l" to "M",
                    "s" to "3", "d" to "72", "v" to "4", "t" to randomHex(8), "daid" to "383", "pt_3rd_aid" to "100497308", "u1" to LOGIN_JUMP)))
                q.key = cookie(r, "qrsig", "ptlogin2.qq.com"); q.image = r.bytes
                if (q.key.isEmpty()) throw MusicError("QQ 未返回二维码签名，请刷新重试")
            }
            val img = q.image
            if (img.size !in 8..65536 || !((img[0].toInt() and 255) == 137 && img[1].toInt() == 80 ||
                (img[0].toInt() and 255) == 255 && (img[1].toInt() and 255) == 216)) throw MusicError("登录服务返回的二维码图片无效")
            if (!q.active || q.epoch != epoch) throw CancellationException()
            loginWork = null
            return q
        } catch (e: Exception) { q.active = false; throw e }
    }
    suspend fun poll(q: QrLogin): Boolean {
        if (!q.active || qr !== q || q.epoch != epoch) return false
        if (System.currentTimeMillis() > q.expires) { q.active = false; q.status = "二维码已失效，请刷新"; return false }
        loginWork = currentCoroutineContext()[Job]
        val result: MusicSession
        if (q.wechat) {
            val params = mutableMapOf("uuid" to q.key, "_" to System.currentTimeMillis().toString())
            if (q.scanned) params["last"] = "404"
            val r = try { wechatGet(q, query("https://lp.open.weixin.qq.com/connect/l/qrconnect", params), "https://open.weixin.qq.com/") }
            catch (_: SocketTimeoutException) { return false }
            val m = Regex("window\\.wx_errcode\\s*=\\s*(\\d+)\\s*;\\s*window\\.wx_code\\s*=\\s*'([^'\\r\\n]*)'").find(r.body(16384))
                ?: throw MusicError("微信扫码状态格式异常")
            when (m.groupValues[1]) {
                "408" -> return false
                "404" -> { q.scanned = true; q.status = "请在微信上确认登录"; return false }
                "402", "403" -> { q.active = false; q.status = "二维码已失效，请刷新"; return false }
                "405" -> {
                    if (m.groupValues[2].isEmpty()) throw MusicError("微信未返回授权码")
                    result = wechatSession(json("code" to m.groupValues[2], "strAppid" to WECHAT_APP_ID), q.device)
                }
                else -> throw MusicError("微信扫码失败（服务码 ${m.groupValues[1]}）")
            }
        } else {
            val r = request(query("https://xui.ptlogin2.qq.com/ssl/ptqrlogin", mapOf("u1" to LOGIN_JUMP, "from_ui" to "1",
                "aid" to "716027609", "daid" to "383", "pt_3rd_aid" to "100497308", "ptqrtoken" to hash33(q.key, 0).toString())), headers = mapOf("Cookie" to "qrsig=${q.key}"))
            val args = parsePtui(r.body(16384))
            when (args[0]) {
                "66" -> return false
                "67" -> { q.scanned = true; q.status = "请在手机 QQ 上确认登录"; return false }
                "65" -> { q.active = false; q.status = "二维码已失效，请刷新"; return false }
                "0" -> result = exchangeQq(args[2])
                else -> throw MusicError("QQ 扫码失败（服务码 ${args[0]}）")
            }
        }
        if (!q.active || q.epoch != epoch || !save(result, q.epoch)) return false
        api.session = result; identity.value = result; restoreError.value = null; q.active = false; qr = null; loginWork = null
        return true
    }
    private suspend fun exchangeQq(redirect: String): MusicSession {
        var r = request(trustedLoginUrl(redirect, "ssl.ptlogin2.graph.qq.com", "/check_sig", "QQ 扫码确认"))
        if (r.code != 302) throw MusicError("QQ 授权校验未跳转")
        val jump = trustedLoginUrl(r.headers["location"].orEmpty(), "graph.qq.com", "/oauth2.0/login_jump", "QQ 授权校验")
        val cookies = listOf("p_uin", "p_skey", "pt_oauth_token").associateWith { cookie(r, it, "graph.qq.com") }
        if (cookies.values.any(String::isEmpty)) throw MusicError("QQ 授权凭据不完整")
        r = request(jump)
        if (r.code != 200) throw MusicError("QQ 授权跳转失败")
        val state = randomHex(16); val id = randomHex(16)
        val form = mapOf("response_type" to "code", "client_id" to "100497308",
            "redirect_uri" to "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/", "scope" to "get_user_info,get_app_friends",
            "state" to state, "switch" to "", "from_ptlogin" to "1", "src" to "1", "update_auth" to "1", "openapi" to "1010_1030",
            "g_tk" to hash33(cookies.getValue("p_skey")).toString(), "auth_time" to System.currentTimeMillis().toString(),
            "ui" to "${id.take(8)}-${id.substring(8,12)}-${id.substring(12,16)}-${id.substring(16,20)}-${id.substring(20)}")
        r = request("https://graph.qq.com/oauth2.0/authorize", FormBody.Builder().apply { form.forEach { (k, v) -> add(k, v) } }.build(),
            mapOf("Cookie" to cookies.entries.joinToString("; ") { "${it.key}=${it.value}" }))
        if (r.code != 302) throw MusicError("QQ 未确认授权")
        val location = r.headers["location"].orEmpty()
        if (runCatching { location.toHttpUrl().host == "graph.qq.com" && location.toHttpUrl().encodedPath == "/oauth2.0/show" }.getOrDefault(false)) {
            trustedLoginUrl(location, "graph.qq.com", "/oauth2.0/show", "QQ 授权回调")
            throw MusicError("QQ 要求继续确认网页授权，请点击“网页登录”完成登录")
        }
        val back = trustedLoginUrl(location, "y.qq.com", "/portal/wx_redirect.html", "QQ 授权回调").toHttpUrl()
        val codes = back.queryParameterValues("code"); val states = back.queryParameterValues("state")
        if (codes.size != 1 || states.size != 1 || states.single() != state || !Regex("^[A-F0-9]{32}$").matches(codes.single().orEmpty()))
            throw MusicError("QQ 授权状态或授权码不匹配")
        val body = json("comm" to json("g_tk" to 5381, "platform" to "yqq", "ct" to 24, "cv" to 0),
            "req" to json("module" to "QQConnectLogin.LoginServer", "method" to "QQLogin", "param" to json("code" to codes.single())))
        return decodeSession(MusicApi.decode(request(MUSIC_URL, body.toString().toRequestBody("application/x-www-form-urlencoded".toMediaType())).body(16384)), 2)
    }
    private suspend fun wechatSession(param: Json, device: Json, prior: MusicSession? = null): MusicSession {
        val comm = deviceComm(device).put("tmeLoginType", 1)
        if (prior != null) comm.put("qq", prior.id).put("authst", prior.key)
        val body = json("comm" to comm, "req" to json("module" to "music.login.LoginServer", "method" to "Login", "param" to param))
        val s = decodeSession(MusicApi.decode(request(MUSIC_URL, body.toString().toRequestBody("application/json".toMediaType()),
            mapOf("User-Agent" to QQ_AGENT, "Referer" to "https://y.qq.com/", "Cookie" to prior?.cookie.orEmpty())).body(16384)), 1)
        return MusicSession(s.raw.put("device", device))
    }
    private suspend fun bootstrapDevice(): Json {
        val imei = randomDigits(14)
        val sum = imei.mapIndexed { i, c -> var n = c.digitToInt(); if (i % 2 == 1) { n *= 2; if (n > 9) n -= 9 }; n }.sum()
        val device = json("androidId" to randomHex(8), "openUdid" to randomHex(16), "imei" to "$imei${(10 - sum % 10) % 10}")
        var now = System.currentTimeMillis()
        for (attempt in 0..1) {
            val (body, headers) = withContext(Dispatchers.Default) { qimeiEnvelope(device, now) }
            val r = request("https://api.tencentmusic.com/tme/trpc/proxy", body.toRequestBody("application/json".toMediaType()), headers)
            fun embedded(value: Any?) = if (value is String) MusicApi.decode(value) else value as? Json ?: Json()
            val data = embedded(embedded(MusicApi.decode(r.body(65536)).opt("data")).opt("data"))
            device.put("qimei", data.text("q16")).put("qimei36", data.text("q36"))
            if (device.text("qimei").isNotEmpty() && device.text("qimei36").isNotEmpty()) break
            val serverTime = runCatching { SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).parse(r.headers["date"].orEmpty())?.time }.getOrNull()
            if (attempt == 0 && serverTime != null && kotlin.math.abs(now - serverTime) > 60000) { now = serverTime; continue }
            throw MusicError("微信登录设备初始化未返回 QIMEI，请稍后重试")
        }
        val s = api.rpc("music.getSession.session", "GetSession", json("uid" to "", "vkey" to 0, "caller" to 0), deviceComm(device), mapOf("Cookie" to "")).obj("session")
        device.put("uid", s.opt("uid")?.toString().orEmpty()).put("sid", s.opt("sid")?.toString().orEmpty())
        if (device.text("uid").isEmpty() || device.text("sid").isEmpty()) throw MusicError("微信登录未返回设备会话")
        return device
    }
    private fun query(url: String, values: Map<String, String>) = url.toHttpUrl().newBuilder().apply { values.forEach { (k, v) -> addQueryParameter(k, v) } }.build().toString()
}
