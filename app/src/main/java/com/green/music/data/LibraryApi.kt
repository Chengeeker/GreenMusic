// Preserve the original ownership, write acknowledgements and read-back checks.
package com.green.music.data

import org.json.JSONArray

data class SongShelf(val title:String,val songs:List<Song>)

suspend fun MusicApi.songShelves():List<SongShelf> {
    val s=requireSession()
    val comm=json("format" to "json","ct" to 20,"cv" to 2276,"platform" to "wk_v17","inCharset" to "utf-8","outCharset" to "utf-8",
        "notice" to 0,"needNewCode" to 1,"uin" to s.id,"qq" to s.id,"authst" to s.key,"tmeLoginType" to s.loginType,"g_tk" to 0,"g_tk_new_20200303" to 0)
    val shelves=mutableListOf<Pair<String,List<Long>>>();var received=0
    for(page in 1..10) {
        val d=try {rpc("music.recommend.RecommendFeed","get_recommend_feed",json("direction" to if(page==1)0 else 1,"page" to page,"s_num" to received,"v_cache" to emptyList<String>(),"v_uniq" to emptyList<String>()),comm).also {
            if(!it.has("retcode")||it.optJSONArray("v_shelf")==null)throw MusicError("QQ 音乐未返回推荐歌曲状态或列表")
        }}catch(e:MusicError){if(shelves.isEmpty())throw e else break}catch(e:java.io.IOException){if(shelves.isEmpty())throw e else break}
        val batch=d.requireRows("v_shelf");received+=batch.size
        for(shelf in batch.filter {it.number("id")==207L}) {
            val cards=shelf.rows("v_niche").flatMap {it.rows("v_card")}
            val songs=cards.filter {it.number("type")==200L}.map {it.number("id")}.toSet()
            val others=cards.filter {it.number("type")!=200L}.map {it.number("id")}.toSet()
            val ids=shelf.obj("miscellany").text("songList").split(',').mapNotNull {it.trim().toLongOrNull()}.filter {it>0&&(it !in others || it in songs)}.distinct().ifEmpty {songs.filter {it>0}}
            if(ids.isEmpty())continue
            val title=shelf.text("title_template","title_content").replace("{String}",shelf.text("title_content")).replace("\u2062","").trim().ifEmpty {"为你推荐的歌曲"}
            shelves+=title to ids
        }
        if(shelves.size>=3||batch.isEmpty()||!d.has("load_mark")||d.number("load_mark")!=0L)break
    }
    val tracks=mutableMapOf<Long,Song>()
    for(batch in shelves.flatMap {it.second}.distinct().chunked(100)) {
        val d=rpc("music.trackInfo.UniformRuleCtrl","CgiGetTrackInfo",json("ids" to batch,"types" to List(batch.size){0}),comm)
        for(song in d.requireRows("tracks").songs())tracks[song.id]=song
    }
    return shelves.map {(title,ids)->SongShelf(title,ids.mapNotNull {tracks[it]})}
}

suspend fun MusicApi.ownedEntries() = rpc("music.musicasset.PlaylistBaseRead", "GetPlaylistByUin",
    json("uin" to requireSession().id)).requireRows("v_playlist")
