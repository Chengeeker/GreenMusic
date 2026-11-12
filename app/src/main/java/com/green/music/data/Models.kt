// Protocol models adapted from GreenMusic/Lilt (AGPL-3.0).
package com.green.music.data

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.security.SecureRandom

typealias Json = JSONObject
fun json(vararg values: Pair<String, Any?>) = Json().apply {
    values.forEach { (key, value) -> put(key, wrap(value)) }
}
private fun wrap(value: Any?): Any = when (value) {
    null -> JSONObject.NULL
    is Iterable<*> -> JSONArray().apply { value.forEach { put(wrap(it)) } }
    is Map<*, *> -> Json().apply { value.forEach { (k, v) -> put(k.toString(), wrap(v)) } }
    else -> value
}
fun Json.obj(key: String) = optJSONObject(key) ?: Json()
fun Json.rows(key: String): List<Json> = optJSONArray(key)?.let { a ->
    (0 until a.length()).mapNotNull { a.optJSONObject(it) }
} ?: emptyList()
fun Json.text(vararg keys: String): String = keys.firstNotNullOfOrNull {
    (opt(it) as? String)?.takeIf(String::isNotEmpty)
} ?: ""
fun Json.number(vararg keys: String): Long = keys.firstNotNullOfOrNull {
    opt(it)?.toString()?.toLongOrNull()
} ?: 0L
fun Json.flag(key: String) = opt(key) == true || number(key) == 1L
fun Json.requireRows(key: String): List<Json> {
    if (opt(key) !is JSONArray) throw MusicError("QQ 音乐未返回有效列表（$key）")
    return rows(key)
}
class MusicError(message: String, val code: Int? = null) : Exception(message)
fun hash33(value: String, initial: Int = 5381): Int = value.fold(initial) { hash, c ->
    (hash * 33 + c.code) and 0x7fffffff
}
private val random = SecureRandom()
fun randomDigits(length: Int) = buildString { repeat(length) { append(random.nextInt(10)) } }
fun randomHex(bytes: Int) = ByteArray(bytes).also(random::nextBytes).joinToString("") { "%02x".format(it) }

