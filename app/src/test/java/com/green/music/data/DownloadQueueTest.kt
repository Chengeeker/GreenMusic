package com.green.music.data

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.green.music.player.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[28],application=Application::class)
class DownloadQueueTest {
    @Test fun privateQuotaCancelsWaitingWorkWithoutDeletingExistingAudio()=runBlocking {
        val context=ApplicationProvider.getApplicationContext<Context>()
        val p=AppSettings(context);p.putAll(mapOf("cacheLimitMb" to 128,"downloadConcurrent" to 1,"downloadRetries" to 0,"downloadLyrics" to false,"downloadTags" to false,"downloadTree" to null))
        val dir=File(context.filesDir,"music_downloads").apply{mkdirs()};val existing=File(dir,"0000000000000000-99-standard.mp3")
        RandomAccessFile(existing,"rw").use{it.setLength(127L*1024*1024)}
        val calls=AtomicInteger()
        val api=object:MusicApi(){override suspend fun rpc(module:String,method:String,param:Json,comm:Json?,headers:Map<String,String>):Json {
            calls.incrementAndGet();return json("sip" to listOf("https://dl.stream.qqmusic.qq.com/"),"midurlinfo" to listOf(json("purl" to "test.mp3")))
        }}
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default);val downloads=Downloads(context,api,p,scope)
        val songs=(1..5).map{id->Song.parse(json("id" to id,"mid" to "s$id","title" to "Song $id","file" to json("media_mid" to "s$id","size_128mp3" to 2*1024*1024)))}
        try {
            downloads.start(songs)
            withTimeout(5000){downloads.tasks.first{it.size==5&&it.none{task->task.status==DownloadStatus.Waiting||task.status==DownloadStatus.Running}}}
            assertFalse(downloads.stopReason.value.isNullOrBlank());assertEquals(1,calls.get());assertEquals(1,downloads.tasks.value.count{it.status==DownloadStatus.Failed})
            assertEquals(4,downloads.tasks.value.count{it.status==DownloadStatus.Cancelled})
            assertTrue(existing.exists());assertEquals(127L*1024*1024,existing.length())
            assertEquals(listOf(existing.name),dir.listFiles()!!.map{it.name})
        }finally{downloads.cancelAll();scope.cancel();existing.delete()}
    }
    @Test fun staleAccountCannotDeleteDownloadAndLegacyTitleUsesHistory()=runBlocking {
        val context=ApplicationProvider.getApplicationContext<Context>();val settings=AppSettings(context);val api=MusicApi()
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default);val downloads=Downloads(context,api,settings,scope)
        val hash=java.security.MessageDigest.getInstance("SHA-256").digest("anonymous".toByteArray()).joinToString(""){"%02x".format(it)}.take(16)
        val file=File(File(context.filesDir,"music_downloads").apply{mkdirs()},"$hash-7-standard.mp3").apply{writeBytes(byteArrayOf(1,2,3))}
        settings.put("history",org.json.JSONArray(listOf(json("id" to 7,"mid" to "s7","title" to "保留的标题"))).toString())
        try {
            val entry=downloads.entries("anonymous").single();assertEquals("保留的标题",entry.song.name)
            api.session=MusicSession(json("str_musicid" to "123","musickey" to "test","loginType" to 2))
            try{downloads.delete(entry);fail("A stale account entry must not be deleted")}catch(_:MusicError){}
            assertTrue(file.exists());api.session=null;downloads.delete(entry);assertFalse(file.exists())
        }finally{scope.cancel();file.delete()}
    }
    @Test fun cancellingAccountDuringUrlResolutionCannotPublish()=runBlocking {
        val context=ApplicationProvider.getApplicationContext<Context>();val p=AppSettings(context)
        p.putAll(mapOf("downloadLyrics" to false,"downloadTags" to false,"downloadConcurrent" to 1))
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val api=object:MusicApi(){override suspend fun rpc(module:String,method:String,param:Json,comm:Json?,headers:Map<String,String>):Json {
            entered.complete(Unit);release.await();return json("sip" to listOf("https://dl.stream.qqmusic.qq.com/"),"midurlinfo" to listOf(json("purl" to "test.mp3")))
        }}
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default);val downloads=Downloads(context,api,p,scope)
        val song=Song.parse(json("id" to 1,"mid" to "s1","file" to json("media_mid" to "s1")))
        try {
            downloads.start(listOf(song));withTimeout(5000){entered.await()}
            api.session=MusicSession(json("str_musicid" to "123","musickey" to "test","loginType" to 2));release.complete(Unit)
            withTimeout(5000){downloads.tasks.first{it.single().status==DownloadStatus.Cancelled}}
            assertTrue(downloads.entries("anonymous").isEmpty());assertTrue(downloads.entries("123").isEmpty())
        }finally{release.complete(Unit);downloads.cancelAll();scope.cancel()}
    }
    @Test fun cancellationIsObservableUntilWorkersFinishCleaningUp()=runBlocking {
        val context=ApplicationProvider.getApplicationContext<Context>();val settings=AppSettings(context)
        settings.putAll(mapOf("downloadLyrics" to false,"downloadTags" to false))
        val entered=CompletableDeferred<Unit>();val cleanup=CompletableDeferred<Unit>()
        val api=object:MusicApi(){override suspend fun rpc(module:String,method:String,param:Json,comm:Json?,headers:Map<String,String>):Json {
            entered.complete(Unit)
            try{awaitCancellation()}finally{withContext(NonCancellable){cleanup.await()}}
        }}
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default);val downloads=Downloads(context,api,settings,scope)
        val song=Song.parse(json("id" to 10,"mid" to "s10","file" to json("media_mid" to "s10")))
        try{
            downloads.start(listOf(song));withTimeout(5000){entered.await()}
            val cancellation=launch{downloads.cancelAll()}
            withTimeout(5000){downloads.cancelling.first{it}}
            assertFalse(cancellation.isCompleted)
            cleanup.complete(Unit);withTimeout(5000){cancellation.join()}
            assertFalse(downloads.cancelling.value)
            assertEquals(DownloadStatus.Cancelled,downloads.tasks.value.single().status)
        }finally{cleanup.complete(Unit);downloads.cancelAll();scope.cancel()}
    }

}
