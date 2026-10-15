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
        // 从 pubspec.yaml 读 version (经 workflow perl 同步)
        val pubspecFile = rootProject.file("../pubspec.yaml")
        val versionLine = pubspecFile.readLines().first { it.startsWith("version:") }
        val versionStr = versionLine.substringAfter("version:").trim()
        val parts = versionStr.split("+")
        val nameStr = parts[0]
        versionName = nameStr

        // 自动计算三段式单调递增版本码: major * 10000 + minor * 100 + patch
        // 例如 2.6.89 -> 20689, 远大于历史旧版本 (1 或 88), 彻底根除 INSTALL_FAILED_VERSION_DOWNGRADE (-25)
        val semverCode = try {
            val semParts = nameStr.split(".")
            val major = semParts.getOrNull(0)?.toIntOrNull() ?: 2
            val minor = semParts.getOrNull(1)?.toIntOrNull() ?: 0
            val patch = semParts.getOrNull(2)?.toIntOrNull() ?: 0
            major * 10000 + minor * 100 + patch
        } catch (_: Exception) {
            20689
        }
        val explicitCode = if (parts.size > 1) parts[1].toIntOrNull() ?: 0 else 0
        versionCode = if (explicitCode > semverCode) explicitCode else semverCode

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

    packaging {
        resources {
            excludes += listOf(
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties",
                "META-INF/*.version",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/license.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/notice.txt",
                "META-INF/ASL2.0",
                "META-INF/AL2.0",
                "META-INF/LGPL2.1"
            )
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
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")
}