data class Artist(val id: Long, val mid: String, val name: String) {
    val cover get() = if (mid.isEmpty()) "" else "https://y.gtimg.cn/music/photo_new/T001R300x300M000$mid.jpg"
    companion object {
        fun parse(j: Json) = Artist(j.number("id", "singerid", "singer_id", "singerID"),
            j.text("mid", "singermid", "singer_mid", "singerMid", "singerMID"),
            j.text("name", "singername", "singer_name", "singerName"))
    }
}
data class Album(val id: Long, val mid: String, val name: String, val picture: String = "") {
    val cover get() = picture.ifEmpty { if (mid.isEmpty()) "" else "https://y.gtimg.cn/music/photo_new/T002R500x500M000$mid.jpg" }
    companion object {
        fun parse(j: Json) = Album(j.number("id", "albumid", "albumID", "album_id"),
            j.text("mid", "albummid", "albumMID", "albumMid", "album_mid", "pmid"),
            j.text("name", "title", "albumname", "albumName", "album_name"), j.text("albumPic", "picUrl"))
    }
}
data class Song(val raw: Json) {
    val id = raw.number("id", "songid", "songId")
    val mid = raw.text("mid", "songmid", "songMid")
    val name = raw.text("title", "name", "songname", "songName")
    val durationMs = raw.number("interval") * 1000
    val artists = raw.rows(if (raw.has("singer")) "singer" else "singers").map(Artist::parse)
    val album = Album.parse(raw.obj("album")).let { a -> if (a.mid.isNotEmpty()) a else a.copy(
        id = a.id.takeIf { it > 0 } ?: raw.number("albumid", "album_id"),
        mid = raw.text("albummid", "album_mid"), name = a.name.ifEmpty { raw.text("albumname", "album_name") }) }
    val mediaMid = raw.obj("file").text("media_mid").ifEmpty { raw.text("strMediaMid", "media_mid") }
    val valid get() = id > 0 && mid.isNotEmpty()
    val artistNames get() = artists.joinToString(" / ") { it.name }
    val cover get() = album.cover
    val releaseYear get() = sequenceOf(raw, raw.obj("album")).map {
        Regex("^(\\d{4})(?:[-/.]|$)").find(it.text("time_public", "pub_time", "publishDate", "release_time", "pubtime"))?.groupValues?.get(1).orEmpty()
    }.firstOrNull { (it.toIntOrNull() ?: 0) in 1000..2999 }.orEmpty()
    fun downloadBytes(quality: String): Long {
        val (modern, legacy) = when (quality) {
            "lossless" -> "size_flac" to "sizeflac"
            "exhigh" -> "size_320mp3" to "size320"
            else -> "size_128mp3" to "size128"
        }
        return (raw.obj("file").number(modern).takeIf { it > 0 } ?: raw.number(legacy)).coerceAtLeast(0)
    }
    companion object {
        fun parse(input: Json): Song {
            var raw = input
            for (key in listOf("musicData", "songInfo", "track_info")) raw.optJSONObject(key)?.let { raw = it }
            return Song(raw)
        }
    }
}
fun List<Json>.songs() = map(Song::parse).filter(Song::valid)
data class MusicList(val id: Long, val name: String, val cover: String = "", val description: String = "",
    val count: Int = 0, val chart: Boolean = false, val owned: Boolean = false, val dirId: Int = 0, val saved: Boolean = false) {
    val editable get() = owned && dirId in 1..199
    companion object {
        fun parse(j: Json, owned: Boolean = false, saved: Boolean = false) = MusicList(
            j.number("tid", "dissid", "id"), j.text("dirName", "title", "dissname", "name"),
            j.text("bigpicUrl", "picUrl", "picurl", "coverUrl", "logo", "albumPicUrl"), j.text("desc"),
            j.number("songNum", "songnum", "song_cnt").toInt(), owned = owned,
            dirId = j.number("dirId", "dirid").toInt(), saved = saved)
    }
}
data class Page<T>(val items: List<T>, val nextOffset: Int, val more: Boolean)
data class SearchPage(val source: String, val nextOffset: Int, val total: Int,
    val songs: List<Song> = emptyList(), val artists: List<Artist> = emptyList(), val albums: List<Album> = emptyList()) {
    val more get() = nextOffset > 0 && nextOffset < total
}
data class SongStream(val url: String, val quality: String, val extension: String)
data class MusicSession(val raw: Json) {
    val id get() = raw.opt("str_musicid")?.toString() ?: raw.opt("musicid")?.toString().orEmpty()
    val key get() = raw.text("musickey")
    val nickname get() = raw.text("nick").ifEmpty { id }
    val avatar get() = raw.text("logo")
    val loginType get() = raw.number("loginType").toInt()
    val encryptUin get() = raw.text("encryptUin", "encrypt_uin").trim()
    val validIdentity get() = (id.toLongOrNull() ?: 0) > 0 && key.isNotEmpty() &&
        !Regex("[\\r\\n;]").containsMatchIn(key) && loginType in 1..2
    val expired get(): Boolean {
        val created = raw.number("musickeyCreateTime"); val expires = raw.number("keyExpiresIn")
        return created > 0 && expires > 0 && System.currentTimeMillis() / 1000 >= created + expires
    }
    val canRefresh get() = loginType == 1 && raw.text("refresh_key", "refresh_token").isNotEmpty()
    val cookie get() = "uin=$id; qqmusic_uin=$id; qm_keyst=$key; qqmusic_key=$key"
    val comm get() = deviceComm(raw.obj("device")).put("qq", id).put("authst", key).put("tmeLoginType", loginType)
}
fun deviceComm(d: Json = Json()) = json("ct" to 11, "cv" to 14090008, "v" to 14090008,
    "chid" to "10003505", "tmeAppID" to "qqmusic").apply {
    if (d.length() > 0) {
        for ((key, source) in mapOf("QIMEI" to "qimei", "QIMEI36" to "qimei36", "OpenUDID" to "openUdid",
            "udid" to "openUdid", "OpenUDID2" to "openUdid", "aid" to "androidId", "uid" to "uid", "sid" to "sid")) {
            if (d.has(source)) put(key, d.get(source))
        }
        put("os_ver", "10"); put("phonetype", "MI 6"); put("devicelevel", "29"); put("newdevicelevel", "29")
        put("rom", "xiaomi/iarim/sagit:10/eomam.200122.001/2001221:user/release-keys")
    }
}
fun validStreamUrl(value: String): Boolean = runCatching {
    val u = URI(value)
    u.scheme in listOf("http", "https") && u.userInfo == null &&
        (u.host == "qqmusic.qq.com" || u.host?.endsWith(".qqmusic.qq.com") == true || u.host?.endsWith(".qq.com") == true)
}.getOrDefault(false)
