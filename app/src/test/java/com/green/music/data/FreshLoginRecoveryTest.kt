package com.green.music.data
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35],manifest=Config.NONE,shadows=[ReplacingAtomicFileShadow::class])
class FreshLoginRecoveryTest {
    private val context=ApplicationProvider.getApplicationContext<Context>()
    private fun newKey()=KeyGenerator.getInstance("AES").apply{init(256)}.generateKey()
    private var deviceKey:SecretKey?=newKey()
    private val keys:(Boolean)->SecretKey={create->deviceKey?:if(create)newKey().also{deviceKey=it}else throw SecretReadFailure(SecretFailureKind.MISSING_KEY)}
    private fun archived(bytes:ByteArray)=File(context.noBackupFilesDir,"account-recovery").listFiles().orEmpty().any{it.readBytes().contentEquals(bytes)}

    private val secrets=SecretStore(context,keyProvider=keys)
    private var reject=false
    private val api=object:MusicApi(){
        override suspend fun rpc(module:String,method:String,param:Json,comm:Json?,headers:Map<String,String>):Json {
            check(method=="GetLoginUserInfo")
            if(reject)throw MusicError("synthetic rejected login")
            return json("info" to json("musicid" to "2","nick" to "synthetic"))
        }
    }
    private val auth=AuthService(api,secrets)
    private val raw="uin=2; qqmusic_key=synthetic-new; login_type=1"
    private val file get()=File(context.applicationInfo.dataDir,"shared_prefs/greenmusic_compose_secrets.xml")
    private suspend fun seed():ByteArray {
        secrets.write("qqmusic_session",json("musicid" to "1","musickey" to "synthetic-old","loginType" to 2).toString())
        return file.readBytes()
    }
    @Test fun freshWebLoginArchivesMissingKeyAndPersistsVerifiedAccount()=runBlocking {
        val old=seed();deviceKey=null
        assertTrue(auth.importWebLoginCookies(raw,auth.beginWebLogin()))
        assertEquals("2",auth.session.value!!.id)
        assertEquals("2",MusicSession(Json(secrets.read("qqmusic_session")!!)).id)
        assertTrue(archived(old))
    }
    @Test fun wrongDeviceKeyCanBeReplacedByVerifiedLogin()=runBlocking {
        val old=seed();deviceKey=newKey()
        assertTrue(auth.importWebLoginCookies(raw,auth.beginWebLogin()));assertTrue(archived(old))
    }
    @Test fun rejectedLoginDoesNotArchiveOrChangeOldCiphertext()=runBlocking {
        val old=seed();deviceKey=null;reject=true
        try{auth.importWebLoginCookies(raw,auth.beginWebLogin());fail()}catch(_:MusicError){}
        assertArrayEquals(old,file.readBytes());assertFalse(archived(old));assertNull(deviceKey)
    }
    @Test fun cancelledLoginDoesNotChangeOldCiphertext()=runBlocking {
        val old=seed();deviceKey=null
        val stale=auth.beginWebLogin();auth.cancelLogin(stale)
        try{auth.importWebLoginCookies(raw,stale);fail()}catch(_:MusicError){}
        assertArrayEquals(old,file.readBytes())
    }
    @Test fun archiveFailureStopsFreshLoginBeforeSaving()=runBlocking {
        val old=seed();deviceKey=null
        File(context.noBackupFilesDir,"account-recovery").writeText("synthetic obstruction")
        try{auth.importWebLoginCookies(raw,auth.beginWebLogin());fail()}catch(_:IllegalStateException){}
        assertArrayEquals(old,file.readBytes());assertNull(deviceKey);assertNull(auth.session.value)
    }
}
