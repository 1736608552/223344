package org.moontechlab.selenetv.screen.player

import android.content.Context
import android.net.Uri
import androidx.annotation.MainThread
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import org.moontechlab.selenetv.hongguo.HongguoRemoteVideo
import org.moontechlab.selenetv.hongguo.HongguoVideoDataSource
import org.moontechlab.selenetv.hongguo.MediaCrypto
import org.moontechlab.selenetv.hongguo.RemoteVideo
import org.moontechlab.selenetv.hongguo.VideoDataSource
import org.moontechlab.selenetv.service.AppDataService
import org.moontechlab.selenetv.service.MediaHttp
import java.util.concurrent.Executors

/**
 * 封装 ExoPlayer，实现 VideoPlayer。位置/时长用毫秒。位置由调用方周期 [syncProgress] 拉取。
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlayerController(
    private val context: Context,
    dataSourceFactory: androidx.media3.datasource.DataSource.Factory = MediaHttp.dataSourceFactory,
    decodeMode: AppDataService.DecodeMode = AppDataService.DecodeMode.HARDWARE,
) : VideoPlayer {

    private val exo: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
        .setLoadControl(org.moontechlab.selenetv.util.DeviceMemoryManager.createExoLoadControl(context))
        .apply {
            if (decodeMode == AppDataService.DecodeMode.SOFTWARE) {
                setRenderersFactory(object : DefaultRenderersFactory(context) {
                    override fun buildVideoRenderers(
                        ctx: Context,
                        extensionRendererMode: Int,
                        mediaCodecSelector: androidx.media3.exoplayer.mediacodec.MediaCodecSelector,
                        enableDecoderFallback: Boolean,
                        eventHandler: android.os.Handler,
                        eventListener: androidx.media3.exoplayer.video.VideoRendererEventListener,
                        allowedVideoJoiningTimeMs: Long,
                        out: ArrayList<androidx.media3.exoplayer.Renderer>,
                    ) {
                        super.buildVideoRenderers(
                            ctx, extensionRendererMode, SoftwareFirstSelector,
                            enableDecoderFallback, eventHandler, eventListener,
                            allowedVideoJoiningTimeMs, out,
                        )
                    }
                })
            } else {
                setRenderersFactory(DefaultRenderersFactory(context).apply {
                    setEnableDecoderFallback(true)
                    setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
                })
            }
        }
        .build().apply {
            videoScalingMode = androidx.media3.common.C.VIDEO_SCALING_MODE_SCALE_TO_FIT
            setAudioAttributes(
                androidx.media3.common.AudioAttributes.Builder()
                    .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                    .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MOVIE)
                    .build(),
                true
            )
        }

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
            exo.setPlaybackSpeed(value)
        }

    private var playerView: PlayerView? = null

    override var resizeMode: VideoResizeMode = VideoResizeMode.FIT
        set(value) {
            field = value
            playerView?.resizeMode = exoResizeMode(value)
        }

    private fun exoResizeMode(mode: VideoResizeMode): Int = when (mode) {
        VideoResizeMode.FIT -> AspectRatioFrameLayout.RESIZE_MODE_FIT
        VideoResizeMode.ZOOM -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
        VideoResizeMode.FILL -> AspectRatioFrameLayout.RESIZE_MODE_FILL
    }

    private var lastUrl: String = ""
    private var lastStartMs: Long = 0L
    private var lastHeaders: Map<String, String>? = null
    private var lastKeyBytes: ByteArray? = null
    private var hasFallbackToRaw: Boolean = false

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private fun resolveFallbackPlayUrl(): Pair<String, Map<String, String>?> {
        val kb = lastKeyBytes
        if (kb != null && kb.size == 16 && !lastUrl.contains("127.0.0.1")) {
            val localUrl = runCatching {
                org.moontechlab.selenetv.hongguo.HongguoLocalServer.instance.getPlayUrl(
                    org.moontechlab.selenetv.hongguo.StreamInfo(lastUrl, kb, "1080P"),
                    MediaHttp.httpClient,
                    eagerWarm = true
                )
            }.getOrDefault("")
            if (localUrl.startsWith("http://127.0.0.1")) {
                return localUrl to null
            }
        }
        return lastUrl to lastHeaders
    }

    private val bufferingWatchdogRunnable = Runnable {
        if (isBuffering && positionMs == 0L && currentRemoteVideo != null && !hasFallbackToRaw && lastUrl.isNotEmpty()) {
            val (fbUrl, fbHeaders) = resolveFallbackPlayUrl()
            android.util.Log.w("PlayerController", "短剧检测到硬件解码器首帧缓冲超时，原地自愈降级到本地回环解密流: $fbUrl")
            hasFallbackToRaw = true
            releaseCurrentRemoteVideo()
            loadDirect(fbUrl, lastStartMs, playWhenReady = true, fbHeaders)
        }
    }

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(playing: Boolean) {
            isPlaying = playing
            if (playing) {
                // 画面正常起播时，立即彻底清除瞬时错误状态，防止假报错悬浮
                error = null
            }
        }
        override fun onRenderedFirstFrame() {
            // 首帧渲染上屏，彻底清空任何历史报错状态
            error = null
        }
        override fun onPlaybackStateChanged(state: Int) {
            isBuffering = state == Player.STATE_BUFFERING
            mainHandler.removeCallbacks(bufferingWatchdogRunnable)
            if (state == Player.STATE_BUFFERING && currentRemoteVideo != null && !hasFallbackToRaw) {
                // 3.5 秒硬件解码死锁看门狗守护，专为海信等老旧电视 SOC 优化
                mainHandler.postDelayed(bufferingWatchdogRunnable, 10000L)
            }
            if (state == Player.STATE_READY) {
                error = null
                hasStarted = true
                val d = exo.duration
                if (d > 0) durationMs = d
            }
            if (state == Player.STATE_ENDED) onEnded()
        }
        override fun onPlayerError(e: PlaybackException) {
            mainHandler.removeCallbacks(bufferingWatchdogRunnable)
            android.util.Log.e("PlayerController", "ExoPlayer 异常: ${e.errorCodeName}, msg=${e.message}")
            // 核心自愈机制：若在 CENC 解密管道加载中抛出异常（如缺少 saio/saiz 索引或 moov 不在开头），
            // 立即原地无缝回退到携带完整 headers (User-Agent + Referer) 的原生网络流播放，绝不黑屏挂死！
            if (currentRemoteVideo != null && !hasFallbackToRaw && lastUrl.isNotEmpty()) {
                val (fbUrl, fbHeaders) = resolveFallbackPlayUrl()
                android.util.Log.w("PlayerController", "短剧纯内存解密源播放受阻，原地自愈无缝降级到本地回环解密流: $fbUrl")
                hasFallbackToRaw = true
                releaseCurrentRemoteVideo()
                error = null
                loadDirect(fbUrl, lastStartMs, playWhenReady = true, fbHeaders)
                return
            }
            error = e.errorCodeName
        }
    }

    private var currentRemoteVideo: AutoCloseable? = null
    private val networkCleanupExecutor = Executors.newSingleThreadExecutor()

    private fun releaseCurrentRemoteVideo() {
        mainHandler.removeCallbacks(bufferingWatchdogRunnable)
        val remote = currentRemoteVideo
        currentRemoteVideo = null
        if (remote != null) {
            networkCleanupExecutor.execute {
                runCatching { remote.close() }
            }
        }
    }

    init { exo.addListener(listener) }

    @MainThread
    override fun loadRemoteVideo(remote: Any, startMs: Long, playWhenReady: Boolean) {
        releaseCurrentRemoteVideo()
        error = null
        hasStarted = false
        lastStartMs = startMs
        hasFallbackToRaw = false

        if (remote is RemoteVideo) {
            currentRemoteVideo = remote
            lastUrl = remote.info.url
            lastKeyBytes = remote.info.key
            val mediaSource = ProgressiveMediaSource.Factory { VideoDataSource(remote) }
                .createMediaSource(
                    MediaItem.Builder()
                        .setMediaId(remote.info.url)
                        .setUri(Uri.parse("hongguotv://episode/${remote.info.url.hashCode()}"))
                        .setMimeType(MimeTypes.VIDEO_MP4)
                        .build()
                )
            exo.setMediaSource(mediaSource)
            exo.prepare()
            if (startMs > 0) exo.seekTo(startMs)
            exo.playWhenReady = playWhenReady
            syncProgress()
            android.util.Log.i("PlayerController", "短剧原版纯内存解密硬解引擎启动成功 (MediaCodec 硬解): ${remote.info.quality}")
        }
    }

    @MainThread
    fun loadDirect(
        url: String,
        startMs: Long,
        playWhenReady: Boolean,
        headers: Map<String, String>? = null,
    ) {
        releaseCurrentRemoteVideo()
        error = null
        hasStarted = false
        lastUrl = url
        lastStartMs = startMs
        lastHeaders = headers

        val mediaItem = MediaItem.fromUri(url)
        if (headers.isNullOrEmpty()) {
            exo.setMediaItem(mediaItem)
        } else {
            // 使用 ProgressiveMediaSource 原生渐进式媒体源工厂，确保 MP4 硬件直连并带上防盗链 Headers
            val okHttpFactory = androidx.media3.datasource.okhttp.OkHttpDataSource.Factory(MediaHttp.httpClient).apply {
                setDefaultRequestProperties(headers)
            }
            val mediaSource = ProgressiveMediaSource.Factory(okHttpFactory).createMediaSource(mediaItem)
            exo.setMediaSource(mediaSource)
        }
        exo.prepare()
        if (startMs > 0) exo.seekTo(startMs)
        exo.playWhenReady = playWhenReady
        syncProgress()
    }

    @MainThread
    override fun load(url: String, startMs: Long, playWhenReady: Boolean) {
        loadDirect(url, startMs, playWhenReady, null)
    }

    @MainThread
    override fun load(
        url: String,
        startMs: Long,
        playWhenReady: Boolean,
        decryptionKey: String?,
        headers: Map<String, String>?,
    ) {
        lastUrl = url
        lastStartMs = startMs
        lastHeaders = headers
        hasFallbackToRaw = false

        val rawKey = decryptionKey?.trim().orEmpty()
        if (rawKey.isNotEmpty()) {
            val keyBytes = MediaCrypto.resolveKeyBytes(rawKey)
            if (keyBytes != null && keyBytes.size == 16) {
                lastKeyBytes = keyBytes
                releaseCurrentRemoteVideo()
                error = null
                hasStarted = false
                try {
                    val remote = HongguoRemoteVideo(MediaHttp.httpClient, url, keyBytes, headers)
                    currentRemoteVideo = remote
                    val mediaSource = ProgressiveMediaSource.Factory(HongguoVideoDataSource.Factory(remote))
                        .createMediaSource(
                            MediaItem.Builder()
                                .setMediaId(url)
                                .setUri(Uri.parse(url))
                                .setMimeType(MimeTypes.VIDEO_MP4)
                                .build()
                        )
                    exo.setMediaSource(mediaSource)
                    exo.prepare()
                    if (startMs > 0) exo.seekTo(startMs)
                    exo.playWhenReady = playWhenReady
                    syncProgress()
                    android.util.Log.i("PlayerController", "短剧原生硬件解码引擎启动成功 (MediaCodec 硬解): $url")
                    return
                } catch (e: Throwable) {
                    android.util.Log.e("PlayerController", "短剧原生硬解媒体源初始化失败，回退原生网络流播放", e)
                }
            } else {
                android.util.Log.w("PlayerController", "短剧解密 Key 校验未通过: $rawKey")
            }
        }

        // 无解密 Key 或解密管线回退：直接使用带 Headers 的原生网络流秒开播放
        loadDirect(url, startMs, playWhenReady, headers)
    }

    @MainThread
    override fun seekTo(ms: Long) { exo.seekTo(ms.coerceAtLeast(0)); syncProgress() }

    @MainThread
    override fun togglePlay() {
        if (exo.playbackState == Player.STATE_IDLE) {
            exo.prepare()
        }
        exo.playWhenReady = !exo.playWhenReady
    }

    @MainThread
    override fun pause() { exo.playWhenReady = false }

    @MainThread
    override fun resumeOrPrepare() {
        if (exo.playbackState == Player.STATE_IDLE) {
            exo.prepare()
        }
    }

    @MainThread
    override fun seekToLiveEdge() { exo.seekToDefaultPosition() }

    @MainThread
    override fun syncProgress() {
        positionMs = exo.currentPosition.coerceAtLeast(0)
        bufferedMs = exo.bufferedPosition.coerceAtLeast(0)
        val d = exo.duration
        if (d > 0) durationMs = d
    }

    @MainThread
    override fun clearError() {
        error = null
    }

    @MainThread
    override fun release() {
        releaseCurrentRemoteVideo()
        networkCleanupExecutor.shutdown()
        exo.removeListener(listener)
        exo.stop()
        exo.clearMediaItems()
        exo.release()
    }

    @Composable
    override fun VideoSurface(modifier: Modifier) {
        // surface_view 硬件直通图层：视频像素直通 VPU 视频处理单元，零拷贝，杜绝机顶盒掉帧（见 R.layout.player_view_surface）。
        AndroidView(
            factory = { ctx ->
                (android.view.LayoutInflater.from(ctx)
                    .inflate(org.moontechlab.selenetv.R.layout.player_view_surface, null) as PlayerView)
                    .apply {
                        useController = false
                        player = exo
                        setBackgroundColor(android.graphics.Color.TRANSPARENT)
                        resizeMode = exoResizeMode(this@PlayerController.resizeMode)
                    }
                    .also { playerView = it }
            },
            onRelease = {
                playerView?.player = null
                playerView = null
            },
            modifier = modifier,
        )
    }
}
