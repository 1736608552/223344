import java.io.FileInputStream
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.androidx.baselineprofile)
    kotlin("plugin.serialization") version "2.1.0"
}

// 稳定签名：从仓库根目录 key.properties 读取密码/别名，storeFile 默认指向已提交的 key.jks。
// CI 在构建前用 secrets 写出 key.properties；本地缺失时回退 debug 签名，保证可正常编译。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) FileInputStream(keystorePropsFile).use { load(it) }
}
val keystoreFile = rootProject.file(keystoreProps.getProperty("storeFile") ?: "key.jks")
val hasReleaseSigning = keystorePropsFile.exists() && keystoreFile.exists()

// 动态从 Monorepo 根目录 pubspec.yaml 或环境变量同步全端版本号
val pubspecFile = rootProject.file("../pubspec.yaml")
val (resolvedVersionName, resolvedVersionCode) = if (pubspecFile.exists()) {
    val versionLine = pubspecFile.readLines().firstOrNull { it.trim().startsWith("version:") } ?: ""
    val rawVersion = versionLine.substringAfter("version:").trim()
    val vName = rawVersion.substringBefore("+").trim().ifEmpty { "2.6.133" }
    val vCode = rawVersion.substringAfter("+", "20733").trim().toIntOrNull() ?: 20733
    vName to vCode
} else {
    (System.getenv("APP_VERSION") ?: "2.6.135") to (System.getenv("APP_BUILD_NUMBER")?.toIntOrNull() ?: 20735)
}

android {
    namespace = "org.moontechlab.selenetv"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.moontechlab.selenetv"
        minSdk = 23
        targetSdk = 36
        versionCode = resolvedVersionCode
        versionName = resolvedVersionName

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    flavorDimensions += "channel"
    productFlavors {
        create("standard") {
            dimension = "channel"
        }
        create("hisense") {
            dimension = "channel"
            applicationIdSuffix = ".hisense"
            versionNameSuffix = "-hisense"
        }
    }

    signingConfigs {
        create("release") {
            storeFile = file("release.keystore")
            storePassword = "lunatv2024"
            keyAlias = "lunatv"
            keyPassword = "lunatv2024"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources {
            excludes += listOf(
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties"
            )
        }
    }
    splits {
        abi {
            // 开启分包功能
            isEnable = true

            // 重置默认列表（默认包含所有架构）
            reset()

            // 明确指定要分离的架构
            // 注意：armv8 对应 "arm64-v8a"，armv7a 对应 "armeabi-v7a"
            include("arm64-v8a", "armeabi-v7a")

            // 不生成通用包，严格分离 a8v 和 v7a
            isUniversalApk = false
        }
    }
}

dependencies {

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation("androidx.compose.material:material-icons-extended:1.7.5")
    implementation("androidx.tv:tv-material:1.1.0-alpha01")
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")
    implementation(libs.androidx.compose.animation.core)
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.exoplayer.hls)
    implementation(libs.androidx.media3.ui)
    implementation(libs.androidx.media3.datasource.okhttp)
    implementation(libs.androidx.media3.extractor)
    implementation(libs.libmpv)

    // Baseline Profile：运行期安装由 :baselineprofile 生成、随 release 打包的 app 级 profile（AOT 热路径）
    implementation(libs.androidx.profileinstaller)
    baselineProfile(project(":baselineprofile"))

    // Ktor Server
    implementation("io.ktor:ktor-server-core:2.3.12")
    implementation("io.ktor:ktor-server-netty:2.3.12")
    implementation("io.ktor:ktor-server-html-builder:2.3.12")
    
    // QRCode
    implementation("io.github.g0dkar:qrcode-kotlin:4.2.0")
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}