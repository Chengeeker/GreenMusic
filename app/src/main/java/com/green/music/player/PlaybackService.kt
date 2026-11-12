package com.green.music.player

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.green.music.R
import android.os.Bundle
import androidx.media3.common.ForwardingPlayer
import androidx.media3.session.CommandButton
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.media3.session.DefaultMediaNotificationProvider
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.launch
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.green.music.MusicApplication
import com.green.music.data.MusicError
import com.green.music.data.QQ_AGENT
import kotlinx.coroutines.runBlocking
import android.net.Uri
import java.io.IOException

@UnstableApi
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    private val artworkExecutor=com.google.common.util.concurrent.MoreExecutors.listeningDecorator(java.util.concurrent.Executors.newFixedThreadPool(2))
    override fun onCreate() {
        super.onCreate()
        val app = application as MusicApplication
        val network = OkHttpDataSource.Factory(app.api.http).setUserAgent(QQ_AGENT)
            .setDefaultRequestProperties(mapOf("Referer" to "https://y.qq.com/"))
        val sources = ResolvingDataSource.Factory(DefaultDataSource.Factory(this, network)) { spec ->
            if (spec.uri.scheme != "greenmusic") spec else {
                val song = app.playback.catalogue[spec.uri.host] ?: throw IOException("歌曲不在当前队列")
                val owner = app.api.session?.id ?: "anonymous"
                try {
                    val resolved = runBlocking {
                        app.downloads.find(owner, song, app.settings.string("quality", "standard"))?.uri
                            ?: app.api.stream(song, app.settings.string("quality", "standard")).url
                    }
                    if (owner != (app.api.session?.id ?: "anonymous")) throw IOException("账号已改变，已取消播放")
                    app.playback.resolved.value=song.id to resolved
                    spec.withUri(Uri.parse(resolved))
                } catch (e: Exception) { throw IOException(if (e is MusicError) e.message else "无法读取音源，请重试", e) }
            }
        }
        val player = ExoPlayer.Builder(this).setMediaSourceFactory(DefaultMediaSourceFactory(sources)).build().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
            setHandleAudioBecomingNoisy(true)
            setWakeMode(C.WAKE_MODE_LOCAL)
        }
        val activity = PendingIntent.getActivity(this, 0, Intent().setClassName(this, "com.green.music.MainActivity"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val shuffleCommand=SessionCommand("com.green.music.toggleShuffle",Bundle.EMPTY)
        val repeatCommand=SessionCommand("com.green.music.cycleRepeat",Bundle.EMPTY)
        val transport=object:ForwardingPlayer(player) {
            override fun getAvailableCommands():Player.Commands=super.getAvailableCommands().buildUpon().apply {if(mediaItemCount>0)addAll(Player.COMMAND_SEEK_TO_NEXT,Player.COMMAND_SEEK_TO_PREVIOUS,Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)}.build()
            override fun isCommandAvailable(command:Int)=availableCommands.contains(command)
            override fun seekToNext(){app.scope.launch{app.playback.next()}}
            override fun seekToNextMediaItem()=seekToNext()
            override fun seekToPrevious(){app.scope.launch{app.playback.previous()}}
            override fun seekToPreviousMediaItem()=seekToPrevious()
        }
        fun buttons():List<CommandButton> = listOf(
            CommandButton.Builder(if(player.shuffleModeEnabled)CommandButton.ICON_SHUFFLE_ON else CommandButton.ICON_SHUFFLE_OFF)
                .setCustomIconResId(if(player.shuffleModeEnabled)R.drawable.ic_media_shuffle_on else R.drawable.ic_media_shuffle)
                .setDisplayName(if(player.shuffleModeEnabled)"关闭随机播放" else "开启随机播放").setSessionCommand(shuffleCommand).build(),
            CommandButton.Builder(when(player.repeatMode){Player.REPEAT_MODE_ONE->CommandButton.ICON_REPEAT_ONE;Player.REPEAT_MODE_ALL->CommandButton.ICON_REPEAT_ALL;else->CommandButton.ICON_REPEAT_OFF})
                .setCustomIconResId(when(player.repeatMode){Player.REPEAT_MODE_ONE->R.drawable.ic_media_repeat_one_on;Player.REPEAT_MODE_ALL->R.drawable.ic_media_repeat_on;else->R.drawable.ic_media_repeat})
                .setDisplayName(when(player.repeatMode){Player.REPEAT_MODE_ONE->"循环：单曲循环，切换为关闭";Player.REPEAT_MODE_ALL->"循环：列表循环，切换为单曲循环";else->"循环：已关闭，切换为列表循环"}).setSessionCommand(repeatCommand).build())
        session = MediaSession.Builder(this, transport).setSessionActivity(activity).setBitmapLoader(androidx.media3.datasource.DataSourceBitmapLoader(artworkExecutor,DefaultDataSource.Factory(this,network),null,512)).setMediaButtonPreferences(buttons()).setCallback(object:MediaSession.Callback {
            override fun onConnect(session:MediaSession,controller:MediaSession.ControllerInfo):MediaSession.ConnectionResult {
                val base=super.onConnect(session,controller)
                return MediaSession.ConnectionResult.AcceptedResultBuilder(session).setAvailableSessionCommands(base.availableSessionCommands.buildUpon().add(shuffleCommand).add(repeatCommand).build()).build()
            }
            override fun onCustomCommand(session:MediaSession,controller:MediaSession.ControllerInfo,command:SessionCommand,args:Bundle):ListenableFuture<SessionResult> {
                when(command.customAction){shuffleCommand.customAction->player.shuffleModeEnabled=!player.shuffleModeEnabled
                    repeatCommand.customAction->player.repeatMode=when(player.repeatMode){Player.REPEAT_MODE_OFF->Player.REPEAT_MODE_ALL;Player.REPEAT_MODE_ALL->Player.REPEAT_MODE_ONE;else->Player.REPEAT_MODE_OFF}
                    else->return Futures.immediateFuture(SessionResult(androidx.media3.session.SessionError.ERROR_NOT_SUPPORTED))}
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
            }
        }).build()
        player.addListener(object:Player.Listener {
            override fun onShuffleModeEnabledChanged(enabled:Boolean){session?.setMediaButtonPreferences(buttons());app.scope.launch{app.settings.put("shuffle",enabled)}}
            override fun onRepeatModeChanged(mode:Int){session?.setMediaButtonPreferences(buttons());app.scope.launch{app.settings.put("repeat",mode)}}
            override fun onPlaybackStateChanged(state:Int){if(state==Player.STATE_ENDED){if(player.shuffleModeEnabled)app.scope.launch{app.playback.next()}else {player.pause();player.seekTo(0)}}}
        })
        setMediaNotificationProvider(DefaultMediaNotificationProvider.Builder(this).setChannelId("com.green.music.playback").setChannelName(R.string.playback_channel).build().apply{setSmallIcon(R.drawable.ic_stat_music)})
    }
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = session?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }
    override fun onDestroy() {
        session?.let { it.player.release(); it.release() }; session = null
        artworkExecutor.shutdownNow()
        super.onDestroy()
    }
}
