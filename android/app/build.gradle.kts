import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.moontechlab.lunatv"
    compileSdk = 36
    ndkVersion = "29.0.14033849"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "org.moontechlab.lunatv"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        // 从 pubspec.yaml 读 version (经 workflow sed 同步)
        // Kotlin DSL 里 flutter.versionCode/versionName 是方法, 调用方式不稳定
        // 直接解析 pubspec.yaml 最稳
        val pubspecFile = rootProject.file("../pubspec.yaml")
        val versionLine = pubspecFile.readLines().first { it.startsWith("version:") }
        val versionStr = versionLine.substringAfter("version:").trim()
        // 格式: <name>+<code> 或只有 <name> (无 + 后缀, 默认 code=1)
        val parts = versionStr.split("+")
        versionName = parts[0]
        versionCode = if (parts.size > 1) parts[1].toInt() else 1

        ndk {
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a"))
        }
    }

    // 固定 release 签名 (keystore 提交在仓库 android/app/release.keystore)
    // 每次 CI 构建签名一致, 可以正常覆盖安装
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
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        debug {
            isMinifyEnabled = false
        }
    }
}

flutter {
    source = "../.."
}

// v2.1.33: OkHttp 给 ImageHttpChannel (Kotlin MethodChannel handler) 用
//   - Android 系统库 Conscrypt/BoringSSL, 全 TLS 1.3 cipher 支持
//   - dart:io 没 public API 强制 TLS 版本, dart:io 的 OpenSSL 跟
//     CF edge zone (e.g., api.fn0.qzz.io) TLS 1.3 cipher 协商失败
//     (SSLV3_ALERT_HANDSHAKE_FAILURE alert 40). OkHttp 可以强制 TLS 1.2,
//     cipher 列表宽得多, 跟所有 CF zone 都有重叠.
//   - 不影响视频 m3u8 播放 (CustomExoPlayer 走原生 ExoPlayer, 完全独立)
// v2.3.11: ExoPlayer 现在直接由 CustomExoPlayerChannel.kt 持有, 不再
//   走 video_player Flutter package. Dart 端不依赖 video_player 抽象,
//   全部通过自研 MethodChannel (org.moontechlab.lunatv/custom_exo_player)
//   直接调原生 ExoPlayer + 自配 DefaultLoadControl (min=30s/max=90s).
dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // v2.2.0+: ExoPlayer (AndroidX Media3) 原生依赖. v2.3.11 之前是
    //   Dart 端 video_player ^2.10.1 内部依赖 media3 1.4.x, 现在直接
    //   走 CustomExoPlayerChannel.kt 调原生, 显式列出来确保版本一致.
    //   之前 libmpv 走的 .so, ~30MB; ExoPlayer 纯 Java, 减小包体积.
    //   1.4.x 是稳定版.
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.4.1")      // HLS
    implementation("androidx.media3:media3-exoplayer-dash:1.4.1")     // DASH
    implementation("androidx.media3:media3-ui:1.4.1")                 // PlayerView
    implementation("androidx.media3:media3-datasource-okhttp:1.4.1")  // OkHttp DataSource
    implementation("androidx.media3:media3-common:1.4.1")
}
