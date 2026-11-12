package com.green.music.player

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.green.music.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import java.util.concurrent.ConcurrentHashMap

data class PlaybackState(val songs: List<Song> = emptyList(), val index: Int = -1, val playing: Boolean = false,
    val loading: Boolean = false, val repeat: Int = Player.REPEAT_MODE_OFF, val shuffle: Boolean = false,
    val speed: Float = 1f, val error: String? = null) {
    val current get() = songs.getOrNull(index)
}
@UnstableApi
class Playback(private val context: Context, private val settings: AppSettings, private val api: MusicApi,
    private val scope: CoroutineScope) {
    val catalogue = ConcurrentHashMap<String, Song>()
    private val mutable = MutableStateFlow(PlaybackState())
    val state = mutable.asStateFlow()
    val position = MutableStateFlow(0L)
    val duration = MutableStateFlow(0L)
    val resolved = MutableStateFlow<Pair<Long,String>?>(null)
    private var controller: MediaController? = null
    private val ready = CompletableDeferred<MediaController>()
    private val persistLock = Mutex()
    private var lastHistoryId = -1L
    private val lyricCache = LinkedHashMap<String, Deferred<List<LyricLine>>>()
    private var ticker: Job? = null

    fun connect() {
        if (controller != null || ready.isCompleted) return
        val future = MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java))).buildAsync()
        future.addListener({
            try {
                val player = future.get(); controller = player
                player.addListener(object : Player.Listener {
                    override fun onEvents(player: Player, events: Player.Events) {
                        refresh()
                        if (events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) scope.launch { recordHistory(); persist() }
                    }
                    override fun onPlayerError(error: PlaybackException) { mutable.value = mutable.value.copy(error = error.cause?.message ?: "播放失败，请重试") }
                })
                restoreQueue(player)
                ready.complete(player)
                refresh()
                ticker = scope.launch {
                    var ticks = 0
                    while (isActive) {
                        if (player.isPlaying) {
                            position.value = player.currentPosition.coerceAtLeast(0)
                            duration.value = player.duration.takeIf { it > 0 } ?: state.value.current?.durationMs ?: 0
                            if (++ticks % 25 == 0) persist()
                        }
                        delay(200)
                    }
                }
            } catch (e: Exception) { ready.completeExceptionally(e); mutable.value = mutable.value.copy(error = "播放服务连接失败，请重启应用") }
        }, ContextCompat.getMainExecutor(context))
    }
    private fun media(song: Song, uri: String? = null): MediaItem {
        catalogue[song.id.toString()] = song
        return MediaItem.Builder().setMediaId(song.id.toString()).setUri(uri ?: "greenmusic://${song.id}")
            .setMediaMetadata(MediaMetadata.Builder().setTitle(song.name).setArtist(song.artistNames).setAlbumTitle(song.album.name)
                .setArtworkUri(song.cover.takeIf(String::isNotEmpty)?.let(Uri::parse)).build()).build()
    }
    private fun restoreQueue(player: MediaController) {
        val songs = savedSongs("queue")
        if (songs.isNotEmpty() && player.mediaItemCount == 0) {
            val index = settings.int("queueIndex", 0).coerceIn(songs.indices)
            player.setMediaItems(songs.map { media(it) }, index, settings.long("position").coerceAtLeast(0))
        }
        player.repeatMode = when (settings.int("repeat")) { 1 -> Player.REPEAT_MODE_ONE; 2, 3 -> Player.REPEAT_MODE_ALL; else -> Player.REPEAT_MODE_OFF }
        player.shuffleModeEnabled = settings.bool("shuffle")
    }
    fun savedSongs(key: String): List<Song> = runCatching {
        val a = JSONArray(settings.string(key, "[]")); (0 until a.length()).mapNotNull { a.optJSONObject(it) }.songs()
    }.getOrDefault(emptyList())
    private fun refresh() {
        val p = controller ?: return
        val songs = (0 until p.mediaItemCount).mapNotNull { catalogue[p.getMediaItemAt(it).mediaId] }
        mutable.value = mutable.value.copy(songs = songs, index = if (songs.isEmpty()) -1 else p.currentMediaItemIndex,
            playing = p.playWhenReady, loading = p.playbackState == Player.STATE_BUFFERING, repeat = p.repeatMode,
            shuffle = p.shuffleModeEnabled, speed = p.playbackParameters.speed)
        position.value = p.currentPosition.coerceAtLeast(0)
        duration.value = p.duration.takeIf { it > 0 } ?: state.value.current?.durationMs ?: 0
    }
    suspend fun playSongs(songs: List<Song>, start: Int = 0) {
        if (songs.isEmpty() || start !in songs.indices) return
        val p = ready.await()
        mutable.value = mutable.value.copy(error = null)
        resolved.value=null
        p.setMediaItems(songs.map { media(it) }, start, 0); p.prepare(); p.play()
        persist()
    }
    suspend fun playDownloaded(song: Song, uri: String) {
        val p = ready.await(); mutable.value = mutable.value.copy(error = null)
        resolved.value=song.id to uri
        p.setMediaItem(media(song, uri)); p.prepare(); p.play(); persist()
    }
    suspend fun toggle() {
        val p = ready.await()
        if (p.playWhenReady && state.value.error==null) p.pause() else { mutable.value = mutable.value.copy(error = null); if (p.playbackState == Player.STATE_IDLE) p.prepare(); p.play() }
        persist()
    }
    suspend fun pause() { ready.await().pause(); persist() }
    suspend fun stop(persistState:Boolean=true) { controller?.stop(); controller?.playWhenReady = false; if(persistState)persist() }
    suspend fun seek(ms: Long) { ready.await().seekTo(ms.coerceIn(0, duration.value.coerceAtLeast(0))); refresh(); persist() }
    suspend fun next() { val p=ready.await();if(p.mediaItemCount==0)return
        val next=if(p.shuffleModeEnabled&&p.mediaItemCount>1)kotlin.random.Random.nextInt(p.mediaItemCount-1).let{if(it>=p.currentMediaItemIndex)it+1 else it} else (p.currentMediaItemIndex+1)%p.mediaItemCount
        select(next)
    }
    suspend fun previous() {val p=ready.await();if(p.currentPosition>3000)seek(0) else if(p.mediaItemCount>0)select(Math.floorMod(p.currentMediaItemIndex-1,p.mediaItemCount))}
    suspend fun select(index: Int) { if (index in state.value.songs.indices) { ready.await().seekTo(index, 0); controller?.prepare(); controller?.play(); persist() } }
    suspend fun repeat() {
        val p = ready.await()
        p.repeatMode = when (p.repeatMode) { Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL; Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE; else -> Player.REPEAT_MODE_OFF }
        settings.put("repeat", when (p.repeatMode) { Player.REPEAT_MODE_ONE -> 1; Player.REPEAT_MODE_ALL -> 2; else -> 0 })
    }
    suspend fun shuffle() { val p = ready.await(); p.shuffleModeEnabled = !p.shuffleModeEnabled; settings.put("shuffle", p.shuffleModeEnabled) }
    suspend fun speed(value: Float) { ready.await().setPlaybackSpeed(value.coerceIn(.5f, 2f)) }
    suspend fun add(song: Song) { ready.await().addMediaItem(media(song)); persist() }
    suspend fun remove(index: Int) { if (index in state.value.songs.indices) { ready.await().removeMediaItem(index); persist() } }
    suspend fun reload() { val p = controller ?: return; p.stop(); p.clearMediaItems(); restoreQueue(p); refresh() }
    fun currentPosition(): Long = controller?.currentPosition?.coerceAtLeast(0) ?: position.value
    suspend fun lyrics(song: Song, force: Boolean = false): List<LyricLine> {
        val key = "${song.id}:${song.mid}"
        if (force) lyricCache.remove(key)?.cancel()
        val result = lyricCache.remove(key) ?: scope.async(Dispatchers.IO) { api.lyrics(song) }
        lyricCache[key] = result
        while (lyricCache.size > 8) lyricCache.remove(lyricCache.keys.first())
        return result.await()
    }
    private suspend fun persist() = persistLock.withLock {
        val p = controller ?: return@withLock
        val songs = (0 until p.mediaItemCount).mapNotNull { catalogue[p.getMediaItemAt(it).mediaId] }
        settings.putAll(mapOf("queue" to JSONArray(songs.map { it.raw }).toString(), "queueIndex" to if (songs.isEmpty()) -1 else p.currentMediaItemIndex,
            "position" to p.currentPosition.coerceAtLeast(0)))
    }
    private suspend fun recordHistory() {
        val song = state.value.current ?: return
        if (song.id == lastHistoryId) return
        lastHistoryId = song.id
        settings.put("history", JSONArray((listOf(song) + savedSongs("history").filter { it.id != song.id }).take(200).map { it.raw }).toString())
    }
}
