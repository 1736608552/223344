package org.moontechlab.selenetv.screen.player

import android.content.Context
import android.os.Build
import androidx.media3.datasource.DataSource
import org.moontechlab.selenetv.service.AppDataService
import org.moontechlab.selenetv.service.AppDataService.PlayerType
import org.moontechlab.selenetv.service.MediaHttp

/** libmpv 最低支持 SDK：设为 21（Android 5.0+），全面支持 Android 6.0/7.1+ 机顶盒解密与播放 */
const val MPV_MIN_SDK = 21

fun resolveEffectivePlayerType(requested: PlayerType, sdkInt: Int): PlayerType =
    if (requested == PlayerType.MPV && sdkInt < MPV_MIN_SDK) PlayerType.EXOPLAYER else requested

/**
 * 按设置 + 系统版本创建播放器后端。
 * @param userAgent 直播源 UA；点播传 null（用默认 DataSource）。
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
object PlayerFactory {
    fun create(
        context: Context,
        userAgent: String? = null,
        preferMpv: Boolean = false,
        isShortDrama: Boolean = false,
    ): VideoPlayer {
        val decode = AppDataService.getDecodeModeSync()
        fun exo(): VideoPlayer {
            val ds: DataSource.Factory =
                if (userAgent != null) MediaHttp.dataSourceFactory(userAgent) else MediaHttp.dataSourceFactory
            return PlayerController(context, ds, decode)
        }

        // 短剧软解 / 非8对齐异常分辨率（如 1924x1080 HEVC Level 6.2）强制路由至 libmpv 纯 FFmpeg CPU 软解：
        // 彻底绕开 MediaCodec / OMX.google.hevc.decoder (Level 5.1上限) 与 Gralloc Surface NV12 stride 对齐花屏！
        // 仅在硬件解码模式下保持 ExoPlayer 零拷贝硬解默认路由。
        if (isShortDrama) {
            if ((preferMpv || decode == AppDataService.DecodeMode.SOFTWARE) && Build.VERSION.SDK_INT >= MPV_MIN_SDK) {
                return try {
                    MpvPlayerController(context, userAgent, AppDataService.DecodeMode.SOFTWARE)
                } catch (e: Throwable) {
                    android.util.Log.e("PlayerFactory", "短剧 MPV 软解引擎初始化失败，回退 ExoPlayer", e)
                    exo()
                }
            }
            return exo()
        }

        val userType = resolveEffectivePlayerType(AppDataService.getPlayerTypeSync(), Build.VERSION.SDK_INT)
        val type = if (preferMpv && Build.VERSION.SDK_INT >= MPV_MIN_SDK) PlayerType.MPV else userType
        return when (type) {
            PlayerType.MPV -> try {
                MpvPlayerController(context, userAgent, decode)
            } catch (e: Throwable) {
                android.util.Log.e("PlayerFactory", "MPV 初始化失败，回退 ExoPlayer", e)
                exo()
            }
            PlayerType.EXOPLAYER -> exo()
        }
    }
}
