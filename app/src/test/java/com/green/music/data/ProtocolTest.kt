package com.green.music.data

import com.green.music.ui.coverImageUrl
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ProtocolTest {
    @Test fun sessionAndCookieBoundaries() {
        val session = musicSessionFromWebCookies("uin=o00123; qm_keyst=fixture%2Bvalue; login_type=1")
        assertEquals("123", session.id); assertEquals("fixture+value", session.key); assertEquals(2, session.loginType)
        for (bad in listOf("uin=1; qm_keyst=x; login_type=0", "uin=1; qm_keyst=x; qm_keyst=y", "uin=1; qm_keyst=x%0aInjected", "uin=1; qm_keyst=%XX")) {
            assertThrows(MusicError::class.java) { musicSessionFromWebCookies(bad) }
        }
        assertEquals("https://graph.qq.com/oauth2.0/login_jump", trustedLoginUrl("https://graph.qq.com/oauth2.0/login_jump#", "graph.qq.com", "/oauth2.0/login_jump", "test"))
        for (bad in listOf("http://graph.qq.com/oauth2.0/login_jump", "https://graph.qq.com.evil.test/oauth2.0/login_jump", "https://user@graph.qq.com/oauth2.0/login_jump", "https://graph.qq.com:444/oauth2.0/login_jump", "https://graph.qq.com/oauth2.0/login_jump#secret"))
            assertThrows(MusicError::class.java) { trustedLoginUrl(bad, "graph.qq.com", "/oauth2.0/login_jump", "test") }
    }
    @Test fun callbackAndJavascriptAreParsedAsData() {
        assertEquals("https://y.qq.com/?token=a%2Bb", qqWebCallbackUrl("com.green.music.login://qq/https://y.qq.com/?token=a%2Bb"))
        assertNull(qqWebCallbackUrl("com.green.music.login://qq/https://evil.test/"))
        assertNull(qqWebCallbackUrl("com.green.music.login://qq/https%253A%252F%252Fy.qq.com"))
        assertNull(qqWebCallbackUrl("com.green.music.login://qq/https://y.qq.com/?x=%0a"))
        assertEquals(listOf("0", "0", "url", "0", "昵称", "x"), parsePtui("ptuiCB('0','0','url','0','昵称','x');"))
        assertThrows(MusicError::class.java) { parsePtui("ptuiCB('0','0','url','0','x','x');evil()") }
        assertThrows(MusicError::class.java) { parsePtui("ptuiCB('0','0','url','0','x',alert(1))") }
        assertTrue(validStreamUrl("http://aqqmusic.tc.qq.com/track.mp3"))
        assertFalse(validStreamUrl("https://qq.com.evil.test/track.mp3"))
        assertFalse(validStreamUrl("https://user@aqqmusic.tc.qq.com/track.mp3"))
    }
    @Test fun enhancedLyricsPreserveTimesAndUnicode() {
        val lines = parseLyrics("[offset:100]\n[00:01.00]<00:01.00>你<00:01.50>好<00:02.00>\n[00:03]普通歌词", "[00:01.10]hello")
        assertEquals(1100L, lines.first().timeMs); assertEquals("你好", lines.first().text)
        assertEquals("hello", lines.first().translation); assertEquals(2100L, lines.first().words.last().endMs)
        assertTrue(parseLyrics("[00:01]<00:02>错<00:01>序").single().words.isEmpty())
        assertEquals(listOf("á", "👩‍👩‍👧‍👦", "🇨🇳", "👍🏽"), graphemes("á👩‍👩‍👧‍👦🇨🇳👍🏽"))
        assertTrue(karaokeWords(lines, 1, 10000, KaraokeMode.Timed).isEmpty())
        assertFalse(karaokeWords(lines, 1, 10000, KaraokeMode.Song).isEmpty())
        val plain = listOf(LyricLine(9000, "测试"))
        assertTrue(karaokeWords(plain, 0, 10000, KaraokeMode.Song).isEmpty())
        assertTrue(karaokeWords(plain, 0, 10000, KaraokeMode.All).last().endMs!! <= 10000)
        assertFalse(encodeLrc(lines).contains('<'))
    }
    @Test fun modelFallbacksAndMalformedStatuses() {
        val song = Song.parse(json("musicData" to json("songid" to 1, "songmid" to "mid", "songname" to "歌", "albummid" to "album",
            "albumname" to "专辑", "singer" to listOf(json("name" to "艺术家")), "time_public" to "2026-10-01")))
        assertTrue(song.valid); assertEquals("album", song.album.mid); assertEquals("2026", song.releaseYear)
        assertEquals("艺术家", song.artistNames)
        assertThrows(MusicError::class.java) { MusicApi.checkStatus(json("code" to "oops")) }
        assertThrows(MusicError::class.java) { MusicApi.checkedPage(emptyList<Song>(), 100, true, 100) }
    }
    @Test fun playlistCdnCoversUseHttpsWithoutLosingImageParameters() {
        val owned = MusicList.parse(json("tid" to 1, "bigpicUrl" to "http://qpic.y.qq.com/music_cover/abc/300?n=1"), owned = true)
        assertEquals("https://qpic.y.qq.com/music_cover/abc/300?n=1", coverImageUrl(owned.cover))
        assertEquals("https://y.gtimg.cn/mediastyle/y/img/cover_love_300.jpg",
            coverImageUrl("http://y.gtimg.cn/mediastyle/y/img/cover_love_300.jpg"))
        assertEquals("https://music-file.y.qq.com/cover.jpg?imageView2/4/w/300/h/300",
            coverImageUrl("//music-file.y.qq.com/cover.jpg?imageView2/4/w/300/h/300"))
        assertEquals("http://qpic.y.qq.com.example.test/a.jpg", coverImageUrl("http://qpic.y.qq.com.example.test/a.jpg"))
    }
    @Test fun encryptedPlaylistIdentityUsesTheRequestedProfileAndKeepsPagination() = runBlocking {
        var creator = json("uin" to 0, "encrypt_uin" to "fixture-encrypted")
        val api = object : MusicApi() {
            override suspend fun cgi(path: String, query: Json, anonymous: Boolean): Json {
                assertEquals("/rsc/fcgi-bin/fcg_get_profile_homepage.fcg", path)
                assertEquals("123", query.text("userid"))
                assertFalse(anonymous)
                return json("data" to json("creator" to creator))
            }
            override suspend fun rpc(module: String, method: String, param: Json, comm: Json?, headers: Map<String, String>): Json {
                assertEquals("CgiGetPlaylistFavInfo", method)
                assertEquals("fixture-encrypted", param.text("uin"))
                assertEquals(100L, param.number("offset"))
                return json("v_list" to listOf(json("tid" to 42, "dirName" to "收藏")), "hasmore" to 1)
            }
        }
        val raw = json("musicid" to "123", "musickey" to "fixture", "loginType" to 2)
        api.session = MusicSession(raw)
        val encrypted = api.lookupPlaylistEncryptUin(api.requireSession().id)
        api.session = MusicSession(raw.put("encryptUin", encrypted))
        val page = api.savedLists(100)
        assertEquals(42L, page.items.single().id)
        assertEquals(101, page.nextOffset)
        assertTrue(page.more)
        for (bad in listOf(json("uin" to 456, "encrypt_uin" to "other"), json("uin" to 0))) {
            creator = bad
            try { api.lookupPlaylistEncryptUin("123"); fail("Invalid profile must not provide a playlist identity") }
            catch (_: MusicError) { }
        }
    }
    @Test fun playlistWriteRequiresOwnershipAndAcknowledgement() = runBlocking {
        val calls = mutableListOf<String>()
        val api = object : MusicApi() {
            override suspend fun rpc(module: String, method: String, param: Json, comm: Json?, headers: Map<String, String>): Json {
                calls += method
                return if (method == "GetPlaylistByUin") json("v_playlist" to listOf(json("tid" to 9, "dirId" to 201, "dirType" to 0, "uin" to "1")))
                else json("retCode" to 0, "result" to json())
            }
        }
        api.session = MusicSession(json("musicid" to "1", "musickey" to "fixture", "loginType" to 2))
        try { api.deletePlaylist(9); fail("favorite system playlist must not be deleted") } catch (_: MusicError) { }
        assertEquals(listOf("GetPlaylistByUin"), calls)
    }
    @Test fun truncatedAnonymousPlaylistIsNotComplete() = runBlocking {
        val api = object : MusicApi() {
            override suspend fun cgi(path: String, query: Json, anonymous: Boolean) = json("cdlist" to listOf(json("songnum" to 200,
                "songlist" to listOf(json("id" to 1, "mid" to "one", "name" to "song")))))
        }
        try { api.playlistPage(MusicList(3, "playlist")); fail("truncated response must fail") } catch (_: MusicError) { }
    }
}
