package com.green.music.player

import com.green.music.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

class DownloadHttpError(val status: Int) : IOException("下载请求失败（HTTP $status）")
class PrivateQuotaError : IOException("私有存储空间不足，请删除歌曲或提高空间上限")
private class RangeFallback : Exception()
class DownloadLimiter(private val bytesPerSecond: Long) {
    private var next = 0L
    private val mutex = Mutex()
    suspend fun take(bytes: Int) {
        if (bytesPerSecond <= 0) return
        val due = mutex.withLock {
            val now = System.nanoTime()
            next = maxOf(now, next) + bytes * 1_000_000_000L / bytesPerSecond
            next
        }
        val wait = (due - System.nanoTime()) / 1_000_000
        if (wait > 0) delay(wait)
        currentCoroutineContext().ensureActive()
    }
}
class DownloadTransfer(private val http: OkHttpClient, private val limiter: DownloadLimiter) {
    private val calls=java.util.concurrent.ConcurrentHashMap<Response,okhttp3.Call>()
    private suspend fun get(url: String, headers: Map<String, String> = emptyMap()): Response {
        val request = Request.Builder().url(url).header("Cookie", "").header("User-Agent", QQ_AGENT)
            .header("Accept-Encoding", "identity").apply { headers.forEach { (k, v) -> header(k, v) } }.build()
        val call=http.newCall(request);val response=call.await()
        if (response.code >= 400 && response.code !in listOf(412, 416)) { response.close(); throw DownloadHttpError(response.code) }
        calls[response]=call
        return response
    }
    private suspend fun consume(r: Response, file: File, expected: Long, progress: suspend (Long) -> Unit) {
        val type = r.header("Content-Type").orEmpty().lowercase(); val encoding = r.header("Content-Encoding")
        if (type.contains("text/") || type.contains("json") || encoding != null && encoding != "identity") throw MusicError("音源未返回完整音频，未保存下载")
        val body = r.body ?: throw MusicError("音源未返回音频")
        val input = body.byteStream()
        var count = 0L
        // Interrupt the socket; only the reader may close Okio's buffered response.
        coroutineScope {
            val reader = currentCoroutineContext()[Job]!!
            val watcher = launch(Dispatchers.Unconfined,start=CoroutineStart.UNDISPATCHED) { try { awaitCancellation() } finally { if (!reader.isActive) calls[r]?.cancel() } }
            try {
                file.outputStream().use { output ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        if (expected >= 0 && count + n > expected) throw MusicError("音源长度不符，请重试")
                        limiter.take(n); output.write(buffer, 0, n); count += n; progress(count)
                    }
                    output.fd.sync()
                }
                if (count == 0L || expected >= 0 && count != expected) throw IOException("歌曲未完整下载，请重试")
            } catch(e:Exception){currentCoroutineContext().ensureActive();throw e} finally {watcher.cancel();calls.remove(r)}
        }
    }
    suspend fun download(url: String, target: File, connections: Int,
        progress: suspend (Long, Long, Double) -> Unit, stage: (String) -> Unit) = withContext(Dispatchers.IO) {
        val start = System.nanoTime()
        suspend fun report(received: Long, total: Long) = progress(received, total, received * 1e9 / (System.nanoTime() - start).coerceAtLeast(1))
        suspend fun single(supplied: Response? = null) {
            stage("单连接下载")
            (supplied ?: get(url)).use { r ->
                if (r.code != 200) throw DownloadHttpError(r.code)
                val expected = r.body?.contentLength() ?: -1
                consume(r, target, expected) { report(it, expected) }
            }
        }
        if (connections == 1) { single(); return@withContext }
        val probe = get(url, mapOf("Range" to "bytes=0-0"))
        if (probe.code == 200) { single(probe); return@withContext }
        val total: Long; val etag: String
        probe.use {
            val match = Regex("^bytes 0-0/(\\d+)$").matchEntire(it.header("Content-Range").orEmpty())
            total = match?.groupValues?.get(1)?.toLongOrNull() ?: 0
            etag = it.header("ETag").orEmpty()
            if (it.code != 206 || total < connections * 1024L * 1024 || total > 64L * 1024 * 1024 * 1024 ||
                !etag.startsWith('"') || !etag.endsWith('"') || etag.startsWith("W/")) {
                it.close(); single(); return@withContext
            }
        }
        val parts = (0 until connections).map { File("${target.path}.segment$it") }
        try {
            stage("${connections}连接下载")
            val counts = LongArray(connections); val reports = Mutex()
            coroutineScope {
                (0 until connections).map { index -> async {
                    val from = total * index / connections; val to = total * (index + 1) / connections - 1
                    get(url, mapOf("Range" to "bytes=$from-$to", "If-Match" to etag)).use { r ->
                        if (r.code != 206 || r.header("Content-Range") != "bytes $from-$to/$total" || r.header("ETag") != etag) throw RangeFallback()
                        consume(r, parts[index], to - from + 1) { count -> reports.withLock { counts[index] = count; report(counts.sum(), total) } }
                    }
                } }.awaitAll()
            }
            stage("合并下载分段")
            target.outputStream().use { out ->
                val buffer = ByteArray(262144)
                for (part in parts) part.inputStream().use { input ->
                    while (true) { currentCoroutineContext().ensureActive(); val n = input.read(buffer); if (n < 0) break; out.write(buffer, 0, n) }
                }
                out.fd.sync()
            }
            if (target.length() != total) throw IOException("分段合并长度不符")
        } catch (_: RangeFallback) { single() }
        finally { parts.forEach { it.delete() } }
    }
}
