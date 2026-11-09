package com.green.music

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.media3.common.util.UnstableApi
import com.green.music.data.MusicError
import com.green.music.ui.GreenMusicRoot
import kotlinx.coroutines.flow.MutableStateFlow

@UnstableApi
class MainActivity : ComponentActivity() {
    val loginCallback = MutableStateFlow<String?>(null)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (android.os.Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
        loginCallback.value = intent?.dataString
        setContent { GreenMusicRoot(application as MusicApplication, this) }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent); loginCallback.value = intent.dataString
    }
}
fun ComponentActivity.displayOptions(): List<Pair<Int,android.view.Display.Mode>> {
        val modes=windowManager.defaultDisplay.supportedModes
        val native=modes.maxOfOrNull {it.physicalWidth} ?: 0
        return (1..8).mapNotNull {index->val width=if(index<=4)native else 1080;val rate=floatArrayOf(120f,90f,72f,60f)[(index-1)%4]
            modes.firstOrNull {it.physicalWidth==width&&kotlin.math.abs(it.refreshRate-rate)<.6f}?.let {index to it}}
    }
fun ComponentActivity.applyDisplayMode(index:Int) {
        val attributes=window.attributes
        if(index==0){attributes.preferredDisplayModeId=0;attributes.preferredRefreshRate=0f}
        else {val mode=displayOptions().firstOrNull {it.first==index}?.second ?: throw MusicError("当前设备不支持此显示模式")
            attributes.preferredDisplayModeId=mode.modeId;attributes.preferredRefreshRate=mode.refreshRate}
        window.attributes=attributes
    }
