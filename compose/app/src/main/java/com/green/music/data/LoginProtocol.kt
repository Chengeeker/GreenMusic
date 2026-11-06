package com.green.music.data

import java.net.URI
import java.net.URLDecoder
import java.math.BigInteger
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.spec.RSAPublicKeySpec
import java.text.SimpleDateFormat
import okio.ByteString.Companion.toByteString
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

const val LOGIN_JUMP = "https://graph.qq.com/oauth2.0/login_jump"
const val WECHAT_APP_ID = "wx48db31d50e334801"
fun trustedLoginUrl(raw: String, host: String, path: String, stage: String): String {
    val uri = runCatching { URI(raw) }.getOrNull()
    if (uri == null || uri.scheme != "https" || uri.host != host || uri.path != path || uri.userInfo != null ||
        !uri.fragment.isNullOrEmpty() || uri.port !in listOf(-1, 443)) throw MusicError("登录服务返回了不可信的跳转地址（$stage）")
    return raw.substringBefore('#')
}
fun isTrustedWebLoginUrl(raw: String): Boolean = runCatching {
    val uri = URI(raw)
    uri.scheme == "https" && (uri.host == "qq.com" || uri.host?.endsWith(".qq.com") == true) &&
        uri.userInfo == null && uri.port in listOf(-1, 443)
}.getOrDefault(false)
fun isMusicWebUrl(raw: String): Boolean = isTrustedWebLoginUrl(raw) && URI(raw).host.let { it == "y.qq.com" || it.endsWith(".y.qq.com") }
fun decodeUriComponent(raw: String) = URLDecoder.decode(raw.replace("+", "%2B"), "UTF-8")
fun qqWebCallbackUrl(raw: String): String? {
    val prefix = "com.green.music.login://qq/"
    if (!raw.startsWith(prefix)) return null
    return runCatching {
        val value = raw.removePrefix(prefix)
        val target = if (value.startsWith("https://")) value else decodeUriComponent(value)
        target.takeIf { !Regex("[\\r\\n]|%0[ad]", RegexOption.IGNORE_CASE).containsMatchIn(it) && isTrustedWebLoginUrl(it) }
    }.getOrNull()
}
fun isQqAppLoginUrl(raw: String) = runCatching {
    val uri = URI(raw)
    uri.scheme in listOf("mqqapi", "wtloginmqq") && uri.host == "ptlogin" && uri.path == "/qlogin" &&
        uri.userInfo == null && uri.port == -1 && uri.fragment.isNullOrEmpty()
}.getOrDefault(false)
fun musicSessionFromWebCookies(raw: String): MusicSession {
    if (raw.length > 65536 || Regex("[\\r\\n]").containsMatchIn(raw)) throw MusicError("网页登录凭据格式无效")
    val names = setOf("uin", "qqmusic_uin", "wxuin", "qqmusic_key", "qm_keyst", "wxqqmusic_key", "login_type", "wxopenid")
    val cookies = mutableMapOf<String, String>()
    for (part in raw.trim().replaceFirst(Regex("^cookie:\\s*", RegexOption.IGNORE_CASE), "").split(';')) {
        val index = part.indexOf('='); if (index < 1) continue
        val name = part.substring(0, index).trim(); if (name !in names) continue
        val value = try { decodeUriComponent(part.substring(index + 1).trim()) } catch (_: IllegalArgumentException) { throw MusicError("网页登录凭据编码无效") }
        if (value.isEmpty()) continue
        if (cookies[name] != null && cookies[name] != value) throw MusicError("网页登录凭据冲突，请刷新网页登录")
        cookies[name] = value
    }
    if (cookies["login_type"] != null && cookies["login_type"] !in listOf("1", "2")) throw MusicError("Cookie 未标记为已登录，请从电脑端已登录的请求重新复制")
    val wechat = cookies["login_type"] == "2" || cookies["login_type"] == null && !cookies["wxopenid"].isNullOrEmpty()
    var id = (cookies[if (wechat) "wxuin" else "uin"] ?: cookies["qqmusic_uin"].orEmpty()).removePrefix("o")
    if (Regex("^\\d+$").matches(id)) id = BigInteger(id).toString()
    val key = cookies[if (wechat) "wxqqmusic_key" else "qqmusic_key"] ?: cookies["qm_keyst"].orEmpty()
    val session = MusicSession(json("musicid" to id, "musickey" to key, "loginType" to if (wechat) 1 else 2))
    if (!session.validIdentity) throw MusicError("尚未取得 QQ 音乐登录态，请先在网页中完成登录授权")
    return session
}
fun parsePtui(input: String): List<String> {
    val body = input.trim().removeSuffix(";")
    if (!body.startsWith("ptuiCB(") || !body.endsWith(')')) throw MusicError("QQ 扫码状态格式异常")
    var rest = body.substring(7, body.length - 1).trim()
    val pattern = Regex("^'((?:[^'\\\\\\r\\n]|\\\\(?:['\\\\nrt]|x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}))*)'\\s*")
    val values = mutableListOf<String>()
    while (rest.isNotEmpty()) {
        val match = pattern.find(rest) ?: throw MusicError("QQ 扫码状态格式异常")
        val value = match.groupValues[1].replace(Regex("\\\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|.)")) {
            val s = it.groupValues[1]
            when {
                s.startsWith('x') || s.startsWith('u') -> s.substring(1).toInt(16).toChar().toString()
                s == "n" -> "\n"; s == "r" -> "\r"; s == "t" -> "\t"; else -> s
            }
        }
        values += value; rest = rest.substring(match.range.last + 1).trim()
        if (rest.isEmpty()) break
        if (!rest.startsWith(',') || values.size >= 7) throw MusicError("QQ 扫码状态格式异常")
        rest = rest.substring(1).trim()
        if (rest.isEmpty()) throw MusicError("QQ 扫码状态格式异常")
    }
    if (values.size !in 6..7) throw MusicError("QQ 扫码状态格式异常")
    return values
}
fun decodeSession(body: Json, expectedType: Int): MusicSession {
    val req = body.obj("req")
    if (!body.has("code") || !req.has("code")) throw MusicError("QQ 音乐未返回登录状态")
    if (MusicApi.statusCode(body.opt("code")) != 0 || MusicApi.statusCode(req.opt("code")) != 0) throw MusicError("QQ 音乐拒绝登录")
    val raw = req.obj("data")
    if (expectedType == 1 && raw.number("loginType") == 0L) raw.put("loginType", 1)
    val s = MusicSession(raw)
    if (!s.validIdentity || s.loginType != expectedType || s.expired) throw MusicError("QQ 音乐返回了无效或过期的登录凭据")
    return s
}

