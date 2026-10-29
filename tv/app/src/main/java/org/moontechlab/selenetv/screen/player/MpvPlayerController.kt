package org.moontechlab.selenetv.screen.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import dev.jdtech.mpv.MPVLib
import org.moontechlab.selenetv.service.AppDataService
import org.moontechlab.selenetv.service.MediaHttp

/**
 * 基于 libmpv 的 VideoPlayer 实现。仅在 API>=26 由 PlayerFactory 构造。
 * 状态通过 MPVLib 属性观察回调（工作线程）切回主线程更新。
 *
 * 注：libmpv 1.0.0（dev.jdtech.mpv）为实例式 API——`MPVLib.create(ctx)` 返回实例，
 * 其余 init/destroy/attachSurface/command/setOptionString/observeProperty/addObserver 等均为实例方法；
 * 格式/事件常量在嵌套对象 `MPVLib.MpvFormat` / `MPVLib.MpvEvent` 中。
 */
class MpvPlayerController(
    context: Context,
    userAgent: String?,
    decodeMode: AppDataService.DecodeMode,
) : VideoPlayer, MPVLib.EventObserver {

    private val mpv: MPVLib = MPVLib.create(context)!!

    private val main = Handler(Looper.getMainLooper())
    private var pendingUrl: String? = null
    private var pendingStartMs: Long = 0
    private var pendingPlayWhenReady: Boolean = true
    private var pendingDecryptionKey: String? = null
    private var pendingHeaders: Map<String, String>? = null
    private var surfaceAttached = false
    @Volatile private var released = false

    // 切频道/切集用 loadfile ... replace 会让「旧文件」先收到一个 END_FILE(stop)。
    // EventObserver 只给 event(id)、拿不到结束原因，无法区分「旧文件被替换」与「新文件加载失败」。
    // 故记录：当前是否有文件在播(fileActive)，以及 replace 时应忽略的旧文件停止事件数(pendingStopEndFiles)。
    // 这些变量只在主线程读写（doLoad 与 event 的 main.post 回调都在主线程）。
    private var fileActive = false
    private var pendingStopEndFiles = 0

    override var positionMs by mutableLongStateOf(0L); private set
    override var durationMs by mutableLongStateOf(0L); private set
    override var bufferedMs by mutableLongStateOf(0L); private set
    override var isPlaying by mutableStateOf(false); private set
    override var isBuffering by mutableStateOf(false); private set
    override var error by mutableStateOf<String?>(null); private set
    override var hasStarted by mutableStateOf(false); private set
    override var onEnded: () -> Unit = {}
    override var speed: Float = 1f
        set(value) {
            field = value
            if (!released) mpv.setPropertyString("speed", value.toString())
        }

    override var resizeMode: VideoResizeMode = VideoResizeMode.FIT
        set(value) {
            field = value
            if (released) return
            when (value) {
                VideoResizeMode.FIT -> {
                    mpv.setPropertyString("keepaspect", "yes")
                    mpv.setPropertyString("panscan", "0")
                }
                VideoResizeMode.ZOOM -> {
                    mpv.setPropertyString("keepaspect", "yes")
                    mpv.setPropertyString("panscan", "1.0")
                }
                VideoResizeMode.FILL -> {
                    mpv.setPropertyString("keepaspect", "no")
                    mpv.setPropertyString("panscan", "0")
                }
            }
        }

    private val currentDecodeMode = decodeMode

    init {
        mpv.setOptionString("vo", "gpu")
        mpv.setOptionString("gpu-context", "android")
        mpv.setOptionString("force-window", "yes")
        mpv.setOptionString("tls-verify", "no")
        mpv.setOptionString("ytdl", "no")
        when (decodeMode) {
            AppDataService.DecodeMode.HARDWARE -> {
                // 优先直通（零拷贝）MediaCodec，失败再退回拷，最后软解。
                // API < 26 时不支持 AImageReader，安全使用 mediacodec-copy 避免奔溃。
                if (android.os.Build.VERSION.SDK_INT >= 26) {
                    mpv.setOptionString("hwdec", "mediacodec,mediacodec-copy")
                } else {
                    mpv.setOptionString("hwdec", "mediacodec-copy")
                }
                mpv.setOptionString("hwdec-codecs", "h264,hevc,vp9,av1")
            }
            AppDataService.DecodeMode.SOFTWARE -> mpv.setOptionString("hwdec", "no")
        }
        userAgent?.let { mpv.setOptionString("user-agent", MediaHttp.resolveLiveUa(it)) }

        val mpvCache = org.moontechlab.selenetv.util.DeviceMemoryManager.getMpvCacheConfig(context)
        mpv.setOptionString("cache", "yes")
        mpv.setOptionString("demuxer-readahead-secs", mpvCache.readaheadSecs)
        mpv.setOptionString("demuxer-max-bytes", mpvCache.maxBytes)
        mpv.setOptionString("demuxer-max-back-bytes", mpvCache.maxBackBytes)
        // FFmpeg(libavformat) 层 HTTP 透明重连
        mpv.setOptionString(
            "stream-lavf-o",
            "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2",
        )

        mpv.init()
        mpv.observeProperty("time-pos", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("duration", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("demuxer-cache-time", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("pause", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("paused-for-cache", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("eof-reached", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.addObserver(this)
    }

    override fun load(url: String, startMs: Long, playWhenReady: Boolean) {
        load(url, startMs, playWhenReady, null, null)
    }

    override fun load(
        url: String,
        startMs: Long,
        playWhenReady: Boolean,
        decryptionKey: String?,
        headers: Map<String, String>?,
    ) {
        error = null
        hasStarted = false
        positionMs = 0; durationMs = 0; bufferedMs = 0
        isBuffering = true
        if (!surfaceAttached) {
            pendingUrl = url
            pendingStartMs = startMs
            pendingPlayWhenReady = playWhenReady
            pendingDecryptionKey = decryptionKey
            pendingHeaders = headers
            return
        }
        doLoad(url, startMs, playWhenReady, decryptionKey, headers)
    }

    private fun doLoad(
        url: String,
        startMs: Long,
        playWhenReady: Boolean,
        decryptionKey: String? = null,
        headers: Map<String, String>? = null,
    ) {
        if (fileActive) pendingStopEndFiles++
        fileActive = true

        val rawKey = decryptionKey?.trim() ?: ""
        val cleanKey = if (rawKey.matches(Regex("^[0-9a-fA-F]{32}$"))) rawKey.lowercase() else ""
        if (cleanKey.isNotEmpty()) {
            // 对齐手机端成熟的解密推流配置：必须包含 protocol_whitelist=[http,https,tcp,tls,crypto,data,file]
            val lavfOptions = listOf(
                "seg_max_retry=3",
                "strict=experimental",
                "allowed_extensions=ALL",
                "protocol_whitelist=[http,https,tcp,tls,crypto,data,file]",
                "decryption_key=$cleanKey"
            ).joinToString(",")
            try {
                mpv.setPropertyString("demuxer-lavf-o", lavfOptions)
                mpv.setPropertyString("network-timeout", "10")
                // 极速探测起播：缩短 lavf 分析时长与探测尺寸，大幅缩短首帧与起播等待
                mpv.setPropertyString("demuxer-lavf-analyzeduration", "1000000")
                mpv.setPropertyString("demuxer-lavf-probesize", "1048576")
                mpv.setPropertyString("force-seekable", "yes")
                mpv.setPropertyString("hr-seek", "default")
                // 核心：严格遵循用户设置中选择的解码方式 (硬解 / 软解)
                val activeDecodeMode = org.moontechlab.selenetv.service.AppDataService.getDecodeModeSync()
                when (activeDecodeMode) {
                    org.moontechlab.selenetv.service.AppDataService.DecodeMode.HARDWARE -> {
                        // 100% 对齐手机端短剧成熟方案：统一采用 auto-safe，硬件零拷贝优先，异常自动回退软解
                        mpv.setPropertyString("hwdec", "auto-safe")
                        mpv.setPropertyString("hwdec-codecs", "all")
                    }
                    org.moontechlab.selenetv.service.AppDataService.DecodeMode.SOFTWARE -> {
                        // 软解模式：走纯 CPU 软解，100% 杜绝机顶盒硬件黑屏
                        mpv.setPropertyString("hwdec", "no")
                        // 极致多核软解性能调优：开启多线程并发与快速解码算法，彻底杜绝慢放与掉帧
                        val cpuCores = Runtime.getRuntime().availableProcessors().coerceIn(2, 4)
                        mpv.setPropertyString("vd-lavc-threads", cpuCores.toString())
                        mpv.setPropertyString("vd-lavc-fast", "yes")
                        mpv.setPropertyString("vd-lavc-skiploopfilter", "nonkey")
                    }
                }
                // 核心音画同步保障：设为 no 防止强制丢帧，音画双时钟对齐
                mpv.setPropertyString("framedrop", "no")
                mpv.setPropertyString("video-sync", "audio")
                mpv.setPropertyString("scale", "bilinear")
                mpv.setPropertyString("audio-pitch-correction", "no")
                mpv.setPropertyString("autosync", "0")
            } catch (e: Exception) {
                android.util.Log.w("MpvPlayerController", "短剧属性注入异常: ${e.message}")
            }
        } else {
            try {
                mpv.setPropertyString("demuxer-lavf-o", "")
                val activeDecodeMode = org.moontechlab.selenetv.service.AppDataService.getDecodeModeSync()
                when (activeDecodeMode) {
                    AppDataService.DecodeMode.HARDWARE -> {
                        mpv.setPropertyString("hwdec", "auto-safe")
                        mpv.setPropertyString("hwdec-codecs", "h264,hevc,vp9,av1")
                    }
                    AppDataService.DecodeMode.SOFTWARE -> {
                        mpv.setPropertyString("hwdec", "no")
                        val cpuCores = Runtime.getRuntime().availableProcessors().coerceIn(2, 4)
                        mpv.setPropertyString("vd-lavc-threads", cpuCores.toString())
                        mpv.setPropertyString("vd-lavc-fast", "yes")
                    }
                }
            } catch (_: Exception) {}
        }

        if (!headers.isNullOrEmpty()) {
            headers["User-Agent"]?.let { try { mpv.setPropertyString("user-agent", it) } catch (_: Exception) {} }
            headers["user-agent"]?.let { try { mpv.setPropertyString("user-agent", it) } catch (_: Exception) {} }
            headers["Referer"]?.let { try { mpv.setPropertyString("referrer", it) } catch (_: Exception) {} }
            headers["referer"]?.let { try { mpv.setPropertyString("referrer", it) } catch (_: Exception) {} }
            val commaHeaders = headers.entries.joinToString(",") { "${it.key}: ${it.value}" }
            try {
                mpv.setPropertyString("http-header-fields", commaHeaders)
            } catch (_: Exception) {}
        }

        val startSec = (startMs / 1000.0).coerceAtLeast(0.0)
        if (startSec > 0) {
            try { mpv.setPropertyString("start", startSec.toString()) } catch (_: Exception) {}
        } else {
            try { mpv.setPropertyString("start", "none") } catch (_: Exception) {}
        }
        mpv.command(arrayOf("loadfile", url, "replace"))
        mpv.setPropertyString("pause", if (playWhenReady) "no" else "yes")
    }

    override fun seekTo(ms: Long) {
        mpv.command(arrayOf("seek", (ms / 1000.0).coerceAtLeast(0.0).toString(), "absolute"))
    }

    override fun togglePlay() {
        mpv.setPropertyString("pause", if (isPlaying) "yes" else "no")
    }

    override fun pause() { mpv.setPropertyString("pause", "yes") }

    // mpv 直播流通常不可 seek，解暂停后自然回到边缘；此处 no-op 即可。
    override fun seekToLiveEdge() {}

    override fun syncProgress() { /* MPV 走属性回调推送，无需主动拉取 */ }

    override fun clearError() {
        main.post {
            if (!released) error = null
        }
    }

    override fun release() {
        if (released) return
        released = true
        mpv.removeObserver(this)
        // mpv.destroy()（尤其硬解 MediaCodec teardown）在主线程会阻塞 ~150ms，正好落在返回直播 tab
        // 的焦点还原窗口内（还原协程也跑在主线程），把它挤占/饿死 → 焦点还原偶发失败或抖动。
        // 放到后台线程释放：此时已 removeObserver、surface 也已在 surfaceDestroyed 里 detach，
        // 不会再有其它 MPVLib 调用与之并发。
        val player = mpv
        Thread({
            try { player.command(arrayOf("stop")); player.destroy() } catch (_: Throwable) {}
        }, "mpv-release").start()
    }

    // ---- MPVLib.EventObserver（工作线程回调，切主线程更新 Compose 状态）----
    override fun eventProperty(property: String) {}
    override fun eventProperty(property: String, value: Long) {}
    override fun eventProperty(property: String, value: Boolean) {
        main.post {
            if (released) return@post
            when (property) {
                "pause" -> isPlaying = !value
                "paused-for-cache" -> isBuffering = value
                "eof-reached" -> if (value) onEnded()
            }
        }
    }
    override fun eventProperty(property: String, value: Double) {
        main.post {
            if (released) return@post
            when (property) {
                "time-pos" -> {
                    positionMs = (value * 1000).toLong().coerceAtLeast(0)
                    // 首帧到达：起播完成，关掉初始加载月牙（之后的重缓冲交回 paused-for-cache）。
                    if (!hasStarted && value > 0) { hasStarted = true; isBuffering = false }
                }
                "duration" -> durationMs = (value * 1000).toLong().coerceAtLeast(0)
                "demuxer-cache-time" -> bufferedMs = (value * 1000).toLong().coerceAtLeast(0)
            }
        }
    }
    override fun eventProperty(property: String, value: String) {}
    override fun event(eventId: Int) {
        if (eventId == MPVLib.MpvEvent.MPV_EVENT_END_FILE) main.post {
            if (released) return@post
            // 旧文件因 replace 停止：吞掉，不算失败（切频道/切集的正常现象）。
            if (pendingStopEndFiles > 0) { pendingStopEndFiles--; return@post }
            fileActive = false
            // 走到这里是「新文件」自己结束：未起播过即视为加载失败（死链/无法解码）。
            if (!hasStarted) error = "mpv: playback failed"
        }
    }

    @Composable
    override fun VideoSurface(modifier: Modifier) {
        AndroidView(
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            if (released) return
                            try {
                                mpv.attachSurface(holder.surface)
                                mpv.setPropertyString("vo", "gpu")
                            } catch (_: Throwable) {}
                            surfaceAttached = true
                            pendingUrl?.let {
                                doLoad(it, pendingStartMs, pendingPlayWhenReady, pendingDecryptionKey, pendingHeaders)
                                pendingUrl = null
                                pendingDecryptionKey = null
                                pendingHeaders = null
                            }
                        }
                        override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {
                            if (released) return
                            try { mpv.setPropertyString("android-surface-size", "${w}x$ht") } catch (_: Throwable) {}
                        }
                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            if (released) return
                            surfaceAttached = false
                            try { mpv.detachSurface() } catch (_: Throwable) {}
                        }
                    })
                }
            },
            modifier = modifier,
        )
    }
}
