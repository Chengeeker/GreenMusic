package com.green.music.data
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.green.music.player.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35],manifest=Config.NONE,shadows=[ReplacingAtomicFileShadow::class])
class BackupLoginRestoreTest {
    private val context=ApplicationProvider.getApplicationContext<Context>()
    private val key=javax.crypto.KeyGenerator.getInstance("AES").apply{init(256)}.generateKey()
    private val secrets=SecretStore(context,keyProvider={key})
    private val settings=AppSettings(context)
    private val api=MusicApi()
    private val auth=AuthService(api,secrets)
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private val backup=BackupService(settings,secrets,auth,Playback(context,settings,api,scope),Downloads(context,api,settings,scope))
    private fun account(id:String)=MusicSession(json("str_musicid" to id,"musickey" to "synthetic-$id","loginType" to 1))
    private fun data(full:Boolean=true)=json("app" to "greenmusic","schema" to 1,"backup_mode" to if(full)"full"else"safe",
        "preferences" to json("themeMode" to 2)).apply{if(full)put("credentials",json("qqmusic" to account("2").raw,"webdavPassword" to "synthetic-dav"))}
    private suspend fun seed(){auth.replaceFromBackup(account("1"));settings.put("themeMode",0)}
    @Test fun malformedAndExpiredStoredSessionsAreNeverAutomaticallyErased()=runBlocking{
        secrets.write("qqmusic_session","{}")
        val raw=secrets.encryptedSnapshot();auth.restore()
        assertEquals(raw,secrets.encryptedSnapshot());assertNotNull(auth.restoreError.value)
        val expired=account("1").raw.put("musickeyCreateTime",1).put("keyExpiresIn",1)
        secrets.write("qqmusic_session",expired.toString())
        val old=secrets.encryptedSnapshot();auth.restore()
        assertEquals(old,secrets.encryptedSnapshot());assertNull(auth.session.value)
    }
    @Test fun encryptedFullBackupRestoresWithAnotherDeviceKey()=runBlocking{
        seed();secrets.write("webdav_password","synthetic-dav")
        val exported=backup.export(true)
        val otherKey=javax.crypto.KeyGenerator.getInstance("AES").apply{init(256)}.generateKey()
        val otherSecrets=SecretStore(context,keyProvider={otherKey});val otherApi=MusicApi();val otherAuth=AuthService(otherApi,otherSecrets)
        val other=BackupService(settings,otherSecrets,otherAuth,Playback(context,settings,otherApi,scope),Downloads(context,otherApi,settings,scope))
        other.restore(exported){it}
        assertEquals("1",otherAuth.session.value!!.id);assertEquals("synthetic-dav",otherSecrets.read("webdav_password"))
        val reopened=SecretStore(context,keyProvider={otherKey})
        assertEquals("1",MusicSession(Json(reopened.read("qqmusic_session")!!)).id)
    }
    @Test fun verifiedSessionIsPersistedAndSafeExportHasNoCredentials()=runBlocking{
        seed();assertTrue(backup.restore(data()){it}.contains("验证"))
        assertEquals("2",auth.session.value!!.id);assertEquals("2",MusicSession(Json(secrets.read("qqmusic_session")!!)).id)
        assertFalse(backup.export(false).has("credentials"));assertEquals(2,settings.int("themeMode"))
    }
    @Test fun failedValidationRestoresSettingsButKeepsCurrentLogin()=runBlocking{
        seed();assertTrue(backup.restore(data()){error("synthetic")}.contains("登录未恢复"))
        assertEquals("1",auth.session.value!!.id);assertEquals(2,settings.int("themeMode"))
    }
    @Test fun safeRestoreKeepsLogin()=runBlocking{
        seed();backup.restore(data(false)){error("must not verify")}
        assertEquals("1",auth.session.value!!.id);assertEquals(2,settings.int("themeMode"))
    }
    @Test fun newerLoginWinsDuringVerification()=runBlocking{
        seed();try{backup.restore(data()){auth.replaceFromBackup(account("3"));it};fail()}catch(_:IllegalStateException){}
        assertEquals("3",auth.session.value!!.id);assertEquals(0,settings.int("themeMode"))
    }
    @Test fun cancellationDoesNotCommitSettingsOrLogin()=runBlocking{
        seed();try{backup.restore(data()){throw CancellationException()};fail()}catch(_:CancellationException){}
        assertEquals("1",auth.session.value!!.id);assertEquals(0,settings.int("themeMode"))
    }
}