fun qimeiEnvelope(device: Json, now: Long): Pair<String, Map<String, String>> {
    val appKey = "0AND0HD6FE4HY80F"
    val modulus = "c4231830a2eb5fc2827170641e79d80fec51bda9a22e4b4ab37d1f205a4ae44d928cda25879f66a3429051663312a127faf8a246bdaaf63918417e90d7c95b5908aa6a2d0f852e4a6770294a548ac1c2fe8f1f252fb826f4ac86ab9a00e7ce47d002a56e7c4b51eb889acc60ca6adbc9f72e81f4d31b1dd7464805264530ab1d"
    val key = randomHex(8); val nonce = randomHex(8); val first = randomDigits(6); val second = randomDigits(9)
    fun date(pattern: String, time: Long = now) = SimpleDateFormat(pattern, Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(time))
    val dated = setOf(1, 2, 13, 14, 17, 18, 21, 22, 25, 26, 29, 30, 33, 34, 37, 38)
    val beacon = (1..40).joinToString("") { i ->
        val value = when (i) { 3 -> "0000000000000000"; 4 -> key.replace('0', '1'); in dated -> "${date("yyyy-MM")}-01$first.$second"; else -> randomDigits(4) }
        "k$i:$value;"
    }
    val reserved = json("harmony" to "0", "clone" to "0", "containe" to "", "oz" to "UhYmelwouA+V2nPWbOvLTgN2/m8jwGB+yUB5v9tysQg=",
        "oo" to "Xecjt+9S1+f8Pz2VLSxgpw==", "kelong" to "0", "uptimes" to date("yyyy-MM-dd HH:mm:ss", now - 3600000),
        "multiUser" to "0", "bod" to "Xiaomi", "dv" to "sagit", "firstLevel" to "", "manufact" to "Xiaomi", "name" to "MI 6",
        "host" to "se.infra", "kernel" to "Linux 5.4.0-54-generic (android-build@google.com)").toString()
    val payload = json("androidId" to device.get("androidId"), "platformId" to 1, "appKey" to appKey, "appVersion" to "14.9.0.8",
        "beaconIdSrc" to beacon, "brand" to "Xiaomi", "channelId" to "10003505", "cid" to "", "imei" to device.get("imei"),
        "imsi" to "", "mac" to "", "model" to "MI 6", "networkType" to "unknown", "oaid" to "", "osVersion" to "Android 10,level 29",
        "qimei" to "", "qimei36" to "", "sdkVersion" to "1.2.13.6", "targetSdkVersion" to "33", "audit" to "", "userId" to "{}",
        "packageId" to "com.tencent.qqmusic", "deviceType" to "Phone", "sdkName" to "", "reserved" to reserved).toString().toByteArray()
    val publicKey = KeyFactory.getInstance("RSA").generatePublic(RSAPublicKeySpec(BigInteger(modulus, 16), BigInteger.valueOf(65537)))
    val wrapped = Cipher.getInstance("RSA/ECB/PKCS1Padding").apply { init(Cipher.ENCRYPT_MODE, publicKey) }.doFinal(key.toByteArray()).toByteString().base64()
    val params = Cipher.getInstance("AES/CBC/PKCS5Padding").apply {
        init(Cipher.ENCRYPT_MODE, SecretKeySpec(key.toByteArray(), "AES"), IvParameterSpec(key.toByteArray())) }.doFinal(payload).toByteString().base64()
    val seconds = now / 1000; val ts = seconds.toString(); val extra = json("appKey" to appKey).toString()
    fun digest(value: String) = MessageDigest.getInstance("MD5").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    val body = json("app" to 0, "os" to 1, "qimeiParams" to json("key" to wrapped, "params" to params, "time" to ts, "nonce" to nonce,
        "sign" to digest("$wrapped$params${seconds * 1000}${nonce}ZdJqM15EeO2zWc08$extra"), "extra" to extra)).toString()
    return body to mapOf("Method" to "GetQimei", "Service" to "trpc.tme_datasvr.qimeiproxy.QimeiProxy", "Appid" to "qimei_qq_android",
        "Sign" to digest("qimei_qq_androidpzAuCmaFAaFaHrdakPjLIEqKrGnSOOvH$ts"), "Timestamp" to ts, "Content-Type" to "application/json", "User-Agent" to "QQMusic")
}
