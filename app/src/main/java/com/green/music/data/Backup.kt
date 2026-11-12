package com.green.music.data

import com.green.music.player.Downloads
import com.green.music.player.Playback
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import okhttp3.Credentials
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

object BackupFormat {
    val bools = setOf("dynamicColor", "pureBlack", "haptics", "floatingNav", "liquidGlass", "translucentNavigationGlass", "customFontWeight", "shuffle", "downloadLyrics", "downloadTags", "lyricCenter", "lyricBlur", "lyricStagger")
    val ranges = mapOf("themeMode" to 0..2, "colorIndex" to 0..7, "fontWeightDelta" to -300..300, "screenRefreshRateMode" to 0..8,
        "queueIndex" to -1..100000, "position" to 0..86400000, "repeat" to 0..3, "cacheLimitMb" to 128..16384,
        "downloadConcurrent" to 1..5, "downloadConnections" to 1..4, "downloadSpeedKiB" to 0..10240, "downloadRetries" to 0..3,
        "lyricFontSize" to 16..40, "lyricFontWeight" to 100..900, "lyricKaraoke" to 0..3)
    val strings = setOf("quality", "downloadQuality", "queue", "history", "webdavUrl", "webdavUsername", "webdavDirectory")
    val keys = bools + ranges.keys + strings + "appTextScale"
    fun validate(backup: Json): Map<String, Any> {
        if (backup.text("app") != "greenmusic" || backup.number("schema") != 1L || backup.text("backup_mode") !in listOf("safe", "full") || backup.optJSONObject("preferences") == null)
            throw MusicError("不是受支持的 GreenMusic 备份")
        val prefs = backup.obj("preferences")
        val result = mutableMapOf<String, Any>()
        for (key in prefs.keys()) {
            if (key in listOf("appIcon", "saltUi")) continue
            if (key !in keys) throw MusicError("备份包含未知设置，未恢复")
            val value = prefs.get(key)
            if (key in bools && value !is Boolean || key in strings && value !is String) throw MusicError("备份设置类型无效")
            ranges[key]?.let { range ->
                if ((value !is Int && value !is Long) || (value as Number).toLong() !in range.first.toLong()..range.last.toLong()) throw MusicError("备份设置范围无效")
            }
            if (key == "appTextScale" && (value !is Number || !value.toDouble().isFinite() || value.toDouble() !in .8..1.5)) throw MusicError("备份字体比例无效")
            if (key == "downloadConnections" && (value as Number).toInt() !in listOf(1,2,4)) throw MusicError("备份下载连接数无效")
            if (key == "lyricFontWeight" && (value as Number).toInt() % 100 != 0) throw MusicError("备份歌词字重无效")
            if (key in listOf("quality", "downloadQuality") && value !in listOf("standard", "exhigh", "lossless")) throw MusicError("备份选项无效")
            if (key in listOf("queue", "history")) {
                val array = try { JSONArray(value as String) } catch (_: Exception) { throw MusicError("备份播放记录格式无效") }
                if (array.length() > 100000 || (0 until array.length()).any { i -> array.optJSONObject(i)?.let { !Song.parse(it).valid } != false }) throw MusicError("备份歌曲记录无效")
            }
            result[key] = if (key == "appTextScale") (value as Number).toFloat() else value
        }
        if (backup.text("backup_mode") == "full") {
            val c = backup.obj("credentials")
            if (!c.has("qqmusic") || c.opt("webdavPassword") !is String) throw MusicError("全量备份凭据不完整")
            if (!c.isNull("qqmusic") && (c.optJSONObject("qqmusic") == null || !MusicSession(c.obj("qqmusic")).validIdentity)) throw MusicError("备份中的 QQ 音乐凭据无效")
        } else if (backup.has("credentials")) throw MusicError("安全备份包含不应有的凭据字段")
        return result
    }
}
@androidx.media3.common.util.UnstableApi
class BackupService(private val settings: AppSettings, private val secrets: SecretStore, private val auth: AuthService,
    private val playback: Playback, private val downloads: Downloads) {
    suspend fun export(full: Boolean): Json {
        val account=auth.session.value;val epoch=auth.backupEpoch
        check(!full || account!=null || !secrets.encryptedSnapshot().containsKey("qqmusic_session")){"本机登录尚未成功读取，已停止全量备份，避免覆盖云端账号资料"}
        val data = json("app" to "greenmusic", "schema" to 1, "backup_mode" to if (full) "full" else "safe",
            "created_at" to SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date()),
            "preferences" to settings.all().filterKeys { it in BackupFormat.keys })
        if (full) data.put("credentials", json("qqmusic" to account?.raw, "webdavPassword" to secrets.read("webdav_password").orEmpty()))
        check(auth.backupEpoch==epoch && auth.session.value===account) { "账号已改变，请重新备份" }
        data.put("accountMode",if(account==null)"GUEST" else "COOKIE")
        BackupFormat.validate(data)
        return data
    }
    suspend fun restore(data: Json,verify:suspend (MusicSession)->MusicSession=auth::verifyBackup): String = restoreMutex.withLock {
        val values=BackupFormat.validate(data)
        val previous=settings.all().toMap();val oldSession=auth.session.value;val epoch=auth.backupEpoch
        val oldEncrypted=secrets.encryptedSnapshot()
        val full=data.text("backup_mode")=="full"
        val candidate=if(full)data.obj("credentials").optJSONObject("qqmusic")?.let(::MusicSession)else null
        var verified:MusicSession?=null
        if(candidate!=null) {
            try {verified=verify(candidate).also{check(it.id==candidate.id){"登录验证账号不匹配"}}}
            catch(e:CancellationException){throw e}
            catch(_:Exception){}
        }
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        check(auth.backupEpoch==epoch && auth.session.value===oldSession) { "账号已改变，请重新恢复" }
        playback.stop(persistState=false);downloads.cancelAll()
        var appliedSettings:Map<String,*>?=null;var appliedSecrets:Map<String,*>?=null;var appliedEpoch:Int?=null
        auth.commitBackup(epoch) { withContext(NonCancellable) {
        try {
            settings.restoreValues(previous,values);appliedSettings=previous+values
            if(full) {
                appliedSecrets=secrets.write("webdav_password",data.obj("credentials").getString("webdavPassword"),recoverUnreadable=true,expected=oldEncrypted)
                if(verified!=null){
                    check(auth.backupEpoch==epoch){"账号已改变，请重新恢复"}
                    appliedSecrets=secrets.write("qqmusic_session",verified.raw.toString(),recoverUnreadable=true,expected=appliedSecrets)
                    auth.acceptBackup(verified,epoch);appliedEpoch=auth.backupEpoch
                }
            } else if(listOf("webdavUrl","webdavUsername").any{values.containsKey(it)&&values[it]!=previous[it]}) {
                appliedSecrets=secrets.write("webdav_password",null,expected=oldEncrypted)
            }
            check(auth.backupEpoch==(appliedEpoch?:epoch)){"账号已改变，请重新恢复"}
            playback.reload()
        }catch(e:Exception) {
            withContext(NonCancellable) {
                try {
                    appliedSecrets?.let{secrets.rollbackEncrypted(it,oldEncrypted)}
                    appliedEpoch?.let{auth.rollbackBackup(oldSession,it)}
                    appliedSettings?.let{settings.restoreValues(it,values.keys.associateWith{key->previous[key]})}
                    playback.reload()
                }catch(rollback:Exception){e.addSuppressed(rollback)}
            }
            throw e
        }
        } }
        when {
            verified!=null->"设置和本地资料已恢复，账号登录已通过验证并恢复。"
            candidate!=null->"资料已恢复，但账号登录未恢复，请重试或重新登录。当前会话保持不变。"
            full->"设置和本地资料已恢复。备份未包含有效登录凭据，当前会话保持不变。"
            else->"设置和本地资料已恢复，当前账号登录保持不变。"
        }
    }
    companion object {private val restoreMutex=kotlinx.coroutines.sync.Mutex()}

}
data class WebDavConfig(val server: String, val username: String, val password: String, val directory: String)
class WebDavService(client: OkHttpClient) {
    private val transport = WebDavTransport(client, MAX_BYTES)
    private suspend fun request(url: HttpUrl, method: String, config: WebDavConfig, bytes: ByteArray? = null): Pair<Int, ByteArray> {
        val response = transport.request(url, method, Credentials.basic(config.username, config.password, Charsets.UTF_8), bytes)
        response.requireStatus(if (method == "GET") "下载" else method, if (method == "MKCOL") setOf(200, 201, 405) else setOf(200, 201, 204, 207))
        return response.code to response.bytes
    }
    suspend fun test(config: WebDavConfig): Boolean = request(baseUrl(config.server), "PROPFIND", config).first in listOf(200,207)
    suspend fun upload(config: WebDavConfig, data: Json) {
        val bytes = data.toString().toByteArray()
        if (bytes.size > MAX_BYTES) throw MusicError("备份超过 8 MB")
        val directory = directoryUrl(config.server, config.directory)
        if (request(directory, "MKCOL", config).first !in listOf(200,201,405)) throw MusicError("备份文件夹创建失败，请检查权限")
        if (request(directory.resolve("backup_greenmusic_latest.json")!!, "PUT", config, bytes).first !in listOf(200,201,204)) throw MusicError("备份上传失败")
        try { request(directory.resolve("backup_greenmusic_${System.currentTimeMillis()}.json")!!, "PUT", config, bytes) }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { /* Confirmed latest remains available when history upload fails. */ }
    }
    suspend fun latest(config: WebDavConfig): Json {
        val (status, bytes) = request(directoryUrl(config.server, config.directory).resolve("backup_greenmusic_latest.json")!!, "GET", config)
        if (status != 200) throw MusicError("备份下载失败（HTTP $status）")
        return try { Json(String(bytes, Charsets.UTF_8)) } catch (_: Exception) { throw MusicError("备份格式无效") }
    }
    companion object {
        const val MAX_BYTES = 8L * 1024 * 1024
        fun baseUrl(input: String): HttpUrl {
            val raw = input.trim().let { if (it.contains("://")) it else "https://$it" }
            val uri = runCatching { java.net.URI(raw) }.getOrNull()
            if (uri == null || uri.host.isNullOrEmpty() || uri.userInfo != null || uri.rawFragment != null || uri.rawQuery != null ||
                !(uri.scheme == "https" || uri.scheme == "http" && uri.host in listOf("localhost", "127.0.0.1"))) throw MusicError("WebDAV 地址必须使用 HTTPS，或本机回环地址")
            return (if (raw.endsWith('/')) raw else "$raw/").toHttpUrl()
        }
        fun directoryUrl(server: String, input: String): HttpUrl {
            val name = input.trim().ifEmpty { "GreenMusic" }
            if (name in listOf(".", "..") || Regex("[/\\\\\\x00-\\x1f]").containsMatchIn(name)) throw MusicError("备份文件夹名称无效")
            return baseUrl(server).newBuilder().addPathSegment(name).addPathSegment("").build()
        }
    }
}
