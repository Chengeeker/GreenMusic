package com.green.music.player

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import com.green.music.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

data class DownloadOptions(val quality: String, val lyrics: Boolean, val tags: Boolean, val tree: String?,
    val concurrent: Int, val connections: Int, val speedKiB: Int, val retries: Int, val limitMb: Int) {
    companion object {
        fun read(p: AppSettings) = DownloadOptions(p.string("downloadQuality", p.string("quality", "standard")), p.bool("downloadLyrics"), p.bool("downloadTags"),
            p.string("downloadTree").takeIf(String::isNotEmpty), p.int("downloadConcurrent", 3).coerceIn(1,5),
            p.int("downloadConnections", 1).takeIf { it in listOf(1,2,4) } ?: 1, p.int("downloadSpeedKiB").coerceIn(0,10240),
            p.int("downloadRetries", 2).coerceIn(0,3), p.int("cacheLimitMb", 256).coerceIn(128,16384))
    }
}
data class DownloadedSong(val song: Song, val file: File, val quality: String, val format: String, val bytes: Long,
    val date: Long, val documentUri: String? = null) { val uri get() = documentUri ?: Uri.fromFile(file).toString() }
enum class DownloadStatus { Waiting, Running, Done, Skipped, Failed, Cancelled }
data class DownloadTask(val song: Song, val status: DownloadStatus = DownloadStatus.Waiting, val received: Long = 0,
    val total: Long = 0, val speed: Double = 0.0, val stage: String = "等待下载", val error: String? = null, val attempt: Int = 0)

