@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.green.music.ui

import android.app.Application
import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import com.green.music.MusicApplication
import com.green.music.data.*
import com.green.music.player.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.rules.TestRule
import org.junit.rules.RuleChain
import org.junit.runners.model.Statement
import org.robolectric.shadows.ShadowPackageManager
import android.content.ComponentName
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import okio.ByteString.Companion.encodeUtf8

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35],application=Application::class,qualifiers="w412dp-h892dp-hdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScreenTest {
    val rule=createAndroidComposeRule<ComponentActivity>()
    private val register=TestRule {base,_->object:Statement(){override fun evaluate(){
        org.robolectric.Shadows.shadowOf(ApplicationProvider.getApplicationContext<android.content.Context>().packageManager).addActivityIfNotPresent(ComponentName(ApplicationProvider.getApplicationContext(),ComponentActivity::class.java))
        base.evaluate()
    }}}
    @get:Rule val rules:TestRule=RuleChain.outerRule(register).around(rule)
    private lateinit var testScope:CoroutineScope
    @After fun close(){if(::testScope.isInitialized)testScope.cancel()}
    private lateinit var app:MusicApplication
    private lateinit var ui:Ui
    private lateinit var lyricsGate:CompletableDeferred<Unit>
    private val song=Song.parse(json("id" to 1,"mid" to "test","title" to "测试歌曲","singer" to listOf(json("name" to "测试歌手")),"interval" to 240))
    private fun fixture(large:Boolean=false,root:Boolean=false,deferLyrics:Boolean=false,content:@Composable ()->Unit) {
        val context=rule.activity
        context.getSharedPreferences("greenmusic_compose",0).edit().clear().putBoolean("dynamicColor",false).putInt("themeMode",2).putInt("colorIndex",0).putFloat("appTextScale",if(large)1.4f else 1f).commit()
        val settings=AppSettings(context);val secrets=SecretStore(context)
        lyricsGate=CompletableDeferred<Unit>().apply{if(!deferLyrics)complete(Unit)}
        val api=object:MusicApi() {override suspend fun rpc(module:String,method:String,param:Json,comm:Json?,headers:Map<String,String>):Json=throw MusicError("主机测试，不请求远端")
            override suspend fun cgi(path:String,query:Json,anonymous:Boolean):Json {lyricsGate.await();return json("lyric" to (0..24).joinToString("\n"){"[00:${it.toString().padStart(2,'0')}.00]第 $it 行测试歌词"}.encodeUtf8().base64())}}
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate);testScope=scope
        app=MusicApplication()
        val playback=Playback(context,settings,api,scope)
        mapOf("settings" to settings,"secrets" to secrets,"api" to api,"auth" to AuthService(api,secrets),"downloads" to Downloads(context,api,settings,scope),"playback" to playback).forEach {(name,value)->MusicApplication::class.java.getDeclaredField(name).apply {isAccessible=true}.set(app,value)}
        ui=Ui(app,context,scope)
        app.initialized.value=true
        // Keep IO completion out of Robolectric's layout interceptor; the loading-touch test releases its own gate.
        if(!deferLyrics)runBlocking {playback.lyrics(song)}
        rule.setContent {if(root)GreenMusicRoot(app,context)else GreenMusicTheme(settings){CompositionLocalProvider(LocalUi provides ui,LocalRippleConfiguration provides null){Surface(Modifier.fillMaxSize()) {content()}}}}
    }
    private fun screenshot(name:String,source:android.view.View?=null,hardware:Boolean=false):Bitmap {
        lateinit var captured:Bitmap
        val output=File("../../.local/compose-preview/$name.png").absoluteFile;output.parentFile!!.mkdirs()
        rule.runOnIdle {
            val view=source ?: rule.activity.window.decorView
            captured=if(hardware){
                val node=android.graphics.RenderNode(name)
                node.setPosition(0,0,view.width,view.height)
                view.draw(node.beginRecording())
                node.endRecording()
                hardwareBitmap(node)
            }else Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888).also {view.draw(android.graphics.Canvas(it))}
            output.outputStream().use{captured.compress(Bitmap.CompressFormat.PNG,100,it)}
        }
        return captured
    }
    private fun setSong(){rule.runOnIdle{val field=Playback::class.java.getDeclaredField("mutable").apply{isAccessible=true};@Suppress("UNCHECKED_CAST") val state=field.get(app.playback) as MutableStateFlow<PlaybackState>;state.value=PlaybackState(songs=listOf(song),index=0)}}
    @Test @Config(qualifiers="w892dp-h412dp-hdpi") fun landscapePlayerKeepsControlsReachable(){
        fixture(large=true){PlayerScreen()};setSong()
        rule.onNodeWithContentDescription("播放").assertIsDisplayed()
        rule.onNodeWithContentDescription("歌曲操作").performScrollTo().assertIsDisplayed()
        screenshot("player-landscape-large")
    }
    @Test fun fullPlayerLyricsBackOnlyClosesLyrics(){
        fixture{PlayerScreen()};setSong()
        rule.waitUntil(5000){rule.onAllNodesWithText("第 0 行测试歌词").fetchSemanticsNodes().isNotEmpty()}
        rule.onNodeWithText("第 0 行测试歌词").performClick()
        rule.waitUntil(5000){rule.onAllNodesWithContentDescription("第 0 行测试歌词").fetchSemanticsNodes().isNotEmpty()}
        rule.runOnIdle{rule.activity.onBackPressedDispatcher.onBackPressed()}
        rule.onNodeWithText("测试歌曲").assertIsDisplayed()
        rule.onNodeWithText("第 0 行测试歌词").assertIsDisplayed()
    }
    @Test fun settingsCanBeReopenedAfterRapidReturn(){
        fixture(root=true){}
        rule.onAllNodesWithText("我的").onFirst().performClick()
        rule.onNodeWithText("设置").performScrollTo().performClick()
        rule.onNodeWithText("歌词界面").performClick()
        rule.onNodeWithText("歌词视图字体大小").assertIsDisplayed()
        rule.mainClock.autoAdvance=false
        rule.runOnIdle{rule.activity.onBackPressedDispatcher.onBackPressed()}
        rule.mainClock.advanceTimeBy(80)
        rule.mainClock.autoAdvance=true
        rule.onNodeWithText("歌词界面").performClick()
        rule.onNodeWithText("歌词视图字体大小").assertIsDisplayed()
    }
    @Test @Config(sdk=[28]) fun oldAndroidRendersBlurredLyrics(){
        fixture{SyncedLyrics(song)};rule.runOnIdle{app.playback.position.value=18_000}
        rule.waitUntil(5000){rule.onAllNodesWithContentDescription("第 18 行测试歌词").fetchSemanticsNodes().isNotEmpty()}
        rule.onNodeWithContentDescription("第 18 行测试歌词").assertIsDisplayed();screenshot("lyrics-api28")
    }
    @Test fun smallDriftDoesNotOpenPlayer(){
        var taps=0;fixture{SwipeFrame("test",{true},{},Modifier.fillMaxWidth().height(120.dp)){Box(Modifier.fillMaxSize().quietClick{taps++}){Text("滑动区域")}}}
        rule.onNodeWithText("滑动区域").performTouchInput{down(center);moveBy(androidx.compose.ui.geometry.Offset(14f,0f));up()}
        rule.runOnIdle{assertEquals(0,taps)}
    }
    @Test fun miniPlayerCanExpandAndReturnRepeatedly(){
        fixture(root=true,deferLyrics=true){};setSong()
        repeat(2){
            if(it==0){
                rule.onNodeWithText("正在加载歌词…").assertIsDisplayed()
                rule.onNodeWithText("测试歌曲").performTouchInput{down(center)}
                rule.runOnIdle{lyricsGate.complete(Unit)}
                rule.waitUntil(5000){rule.onAllNodesWithText("第 0 行测试歌词").fetchSemanticsNodes().isNotEmpty()}
                rule.onNodeWithText("测试歌曲").performTouchInput{up()}
            }else rule.onNodeWithText("测试歌曲").performClick()
            rule.mainClock.advanceTimeBy(450)
            val rendered=screenshot("root-player-$it")
            val title=rule.onNodeWithText("测试歌曲").fetchSemanticsNode().boundsInRoot
            var bright=0
            for(y in title.top.toInt().coerceAtLeast(0) until title.bottom.toInt().coerceAtMost(rendered.height))for(x in title.left.toInt().coerceAtLeast(0) until title.right.toInt().coerceAtMost(rendered.width)){
                val pixel=rendered.getPixel(x,y);if(android.graphics.Color.red(pixel)>160&&android.graphics.Color.green(pixel)>160&&android.graphics.Color.blue(pixel)>160)bright++
            }
            assertTrue("Dark player title must use a readable foreground",bright>20)
            rule.onNodeWithContentDescription("歌曲操作").assertIsDisplayed()
            rule.mainClock.autoAdvance=false
            rule.runOnIdle{rule.activity.onBackPressedDispatcher.onBackPressed()}
            rule.mainClock.advanceTimeBy(100)
            rule.mainClock.autoAdvance=true
            rule.onNodeWithText("测试歌曲").assertIsDisplayed()
        }
    }
    @Test fun collapsingPlayerRemovesTheExtraTitleLineBeforeArrival() {
        val title = "A long track title that occupies two lines in the full music player"
        val longSong = Song.parse(json("id" to 2, "mid" to "title", "title" to title))
        val mini = androidx.compose.ui.geometry.Rect(24f, 450f, 225f, 485f)
        val full = androidx.compose.ui.geometry.Rect(36f, 54f, 530f, 180f)
        val offset = androidx.compose.animation.core.Animatable(0f)
        val flight = PlayerFlight(PlayerOrigin(mini, mini, mini, androidx.compose.ui.text.TextStyle.Default), offset, longSong, closing = true)
        fixture {
            SideEffect { ui.playerEnd["title"] = full }
            PlayerFlightOverlay(flight)
        }
        fun titleLayout(): androidx.compose.ui.text.TextLayoutResult {
            val results = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            rule.onNodeWithText(title).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(results) }
            return results.single()
        }
        assertEquals(2, titleLayout().lineCount)
        rule.runOnIdle { testScope.launch { offset.snapTo(.4f) } }
        assertEquals(1, titleLayout().lineCount)
        assertTrue(rule.onNodeWithText(title).fetchSemanticsNode().boundsInRoot.top < mini.top)
    }
    // Robolectric #8460: a text field in a dialog loops with explicit width/height qualifiers.
    @Test @Config(qualifiers="w320dp-h470dp-mdpi") fun playlistNameCannotSaveEmptyOrExceedLimit(){
        fixture {TextButton({testScope.launch{ui.input("创建歌单")}}){Text("打开")};ui.dialog?.invoke()}
        rule.onNodeWithText("打开").performClick()
        rule.onNodeWithText("保存").performClick()
        rule.onNodeWithText("创建歌单").assertIsDisplayed()
        rule.onNode(hasSetTextAction()).performTextInput("123456789012345678901")
        rule.onNodeWithText("0/20").assertIsDisplayed()
        rule.onNode(hasSetTextAction()).performTextInput("我的新歌单")
        rule.onNodeWithText("保存").performClick()
        rule.onNodeWithText("创建歌单").assertDoesNotExist()
    }
    @Test fun artworkColorsMatchFlutterPalette(){
        val context=ApplicationProvider.getApplicationContext<android.content.Context>()
        val palettes=Json(context.assets.open("flutter_theme_colors.json").bufferedReader().use{it.readText()})
        val seeds=longArrayOf(0xFFFA2F3A,0xFFFF8200,0xFF1976D2,0xFF2E7D32,0xFF7B1FA2,0xFFE91E63,0xFF00897B,0xFF455A64)
        seeds.forEachIndexed{index,seed->listOf(false,true).forEach {dark->
            val expected=palettes.getJSONObject("${index}_${if(dark)"dark" else "light"}");val actual=artworkScheme(seed.toInt(),dark)
            colorRoles(actual).forEach{(name,color)->assertEquals("$index/$dark/$name",expected.getLong(name).toInt(),color.toArgb())}
        }}
    }
    private fun colorRoles(s:ColorScheme)=mapOf(
        "primary" to s.primary,"onPrimary" to s.onPrimary,"primaryContainer" to s.primaryContainer,"onPrimaryContainer" to s.onPrimaryContainer,
        "secondary" to s.secondary,"onSecondary" to s.onSecondary,"secondaryContainer" to s.secondaryContainer,"onSecondaryContainer" to s.onSecondaryContainer,
        "tertiary" to s.tertiary,"onTertiary" to s.onTertiary,"tertiaryContainer" to s.tertiaryContainer,"onTertiaryContainer" to s.onTertiaryContainer,
        "error" to s.error,"onError" to s.onError,"errorContainer" to s.errorContainer,"onErrorContainer" to s.onErrorContainer,
        "surface" to s.surface,"onSurface" to s.onSurface,"surfaceVariant" to s.surfaceVariant,"onSurfaceVariant" to s.onSurfaceVariant,
        "surfaceContainerLowest" to s.surfaceContainerLowest,"surfaceContainerLow" to s.surfaceContainerLow,"surfaceContainer" to s.surfaceContainer,"surfaceContainerHigh" to s.surfaceContainerHigh,"surfaceContainerHighest" to s.surfaceContainerHighest,
        "outline" to s.outline,"outlineVariant" to s.outlineVariant,"inverseSurface" to s.inverseSurface,"inverseOnSurface" to s.inverseOnSurface,"inversePrimary" to s.inversePrimary,
        "background" to s.background,"onBackground" to s.onBackground,"surfaceDim" to s.surfaceDim,"surfaceBright" to s.surfaceBright,"surfaceTint" to s.surfaceTint,"scrim" to s.scrim)

    @Test fun dynamicColorsMatchFlutterPluginIncludingSurfaceRoles() {
        val samples=Json(javaClass.getResourceAsStream("/flutter_visual_tokens.json")!!.bufferedReader().use{it.readText()}).getJSONArray("dynamic")
        for(i in 0 until samples.length()) {
            val sample=samples.getJSONObject(i);val palettes=sample.getJSONObject("palettes");val expected=sample.getJSONObject("colors")
            val actual=flutterDynamicScheme(sample.getBoolean("dark")){palette,tone->Color(palettes.getJSONObject(palette).getLong(tone.toString()).toInt())}
            colorRoles(actual).forEach{(name,color)->assertEquals("Dynamic $i/$name",expected.getLong(name).toInt(),color.toArgb())}
        }
    }
    @Test fun glassRendersTintedBackdropInsteadOfGeometry() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val backdrop = Bitmap.createBitmap(128, 64, Bitmap.Config.ARGB_8888)
        val warm = android.graphics.Color.rgb(240, 56, 20)
        val cool = android.graphics.Color.rgb(24, 56, 240)
        backdrop.setPixels(IntArray(128 * 64) { if (it / 128 < 32) warm else cool }, 0, 128, 0, 0, 128, 64)
        val effect = GlassEffect(context)
        fun render(dark: Boolean, indicator: Boolean): Bitmap {
            val values = glassUniforms(104f, 40f, 1f, dark, indicator, 0f, padding = 12)
            val node = android.graphics.RenderNode("glass-pixel-check")
            node.setPosition(0, 0, 128, 64)
            node.beginRecording().drawBitmap(backdrop, 0f, 0f, null)
            node.endRecording()
            node.setRenderEffect(effect.effect(values, 2f).asAndroidRenderEffect())
            return hardwareBitmap(node)
        }
        val dark = render(true, false)
        val top = dark.getPixel(64, 22)
        val bottom = dark.getPixel(64, 42)
        assertEquals(0, android.graphics.Color.alpha(dark.getPixel(3, 3)))
        assertEquals(255, android.graphics.Color.alpha(top))
        assertTrue("Upper glass must sample the warm upper backdrop", android.graphics.Color.red(top) > android.graphics.Color.blue(top) + 50)
        assertTrue("Lower glass must sample the cool lower backdrop", android.graphics.Color.blue(bottom) > android.graphics.Color.red(bottom) + 50)
        assertTrue(android.graphics.Color.green(render(false, false).getPixel(64, 22)) > android.graphics.Color.green(top) + 80)
        assertTrue(android.graphics.Color.green(render(true, true).getPixel(64, 22)) > android.graphics.Color.green(top))
    }

    private fun hardwareBitmap(node: android.graphics.RenderNode): Bitmap {
        // Robolectric's hardware path supports RuntimeShader; a bitmap Canvas does not.
        val renderBitmap = android.graphics.HardwareRenderer::class.java.getDeclaredMethod(
            "createHardwareBitmap", android.graphics.RenderNode::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
        )
        return (renderBitmap.invoke(null, node, node.width, node.height) as Bitmap).copy(Bitmap.Config.ARGB_8888, false)
    }

    @Test fun floatingGlassSamplesThePageAndCommitsDragOnRelease() {
        var selected by mutableIntStateOf(0)
        fixture {
            val layer = rememberGraphicsLayer()
            val backdrop = remember { Backdrop(layer) }
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Canvas(Modifier.matchParentSize().recordBackdrop(backdrop)) {
                    drawRect(Color(0xFFF03814), size = Size(size.width, size.height / 2))
                    drawRect(Color(0xFF1838F0), topLeft = Offset(0f, size.height / 2), size = Size(size.width, size.height / 2))
                }
                val icons = listOf(Icons.Rounded.Explore, Icons.Rounded.Search, Icons.Rounded.LibraryMusic)
                CompositionLocalProvider(LocalBackdrop provides backdrop) {
                    GlassNavigation(selected, { selected = it }, 240.dp, 56.dp, listOf("发现", "搜索", "我的"), icons, icons)
                }
            }
        }
        val tab = rule.onNodeWithContentDescription("我的").fetchSemanticsNode().boundsInRoot
        fun renderNavigation() = rule.runOnIdle {
            val view = rule.activity.window.decorView
            val node = android.graphics.RenderNode("floating-navigation-check")
            node.setPosition(0, 0, view.width, view.height)
            view.draw(node.beginRecording())
            node.endRecording()
            hardwareBitmap(node)
        }
        val rendered = renderNavigation()
        val x = (tab.left + tab.width * .15f).toInt()
        val upper = rendered.getPixel(x, (tab.center.y - 16).toInt())
        val lower = rendered.getPixel(x, (tab.center.y + 16).toInt())
        assertTrue("Upper capsule must tint the warm page behind it", android.graphics.Color.red(upper) in 120..220 && android.graphics.Color.red(upper) > android.graphics.Color.blue(upper) + 50)
        assertTrue("Lower capsule must tint the cool page behind it", android.graphics.Color.blue(lower) in 120..220 && android.graphics.Color.blue(lower) > android.graphics.Color.red(lower) + 50)
        val discover = rule.onNodeWithContentDescription("发现")
        val restingBounds = discover.fetchSemanticsNode().boundsInRoot
        rule.mainClock.autoAdvance = false
        val outsideY = (restingBounds.top - 6).toInt()
        discover.performTouchInput { down(center);moveBy(Offset(tab.width, 0f), delayMillis = 40) }
        repeat(25) { rule.mainClock.advanceTimeByFrame() }
        val quickDrag = renderNavigation()
        val middleX = rule.onNodeWithContentDescription("搜索").fetchSemanticsNode().boundsInRoot.center.x.toInt()
        assertEquals("A quick drag must not expand the water drop", rendered.getPixel(middleX,outsideY), quickDrag.getPixel(middleX,outsideY))
        discover.performTouchInput { cancel() }
        rule.mainClock.advanceTimeBy(500)
        discover.performTouchInput { down(center) }
        rule.mainClock.advanceTimeBy(500)
        val held = renderNavigation()
        assertEquals("Glass must not resize the touch layout during expansion", restingBounds, discover.fetchSemanticsNode().boundsInRoot)
        val outsideX = restingBounds.center.x.toInt()
        assertNotEquals("Long press must draw the larger lens above the tab", rendered.getPixel(outsideX,outsideY), held.getPixel(outsideX,outsideY))
        fun swipeHeldDrop(tabDistance: Float) {
            repeat(8) {
                discover.performTouchInput { moveBy(Offset(tab.width * tabDistance / 8, 0f), delayMillis = 16) }
                rule.mainClock.advanceTimeByFrame()
            }
            rule.mainClock.advanceTimeBy(220)
        }
        swipeHeldDrop(2f)
        val right = renderNavigation()
        swipeHeldDrop(-2f)
        val left = renderNavigation()
        val rightX = tab.center.x.toInt()
        assertNotEquals("After a held drag, the drop must reach the right tab and follow back to the left",
            right.getPixel(rightX,outsideY), left.getPixel(rightX,outsideY))
        swipeHeldDrop(1f)
        rule.runOnIdle { assertEquals(0, selected) }
        val moving=renderNavigation()
        var changed=0
        val middle=rule.onNodeWithContentDescription("搜索").fetchSemanticsNode().boundsInRoot
        for(y in middle.top.toInt() until middle.bottom.toInt())for(xp in middle.left.toInt() until middle.right.toInt())if(moving.getPixel(xp,y)!=rendered.getPixel(xp,y))changed++
        assertTrue("Dragging must render the active refracting lens",changed>500)
        val directory=File("../../.local/compose-preview").apply{mkdirs()}
        listOf("glass-hold39-dark" to held,"glass-drag39-right" to right,"glass-drag39-left" to left).forEach{(name,frame)->File(directory,"$name.png").outputStream().use{frame.compress(Bitmap.CompressFormat.PNG,100,it)}}
        discover.performTouchInput { advanceEventTime(150);up() }
        rule.mainClock.autoAdvance = true
        rule.onNodeWithContentDescription("搜索").assertIsSelected()
        rule.onNodeWithContentDescription("搜索").performTouchInput {down(center);moveBy(Offset(tab.width,0f),delayMillis=250);cancel()}
        rule.onNodeWithContentDescription("搜索").assertIsSelected()
    }

    @Test fun glassPressureStartsDecayingOnRelease() {
        var touching by mutableStateOf(true)
        var pressure = 0f
        rule.mainClock.autoAdvance = false
        fixture {
            val value = navigationGlassMotion(1, touching, true, 1f, longPressed = true, reduced = false)
            SideEffect { pressure = value.second }
        }
        rule.runOnIdle { assertEquals(1f, pressure, .001f) }
        rule.runOnUiThread { touching = false }
        repeat(6) {
            rule.mainClock.advanceTimeByFrame()
            rule.waitForIdle()
        }
        var previous = rule.runOnIdle {
            assertTrue("The drop must already be fading within the first 96 ms (pressure=$pressure)", pressure in .001f..0.999f)
            pressure
        }
        repeat(4) {
            rule.mainClock.advanceTimeBy(32)
            rule.runOnIdle { assertTrue(pressure <= previous); previous = pressure }
        }
        rule.mainClock.advanceTimeBy(80)
        rule.runOnIdle { assertEquals(0f, pressure, .001f) }
        assertArrayEquals(floatArrayOf(1f, 1f), jellyScale(100f, 0f), .001f)
        rule.mainClock.autoAdvance = true
    }

    @Test fun darkThemeUsesAppForegroundAndDisablesForceDark() {
        val attributes = rule.activity.obtainStyledAttributes(com.green.music.R.style.AppTheme, intArrayOf(android.R.attr.forceDarkAllowed))
        try {
            assertFalse(attributes.getBoolean(0, true))
        } finally {
            attributes.recycle()
        }
        fixture {
            Text("主题文字", color = LocalContentColor.current)
        }
        fun foregroundPixels(dark: Boolean): Int {
            val image = screenshot(if (dark) "theme-dark" else "theme-light")
            val bounds = rule.onNodeWithText("主题文字").fetchSemanticsNode().boundsInRoot
            var count = 0
            for (y in bounds.top.toInt() until bounds.bottom.toInt()) {
                for (x in bounds.left.toInt() until bounds.right.toInt()) {
                    val color = image.getPixel(x, y)
                    val red = android.graphics.Color.red(color)
                    if (if (dark) red > 160 else red < 80) count++
                }
            }
            return count
        }
        assertTrue("Dark mode needs light text", foregroundPixels(true) > 20)
        runBlocking { app.settings.put("themeMode", 1) }
        assertTrue("Light mode needs dark text", foregroundPixels(false) > 20)
    }
    @Test fun settingsScrollAndSave() {
        fixture {LyricsSettingsScreen()}
        rule.onNodeWithText("歌词视图字体大小").assertIsDisplayed()
        rule.onNodeWithText("歌词视图文本居中对齐").performClick()
        rule.waitUntil(5000){!app.settings.bool("lyricCenter",true)}
        rule.onNodeWithText("卡拉 OK（逐字）歌词动画兼容策略").performScrollTo().assertIsDisplayed()
        screenshot("lyrics-settings-dark")
    }
    @Test fun glassSwitchUpdatesImmediatelyAndCanBeTurnedOffAgain() {
        fixture { ThemeSettingsScreen() }
        val row = rule.onNode(hasText("使用液态玻璃效果") and hasClickAction())
        row.performScrollTo().performTouchInput { click(centerLeft + Offset(30f, 0f)) }
        rule.waitUntil(5000) { app.settings.bool("liquidGlass") }
        val toggle = rule.onNode(isToggleable() and hasAnyAncestor(hasText("使用液态玻璃效果")))
        toggle.assertIsOn()
        toggle.performTouchInput { click() }
        rule.waitUntil(5000) { !app.settings.bool("liquidGlass") }
        toggle.assertIsOff()
        assertFalse(AppSettings(rule.activity).bool("liquidGlass"))
        val revision = app.settings.revision
        runBlocking { app.settings.putAll(mapOf("position" to 3000L,"queueIndex" to 1)) }
        assertEquals("Playback persistence must not invalidate all settings UI", revision, app.settings.revision)
    }

    @Test fun glassPreferenceActuallyChangesRetainedHomeNavigation() {
        fixture(root=true) {}
        fun settings() {
            rule.onAllNodesWithText("我的").onFirst().performClick()
            rule.onNodeWithText("设置").performScrollTo().performClick()
            rule.onNodeWithText("个性化").performClick()
        }
        val tabs = SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role, androidx.compose.ui.semantics.Role.Tab)
        repeat(2) { pass ->
            settings()
            rule.onNodeWithText("使用液态玻璃效果").performScrollTo().performClick()
            rule.waitUntil(5000) { app.settings.bool("liquidGlass") == (pass == 0) }
            rule.runOnIdle { rule.activity.onBackPressedDispatcher.onBackPressed() }
            rule.onNodeWithText("个性化").assertIsDisplayed()
            rule.runOnIdle { rule.activity.onBackPressedDispatcher.onBackPressed() }
            rule.mainClock.advanceTimeBy(400)
            rule.onAllNodes(tabs).assertCountEquals(if(pass == 0) 3 else 0)
        }
    }

    @Test fun typographyMatchesExportedFlutterGeometryInBothThemes() {
        lateinit var actual: Typography
        fixture { actual = MaterialTheme.typography; Text("字体基线") }
        val baseline = Json(javaClass.getResourceAsStream("/flutter_visual_tokens.json")!!.bufferedReader().use { it.readText() })
        for (dark in listOf(true,false)) {
            runBlocking { app.settings.put("themeMode",if(dark)2 else 1) }
            rule.runOnIdle {
                val styles = mapOf("displayLarge" to actual.displayLarge,"displayMedium" to actual.displayMedium,"displaySmall" to actual.displaySmall,
                    "headlineLarge" to actual.headlineLarge,"headlineMedium" to actual.headlineMedium,"headlineSmall" to actual.headlineSmall,
                    "titleLarge" to actual.titleLarge,"titleMedium" to actual.titleMedium,"titleSmall" to actual.titleSmall,
                    "bodyLarge" to actual.bodyLarge,"bodyMedium" to actual.bodyMedium,"bodySmall" to actual.bodySmall,
                    "labelLarge" to actual.labelLarge,"labelMedium" to actual.labelMedium,"labelSmall" to actual.labelSmall)
                styles.forEach { (name,style) ->
                    val expected=baseline.getJSONObject(if(dark)"dark" else "light").getJSONObject(name)
                    assertEquals(name,expected.getDouble("size").toFloat(),style.fontSize.value,.001f)
                    assertEquals(name,(expected.getDouble("height")*expected.getDouble("size")).toFloat(),style.lineHeight.value,.001f)
                    assertEquals(name,expected.getInt("weight"),style.fontWeight!!.weight)
                    assertEquals(name,0f,style.letterSpacing.value,.001f)
                    if(name=="titleSmall"||name=="bodySmall")assertEquals(name,expected.getLong("color").toInt(),style.color.toArgb())
                }
            }
        }
    }

    @Test fun restoredLyricsUtilityTogglesWithoutChangingTrack() {
        fixture { PlayerScreen() }; setSong()
        rule.onNodeWithContentDescription("同步歌词").performClick()
        rule.onNodeWithContentDescription("显示封面").assertIsDisplayed().performClick()
        rule.onNodeWithContentDescription("同步歌词").assertIsDisplayed()
        rule.onNodeWithText("测试歌曲").assertIsDisplayed()
        rule.runOnIdle { assertEquals(song.id,app.playback.state.value.current!!.id) }
    }

    @Test fun lyricWheelProjectionMatchesFlutterAtEveryDensity() {
        val samples=Json(javaClass.getResourceAsStream("/flutter_visual_tokens.json")!!.bufferedReader().use {it.readText()}).getJSONArray("wheel")
        for(i in 0 until samples.length())for(density in listOf(1f,1.5f,3f)) {
            val s=samples.getJSONObject(i);val point=floatArrayOf(s.getDouble("x").toFloat()*density,s.getDouble("y").toFloat()*density)
            lyricWheelProjection(s.getDouble("height").toFloat()*density,density,s.getDouble("distance").toFloat(),s.getBoolean("single")).mapPoints(point)
            assertEquals("Wheel x $i at $density",s.getDouble("expectedX").toFloat()*density,point[0],.001f)
            assertEquals("Wheel y $i at $density",s.getDouble("expectedY").toFloat()*density,point[1],.001f)
        }
    }
    @Test fun settingSliderShowsLiveValueAndPersistsOnRelease() {
        fixture {LyricsSettingsScreen()}
        val slider=rule.onAllNodes(SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsActions.SetProgress)).onFirst()
        slider.performTouchInput{down(center);moveTo(centerRight-Offset(12f,0f),delayMillis=200)}
        rule.waitForIdle()
        rule.onNode(hasContentDescription("当前值",substring=true)).assertExists()
        val before=app.settings.lyrics().fontSize
        slider.performTouchInput{up()}
        rule.waitUntil(5000){app.settings.lyrics().fontSize!=before}
        rule.onNode(hasContentDescription("当前值",substring=true)).assertDoesNotExist()
    }

    @Test fun frostedBackdropDoesNotPaintOutsideToolbar() {
        fixture {
            val layer = rememberGraphicsLayer()
            val backdrop = remember { Backdrop(layer) }
            Box(Modifier.fillMaxSize()) {
                Canvas(Modifier.matchParentSize().recordBackdrop(backdrop)) {
                    drawRect(Color.Red)
                    drawRect(Color.Blue, topLeft = Offset(0f, 80.dp.toPx()))
                }
                BackdropSurface(Modifier.fillMaxWidth().height(80.dp), backdrop)
            }
        }
        val rendered = rule.runOnIdle {
            val view = rule.activity.window.decorView
            val node = android.graphics.RenderNode("toolbar-boundary-check")
            node.setPosition(0, 0, view.width, view.height)
            view.draw(node.beginRecording()); node.endRecording()
            hardwareBitmap(node)
        }
        val density = rule.activity.resources.displayMetrics.density
        val root = rule.onRoot().fetchSemanticsNode().boundsInRoot
        val x = root.center.x.toInt()
        for (dp in 81..145) {
            assertEquals("Blur leaked below the toolbar at $dp dp", android.graphics.Color.BLUE,
                rendered.getPixel(x, (root.top + dp * density).toInt()))
        }
        val edge = rendered.getPixel(x, (root.top + 76 * density).toInt())
        assertTrue("Toolbar blur must sample content just below its boundary", android.graphics.Color.blue(edge) > 35)
    }
    @Test fun miniPlayerIsBounded() {
        fixture {Column {Box(Modifier.weight(1f));MiniPlayer()}}
        rule.runOnIdle {
            val field=Playback::class.java.getDeclaredField("mutable").apply {isAccessible=true}
            @Suppress("UNCHECKED_CAST") val state=field.get(app.playback) as MutableStateFlow<PlaybackState>
            state.value=PlaybackState(songs=listOf(song),index=0)
        }
        rule.onNodeWithText("测试歌曲").assertIsDisplayed()
        val title=rule.onNodeWithText("测试歌曲").fetchSemanticsNode().boundsInRoot
        val root=rule.onRoot().fetchSemanticsNode().boundsInRoot
        assertTrue("Mini player must stay at the bottom",title.top>root.height*.75f)
        screenshot("mini-player-dark")
    }
    @Test fun lyricsFirstFrameLocatesCurrentLine() {
        fixture {SyncedLyrics(song)}
        rule.runOnIdle {app.playback.position.value=18_000;app.playback.duration.value=240_000}
        rule.waitUntil(5000){rule.onAllNodesWithContentDescription("第 18 行测试歌词").fetchSemanticsNodes().isNotEmpty()}
        rule.onNodeWithContentDescription("第 18 行测试歌词").assertIsDisplayed().assertIsSelected()
        screenshot("lyrics-current-line")
    }
    @Test fun flutterListGeometryUsesIndependentTextAndControlPadding() {
        fixture {Column {
            Box(Modifier.testTag("single")){ListRow("Single",leading={Cover("")})}
            Box(Modifier.testTag("double")){SongRow(song,selected=true,more={},play={})}
            Box(Modifier.testTag("choice")){ChoiceRow("Choice",true,"Summary") {}}
        }}
        val density=rule.activity.resources.displayMetrics.density
        assertEquals(62f*density,rule.onNodeWithTag("single").fetchSemanticsNode().boundsInRoot.height,1f)
        assertEquals(78f*density,rule.onNodeWithTag("double").fetchSemanticsNode().boundsInRoot.height,1f)
        assertEquals(76f*density,rule.onNodeWithTag("choice").fetchSemanticsNode().boundsInRoot.height,1f)
        assertEquals(80f*density,rule.onNodeWithText("Single",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot.left,1f)
        val title=rule.onNodeWithText(song.name,useUnmergedTree=true)
        val layouts=mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        title.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult){it(layouts)}
        val row=rule.onNodeWithTag("double").fetchSemanticsNode().boundsInRoot
        assertEquals(35f*density,title.fetchSemanticsNode().boundsInRoot.top-row.top+layouts.single().firstBaseline,1f)
        screenshot("visual35-list-geometry")
    }
    @Test fun musicPageFloatsMiniPlayerOverContentAndMeasuresBottomPadding() {
        var bottom=0.dp
        fixture {MusicPage("Measured"){padding->
            SideEffect {bottom=padding.calculateBottomPadding()}
            Box(Modifier.fillMaxSize().background(Color.Red).testTag("body"))
        }}
        val initial=rule.onNodeWithTag("body").fetchSemanticsNode().boundsInRoot
        val emptyPadding=bottom
        setSong()
        assertEquals(initial,rule.onNodeWithTag("body").fetchSemanticsNode().boundsInRoot)
        assertTrue(bottom-emptyPadding>=68.dp)
        val mini=rule.onNodeWithText(song.name).fetchSemanticsNode().boundsInRoot
        val frame=screenshot("greenmusic44-secondary")
        assertEquals(Color.Red.toArgb(),frame.getPixel(2,mini.center.y.toInt()))
        assertEquals(Color.Red.toArgb(),frame.getPixel(frame.width-3,mini.center.y.toInt()))
        assertNotEquals(Color.Red.toArgb(),frame.getPixel(frame.width/2,mini.center.y.toInt()))
    }
    @Test fun openingAndClosingMusicPageMovesOneMiniPlayerBetweenAnchors() {
        val secondary=Screen("songs","列表")
        fixture {
            RetainedRoutes(ui){screen->
                if(screen.kind=="home")HomeScreen()
                else MusicPage(screen.title){Box(Modifier.fillMaxSize().background(Color.Red))}
            }
        }
        setSong()
        rule.onNodeWithContentDescription("我的").performClick()
        val home=ui.stack.first()
        val homeTop=rule.runOnIdle {ui.miniPlayerAnchors.getValue(home.id).top.toInt()}
        val nav=rule.onNodeWithContentDescription("我的").fetchSemanticsNode().boundsInRoot
        val homeFrame=screenshot("greenmusic45-home",hardware=true)
        val x=homeFrame.width/2
        val card=homeFrame.getPixel(x,homeTop+2)
        rule.mainClock.autoAdvance=false
        rule.runOnIdle {ui.go(secondary)}
        repeat(8) {rule.mainClock.advanceTimeByFrame();rule.waitForIdle()}
        val startTop=rule.runOnIdle {ui.miniPlayerAnchors.getValue(secondary.id).top.toInt()}
        assertTrue(startTop>homeTop+20)
        fun assertMidFlight(frame:Bitmap) {
            val midTop=(homeTop..startTop).first {frame.getPixel(x,it)==card}
            assertTrue(midTop in (homeTop+2) until (startTop-2))
            assertEquals(card,frame.getPixel(30,midTop+46))
        }
        assertMidFlight(screenshot("greenmusic45-enter-mid",hardware=true))
        rule.onAllNodesWithText(song.name).assertCountEquals(0)
        rule.mainClock.advanceTimeBy(350)
        rule.onAllNodesWithText(song.name).assertCountEquals(1)

        // A nested music page uses the same shared card even when both anchors have the same height.
        val nested=Screen("downloads","下载")
        rule.runOnIdle {ui.go(nested)}
        repeat(8) {rule.mainClock.advanceTimeByFrame();rule.waitForIdle()}
        rule.onAllNodesWithText(song.name).assertCountEquals(0)
        val nestedFrame=screenshot("greenmusic45-nested-mid",hardware=true)
        assertEquals(card,nestedFrame.getPixel(x,startTop+2))
        rule.mainClock.advanceTimeBy(350)
        rule.onNodeWithContentDescription("返回").performClick()
        repeat(8) {rule.mainClock.advanceTimeByFrame();rule.waitForIdle()}
        rule.onAllNodesWithText(song.name).assertCountEquals(0)
        rule.mainClock.advanceTimeBy(250)

        rule.onNodeWithContentDescription("返回").performClick()
        rule.runOnIdle {assertEquals(home,ui.stack.last())}
        repeat(8) {rule.mainClock.advanceTimeByFrame();rule.waitForIdle()}
        val mid=screenshot("greenmusic45-return-mid",hardware=true)
        assertMidFlight(mid)
        rule.onNodeWithContentDescription("我的").assertDoesNotExist()
        rule.mainClock.advanceTimeBy(250)
        rule.mainClock.autoAdvance=true
        val end=screenshot("greenmusic45-return-home",hardware=true)
        assertEquals(card,end.getPixel(x,homeTop+2))
        assertNotEquals(mid.getPixel(nav.center.x.toInt(),nav.center.y.toInt()),end.getPixel(nav.center.x.toInt(),nav.center.y.toInt()))
        rule.onNodeWithContentDescription("我的").assertIsDisplayed()
        rule.onAllNodesWithText(song.name).assertCountEquals(1)
    }
    @Test fun songSheetRestoresHeaderAndDownloadSheetRestoresRadioSelection() {
        fixture {Column {Button({songActions(ui,song,onQuality={})}){Text("Menu")};Box(Modifier.weight(1f)){ui.sheet?.invoke()}}}
        rule.onNodeWithText("Menu").performClick()
        rule.onNodeWithText(song.name).assertIsDisplayed();rule.onNodeWithText(song.artistNames).assertIsDisplayed()
        rule.onNodeWithText("播放音质").assertIsDisplayed()
        rule.runOnIdle {assertEquals(1f,ui.sheetHeight)}
        rule.onNodeWithText("下载歌曲").performClick()
        rule.onNodeWithText("默认下载音质").assertIsDisplayed()
        rule.runOnIdle {assertEquals(.75f,ui.sheetHeight)}
        screenshot("visual35-download-quality")
    }
    @Test fun collectionPlacesBatchDownloadToTheRightOfPlayAll() {
        fixture {SongsScreen(remember{Screen("songs","本地测试歌单",loader={Page(listOf(song),1,false)})})}
        rule.waitUntil(5000){rule.onAllNodesWithText(song.name).fetchSemanticsNodes().isNotEmpty()}
        val play=rule.onNodeWithText("播放全部").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val download=rule.onNodeWithText("批量下载").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertEquals(play.center.y,download.center.y,1f)
        assertTrue(play.right<download.left)
        screenshot("greenmusic43-playlist")
        rule.onNodeWithText("批量下载").performClick()
        rule.runOnIdle {assertEquals("batch",ui.stack.last().kind)}
    }
    @Test @Config(qualifiers="w280dp-h700dp-mdpi") fun collectionActionsRemainVisibleAtLargeTextOnNarrowScreens() {
        fixture(large=true){SongsScreen(remember{Screen("songs","本地测试歌单",loader={Page(listOf(song),1,false)})})}
        rule.waitUntil(5000){rule.onAllNodesWithText(song.name).fetchSemanticsNodes().isNotEmpty()}
        val play=rule.onNodeWithText("播放全部").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val download=rule.onNodeWithText("批量下载").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertTrue(play.bottom<=download.top)
    }
    @Test fun batchSelectionRetainsMiniPlayerAndUsesTrailingCheckboxes() {
        fixture {BatchDownloadScreen(remember{Screen("batch","本地测试歌单",loader={Page(listOf(song),1,false)})})}
        rule.waitUntil(5000){rule.onAllNodesWithText("全选").fetchSemanticsNodes().isNotEmpty()}
        setSong()
        rule.onNodeWithText("选择歌曲").assertIsDisplayed()
        rule.onNodeWithText("上限 256 MB").assertIsDisplayed()
        rule.onNodeWithText("已选 1 / 1 首").assertIsDisplayed()
        rule.onNodeWithText("全选").performClick()
        rule.onNodeWithText("下载所选 0 首").assertIsNotEnabled()
        rule.onNodeWithText("已选 0 / 1 首").assertIsDisplayed()
        rule.onNodeWithText("全选").performClick()
        rule.onNodeWithText("下载所选 1 首").assertIsEnabled()
        assertEquals(2,rule.onAllNodesWithText(song.name).fetchSemanticsNodes().size)
        rule.onAllNodes(isToggleable()).assertCountEquals(2).assertAll(isOn())
        rule.runOnIdle { testScope.launch { app.settings.put("downloadTree","content://test/tree/public") } }
        rule.waitUntil(5000){rule.onAllNodesWithText("公有目录").fetchSemanticsNodes().isNotEmpty()}
        rule.onNodeWithText("仅受实际可用空间限制").assertIsDisplayed()
        rule.onNodeWithText("同时下载",substring=true).assertDoesNotExist()
        screenshot("greenmusic43-batch")
    }
    @Test fun webDavValidationStaysUnderFieldsAndDoesNotStartNetworkWork() {
        fixture {WebDavScreen()}
        rule.waitUntil(5000){rule.onAllNodesWithText("测试服务器连接").fetchSemanticsNodes().isNotEmpty()}
        val field=rule.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().first().boundsInRoot
        assertEquals(48f*rule.activity.resources.displayMetrics.density,field.height,1f)
        rule.onNodeWithText("测试服务器连接").performScrollTo().performClick()
        rule.onNodeWithText("请输入 WebDAV 服务器地址").assertExists()
        rule.onNodeWithText("请输入账号").assertExists()
        rule.onNodeWithText("请输入密码或授权 Token").assertExists()
        assertEquals("WebDAV 请使用 HTTPS 地址",webDavUrlError("http://example.com"))
        assertEquals("WebDAV 请使用 HTTPS 地址",webDavUrlError("https://user:password@example.com"))
        assertNull(webDavUrlError("https://example.com/dav/"))
        rule.runOnIdle {assertTrue(app.settings.string("webdavUrl").isEmpty())}
        screenshot("visual35-webdav-validation")
    }

    @Test fun sheetOpensExpandedAndDefaultMenusHonorFlutterHeightLimit() {
        lateinit var sheetView:android.view.View
        fixture {Button({ui.sheet={val view=androidx.compose.ui.platform.LocalView.current;SideEffect{sheetView=view.rootView};Column(Modifier.verticalScroll(androidx.compose.foundation.rememberScrollState())){repeat(15){ListRow("Option $it")}}}}){Text("Open menu")};ui.sheet?.let{ReviewBottomSheet(ui,it)}}
        rule.onNodeWithText("Open menu").performClick()
        rule.waitForIdle()
        val first=rule.onNodeWithText("Option 0",useUnmergedTree=true).fetchSemanticsNode().boundsInWindow
        val density=rule.activity.resources.displayMetrics.density
        val screenHeight=rule.activity.resources.configuration.screenHeightDp*density
        val dialog=rule.onNode(isDialog()).fetchSemanticsNode().boundsInWindow
        assertEquals("Default menu opens fully at Flutter's 9/16 height",dialog.bottom-screenHeight*(9f/16f)+69*density,first.top,2*density)
        rule.onNodeWithText("Option 14").performScrollTo().assertIsDisplayed()
        screenshot("visual35-sheet",sheetView)
    }

    private fun assertCurrentLyricsNearViewportCenter(large:Boolean=false) {
        fixture(large=large){PlayerScreen()};setSong()
        rule.onNodeWithContentDescription("同步歌词").performClick()
        for(index in listOf(0,18,24)) {
            rule.runOnIdle{app.playback.position.value=index*1000L}
            rule.waitUntil(5000){rule.onAllNodesWithContentDescription("第 $index 行测试歌词").fetchSemanticsNodes().isNotEmpty()}
            rule.waitForIdle()
            val line=hasContentDescription("第 $index 行测试歌词")
            val current=rule.onNode(line).assertIsSelected().fetchSemanticsNode().boundsInRoot
            val viewport=rule.onNode(hasScrollAction() and hasAnyDescendant(line)).fetchSemanticsNode().boundsInRoot
            assertEquals("First, middle and last lyric must reach the anchor inside the lyrics viewport",
                viewport.top+viewport.height*.47f,current.center.y,2*rule.activity.resources.displayMetrics.density)
            if(index==18) screenshot(if(large)"player38-lyrics-landscape"else "player38-lyrics-center")
        }
    }
    @Test fun fullPlayerCentersFirstMiddleAndLastLyricsWithinViewport(){assertCurrentLyricsNearViewportCenter()}
    @Test @Config(qualifiers="w892dp-h412dp-hdpi") fun landscapeLyricsCenterWithLargeText(){assertCurrentLyricsNearViewportCenter(true)}
    @Test fun karaokeSweepsInAccentColorInLightAndDarkThemes() {
        var accent=0
        var preview by mutableStateOf(false)
        fixture {val color=MaterialTheme.colorScheme.primary;SideEffect{accent=color.toArgb()};SyncedLyrics(song,preview=preview)}
        fun accentPixels():Int {
            val bounds=rule.onNodeWithContentDescription("第 18 行测试歌词").fetchSemanticsNode().boundsInRoot
            val bitmap=screenshot("player36-karaoke-${app.settings.int("themeMode")}")
            var count=0
            for(y in bounds.top.toInt().coerceAtLeast(0) until bounds.bottom.toInt().coerceAtMost(bitmap.height))for(x in bounds.left.toInt().coerceAtLeast(0) until bounds.right.toInt().coerceAtMost(bitmap.width)){
                val pixel=bitmap.getPixel(x,y)
                if(kotlin.math.abs(android.graphics.Color.red(pixel)-android.graphics.Color.red(accent))<5&&kotlin.math.abs(android.graphics.Color.green(pixel)-android.graphics.Color.green(accent))<5&&kotlin.math.abs(android.graphics.Color.blue(pixel)-android.graphics.Color.blue(accent))<5)count++
            }
            return count
        }
        for(mode in listOf(2,1)) {
            rule.runOnIdle {testScope.launch{app.settings.put("themeMode",mode)};app.playback.position.value=18_000}
            rule.waitUntil(5000){app.settings.int("themeMode")==mode&&rule.onAllNodesWithContentDescription("第 18 行测试歌词").fetchSemanticsNodes().isNotEmpty()};rule.waitForIdle()
            val start=accentPixels()
            rule.runOnIdle{app.playback.position.value=18_500};rule.waitForIdle()
            val partial = accentPixels()
            assertTrue("Sung words must visibly use the accent, not a white/gray fade",partial>start+50)
            rule.runOnIdle { preview=true }
            assertEquals("The slide preview must show the same partial karaoke progress",partial,accentPixels())
            rule.runOnIdle { preview=false }
        }
        rule.runOnIdle{testScope.launch{app.settings.put("lyricKaraoke",KaraokeMode.Off.ordinal)}}
        rule.waitUntil(5000){app.settings.lyrics().karaoke==KaraokeMode.Off};rule.waitForIdle()
        assertEquals("Disabling karaoke restores normal whole-line highlighting",0,accentPixels())
    }
    @Test fun playerRetainsBothPanesDuringButtonAndSwipeTransitions() {
        var lyrics by mutableStateOf(false)
        val mounts = IntArray(2)
        fixture {
            SwipeFrame(1L to lyrics, { if(it>0)!lyrics else lyrics }, { lyrics=it>0 },
                Modifier.fillMaxWidth().height(220.dp), retainedPane=if(lyrics)1 else 0) { step ->
                val pane = (if(lyrics)1 else 0) + step
                DisposableEffect(Unit) { mounts[pane]++; onDispose {} }
                Box(Modifier.fillMaxSize().testTag(if(pane==0)"cover-pane" else "lyrics-pane"))
            }
        }
        rule.runOnIdle { lyrics=true }
        rule.onNodeWithTag("lyrics-pane").assertIsDisplayed()
        rule.onNodeWithTag("lyrics-pane").performTouchInput { swipeRight() }
        rule.onNodeWithTag("cover-pane").assertIsDisplayed()
        rule.runOnIdle { assertArrayEquals(intArrayOf(1,1),mounts) }
    }
    @Test fun settingsGroupsAreClearAndObviousRowsHaveNoExplanatorySubtitles() {
        fixture{SettingsScreen()}
        listOf("外观与交互","播放与歌词","下载与存储","账号与备份","关于").forEach{rule.onNodeWithText(it).assertExists()}
        listOf("字号、对齐与歌词动效","查看、播放与删除已下载歌曲","音质、保存位置与 LRC 歌词","封面内存缓存与下载管理入口","备份与恢复设置、队列和最近播放").forEach{rule.onNodeWithText(it).assertDoesNotExist()}
        rule.onNodeWithText("歌词界面").assertIsDisplayed()
        screenshot("settings36-top")
        rule.onNodeWithText("WebDAV备份").performScrollTo().assertIsDisplayed()
        screenshot("settings36-bottom")
        rule.onNodeWithText("WebDAV备份").performClick()
        rule.runOnIdle{assertEquals("webdav",ui.stack.last().kind)}
    }

}