suspend fun MusicApi.ownedLists() = ownedEntries().map { MusicList.parse(it, owned = true) }.filter { it.id > 0 }
internal suspend fun MusicApi.lookupPlaylistEncryptUin(accountId: String): String {
    val creator = cgi("/rsc/fcgi-bin/fcg_get_profile_homepage.fcg",
        json("ct" to 20, "cv" to 4747474, "cid" to 205360838, "userid" to accountId)).obj("data").obj("creator")
    val returnedId = creator.number("uin")
    // The homepage can mask the numeric ID as zero even when it returns the requested account's encrypted ID.
    if (returnedId != 0L && returnedId.toString() != accountId) throw MusicError("QQ 音乐返回的歌单账号不匹配，请重试")
    return creator.text("encrypt_uin", "encryptUin").trim().takeIf { it.isNotEmpty() && it != "0" }
        ?: throw MusicError("QQ 音乐暂未返回收藏歌单所需的账号标识，请重试")
}
suspend fun MusicApi.savedLists(offset: Int = 0): Page<MusicList> {
    val s = requireSession()
    if (s.encryptUin.isEmpty()) throw MusicError("QQ 音乐暂未返回收藏歌单所需的账号标识，请重试")
    val d = rpc("music.musicasset.PlaylistFavRead", "CgiGetPlaylistFavInfo", json("uin" to s.encryptUin, "offset" to offset, "size" to 100))
    val rows = d.requireRows("v_list")
    return MusicApi.checkedPage(rows.map { MusicList.parse(it, saved = true) }.filter { it.id > 0 }, offset + rows.size, d.flag("hasmore"), offset)
}
suspend fun MusicApi.ordinaryPlaylist(id: Long): Json {
    val s = requireSession()
    val entry = ownedEntries().singleOrNull { it.number("tid") == id } ?: throw MusicError("只能编辑自己创建的普通歌单")
    if (entry.number("dirId") !in 1..199 || entry.number("dirType") != 0L || entry.has("uin") && entry.opt("uin").toString() != s.id)
        throw MusicError("只能编辑自己创建的普通歌单")
    return entry
}
suspend fun MusicApi.writeResult(module: String, method: String, param: Json): Json {
    requireSession()
    val d = rpc(module, method, param)
    if (d.opt("retCode").toString() != "0" || d.optJSONObject("result") == null)
        throw MusicError("QQ 音乐未确认更改，请刷新检查，避免重复提交")
    return d.obj("result")
}
fun validatePlaylistName(name: String) {
    if (name.trim().isEmpty() || name.codePointCount(0, name.length) > 20 || Regex("[\\x00-\\x1F\\x7F]").containsMatchIn(name))
        throw MusicError("歌单名称应为 1–20 个字符且不含控制字符")
}
suspend fun MusicApi.createPlaylist(name: String): MusicList {
    validatePlaylistName(name)
    val result = writeResult("music.musicasset.PlaylistBaseWrite", "AddPlaylist", json("dirName" to name))
    val id = result.number("tid"); val dir = result.number("dirId")
    if (id <= 0 || dir !in 1..199) throw MusicError("QQ 音乐未返回新歌单标识")
    val entry = ordinaryPlaylist(id)
    if (entry.number("dirId") != dir) throw MusicError("新歌单标识不一致，请刷新检查")
    return MusicList.parse(entry, owned = true)
}
suspend fun MusicApi.renamePlaylist(id: Long, name: String) {
    validatePlaylistName(name)
    val dir = ordinaryPlaylist(id).number("dirId")
    suspend fun settings(): Json {
        val info = rpc("music.srfDissInfo.aiDissInfo", "uniform_get_Dissinfo", json("dirid" to dir, "optype" to 3,
            "tag" to 1, "userinfo" to 0, "pic_dpi" to 300)).obj("dirinfo")
        if (info.number("dirid") != dir || listOf("title", "desc", "picurl", "picurl2").any { info.opt(it) !is String } ||
            info.optJSONArray("tag") == null || info.getJSONArray("tag").length() > 3)
            throw MusicError("歌单设置不完整，无法安全保留后更名")
        return info
    }
    val before = settings(); val show = before.number("dir_show")
    if (show !in 1..2 || before.text("picurl2").isNotEmpty()) throw MusicError("此歌单暂不支持保留原设置后更名")
    val tags = before.rows("tag").map { it.number("id") }
    if (tags.any { it <= 0 } || tags.size != before.getJSONArray("tag").length()) throw MusicError("歌单标签无效")
    val result = writeResult("music.musicasset.PlaylistBaseWrite", "EditPlaylist", json("dirId" to dir, "mask" to 95,
        "dirNewName" to name, "dirNewDesc" to before.get("desc"), "dirNewPicUrl" to before.get("picurl"),
        "dirNewPicUrl2" to "", "dirNewtaglist" to tags.joinToString(","), "dirShow" to show))
    if (result.number("tid") != id || result.number("dirId") != dir) throw MusicError("QQ 音乐未确认歌单更名")
    val after = settings()
    if (after.text("title") != name || after.text("desc") != before.text("desc") || after.text("picurl") != before.text("picurl") ||
        after.number("dir_show") != show || after.rows("tag").map { it.number("id") } != tags)
        throw MusicError("更名后设置未被确认，请刷新检查")
}
suspend fun MusicApi.editPlaylistSongs(id: Long, songIds: List<Long>, add: Boolean = true) {
    if (songIds.isEmpty() || songIds.size > 100 || songIds.any { it <= 0 }) throw MusicError("一次请选择 1–100 首有效歌曲")
    val dir = ordinaryPlaylist(id).number("dirId")
    val result = writeResult("music.musicasset.PlaylistDetailWrite", if (add) "AddSonglist" else "DelSonglist",
        json("dirId" to dir, "v_songInfo" to songIds.map { json("songId" to it, "songType" to 0) }))
    if (result.number("tid") != id || result.number("dirId") != dir) throw MusicError("QQ 音乐未确认歌曲更改，请刷新检查")
}
suspend fun MusicApi.deletePlaylist(id: Long) {
    val dir = ordinaryPlaylist(id).number("dirId")
    val result = writeResult("music.musicasset.PlaylistBaseWrite", "DelPlaylist", json("dirId" to dir))
    if (result.number("tid") != id || result.number("dirId") != dir || result.number("updateTime") != 0L)
        throw MusicError("QQ 音乐未确认删除歌单")
    if (ownedEntries().any { it.number("tid") == id || it.number("dirId") == dir }) throw MusicError("删除后仍返回此歌单，请刷新检查")
}
suspend fun MusicApi.songLiked(song: Song): Boolean {
    requireSession()
    return rpc("music.musicasset.SongFavRead", "IsSongFanByMid", json("v_songMid" to listOf(song.mid))).obj("m_fan").opt(song.mid) as? Boolean
        ?: throw MusicError("QQ 音乐未返回喜欢状态")
}
suspend fun MusicApi.likeSong(input: Song, liked: Boolean) {
    requireSession()
    val song = songDetail(input)
    if (songLiked(song) == liked) return
    writeResult("music.musicasset.PlaylistDetailWrite", if (liked) "AddSonglist" else "DelSonglist",
        json("dirId" to 201, "v_songInfo" to listOf(json("songId" to song.id, "songType" to 0))))
    if (songLiked(song) != liked) throw MusicError("QQ 音乐未确认喜欢状态的更改")
}
suspend fun MusicApi.albumLiked(album: Album): Boolean {
    val s = requireSession()
    if (!Regex("^[A-Za-z0-9]{1,64}$").matches(album.mid)) throw MusicError("专辑标识无效")
    return rpc("music.musicasset.AlbumFavRead", "IsAlbumFan", json("uin" to (s.id.toLongOrNull()?.takeIf { it <= 9007199254740991L } ?: s.id),
        "v_albumMid" to listOf(album.mid))).obj("m_fan").opt(album.mid) as? Boolean ?: throw MusicError("QQ 音乐未返回专辑收藏状态")
}
suspend fun MusicApi.likeAlbum(album: Album, liked: Boolean) {
    val s = requireSession()
    if (albumLiked(album) == liked) return
    val d = rpc("music.musicasset.AlbumFavWrite", if (liked) "FavAlbum" else "CancelFavAlbum",
        json("uin" to s.id, "v_albumMid" to listOf(album.mid)))
    if (d.opt("result").toString() != "0" || listOf("v_failedAlbumId", "v_failedAlbumMid").any { d.optJSONArray(it)?.length() != 0 })
        throw MusicError("QQ 音乐未确认专辑收藏更改")
    if (albumLiked(album) != liked) throw MusicError("QQ 音乐未确认专辑收藏状态")
}
suspend fun MusicApi.unfavoritePlaylist(id: Long) {
    val d = rpc("music.musicasset.PlaylistFavWrite", "CancelFavPlaylist", json("uin" to requireSession().id, "v_playlistId" to listOf(id)))
    if (d.opt("result").toString() != "0" || d.optJSONArray("v_failedPlaylistId")?.length() != 0) throw MusicError("QQ 音乐未确认取消收藏歌单")
}
suspend fun MusicApi.likedAlbums(offset: Int = 0): Page<Album> {
    val d = cgi("/fav/fcgi-bin/fcg_get_profile_order_asset.fcg", json("ct" to 20, "cid" to 205360956, "userid" to requireSession().id,
        "reqtype" to 2, "sin" to offset, "ein" to offset + 29)).obj("data")
    if (!d.has("totalalbum") || d.opt("albumlist") !is JSONArray && d.number("totalalbum") > 0) throw MusicError("QQ 音乐未返回收藏专辑列表")
    val entries = d.rows("albumlist")
    return MusicApi.checkedPage(entries.map(Album::parse), offset + entries.size, offset + entries.size < d.number("totalalbum"), offset)
}
suspend fun MusicApi.purchasedPage(albums: Boolean, offset: Int = 0): Page<Json> {
    val s = requireSession(); val token = hash33(s.key)
    val d = cgi("/shop/fcgi-bin/fcg_get_order", json("from" to 1, "cmd" to "sales_album", "type" to if (albums) 1 else 2,
        "uin" to s.id, "start" to offset, "num" to 30, "platform" to "yqq", "ct" to 24, "cv" to 4747474,
        "inCharset" to "utf-8", "notice" to 0, "needNewCode" to 1, "g_tk" to token, "g_tk_new_20200303" to token)).obj("data")
    MusicApi.checkStatus(d)
    val key = if (albums) "albumlist" else "songlist"; val total = d.opt("total")?.toString()?.toIntOrNull()
    if (total == null || total < 0 || d.opt(key) !is JSONArray && total > 0) throw MusicError("QQ 音乐未返回有效已购列表")
    val entries = d.rows(key)
    return MusicApi.checkedPage(entries, offset + entries.size, offset + entries.size < total, offset)
}
data class CommentPage(val items: List<Json>, val total: Int, val cursor: Json?)
suspend fun MusicApi.comments(song: Song, cursor: Json? = null, hot: Boolean = false): CommentPage {
    val page = cursor ?: Json()
    val param = json("BizType" to 1, "BizId" to song.id.toString(), "PageSize" to 25, "PageNum" to page.number("page"),
        "LastCommentSeqNo" to page.text("sequence"), "PicEnable" to 1)
    if (hot) param.put("HotType", 1).put("WithAirborne", 0)
    else param.put("FromCommentId", "").put("WithHot", 0).put("LastTotal", page.number("total")).put("LastTotalVer", page.opt("version") ?: "0")
    val d = rpc("music.globalComment.CommentRead", if (hot) "GetHotCommentList" else "GetNewCommentList", param, webComm, mapOf("Cookie" to ""))
    val list = d.obj("CommentList"); val entries = list.requireRows("Comments"); val sequence = entries.lastOrNull()?.text("SeqNo").orEmpty()
    val more = sequence.isNotEmpty() && list.flag("HasMore")
    if (more && sequence == page.text("sequence")) throw MusicError("评论分页未前进，请刷新重试")
    return CommentPage(entries, list.number("Total").toInt(), if (more) json("sequence" to sequence, "page" to page.number("page") + 1,
        "total" to list.number("Total"), "version" to (d.opt("TotalVer") ?: "0")) else null)
}