class Downloads(private val context: Context, private val api: MusicApi, private val settings: AppSettings, private val scope: CoroutineScope) {
    private val directory = File(context.filesDir, "music_downloads")
    private val legacy = File(context.cacheDir, "music_cache")
    private val directories get() = listOf(directory, legacy)
    private val namePattern = Regex("^[a-f0-9]{16}-([1-9]\\d*)-(standard|exhigh|lossless)\\.(mp3|flac)$")
    private val mutable = MutableStateFlow<List<DownloadTask>>(emptyList())
    val tasks = mutable.asStateFlow()
    private val mutableCancelling=MutableStateFlow(false)
    val cancelling=mutableCancelling.asStateFlow()
    private val mutableStopReason=MutableStateFlow<String?>(null)
    val stopReason=mutableStopReason.asStateFlow()
    val revision = MutableStateFlow(0)
    private var batch: Job? = null
    private var batchOwner: String? = null
    private var batchOptions: DownloadOptions? = null
    val owner get() = batchOwner
    var title = "下载任务"; private set
    @Volatile private var quotaFailed = false
    private val mutation = Mutex()
    private val quota = Mutex()
    private val saf = Mutex()
    private var privateBase = 0L
    private var committed = 0L
    private val reserved = mutableMapOf<String, Long>()
    private val workers = mutableMapOf<Long, Job>()
    val active get() = batch?.isActive == true
    private fun accountScope(owner: String) = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray()).joinToString("") { "%02x".format(it) }.take(16)
    private fun name(owner: String, song: Song, quality: String, format: String) = "${accountScope(owner)}-${song.id}-$quality.$format"
    private fun update(id: Long, transform: (DownloadTask) -> DownloadTask) { synchronized(mutable) { mutable.value = mutable.value.map { if (it.song.id == id) transform(it) else it } } }
    suspend fun initialize() = withContext(Dispatchers.IO) {
        directory.mkdirs()
        for (dir in directories) for (file in dir.listFiles().orEmpty()) {
            val base = file.name.replace(Regex("\\.part\\.segment[0-3]$|\\.part\\.tags\\.part$|\\.lrc\\.part$|\\.json\\.tmp$|\\.part$"), "")
            if (base != file.name && namePattern.matches(base) && file.isFile) file.delete()
        }
    }
    suspend fun privateSize(): Long = withContext(Dispatchers.IO) {
        directories.flatMap { it.listFiles().orEmpty().asList() }.filter { it.isFile && namePattern.matches(it.name) }.distinctBy { it.name }.sumOf { it.length() }
    }
    suspend fun totalSize():Long=withContext(Dispatchers.IO) {
        val seen=mutableSetOf<String>();var bytes=0L
        for(dir in directories)for(entry in dir.listFiles().orEmpty()){
            val file=if(entry.name.endsWith(".json"))File(entry.path.removeSuffix(".json"))else entry
            if(!namePattern.matches(file.name)||file.name in seen)continue
            val external=external(file)
            if(external!=null){bytes+=external.bytes;seen+=file.name}else if(file.isFile&&file.length()>0){bytes+=file.length();seen+=file.name}
        };bytes
    }
    private fun exists(uri: String): Boolean = try {
        context.contentResolver.query(Uri.parse(uri), arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { it.moveToFirst() } ?: false
    } catch (_: Exception) { false }
    private fun external(file: File): DownloadedSong? {
        val meta = File("${file.path}.json")
        if (!meta.isFile || meta.length() > 32768) return null
        return runCatching {
            val data = Json(meta.readText()); val download = data.obj("download"); val uri = download.text("uri")
            val match = namePattern.matchEntire(file.name) ?: return null
            if (Uri.parse(uri).scheme != "content" || download.number("bytes") <= 0 || !exists(uri)) return null
            val song = Song.parse(data)
            if (song.id.toString() != match.groupValues[1]) return null
            val date = runCatching { SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.ROOT).parse(download.text("date"))?.time }.getOrNull() ?: meta.lastModified()
            DownloadedSong(song, file, match.groupValues[2], match.groupValues[3], download.number("bytes"), date, uri)
        }.getOrNull()
    }
    suspend fun find(owner: String, song: Song, preferred: String, exact: Boolean = false): DownloadedSong? = withContext(Dispatchers.IO) {
        for (quality in (if (exact) listOf(preferred) else listOf(preferred, "lossless", "exhigh", "standard")).distinct()) {
            val format = if (quality == "lossless") "flac" else "mp3"
            for (dir in directories) {
                val file = File(dir, name(owner, song, quality, format))
                external(file)?.let { return@withContext it }
                if (file.isFile && file.length() > 0) return@withContext DownloadedSong(song, file, quality, format, file.length(), file.lastModified())
            }
        }
        null
    }
    suspend fun entries(owner: String): List<DownloadedSong> = withContext(Dispatchers.IO) {
        val prefix = accountScope(owner) + "-"; val result = linkedMapOf<String, DownloadedSong>()
        val known=listOf("queue","history").flatMap {key->runCatching {val rows=org.json.JSONArray(settings.string(key,"[]"));(0 until rows.length()).mapNotNull{rows.optJSONObject(it)}.songs()}.getOrDefault(emptyList())}.associateBy{it.id}
        for (dir in directories) for (entry in dir.listFiles().orEmpty()) {
            val file = if (entry.name.endsWith(".json")) File(entry.path.removeSuffix(".json")) else entry
            val match = namePattern.matchEntire(file.name) ?: continue
            if (!file.name.startsWith(prefix) || result.containsKey(file.name)) continue
            external(file)?.let { result[file.name] = it; continue }
            if (!file.isFile || file.length() <= 0) continue
            val meta = File("${file.path}.json")
            val song = if (meta.isFile && meta.length() <= 32768) runCatching { Song.parse(Json(meta.readText())) }.getOrNull() else null
            val fallback = known[match.groupValues[1].toLong()] ?: Song(json("id" to match.groupValues[1].toLong(), "title" to "歌曲 ${match.groupValues[1]}"))
            result[file.name] = DownloadedSong(song?.takeIf { it.id == fallback.id } ?: fallback, file, match.groupValues[2], match.groupValues[3], file.length(), file.lastModified())
        }
        result.values.sortedByDescending { it.date }
    }
    suspend fun start(songs: List<Song>, quality: String? = null, title: String = "下载任务") = mutation.withLock {
        if (active) throw MusicError("已有下载任务，请等待完成或先取消")
        val selected = songs.filter(Song::valid).distinctBy { it.id }
        if (selected.isEmpty()) throw MusicError("请选择歌曲")
        val options = DownloadOptions.read(settings).let { if (quality == null) it else it.copy(quality = quality) }
        val owner = api.session?.id ?: "anonymous"
        privateBase = privateSize(); committed = 0; reserved.clear(); workers.clear()
        mutable.value = selected.map { DownloadTask(it) }; batchOwner = owner; batchOptions = options
        this.title = title; quotaFailed = false;mutableCancelling.value=false;mutableStopReason.value=null
        batch = scope.launch(Dispatchers.IO) {
            val slots = Semaphore(options.concurrent); val limiter = DownloadLimiter(options.speedKiB * 1024L)
            try { supervisorScope {
                selected.forEach { song ->
                    val job = launch(start = CoroutineStart.LAZY) {
                        try { slots.withPermit { if(quotaFailed)throw CancellationException();download(song, owner, options, limiter) } }
                        catch (e: CancellationException) { update(song.id) { if (it.status in listOf(DownloadStatus.Done, DownloadStatus.Skipped)) it else it.copy(status = DownloadStatus.Cancelled, stage = "已取消") }; throw e }
                    }
                    synchronized(workers) { workers[song.id] = job }; job.start()
                }
            } } finally {
                mutable.value = mutable.value.map { if (it.status in listOf(DownloadStatus.Waiting, DownloadStatus.Running)) it.copy(status = DownloadStatus.Cancelled, stage = "已取消") else it }
                reserved.clear(); revision.value++
            }
        }
    }
    suspend fun retry() {
        val owner = api.session?.id ?: "anonymous"
        if (owner != batchOwner) throw MusicError("账号已改变，请重新选择下载歌曲")
        start(tasks.value.filter { it.status in listOf(DownloadStatus.Failed, DownloadStatus.Cancelled) }.map { it.song }, batchOptions?.quality, title)
    }
    suspend fun cancelAll() = mutation.withLock {
        mutableCancelling.value=batch?.isActive==true
        try{batch?.cancelAndJoin();batch=null}finally{mutableCancelling.value=false}
    }
    fun cancel(id: Long) { synchronized(workers) { workers[id]?.cancel() } }
    private suspend fun download(song: Song, owner: String, options: DownloadOptions, limiter: DownloadLimiter) {
        for (attempt in 0..options.retries) {
            try {
                currentCoroutineContext().ensureActive()
                if (owner != (api.session?.id ?: "anonymous")) throw CancellationException()
                update(song.id) { it.copy(status = DownloadStatus.Running, attempt=attempt, stage = if (attempt == 0) "准备下载" else "重试下载（$attempt）", error = null) }
                if (find(owner, song, options.quality, exact = true) != null) {
                    update(song.id) { it.copy(status = DownloadStatus.Skipped, stage = "已下载，跳过") }; return
                }
                val stream = api.stream(song, options.quality)
                if (owner != (api.session?.id ?: "anonymous")) throw CancellationException()
                if (find(owner, song, stream.quality, exact = true) != null) {
                    update(song.id) { it.copy(status = DownloadStatus.Skipped, stage = "已下载，跳过") }; return
                }
                val detailed = if (options.tags) api.songDetail(song) else song
                val lyrics = if (options.lyrics || options.tags) encodeLrc(api.lyrics(song)) else ""
                val tags = if (options.tags) downloadMetadata(api, detailed, lyrics) else null
                save(owner, detailed, stream, options, limiter, if (options.lyrics) lyrics else "", tags)
                update(song.id) { it.copy(status = DownloadStatus.Done, stage = "下载完成") }; revision.value++; return
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                val retryable = e is DownloadHttpError && (e.status in listOf(408,429) || e.status >= 500) || e is java.net.SocketException || e is java.net.SocketTimeoutException || e is java.net.UnknownHostException
                if (retryable && attempt < options.retries) { update(song.id) { it.copy(stage = "等待重试") }; delay(1000L shl attempt); continue }
                update(song.id) { it.copy(status = DownloadStatus.Failed, stage = "下载失败", error = e.message ?: "下载未完成") }
                if (e is PrivateQuotaError) { quotaFailed=true;mutableStopReason.value=e.message; synchronized(workers) { workers.filterKeys { it != song.id }.values.forEach { it.cancel() } } }
                return
            }
        }
    }
    private suspend fun reserve(key: String, bytes: Long, options: DownloadOptions) {
        if (options.tree != null) return
        quota.withLock {
            if (privateBase + committed + reserved.filterKeys { it != key }.values.sum() + bytes > options.limitMb * 1024L * 1024) throw PrivateQuotaError()
            reserved[key] = bytes
        }
    }
    private suspend fun save(owner: String, song: Song, stream: SongStream, options: DownloadOptions, limiter: DownloadLimiter, lyrics: String, tags: AudioTags?) {
        directory.mkdirs()
        val target = File(directory, name(owner, song, stream.quality, stream.extension)); val key = target.name
        val temp = File("${target.path}.part"); val lrc = File("${target.path}.lrc.part"); val tagged = File("${temp.path}.tags.part")
        val indexTemp = File("${target.path}.json.tmp"); val published = mutableListOf<String>(); var localPublished = false; var lrcPublished = false
        var lastReport = 0L
        try {
            reserve(key, song.downloadBytes(stream.quality), options)
            DownloadTransfer(api.http, limiter).download(stream.url, temp, options.connections, { count, total, speed ->
                reserve(key, maxOf(count, total), options)
                val now = System.nanoTime()
                if (now - lastReport >= 200_000_000 || count == total || lastReport == 0L) {
                    lastReport = now; update(song.id) { it.copy(received = count, total = total, speed = speed) }
                }
            }, { stage -> update(song.id) { it.copy(stage = stage) } })
            currentCoroutineContext().ensureActive()
            if (tags != null) update(song.id) { it.copy(stage = "正在写入标签") }
            val audio = if (tags == null) temp else writeAudioTags(temp, stream.extension, tags)
            val length = audio.length(); reserve(key, length, options)
            if(owner != (api.session?.id ?: "anonymous"))throw CancellationException()
            if (lyrics.isNotEmpty()) lrc.outputStream().use { it.write(lyrics.toByteArray()); it.fd.sync() }
            update(song.id) { it.copy(stage = "正在保存文件") }
            val metadata = safeSong(song)
            if (options.tree != null) {
                saf.withLock {
                    val title = "${song.name} - ${song.artistNames} [${song.id}-${stream.quality}]".replace(Regex("[\\x00-\\x1f/\\\\]"), "_").take(110)
                    val uri = export(options.tree, "$title.${stream.extension}", audio, if (stream.extension == "flac") "audio/flac" else "audio/mpeg")
                    published += uri
                    currentCoroutineContext().ensureActive()
                    val lyricUri = if (lrc.isFile) export(options.tree, "$title.lrc", lrc, "text/plain").also { published += it } else null
                    currentCoroutineContext().ensureActive()
                    metadata.put("download", json("uri" to uri, "lyricsUri" to lyricUri, "bytes" to length,
                        "date" to SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())))
                }
            } else {
                currentCoroutineContext().ensureActive()
                if (!audio.renameTo(target)) throw IOException("歌曲保存失败")
                localPublished = true
                if (lrc.isFile) { if (!lrc.renameTo(File(target.path.substringBeforeLast('.') + ".lrc"))) throw IOException("歌词保存失败"); lrcPublished = true }
            }
            currentCoroutineContext().ensureActive()
            if(owner != (api.session?.id ?: "anonymous"))throw CancellationException()
            indexTemp.outputStream().use { it.write(metadata.toString().toByteArray()); it.fd.sync() }
            if (!indexTemp.renameTo(File("${target.path}.json"))) throw IOException("歌曲索引保存失败")
            quota.withLock { if (options.tree == null) committed += length; reserved.remove(key) }
        } catch (e: Exception) {
            withContext(NonCancellable + Dispatchers.IO) {
                published.forEach { runCatching { DocumentsContract.deleteDocument(context.contentResolver, Uri.parse(it)) } }
                if (localPublished) target.delete()
                if (lrcPublished) File(target.path.substringBeforeLast('.') + ".lrc").delete()
            }
            throw e
        } finally {
            withContext(NonCancellable + Dispatchers.IO) {
                listOf(temp, tagged, lrc, indexTemp).forEach { it.delete() }
                quota.withLock { reserved.remove(key) }
            }
        }
    }
    private suspend fun export(tree: String, name: String, file: File, mime: String): String {
        val treeUri = Uri.parse(tree)
        if (treeUri.scheme != "content" || context.contentResolver.persistedUriPermissions.none { it.uri == treeUri && it.isWritePermission }) throw MusicError("保存目录授权已失效，请重新选择文件夹")
        val parent = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
        val document = DocumentsContract.createDocument(context.contentResolver, parent, mime, name) ?: throw IOException("无法创建下载文件")
        try {
            context.contentResolver.openOutputStream(document, "w")?.use { out -> file.inputStream().use { input ->
                val buffer = ByteArray(262144)
                while (true) { currentCoroutineContext().ensureActive(); val n = input.read(buffer); if (n < 0) break; out.write(buffer, 0, n) }
                out.flush()
            } } ?: throw IOException("无法写入下载文件")
            return document.toString()
        } catch (e: Exception) { runCatching { DocumentsContract.deleteDocument(context.contentResolver, document) }; throw e }
    }
    suspend fun delete(entry: DownloadedSong) = withContext(Dispatchers.IO) {
        if (active) throw MusicError("请先等待下载完成或取消下载，再删除文件")
        val file=entry.file.canonicalFile
        if(!namePattern.matches(file.name)||!file.name.startsWith(accountScope(api.session?.id ?: "anonymous")+"-")||directories.none{it.canonicalFile==file.parentFile})throw MusicError("账号或文件位置已改变，请刷新下载列表")
        val meta = File("${entry.file.path}.json")
        if (entry.documentUri != null) {
            val lyric = runCatching { Json(meta.readText()).obj("download").text("lyricsUri") }.getOrDefault("")
            if (lyric.isNotEmpty() && exists(lyric) && !DocumentsContract.deleteDocument(context.contentResolver, Uri.parse(lyric))) throw IOException("无法删除歌词文件")
            if (exists(entry.documentUri) && !DocumentsContract.deleteDocument(context.contentResolver, Uri.parse(entry.documentUri))) throw IOException("无法删除歌曲文件")
        } else {
            if (entry.file.exists() && !entry.file.delete()) throw IOException("无法删除歌曲文件")
            File(entry.file.path.substringBeforeLast('.') + ".lrc").delete()
        }
        meta.delete(); revision.value++
    }
}
fun safeSong(song: Song) = json("id" to song.id, "mid" to song.mid, "title" to song.name, "time_public" to song.releaseYear,
    "interval" to song.durationMs / 1000, "singer" to song.artists.map { json("id" to it.id, "mid" to it.mid, "name" to it.name) },
    "album" to json("id" to song.album.id, "mid" to song.album.mid, "name" to song.album.name), "file" to json("media_mid" to song.mediaMid))
