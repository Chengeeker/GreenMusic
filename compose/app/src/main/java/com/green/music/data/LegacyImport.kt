package com.green.music.data

import android.content.Context
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.security.KeyStore
import java.security.spec.MGF1ParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

// Read the existing plugin's default RSA-OAEP/AES-GCM layout without migrating or deleting its keys.
suspend fun importFlutterSecrets(context: Context, settings: AppSettings, target: SecretStore) = withContext(Dispatchers.IO) {
    if (settings.bool("flutterSecretsImported")) return@withContext
    val source = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE)
    val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_"
    val names = listOf("qqmusic_session", "webdav_password").filter { source.contains(prefix + it) }
    if (names.isNotEmpty()) {
        try {
            val wrapped = context.getSharedPreferences("FlutterSecureKeyStorage", Context.MODE_PRIVATE)
                .getString("AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK", null)
                ?: throw MusicError("旧凭据加密格式不受支持，请重新登录或导入完整备份")
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val privateKey = store.getKey(context.packageName + ".FlutterSecureStoragePluginKeyOAEP", null)
                ?: throw MusicError("旧凭据密钥不可用，请重新登录或导入完整备份")
            val rsa = Cipher.getInstance("RSA/ECB/OAEPPadding", "AndroidKeyStoreBCWorkaround")
            rsa.init(Cipher.UNWRAP_MODE, privateKey, OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT))
            val aes = rsa.unwrap(Base64.decode(wrapped, Base64.DEFAULT), "AES", Cipher.SECRET_KEY)
            val decoded = names.associateWith { name ->
                val bytes = Base64.decode(source.getString(prefix + name, null), Base64.DEFAULT)
                require(bytes.size >= 28)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, aes, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
            }
            decoded["qqmusic_session"]?.let { if (!MusicSession(MusicApi.decode(it)).validIdentity) throw MusicError("旧登录凭据无效，请重新登录") }
            decoded.forEach { (name, value) -> if (target.read(name) == null) target.write(name, value) }
        } catch (e: MusicError) { throw e }
        catch (_: Exception) { throw MusicError("旧凭据导入失败，原数据已保留；请重新登录或导入完整备份") }
    }
    settings.put("flutterSecretsImported", true)
}
