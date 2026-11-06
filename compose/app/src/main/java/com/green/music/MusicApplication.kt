package com.green.music

import android.app.Application
import androidx.media3.common.util.UnstableApi
import com.green.music.data.*
import com.green.music.player.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow

@UnstableApi
class MusicApplication : Application() {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    lateinit var settings: AppSettings; private set
    lateinit var secrets: SecretStore; private set
    lateinit var api: MusicApi; private set
    lateinit var auth: AuthService; private set
    lateinit var downloads: Downloads; private set
    lateinit var playback: Playback; private set
    val initialized = MutableStateFlow(false)
    val startupError = MutableStateFlow<String?>(null)
    override fun onCreate() {
        super.onCreate()
        settings = AppSettings(this); secrets = SecretStore(this); api = MusicApi(); auth = AuthService(api, secrets)
        downloads = Downloads(this, api, settings, scope); playback = Playback(this, settings, api, scope)
        scope.launch {
            try { settings.importFlutter(this@MusicApplication); importFlutterSecrets(this@MusicApplication, settings, secrets) }
            catch (e: Exception) { startupError.value = e.message ?: "旧数据导入失败，原数据保留" }
            try { downloads.initialize() } catch (_: Exception) { startupError.value = "临时下载清理失败，完整文件保留" }
            playback.connect(); initialized.value = true
            launch { auth.restore() }
            var previous = api.session?.id
            auth.session.collect { current ->
                if (current?.id != previous) {
                    downloads.cancelAll(); playback.stop()
                    previous = current?.id
                }
            }
        }
    }
}
