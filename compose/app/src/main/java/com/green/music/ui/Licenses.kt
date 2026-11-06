package com.green.music.ui
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.green.music.BuildConfig

private val licenses=listOf(
    Triple("Lilt","AGPL-3.0","AGPL-3.0"),Triple("Review","MIT","Review-MIT"),Triple("liquid_glass_widgets","MIT","LiquidGlass-MIT"),Triple("Glass renderer attribution","MIT · upstream notices","LiquidGlass-notices"),
    Triple("Flutter · 歌词投影与滑块形状","BSD-3-Clause","Flutter-BSD"),Triple("dynamic_color","Apache-2.0","Apache-2.0"),
    Triple("AndroidX · Compose · Media3","Apache-2.0","Apache-2.0"),Triple("Kotlin · kotlinx.coroutines","Apache-2.0","Apache-2.0"),
    Triple("Material Components · Material Color Utilities · Material Icons","Apache-2.0","Apache-2.0"),Triple("OkHttp · Okio · Coil","Apache-2.0","Apache-2.0"),Triple("Guava · Error Prone","Apache-2.0","Apache-2.0"))
@Composable fun LicensesScreen() {
    val ui=LocalUi.current
    ReviewPage("开源许可"){insets->LazyColumn(contentPadding=insets){
        item{Column(Modifier.fillMaxWidth().padding(24.dp),horizontalAlignment=Alignment.CenterHorizontally){Text("GreenMusic",style=MaterialTheme.typography.headlineSmall);Text(BuildConfig.VERSION_NAME);Spacer(Modifier.height(16.dp));Text("音乐接口复用 Lilt；Material 3 界面复用 Review。",textAlign=TextAlign.Center)}}
        items(licenses){license->PreferenceRow(license.first,license.second){ui.go(Screen("licenseText",license.first,license.third))}}
    }}
}
@Composable fun LicenseTextScreen(screen:Screen) {
    val context=LocalContext.current;val text=remember(screen.data){context.assets.open("licenses/${screen.data}").bufferedReader().use{it.readText()}}
    ReviewPage(screen.title){insets->Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(insets).padding(16.dp)){SelectionContainerText(text)}}
}
@Composable private fun SelectionContainerText(text:String){androidx.compose.foundation.text.selection.SelectionContainer{Text(text,style=MaterialTheme.typography.bodySmall)}}
