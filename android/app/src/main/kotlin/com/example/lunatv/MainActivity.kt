package org.moontechlab.lunatv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // v2.1.33: 注册 [ImageHttpChannel] (OkHttp + 强制 TLS 兼容模式),
    //   避开 dart:io TLS 1.3 cipher 跟 CF edge zone 协商失败
    //   (SSLV3_ALERT_HANDSHAKE_FAILURE). 不影响视频 m3u8 播放 (libmpv).
    // v2.1.46: 注册 [ApkInstallChannel] — app 内建下载器下完 APK 后,
    //   用 FileProvider 把 file:// 转 content:// 调起系统 APK 安装器.
    //   跟 [ImageHttpChannel] 平行, 自己写 channel 不用第三方 pub package.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ImageHttpChannel(flutterEngine.dartExecutor.binaryMessenger)
        ApkInstallChannel(flutterEngine.dartExecutor.binaryMessenger, this)
        // v2.2.0+59: 屏幕常亮 channel — 播放视频时 Flutter 端调
        //   setKeepScreenOn(true) 阻止系统屏保, 离开播放页时
        //   setKeepScreenOn(false) 还原. 走 Activity.window FLAG_KEEP_SCREEN_ON,
        //   Activity 不可见时 (切后台) OS 自动失效, 不用管 lifecycle.
        KeepScreenOnChannel(flutterEngine.dartExecutor.binaryMessenger, this)
        // v2.5.18: 物理音量键 channel — 拦截 KEYCODE_VOLUME_UP/DOWN/MUTE,
        //   不让系统默认 adjustStreamVolume 弹系统音量条. 转发到 Dart 端,
        //   Dart 端走 volume_controller 3.4.4 (showSystemUI=false) 调音量.
        VolumeKeyChannel.configure(flutterEngine, this)
        // 注册红果短剧原生签名解析与 CENC 解密通道 (对齐 hongguoTV)
        io.flutter.plugin.common.MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.lunatv/hongguo_resolver").setMethodCallHandler { call, result ->
            when (call.method) {
                "resolveStream" -> {
                    val vid = call.argument<String>("vid") ?: ""
                    val maxQuality = call.argument<Int>("maxQuality") ?: 1080
                    Thread {
                        try {
                            val res = org.moontechlab.lunatv.hongguo.HongguoStreamResolver.resolve(vid, maxQuality)
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("RESOLVE_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "fetchEpisodeVids" -> {
                    val seriesId = call.argument<String>("seriesId") ?: ""
                    Thread {
                        try {
                            val vids = org.moontechlab.lunatv.hongguo.HongguoStreamResolver.fetchEpisodeVids(seriesId)
                            runOnUiThread { result.success(vids) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("FETCH_ERROR", e.message, null) }
                        }
                    }.start()
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    // v2.5.18: 物理音量键拦截 — super.dispatchKeyEvent 会调
    //   AudioManager.adjustStreamVolume 弹系统音量条, 必须先于 super
    //   拦截. VolumeKeyChannel.onKeyEvent 内部判断 enabled + 是否
    //   音量键, 是音量键且 enabled 时返回 true 消费 (不放行到 super).
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (VolumeKeyChannel.onKeyEvent(event)) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}
