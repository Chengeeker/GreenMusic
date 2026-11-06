package com.green.music.data

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableIntStateOf
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("greenmusic_compose", Context.MODE_PRIVATE)
    var revision by mutableIntStateOf(0)
        private set
    private val mutex = Mutex()
    @Volatile private var snapshot: Map<String, *> = prefs.all
    // Read in the consuming composition, including skipped SettingsBody content lambdas.
    private fun values(): Map<String, *> { revision; return snapshot }
    fun bool(key: String, default: Boolean = false) = values()[key] as? Boolean ?: default
    fun int(key: String, default: Int = 0) = (values()[key] as? Number)?.toInt() ?: default
    fun long(key: String, default: Long = 0) = (values()[key] as? Number)?.toLong() ?: default
    fun string(key: String, default: String = "") = values()[key] as? String ?: default
    fun float(key: String, default: Float = 1f) = (values()[key] as? Number)?.toFloat() ?: default
    fun all(): Map<String, *> = values()
    fun previewTextScale(value:Float) {snapshot=snapshot+mapOf("appTextScale" to value.coerceIn(.8f,1.4f));revision++}
    fun clearPreview() {snapshot=prefs.all;revision++}
    suspend fun put(key: String, value: Any?) = putAll(mapOf(key to value))
    suspend fun putAll(values: Map<String, Any?>) = mutex.withLock {
        withContext(Dispatchers.IO) {
            val edit = prefs.edit()
            values.forEach { (key, value) -> edit.value(key, value) }
            if (!edit.commit()) throw MusicError("设置保存失败，请检查存储空间")
            snapshot = prefs.all
        }
        if(values.keys.any {it !in setOf("queue", "queueIndex", "position")})revision++
    }
    suspend fun importFlutter(context: Context) {
        if (bool("flutterImported")) return
        val old = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).all
        val imported = old.filterKeys { it.startsWith("flutter.") }.mapKeys { it.key.removePrefix("flutter.") }
            .filterValues { it is Boolean || it is Number || it is String }
            .filterKeys { !prefs.contains(it) }.toMutableMap()
        // SharedPreferences stores Dart doubles as strings with this marker.
        (imported["appTextScale"] as? String)?.removePrefix("VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGRvdWJsZS4")?.toFloatOrNull()?.let { imported["appTextScale"] = it }
        imported["flutterImported"] = true
        putAll(imported)
    }
    fun lyrics() = LyricsSettings(int("lyricFontSize", 24).coerceIn(16, 40), (int("lyricFontWeight", 600) / 100 * 100).coerceIn(100, 900),
        bool("lyricCenter", true), bool("lyricBlur", true), bool("lyricStagger", true), KaraokeMode.entries[int("lyricKaraoke", 3).coerceIn(0, 3)])
}
private fun SharedPreferences.Editor.value(key: String, value: Any?): SharedPreferences.Editor = when (value) {
    null -> remove(key)
    is Boolean -> putBoolean(key, value)
    is Int -> putInt(key, value)
    is Long -> putLong(key, value)
    is Float -> putFloat(key, value)
    is Double -> putFloat(key, value.toFloat())
    is String -> putString(key, value)
    else -> throw MusicError("不支持的设置类型")
}

class SecretStore(context: Context) {
    private val prefs = context.getSharedPreferences("greenmusic_compose_secrets", Context.MODE_PRIVATE)
    private val lock = Mutex()
    private val alias = "greenmusic.compose.credentials.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    suspend fun read(name: String): String? = lock.withLock { withContext(Dispatchers.IO) {
        val stored = prefs.getString(name, null) ?: return@withContext null
        try {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            require(bytes.size >= 28)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.updateAAD(name.toByteArray())
            String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
        } catch (_: Exception) { throw MusicError("本机凭据无法解密，请重新登录；旧 Flutter 数据保持原样") }
    } }
    suspend fun write(name: String, value: String?) = lock.withLock { withContext(Dispatchers.IO) {
        val editor = prefs.edit()
        if (value == null) editor.remove(name) else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key()); cipher.updateAAD(name.toByteArray())
            val encrypted = cipher.iv + cipher.doFinal(value.toByteArray())
            editor.putString(name, Base64.encodeToString(encrypted, Base64.NO_WRAP))
        }
        if (!editor.commit()) throw MusicError("凭据保存失败，请检查存储空间")
    } }
}
