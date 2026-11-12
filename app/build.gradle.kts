import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.green.music"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.green.music"
        minSdk = 24
        targetSdk = 36
        versionCode = 50
        versionName = "1.2.18"
        ndk { abiFilters += "arm64-v8a" }
    }
    val signingRoot = rootProject.file(".local/signing")
    val keyFile = signingRoot.resolve("key.properties")
    val releaseSigning = if (keyFile.exists()) {
        val key = Properties().apply { keyFile.inputStream().use { load(it) } }
        signingConfigs.create("release") {
            storeFile = signingRoot.resolve(key.getProperty("storeFile"))
            storeType = key.getProperty("storeType", "PKCS12")
            storePassword = key.getProperty("storePassword")
            keyAlias = key.getProperty("keyAlias")
            keyPassword = key.getProperty("keyPassword")
        }
    } else null
    buildTypes {
        release {
            signingConfig = releaseSigning
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests.isReturnDefaultValues = true; unitTests.isIncludeAndroidResources = true }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
dependencies {
    implementation("io.github.kyant0:backdrop:1.0.6")
    implementation("com.github.QWEA0:liquidglass:v2.0.11")
    implementation(platform("androidx.compose:compose-bom:2026.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("com.google.android.material:material:1.14.0")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.media3:media3-exoplayer:1.9.2")
    implementation("androidx.media3:media3-session:1.9.2")
    implementation("androidx.media3:media3-datasource-okhttp:1.9.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("org.robolectric:robolectric:4.16")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.compose.ui:ui-test-manifest")
}

// A transitive runtime upgrade must not leave app bytecode compiled against an older Compose API.
val verifyComposeAlignment by tasks.registering {
    doLast {
        val report = mutableListOf<String>()
        val mismatches = mutableListOf<String>()
        for (variant in listOf("debug", "release")) {
            fun versions(suffix: String) = configurations.getByName(variant + suffix)
                .incoming.resolutionResult.allComponents.mapNotNull { it.moduleVersion }
                .filter { it.group.startsWith("androidx.compose.") }
                .associate { "${it.group}:${it.name}" to it.version }
            val compile = versions("CompileClasspath")
            val runtime = versions("RuntimeClasspath")
            for ((module, version) in compile.toSortedMap()) {
                val packaged = runtime[module]
                val line = "$variant $module compile=$version runtime=$packaged"
                report += line
                if (version != packaged) mismatches += line
            }
        }
        val output = layout.buildDirectory.file("reports/compose-alignment.txt").get().asFile
        output.parentFile.mkdirs()
        output.writeText(report.joinToString("\n"))
        check(mismatches.isEmpty()) { "Compose compile/runtime mismatch:\n" + mismatches.joinToString("\n") }
        logger.lifecycle("Compose compile/runtime alignment verified for debug and release")
    }
}
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(verifyComposeAlignment) }
