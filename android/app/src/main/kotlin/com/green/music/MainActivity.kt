package com.green.music

import com.ryanheise.audioservice.AudioServiceFragmentActivity
import android.content.res.Configuration
import android.os.Build
import android.provider.Settings
import android.webkit.CookieManager
import android.content.Intent
import android.content.ActivityNotFoundException
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceFragmentActivity() {
    private var settingsChannel: MethodChannel? = null
    private var qqWebLoginPending = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(MusicFilesPlugin::class.java)) flutterEngine.plugins.add(MusicFilesPlugin())
        settingsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.green.music/settings")
        settingsChannel?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getFontWeightAdjustment" -> result.success(systemFontWeight())
                    "getMusicWebCookies" -> result.success(CookieManager.getInstance().getCookie("https://y.qq.com/") ?: "")
                    "openQqWebLogin" -> result.success(openQqWebLogin(call.argument<String>("url") ?: ""))
                    "cancelQqWebLogin" -> { qqWebLoginPending = false; result.success(null) }
                    "getSupportedDisplayModes" -> result.success(windowManager.defaultDisplay.supportedModes.map {
                        mapOf("width" to it.physicalWidth, "height" to it.physicalHeight, "refreshRate" to it.refreshRate)
                    })
                    "setScreenRefreshRateMode" -> {
                        applyDisplayMode(call.argument<Int>("mode") ?: 0); result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("settings_failed", "系统未能应用此设置", null) }
        }
        try { applyDisplayMode(getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).getLong("flutter.screenRefreshRateMode", 0).toInt()) }
        catch (_: Exception) { /* A restored preference may not exist on this device. */ }
    }

    private fun openQqWebLogin(raw: String): Boolean {
        val uri = Uri.parse(raw)
        if (uri.scheme !in setOf("mqqapi", "wtloginmqq") || uri.host != "ptlogin" ||
            uri.path != "/qlogin" || !uri.userInfo.isNullOrEmpty() || uri.port != -1 ||
            !uri.fragment.isNullOrEmpty()) return false
        return try {
            val target = uri.buildUpon().clearQuery()
            for (name in uri.queryParameterNames) {
                if (name in setOf("schemacallback", "encode_jump_url", "replace_https")) continue
                for (value in uri.getQueryParameters(name)) target.appendQueryParameter(name, value)
            }
            // Return to this WebView instead of the browser named in the site's user agent.
            target.appendQueryParameter("schemacallback", "com.green.music.login://qq/")
            target.appendQueryParameter("encode_jump_url", "1")
            qqWebLoginPending = true
            startActivity(Intent(Intent.ACTION_VIEW, target.build()).setPackage("com.tencent.mobileqq"))
            true
        } catch (_: ActivityNotFoundException) { qqWebLoginPending = false; false }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = intent.data ?: return
        if (qqWebLoginPending && intent.action == Intent.ACTION_VIEW &&
            uri.scheme == "com.green.music.login" && uri.host == "qq") {
            qqWebLoginPending = false
            settingsChannel?.invokeMethod("onQqWebLoginCallback", uri.toString())
        }
    }

    // Adapted from Review: retain the system font-weight preference without its login bridge.
    private fun systemFontWeight(): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val adjustment = resources.configuration.fontWeightAdjustment
            if (adjustment != Configuration.FONT_WEIGHT_ADJUSTMENT_UNDEFINED) return adjustment
        }
        return try {
            if (Settings.Secure.getInt(contentResolver, "accessibility_display_bold_text_enabled", 0) == 1) 300 else 0
        } catch (_: Exception) { 0 }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        settingsChannel?.invokeMethod("onFontWeightAdjustmentChanged", systemFontWeight())
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        qqWebLoginPending = false
        settingsChannel?.setMethodCallHandler(null)
        settingsChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun applyDisplayMode(index: Int) {
        require(index in 0..8)
        val attributes = window.attributes
        if (index == 0) { attributes.preferredDisplayModeId = 0; attributes.preferredRefreshRate = 0f }
        else {
            val modes = windowManager.defaultDisplay.supportedModes
            val width = if (index <= 4) modes.maxOf { it.physicalWidth } else 1080
            val rate = floatArrayOf(120f, 90f, 72f, 60f)[(index - 1) % 4]
            val mode = modes.firstOrNull { it.physicalWidth == width && kotlin.math.abs(it.refreshRate - rate) < .6f }
                ?: throw IllegalArgumentException("Unsupported display mode")
            attributes.preferredDisplayModeId = mode.modeId; attributes.preferredRefreshRate = mode.refreshRate
        }
        window.attributes = attributes
    }

}
