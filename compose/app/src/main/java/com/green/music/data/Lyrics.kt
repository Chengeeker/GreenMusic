package com.green.music.data

import java.text.BreakIterator
import okio.ByteString.Companion.decodeBase64
import java.util.Locale
import java.io.IOException

data class LyricWord(val text: String, val timeMs: Long, val endMs: Long? = null)
data class LyricLine(val timeMs: Long, val text: String, val translation: String = "", val words: List<LyricWord> = emptyList())
enum class KaraokeMode(val label: String, val detail: String) {
    Off("关闭", "仅高亮当前整行，不播放逐字动画"),
    Timed("仅当前行", "仅有真实逐字时间的行播放动画"),
    Song("拓展同首歌词", "歌曲含真实逐字时间时，为其余行估算动画"),
    All("拓展全部行", "所有行均可播放动画；缺少逐字时间时按行时长估算")
}
data class LyricsSettings(val fontSize: Int = 24, val weight: Int = 600, val center: Boolean = true,
    val blur: Boolean = true, val stagger: Boolean = true, val karaoke: KaraokeMode = KaraokeMode.All)

fun parseLyrics(original: String, translation: String = ""): List<LyricLine> {
    val wordTag = Regex("<(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?>")
    val rowTag = Regex("\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]")
    fun stamp(m: MatchResult): Long = m.groupValues[1].toLong() * 60_000 + m.groupValues[2].toLong() * 1000 +
        m.groupValues[3].padEnd(3, '0').toLong()
    fun parse(input: String): List<LyricLine> {
        val offset = Regex("\\[offset:([+-]?\\d+)\\]").find(input)?.groupValues?.get(1)?.toLongOrNull() ?: 0
        return input.lineSequence().flatMap { line ->
            val matches = rowTag.findAll(line).toList()
            if (matches.isEmpty()) return@flatMap emptySequence()
            val content = line.substring(matches.last().range.last + 1).trim()
            val markers = wordTag.findAll(content).toList(); val plain = content.replace(wordTag, "").trim()
            matches.asSequence().map { match ->
                val time = (stamp(match) + offset).coerceAtLeast(0)
                var valid = markers.isNotEmpty() && content.substring(0, markers.first().range.first).isBlank()
                val words = mutableListOf<LyricWord>()
                for ((index, marker) in markers.withIndex()) {
                    if (!valid) break
                    val start = stamp(marker) + offset; val end = markers.getOrNull(index + 1)?.let { stamp(it) + offset }
                    if (start < time || end != null && end < start) { valid = false; break }
                    var text = content.substring(marker.range.last + 1, markers.getOrNull(index + 1)?.range?.first ?: content.length)
                    if (index == 0) text = text.trimStart()
                    if (index == markers.lastIndex || index == markers.lastIndex - 1 && content.substring(markers.last().range.last + 1).isEmpty()) text = text.trimEnd()
                    if (text.isNotEmpty()) words += LyricWord(text, start, end)
                }
                LyricLine(time, plain, words = if (valid && words.joinToString("") { it.text } == plain) words else emptyList())
            }
        }.sortedBy { it.timeMs }.toList()
    }
    val translations = parse(translation).associate { it.timeMs to it.text }
    return parse(original).map { it.copy(translation = translations[it.timeMs].orEmpty()) }
}

fun karaokeWords(lines: List<LyricLine>, index: Int, durationMs: Long, mode: KaraokeMode): List<LyricWord> {
    if (mode == KaraokeMode.Off || index !in lines.indices) return emptyList()
    val line = lines[index]
    if (line.words.isNotEmpty()) return line.words
    if (mode == KaraokeMode.Timed || mode == KaraokeMode.Song && lines.none { it.words.isNotEmpty() }) return emptyList()
    val parts = graphemes(line.text)
    if (parts.isEmpty()) return emptyList()
    val next = lines.getOrNull(index + 1)?.timeMs
    var end = next?.coerceAtMost(line.timeMs + 8000) ?: line.timeMs + (parts.size * 220L).coerceIn(800, 8000)
    if (durationMs > 0) end = minOf(end, durationMs)
    if (end <= line.timeMs) return emptyList()
    val span = end - line.timeMs
    return parts.mapIndexed { i, part -> LyricWord(part, line.timeMs + span * i / parts.size, line.timeMs + span * (i + 1) / parts.size) }
}

// Join ZWJ/variation/skin-tone sequences as one animation unit on API 24 too.
fun graphemes(text: String): List<String> {
    val result = mutableListOf<String>()
    var start = 0; var index = 0; var join = false; var regional = false
    while (index < text.length) {
        val cp = text.codePointAt(index)
        val type = Character.getType(cp)
        val mark = type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt() ||
            type == Character.ENCLOSING_MARK.toInt() || cp in 0xFE00..0xFE0F || cp in 0xE0100..0xE01EF || cp in 0x1F3FB..0x1F3FF
        val isRegional = cp in 0x1F1E6..0x1F1FF
        if (index > start && !mark && !join && cp != 0x200D && !(isRegional && regional)) {
            result += text.substring(start, index); start = index
        }
        join = cp == 0x200D
        regional = isRegional && !regional
        index += Character.charCount(cp)
    }
    if (index > start) result += text.substring(start)
    return result
}
fun encodeLrc(lines: List<LyricLine>): String = lines.joinToString("\n") { line ->
    val ms = line.timeMs.coerceAtLeast(0)
    val stamp="[%02d:%02d.%02d]".format(Locale.ROOT,ms/60000,ms/1000%60,ms%1000/10)
    val text=line.text.replace(Regex("[\\r\\n]+")," ");val translated=line.translation.replace(Regex("[\\r\\n]+")," ")
    "$stamp$text"+if(translated.isNotEmpty())"\n$stamp$translated" else ""
}
suspend fun MusicApi.lyrics(song: Song): List<LyricLine> {
    fun decode(value: Any?): String {
        if (value == null || value.toString().isEmpty()) return ""
        return value.toString().decodeBase64()?.utf8() ?: throw MusicError("QQ 音乐歌词编码异常")
    }
    val d = cgi("/lyric/fcgi-bin/fcg_query_lyric_new.fcg", json("songmid" to song.mid, "pcachetime" to song.id))
    val original = decode(d.opt("lyric")); var translation = decode(d.opt("trans"))
    if (translation.isEmpty()) {
        try {
            val param = json("songMID" to song.mid, "songName" to "", "singerName" to "", "albumName" to "", "interval" to 0,
                "crypt" to 0, "ct" to 19, "cv" to 2111, "lrc_t" to 0, "qrc" to 0, "qrc_t" to 0, "roma" to 0, "roma_t" to 0,
                "trans" to 1, "trans_t" to 0, "type" to 0)
            translation = decode(rpc("music.musichallSong.PlayLyricInfo", "GetPlayLyricInfo", param,
                json("ct" to 11, "cv" to "1003006", "v" to "1003006", "tmeAppID" to "qqmusiclight", "nettype" to "NETWORK_WIFI", "udid" to "0", "uid" to "0"),
                mapOf("Cookie" to "tmeLoginType=-1", "User-Agent" to "okhttp/3.14.9")).opt("trans"))
        } catch (_: MusicError) { /* Optional translation must not discard original lyrics. */ }
        catch (_: IOException) { /* Preserve original when translation is unavailable. */ }
    }
    return parseLyrics(original, translation)
}
