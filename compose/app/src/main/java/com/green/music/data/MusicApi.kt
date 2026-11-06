package com.green.music.data

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException

const val MUSIC_URL = "https://u.y.qq.com/cgi-bin/musicu.fcg"
const val QQ_AGENT = "QQMusic 14090008(android 10)"
val webComm get() = json("ct" to 24, "cv" to 0)

// Cancel the underlying socket when a screen or account cancels its coroutine.
suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, error: IOException) {
            if (!continuation.isCancelled) continuation.resumeWithException(error)
        }
        override fun onResponse(call: Call, response: Response) {
            continuation.resume(response) { _, abandoned, _ -> abandoned.close() }
        }
    })
}

suspend fun <T> Call.consume(block: (Response)->T): T = withContext(Dispatchers.IO) {
    val response=await()
    try {coroutineScope {
        // Cancel the socket, then let the reader close its own buffer; concurrent close corrupts Okio's timeout state.
        val closer=launch(Dispatchers.Unconfined,start=CoroutineStart.UNDISPATCHED) {
            try {awaitCancellation()} finally {this@consume.cancel()}
        }
        try {block(response)} catch(e:Exception){currentCoroutineContext().ensureActive();throw e} finally {closer.cancel()}
    }} finally {response.close()}
}

open class MusicApi(val http: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS).readTimeout(25, TimeUnit.SECONDS)
    .writeTimeout(20, TimeUnit.SECONDS).build()) {
    @Volatile var session: MusicSession? = null
    private val searchMutex = Mutex()
    private var lastSearch = 0L

    suspend fun request(request: Request, maxBytes: Long = 16L * 1024 * 1024): String = http.newCall(request).consume { r ->
        if (!r.isSuccessful) throw MusicError("网络请求失败（HTTP ${r.code}），请重试", r.code)
        val body = r.body ?: throw MusicError("服务未返回数据")
        if (body.contentLength() > maxBytes) throw MusicError("服务响应过大")
        val source = body.source()
        source.request(maxBytes + 1)
        if (source.buffer.size > maxBytes) throw MusicError("服务响应过大")
        source.readUtf8()
    }
    open suspend fun rpc(module: String, method: String, param: Json,
        comm: Json? = null, headers: Map<String, String> = emptyMap()): Json {
        val identity = session
        val payload = json("comm" to (comm ?: identity?.comm ?: webComm),
            "req_0" to json("module" to module, "method" to method, "param" to param))
        val builder = Request.Builder().url(MUSIC_URL).header("User-Agent", QQ_AGENT)
            .header("Referer", "https://y.qq.com/").header("Cookie", identity?.cookie.orEmpty())
            .post(payload.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
        headers.forEach { (k, v) -> builder.header(k, v) }
        val body = decode(request(builder.build())); val req = body.obj("req_0")
        if (!body.has("code") || !req.has("code")) throw MusicError("QQ 音乐未返回接口状态")
        for (value in listOf(body.opt("code"), req.opt("code"), req.opt("subcode") ?: 0)) {
            val code = statusCode(value)
            if (code != 0) throw MusicError("QQ 音乐请求失败（$method，服务码 $code）", code)
        }
        val data = req.optJSONObject("data") ?: throw MusicError("QQ 音乐未返回 $method 数据")
        checkStatus(data)
        return data
    }
    open suspend fun cgi(path: String, query: Json, anonymous: Boolean = false): Json {
        val url = "https://c.y.qq.com$path".toHttpUrl().newBuilder()
            .addQueryParameter("format", "json").addQueryParameter("outCharset", "utf-8")
        query.keys().forEach { key -> url.addQueryParameter(key, query.get(key).toString()) }
        val data = decode(request(Request.Builder().url(url.build()).header("User-Agent", QQ_AGENT)
            .header("Referer", "https://y.qq.com/").header("Cookie", if (anonymous) "" else session?.cookie.orEmpty()).build()))
        if (!data.has("code")) throw MusicError("QQ 音乐未返回接口状态")
        checkStatus(data)
        return data
    }
    fun requireSession(): MusicSession = session?.takeIf { it.validIdentity && !it.expired }
        ?: throw MusicError("请先登录 QQ 音乐，或重新扫码恢复登录")

    suspend fun suggestions(input: String): List<String> {
        val query = input.trim()
        if (query.isEmpty() || query.codePointCount(0, query.length) > 60) return emptyList()
        val d = cgi("/splcloud/fcgi-bin/smartbox_new.fcg", json("key" to query, "inCharset" to "utf-8",
            "platform" to "yqq", "needNewCode" to 0), true).obj("data")
        return listOf("song", "singer", "album").flatMap { d.obj(it).rows("itemlist") }
            .map { it.text("name") }.filter(String::isNotEmpty).distinct().take(8)
    }
    suspend fun search(input: String, kind: Int = 0, offset: Int = 0, source: String = ""): SearchPage {
        val query = input.trim()
        if (query.isEmpty() || query.codePointCount(0, query.length) > 60 || kind !in 0..2 || offset < 0)
            throw MusicError("请输入 1–60 个字符")
        searchMutex.withLock {
            val wait = 1000 - (System.nanoTime() / 1_000_000 - lastSearch)
            if (wait > 0) delay(wait)
            lastSearch = System.nanoTime() / 1_000_000
        }
        suspend fun fetch(backend: String): SearchPage {
            val key = listOf("song", "singer", "album")[kind]
            val entries: List<Json>; val total: Int
            if (backend == "legacy") {
                val section = cgi("/soso/fcgi-bin/client_search_cp", json("p" to offset / 20 + 1,
                    "n" to 20, "w" to query, "t" to listOf(0, 9, 8)[kind], "cr" to 1, "new_json" to 1)).obj("data").obj(key)
                entries = section.requireRows("list"); total = section.number("totalnum").toInt()
                if (offset > 0 && total == 0 && entries.isEmpty()) throw MusicError("QQ 音乐搜索分页暂不可用，请稍后重试")
            } else {
                val s = session
                val comm = json("ct" to 11, "cv" to 0, "uin" to (s?.id ?: "0"), "format" to "json")
                if (s != null) comm.put("qq", s.id).put("authst", s.key).put("tmeLoginType", s.loginType)
                val d = rpc("music.search.SearchCgiService", "DoSearchForQQMusicDesktop", json("query" to query,
                    "search_type" to kind, "num_per_page" to 20, "page_num" to offset / 20 + 1), comm,
                    mapOf("User-Agent" to "Mozilla/5.0", "Cookie" to (s?.cookie ?: "tmeLoginType=-1")))
                val meta = d.obj("meta")
                if (meta.length() == 0) throw MusicError("QQ 音乐搜索列表格式异常")
                entries = d.obj("body").obj(key).requireRows("list"); total = meta.number("sum").toInt()
                if (entries.isEmpty() && meta.number("is_filter") < 0) throw MusicError("QQ 音乐暂时限制此搜索，请登录或稍后重试")
            }
            return SearchPage(backend, offset + entries.size, total,
                songs = if (kind == 0) entries.songs() else emptyList(),
                artists = if (kind == 1) entries.map(Artist::parse).filter { it.id > 0 && it.mid.isNotEmpty() } else emptyList(),
                albums = if (kind == 2) entries.map(Album::parse).filter { it.id > 0 && it.mid.isNotEmpty() } else emptyList())
        }
        if (source.isNotEmpty()) return fetch(source)
        return try { fetch("desktop") } catch (e: MusicError) { fetch("legacy") } catch (e: IOException) { fetch("legacy") }
    }
    suspend fun featured() = rpc("music.playlist.PlaylistSquare", "GetRecommendFeed", json("From" to 0, "Size" to 24))
        .requireRows("List").map { it.obj("Playlist").obj("basic") }.map { b -> MusicList(b.number("tid"), b.text("title"),
            b.obj("cover").text("default_url", "big_url", "medium_url", "small_url"), b.text("desc"), b.number("song_cnt").toInt()) }.filter { it.id > 0 }
    suspend fun recommended(): List<MusicList> {
        val s = requireSession()
        val data = rpc("music.recommend.RecommendFeed", "get_recommend_feed", json("direction" to 0, "page" to 1,
            "s_num" to 0, "v_cache" to emptyList<String>()), json("ct" to 20, "cv" to 13020008, "qq" to s.id,
            "authst" to s.key, "tmeLoginType" to s.loginType))
        if (!data.has("retcode")) throw MusicError("QQ 音乐未返回个性化歌单状态")
        return data.requireRows("v_shelf").flatMap { it.rows("v_niche") }.flatMap { it.rows("v_card") }
            .filter { it.number("type") == 500L && it.number("subtype") == 0L && it.number("jumptype") == 10014L && it.number("id") > 0 }
            .distinctBy { it.number("id") }.map { MusicList(it.number("id"), it.text("title"), it.text("cover")) }
    }
    suspend fun charts() = rpc("musicToplist.ToplistInfoServer", "GetAll", json(), webComm).requireRows("group")
        .flatMap { it.rows("toplist") }.filter { it.number("recType") == 10005L && it.number("topId") > 0 }
        .map { MusicList(it.number("topId"), it.text("title"), it.text("headPicUrl", "frontPicUrl"), it.text("intro"), it.number("totalNum").toInt(), chart = true) }
    suspend fun daily(): List<Song> {
        requireSession()
        return rpc("music.srfDissInfo.aiDissInfo", "uniform_get_Dissinfo", json("dirid" to 202, "optype" to 3,
            "tag" to 1, "userinfo" to 0, "pic_dpi" to 300)).requireRows("songlist").songs()
    }
    suspend fun radio(): List<Song> {
        requireSession()
        return rpc("music.radioProxy.MbTrackRadioSvr", "get_radio_track", json("id" to 99, "firstplay" to 1, "num" to 15)).requireRows("tracks").songs()
    }
    suspend fun songDetail(song: Song): Song {
        val result = Song.parse(rpc("music.pf_song_detail_svr", "get_song_detail_yqq",
            json("song_type" to 0, "song_mid" to song.mid, "song_id" to song.id.toString())).obj("track_info"))
        if (!result.valid || result.id != song.id) throw MusicError("QQ 音乐未返回有效歌曲详情")
        return result
    }
    suspend fun playlistPage(p: MusicList, offset: Int = 0): Page<Song> {
        if (p.chart) {
            val d = rpc("musicToplist.ToplistInfoServer", "GetDetail", json("topid" to p.id, "offset" to offset, "num" to 100, "period" to ""), webComm)
            if (d.obj("data").number("recType") != 10005L) throw MusicError("此榜单暂不支持歌曲播放")
            val entries = d.requireRows("songInfoList"); val next = offset + entries.size
            return checkedPage(entries.songs(), next, next < d.obj("data").number("totalNum"), offset)
        }
        if (offset > 0 || p.owned && !session?.encryptUin.isNullOrEmpty()) return privateSongs(p, offset)
        try {
            val d = cgi("/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg", json("disstid" to p.id, "type" to 1,
                "json" to 1, "utf8" to 1, "onlysong" to 0, "new_format" to 1)).requireRows("cdlist").firstOrNull()
                ?: throw MusicError("QQ 音乐未返回歌单详情")
            val entries = d.requireRows("songlist"); val count = d.number("total_song_num", "songnum")
            if (count > entries.size) {
                if (session == null) throw MusicError("服务端只返回了部分歌单，请登录后重试完整歌单")
                return privateSongs(p, 0)
            }
            val songs = entries.songs()
            if (songs.isEmpty() && (p.count > 0 || count > 0) && session != null) return privateSongs(p, 0)
            return Page(songs, entries.size, false)
        } catch (e: MusicError) {
            if (session != null && (e.code == 10 || p.owned)) return privateSongs(p, offset)
            throw e
        }
    }
    private suspend fun privateSongs(p: MusicList, offset: Int): Page<Song> {
        val s = requireSession()
        val d = rpc("music.srfDissInfo.DissInfo", "CgiGetDiss", json("disstid" to p.id, "dirid" to 0, "tag" to true,
            "song_begin" to offset, "song_num" to 100, "userinfo" to true, "orderlist" to true, "enc_host_uin" to s.encryptUin))
        val entries = d.requireRows("songlist"); val next = offset + entries.size
        return checkedPage(entries.songs(), next, d.flag("hasmore") || d.number("total_song_num") > next, offset)
    }
    suspend fun artistSongs(artist: Artist, offset: Int = 0) = rpc("music.web_singer_info_svr", "get_singer_detail_info",
        json("sort" to 5, "singermid" to artist.mid, "sin" to offset, "num" to 50)).requireRows("songlist").songs()
    suspend fun artistAlbums(artist: Artist, offset: Int = 0): List<Album> {
        val d = rpc("music.musichallAlbum.AlbumListServer", "GetAlbumList", json("sort" to 5, "singermid" to artist.mid,
            "begin" to offset, "num" to 30), webComm)
        return d.requireRows(if (d.has("albumList")) "albumList" else "albumlist").map(Album::parse)
    }
    suspend fun albumSongs(album: Album): List<Song> {
        val d = cgi("/v8/fcg-bin/fcg_v8_album_info_cp.fcg", json("albummid" to album.mid)).obj("data")
        return d.requireRows(if (d.has("list")) "list" else "songlist").songs()
    }
    suspend fun stream(input: Song, quality: String): SongStream {
        val song = if (input.mediaMid.isEmpty()) songDetail(input) else input
        val formats = buildList {
            if (session != null && quality == "lossless") add(Triple("F000", "flac", "lossless"))
            if (session != null && quality != "standard") add(Triple("M800", "mp3", "exhigh"))
            add(Triple("M500", "mp3", "standard"))
        }
        val guid = randomDigits(18)
        for ((prefix, extension, actualQuality) in formats) {
            val s = session
            val param = json("filename" to listOf("$prefix${song.mid}${song.mediaMid.ifEmpty { song.mid }}.$extension"),
                "guid" to guid, "songmid" to listOf(song.mid), "songtype" to listOf(0), "uin" to (s?.id ?: "0"))
            if (s != null) param.put("ctx", 0) else param.put("loginflag", 1).put("platform", "20")
            val d = rpc(if (s != null) "music.vkey.GetVkey" else "vkey.GetVkeyServer", if (s != null) "UrlGetVkey" else "CgiGetVkey", param)
            for (entry in d.rows("midurlinfo")) {
                val mid = entry.text("songmid"); val purl = entry.text("purl")
                if (purl.isEmpty() || mid.isNotEmpty() && mid != song.mid) continue
                fun hosts(data: Json): List<String> = data.optJSONArray("sip")?.let { a ->
                    (0 until a.length()).mapNotNull { a.opt(it) as? String }.filter(::validStreamUrl) } ?: emptyList()
                var hosts = hosts(d)
                if (hosts.isEmpty()) hosts = hosts(rpc("music.audioCdnDispatch.cdnDispatch", "GetCdnDispatch",
                    json("guid" to guid, "uid" to "0", "use_new_domain" to 1, "use_ipv6" to 1)))
                val url = URI(hosts.firstOrNull() ?: "http://dl.stream.qqmusic.qq.com/").resolve(purl).toString()
                if (!validStreamUrl(url)) throw MusicError("QQ 音乐返回了不可信的播放地址")
                return SongStream(url, actualQuality, extension)
            }
        }
        throw MusicError("QQ 音乐未提供播放链接，可能需要登录、会员或相应地区版权权限")
    }
    companion object {
        fun decode(input: String): Json = try {
            val s = input.trim()
            Json(Regex("^\\w+\\(([\\s\\S]*)\\);?$").matchEntire(s)?.groupValues?.get(1) ?: s)
        } catch (e: Exception) { throw MusicError("QQ 音乐响应格式无法解析") }
        fun statusCode(value: Any?) = value?.toString()?.toIntOrNull() ?: throw MusicError("QQ 音乐返回了无效的接口状态")
        fun checkStatus(data: Json) {
            for (key in listOf("code", "subcode", "retcode")) if (data.has(key)) {
                val code = statusCode(data.opt(key))
                if (code != 0) throw MusicError("QQ 音乐业务请求失败（服务码 $code）", code)
            }
        }
        fun <T> checkedPage(items: List<T>, next: Int, more: Boolean, offset: Int): Page<T> {
            if (more && next <= offset) throw MusicError("QQ 音乐分页未前进，请稍后重试完整列表")
            return Page(items, next, more)
        }
    }
}
