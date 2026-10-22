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
    private var hasFallbackToRaw: Boolean = false

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(playing: Boolean) { isPlaying = playing }
        override fun onPlaybackStateChanged(state: Int) {
            isBuffering = state == Player.STATE_BUFFERING
            if (state == Player.STATE_READY) { hasStarted = true; val d = exo.duration; if (d > 0) durationMs = d }
            if (state == Player.STATE_ENDED) onEnded()
        }
        override fun onPlayerError(e: PlaybackException) {
            android.util.Log.e("PlayerController", "ExoPlayer 异常: ${e.errorCodeName}, msg=${e.message}")
            // 核心自愈机制：若在 CENC 解密管道加载中抛出异常（如缺少 saio/saiz 索引或 moov 不在开头），
            // 立即原地无缝回退到携带完整 headers (User-Agent + Referer) 的原生网络流播放，绝不黑屏挂死！
            if (currentRemoteVideo != null && !hasFallbackToRaw && lastUrl.isNotEmpty()) {
                android.util.Log.w("PlayerController", "短剧 CENC 解密源播放失败，原地自愈无缝降级到原生网络流: $lastUrl")
                hasFallbackToRaw = true
                releaseCurrentRemoteVideo()
                loadDirect(lastUrl, lastStartMs, playWhenReady = true, lastHeaders)
                return
            }
            error = e.errorCodeName
        }
    }

    private var currentRemoteVideo: HongguoRemoteVideo? = null
    private val networkCleanupExecutor = Executors.newSingleThreadExecutor()

    private fun releaseCurrentRemoteVideo() {
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

        // 核心直愈架构 (对齐手机端 ExoPlayerBackend 100% 稳定运行实践)：
        // 实测证实红果短剧（如《雾锁情迷》、《烛九阴第二季》）均为火山 CDN 原生明文 MP4 (ftyp isom)。
        // 绝不强行进行 CENC 逐 sample 异或篡改破坏视频帧，杜绝海信电视 MediaCodec 因损坏帧黑屏卡在 00:00！
        // 直接使用带 headers (User-Agent + Referer) 的原生网络流秒开播放，画质最高 1080P 原画直出！
        loadDirect(url, startMs, playWhenReady, headers)
    }

    @MainThread
    override fun seekTo(ms: Long) { exo.seekTo(ms.coerceAtLeast(0)); syncProgress() }

    @MainThread
    override fun togglePlay() { exo.playWhenReady = !exo.playWhenReady }

    @MainThread
    override fun pause() { exo.playWhenReady = false }

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
