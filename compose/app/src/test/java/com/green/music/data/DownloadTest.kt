package com.green.music.data

import com.green.music.player.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger

class DownloadTest {
    @Test fun cancellingAfterHeadersClosesSlowBody()=runBlocking {
        val server=MockWebServer();server.enqueue(MockResponse().setBody("slow body").setBodyDelay(2,java.util.concurrent.TimeUnit.SECONDS));server.start()
        val call=OkHttpClient().newCall(okhttp3.Request.Builder().url(server.url("/")).build());val entered=CompletableDeferred<Unit>()
        val job=launch(Dispatchers.IO){call.consume{response->entered.complete(Unit);response.body!!.string()}}
        try{withTimeout(3000){entered.await()};withTimeout(1500){job.cancelAndJoin()};assertTrue(call.isCanceled())}finally{call.cancel();job.cancelAndJoin();server.shutdown()}
    }

    @Test fun cancellingDownloadBodyDoesNotWaitForReadTimeout()=runBlocking {
        val server=MockWebServer();server.enqueue(MockResponse().setBody(okio.Buffer().write(ByteArray(131072))).throttleBody(65536,2,java.util.concurrent.TimeUnit.SECONDS));server.start()
        val dir=Files.createTempDirectory("greenmusic-cancel").toFile();val target=File(dir,"song.part");val first=CompletableDeferred<Unit>()
        val job=launch(Dispatchers.IO){DownloadTransfer(OkHttpClient(),DownloadLimiter(0)).download(server.url("/").toString(),target,1,{bytes,_,_->if(bytes>0)first.complete(Unit)},{})}
        try{withTimeout(3000){first.await()};withTimeout(1500){job.cancelAndJoin()};assertTrue(job.isCancelled)}finally{job.cancelAndJoin();server.shutdown();target.delete();dir.delete()}
    }
    @Test fun rangeDownloadsMergeBytesAndFallbackOnVersionChange() = runBlocking {
        val payload = ByteArray(5 * 1024 * 1024) { (it % 251).toByte() }
        val directory = Files.createTempDirectory("greenmusic-ranges").toFile()
        val server = MockWebServer(); val pieces = AtomicInteger(); var corrupt = false
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val range = request.getHeader("Range")
                if (range == null) return MockResponse().setBody(Buffer().write(payload))
                val match = Regex("bytes=(\\d+)-(\\d+)").matchEntire(range)!!
                val from = match.groupValues[1].toInt(); val to = match.groupValues[2].toInt()
                if (to > 0) pieces.incrementAndGet()
                return MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes $from-$to/${payload.size}")
                    .setHeader("ETag", if (corrupt && from > 0) "\"changed\"" else "\"version1\"")
                    .setBody(Buffer().write(payload, from, to - from + 1))
            }
        }
        server.start()
        try {
            val target = File(directory, "song.part")
            val transfer = DownloadTransfer(OkHttpClient(), DownloadLimiter(0))
            transfer.download(server.url("/song").toString(), target, 4, { _, _, _ -> }, {})
            assertEquals(4, pieces.get()); assertArrayEquals(payload, target.readBytes())
            corrupt = true
            transfer.download(server.url("/song").toString(), target, 4, { _, _, _ -> }, {})
            assertArrayEquals(payload, target.readBytes())
            assertEquals(listOf("song.part"), directory.listFiles()!!.map { it.name })
        } finally { server.shutdown(); directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }
    @Test fun rejectedHttpBodyAndUnexpectedPartialAreNotPublished() = runBlocking {
        val directory = Files.createTempDirectory("greenmusic-reject").toFile(); val server = MockWebServer(); server.start()
        try {
            val transfer = DownloadTransfer(OkHttpClient(), DownloadLimiter(0)); val target = File(directory, "song.part")
            server.enqueue(MockResponse().setResponseCode(503).setBody("busy"))
            try { transfer.download(server.url("/").toString(), target, 1, { _,_,_ -> }, {}); fail("503") } catch (e: DownloadHttpError) { assertEquals(503, e.status) }
            server.enqueue(MockResponse().setResponseCode(206).setBody("part"))
            try { transfer.download(server.url("/").toString(), target, 1, { _,_,_ -> }, {}); fail("partial") } catch (e: DownloadHttpError) { assertEquals(206, e.status) }
            server.enqueue(MockResponse().setHeader("Content-Type", "text/html").setBody("not audio"))
            try { transfer.download(server.url("/").toString(), target, 1, { _,_,_ -> }, {}); fail("html") } catch (_: MusicError) { }
            assertFalse(target.exists())
        } finally { server.shutdown(); directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }
    @Test fun limiterSharesClockAndCancellationInterruptsWait() = runBlocking {
        val limiter = DownloadLimiter(64 * 1024)
        val start = System.nanoTime()
        coroutineScope { List(4) { async { limiter.take(16 * 1024) } }.awaitAll() }
        assertTrue((System.nanoTime() - start) / 1_000_000 >= 900)
        val job = launch { DownloadLimiter(1).take(65536) }
        delay(30); withTimeout(1000) { job.cancelAndJoin() }
    }
    @Test fun tagsKeepMp3AndFlacAudioPayload() = runBlocking {
        val dir = Files.createTempDirectory("greenmusic-tags").toFile()
        val payload = byteArrayOf(255.toByte(), 251.toByte(), 144.toByte(), 0) + ByteArray(2048) { (it % 251).toByte() }
        val tags = AudioTags("中文🎵", "歌手", "专辑", "2026", "[00:01.000]歌词")
        try {
            val mp3 = File(dir, "song.mp3.part"); mp3.writeBytes(payload)
            val tagged = writeAudioTags(mp3, "mp3", tags).readBytes()
            assertEquals("ID3", String(tagged.copyOfRange(0,3)))
            val size = tagged.copyOfRange(6,10).fold(0) { n, b -> (n shl 7) or b.toInt() }
            assertArrayEquals(payload, tagged.copyOfRange(size + 10, tagged.size))
            val flac = File(dir, "song.flac.part"); flac.writeBytes("fLaC".toByteArray() + byteArrayOf(128.toByte(),0,0,34) + ByteArray(34) + payload)
            val result = writeAudioTags(flac, "flac", tags).readBytes(); var at = 4
            while (true) {
                val last = result[at].toInt() and 128 != 0
                val length = ((result[at+1].toInt() and 255) shl 16) or ((result[at+2].toInt() and 255) shl 8) or (result[at+3].toInt() and 255)
                at += 4 + length
                if (last) break
            }
            assertArrayEquals(payload, result.copyOfRange(at,result.size))
            assertTrue(String(result, Charsets.UTF_8).contains("TITLE=中文🎵"))
        } finally { dir.listFiles()?.forEach { it.delete() }; dir.delete() }
    }
    @Test fun backupBoundariesAndWebdavOrigin() {
        val backup = json("app" to "greenmusic", "schema" to 1, "backup_mode" to "safe", "preferences" to json("lyricFontWeight" to 600, "downloadConnections" to 4))
        assertEquals(600, BackupFormat.validate(backup)["lyricFontWeight"])
        backup.obj("preferences").put("lyricFontWeight", 650)
        assertThrows(MusicError::class.java) { BackupFormat.validate(backup) }
        backup.obj("preferences").put("lyricFontWeight", 600).put("downloadTree", "content://directory")
        assertThrows(MusicError::class.java) { BackupFormat.validate(backup) }
        for (bad in listOf("http://example.com", "https://user:password@example.com", "https://example.com?x=y", "https://example.com#x"))
            assertThrows(MusicError::class.java) { WebDavService.baseUrl(bad) }
        assertThrows(MusicError::class.java) { WebDavService.directoryUrl("https://example.com", "../other") }
        assertEquals("https://example.com/dav/GreenMusic/", WebDavService.directoryUrl("https://example.com/dav", "GreenMusic").toString())
    }
}
