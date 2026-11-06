package com.green.music.player

import android.graphics.BitmapFactory
import com.green.music.data.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

data class AudioTags(val title: String, val artist: String, val album: String, val year: String, val lyrics: String,
    val cover: ByteArray? = null, val mime: String = "", val width: Int = 0, val height: Int = 0)
private fun u32(value: Int, little: Boolean = false) = ByteBuffer.allocate(4).order(if (little) ByteOrder.LITTLE_ENDIAN else ByteOrder.BIG_ENDIAN).putInt(value).array()
private fun utf16(value: String) = byteArrayOf(255.toByte(), 254.toByte()) + value.replace("\u0000", "").toByteArray(Charsets.UTF_16LE)
private fun id3(t: AudioTags): ByteArray {
    val frames = ByteArrayOutputStream()
    fun frame(id: String, data: ByteArray) { frames.write(id.toByteArray(Charsets.US_ASCII)); frames.write(u32(data.size)); frames.write(byteArrayOf(0, 0)); frames.write(data) }
    mapOf("TIT2" to t.title, "TPE1" to t.artist, "TALB" to t.album, "TYER" to t.year).forEach { (key, value) -> if (value.isNotEmpty()) frame(key, byteArrayOf(1) + utf16(value)) }
    if (t.lyrics.isNotEmpty()) frame("USLT", byteArrayOf(1) + "und".toByteArray() + utf16("") + byteArrayOf(0, 0) + utf16(t.lyrics))
    t.cover?.let { frame("APIC", byteArrayOf(0) + t.mime.toByteArray() + byteArrayOf(0, 3, 0) + it) }
    val raw = frames.toByteArray(); val safe = ByteArrayOutputStream()
    raw.forEachIndexed { index, byte ->
        safe.write(byte.toInt())
        if ((byte.toInt() and 255) == 255 && (index == raw.lastIndex || raw[index + 1].toInt() == 0 || (raw[index + 1].toInt() and 255) >= 224)) safe.write(0)
    }
    val body = safe.toByteArray(); val n = body.size
    return "ID3".toByteArray() + byteArrayOf(3, 0, 128.toByte(), ((n shr 21) and 127).toByte(), ((n shr 14) and 127).toByte(), ((n shr 7) and 127).toByte(), (n and 127).toByte()) + body
}
private fun comments(t: AudioTags, old: ByteArray?): ByteArray {
    val fields = mutableListOf<String>()
    if (old != null) {
        val buffer = ByteBuffer.wrap(old).order(ByteOrder.LITTLE_ENDIAN)
        fun length(): Int { if (buffer.remaining() < 4) throw MusicError("FLAC 标签损坏"); return buffer.int.also { if (it < 0) throw MusicError("FLAC 标签损坏") } }
        fun string(): String { val n = length(); if (n > buffer.remaining()) throw MusicError("FLAC 标签损坏"); return try {Charsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT).decode(ByteBuffer.wrap(ByteArray(n).also(buffer::get))).toString()}catch(_:java.nio.charset.CharacterCodingException){throw MusicError("FLAC 标签损坏")} }
        string(); val count = length()
        if (count > old.size / 4) throw MusicError("FLAC 标签损坏")
        repeat(count) { fields += string() }
    }
    mapOf("TITLE" to t.title, "ARTIST" to t.artist, "ALBUM" to t.album, "DATE" to t.year, "LYRICS" to t.lyrics).forEach { (key, value) ->
        if (value.isNotEmpty()) { fields.removeAll { it.substringBefore('=').uppercase() == key }; fields += "$key=${value.replace("\u0000", "")}" }
    }
    val out = ByteArrayOutputStream()
    fun string(s: String) { val bytes = s.toByteArray(); out.write(u32(bytes.size, true)); out.write(bytes) }
    string("GreenMusic"); out.write(u32(fields.size, true)); fields.forEach(::string)
    return out.toByteArray()
}
private fun picture(t: AudioTags): ByteArray {
    val mime = t.mime.toByteArray(); val cover = t.cover!!
    return u32(3) + u32(mime.size) + mime + u32(0) + u32(t.width) + u32(t.height) + u32(0) + u32(0) + u32(cover.size) + cover
}
suspend fun writeAudioTags(source: File, format: String, tags: AudioTags): File = withContext(Dispatchers.IO) {
    if (listOf(tags.title, tags.artist, tags.album, tags.year, tags.lyrics).sumOf { it.length } > 1024 * 1024 || (tags.cover?.size ?: 0) > 5 * 1024 * 1024) throw MusicError("歌曲标签过大")
    val output = File("${source.path}.tags.part")
    try {
        RandomAccessFile(source, "r").use { input ->
            val length = input.length(); var end = length; val header = ByteArrayOutputStream()
            fun read(n: Int): ByteArray {
                if (n !in 0..16 * 1024 * 1024) throw MusicError("音频标签过大")
                if (n > length - input.filePointer) throw MusicError("音频文件不完整")
                return ByteArray(n).also(input::readFully)
            }
            if (format == "mp3") {
                val prefix = read(10); var start = 0L
                if (String(prefix.copyOfRange(0, 3)) == "ID3") {
                    if (prefix[3].toInt() !in 2..4 || prefix.drop(6).any { (it.toInt() and 255) > 127 }) throw MusicError("不支持的 MP3 标签头")
                    start = 10L + prefix.drop(6).fold(0L) { n, b -> (n shl 7) or b.toLong() }
                    if (prefix[3].toInt() == 4 && prefix[5].toInt() and 16 != 0) start += 10
                }
                if (start + 4 > length) throw MusicError("MP3 文件不完整")
                input.seek(start); val frame = read(4)
                if (frame[0].toInt() and 255 != 255 || frame[1].toInt() and 224 != 224 || frame[1].toInt() and 6 == 0) throw MusicError("音源不是有效的 MP3 文件")
                if (length - start >= 128) { input.seek(length - 128); if (String(read(3)) == "TAG") end -= 128 }
                input.seek(start); header.write(id3(tags))
            } else if (format == "flac") {
                if (String(read(4)) != "fLaC") throw MusicError("音源不是有效的 FLAC 文件")
                val blocks = mutableListOf<Pair<Int, ByteArray>>(); var oldComments: ByteArray? = null; var last = false; var total = 0
                while (!last) {
                    val h = read(4); last = h[0].toInt() and 128 != 0; val type = h[0].toInt() and 127
                    val size = ((h[1].toInt() and 255) shl 16) or ((h[2].toInt() and 255) shl 8) or (h[3].toInt() and 255)
                    total += size + 4
                    if (total > 16 * 1024 * 1024 || type == 127) throw MusicError("FLAC 标签无效或过大")
                    val body = read(size)
                    if (blocks.isEmpty() && (type != 0 || size != 34)) throw MusicError("FLAC 缺少音频信息")
                    if (type == 4) oldComments = body
                    else if (type != 1 && !(type == 6 && tags.cover != null && size >= 4 && ByteBuffer.wrap(body).int == 3)) blocks += type to body
                }
                if (input.filePointer >= length) throw MusicError("FLAC 没有音频数据")
                blocks += 4 to comments(tags, oldComments)
                if (tags.cover != null) blocks += 6 to picture(tags)
                header.write("fLaC".toByteArray())
                blocks.forEachIndexed { index, (type, body) ->
                    if (body.size > 0xffffff) throw MusicError("FLAC 标签过大")
                    header.write(type or if (index == blocks.lastIndex) 128 else 0)
                    header.write((body.size shr 16) and 255); header.write((body.size shr 8) and 255); header.write(body.size and 255); header.write(body)
                }
            } else throw MusicError("暂不支持此音频格式的标签写入")
            if (header.size() > 16 * 1024 * 1024) throw MusicError("音频标签过大")
            output.outputStream().use { out ->
                header.writeTo(out)
                val buffer = ByteArray(262144)
                while (input.filePointer < end) {
                    currentCoroutineContext().ensureActive()
                    val n = input.read(buffer, 0, minOf(buffer.size.toLong(), end - input.filePointer).toInt())
                    if (n <= 0) throw MusicError("音频文件不完整")
                    out.write(buffer, 0, n)
                }
                out.fd.sync()
            }
        }
        output
    } catch (e: Exception) { output.delete(); throw e }
}
suspend fun downloadMetadata(api: MusicApi, song: Song, lyrics: String): AudioTags = withContext(Dispatchers.IO) {
    var cover: ByteArray? = null; var mime = ""; var width = 0; var height = 0
    if (song.cover.isNotEmpty()) {
        val request = Request.Builder().url(song.cover).header("Cookie", "").header("Referer", "https://y.qq.com/").build()
        cover = api.http.newCall(request).await().use { r ->
            if (!r.isSuccessful) throw MusicError("封面下载失败（HTTP ${r.code}）")
            val source = r.body?.source() ?: throw MusicError("封面下载为空")
            source.request(5L * 1024 * 1024 + 1)
            if (source.buffer.size > 5 * 1024 * 1024) throw MusicError("封面超过 5 MB，未写入歌曲")
            source.readByteArray()
        }
        mime = when {
            cover.size >= 3 && cover[0].toInt() and 255 == 255 && cover[1].toInt() and 255 == 216 -> "image/jpeg"
            cover.size >= 8 && cover[0].toInt() and 255 == 137 && cover[1].toInt() == 80 && cover[2].toInt() == 78 && cover[3].toInt() == 71 -> "image/png"
            else -> throw MusicError("封面不是支持的 JPEG / PNG 图片")
        }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(cover, 0, cover.size, options)
        width = options.outWidth; height = options.outHeight
        if (width !in 1..4096 || height !in 1..4096) throw MusicError("封面尺寸无效或过大")
    }
    AudioTags(song.name, song.artistNames, song.album.name, song.releaseYear, lyrics, cover, mime, width, height)
}
