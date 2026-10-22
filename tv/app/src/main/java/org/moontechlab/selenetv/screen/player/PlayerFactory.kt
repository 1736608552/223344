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

        // 短剧架构守则 (100% 遵照标杆项目 hongguoTV 工业级实践)：
        // 电视端短剧必须依托 HongguoVideoDataSource + MediaCrypto 内存透明解密管线直接喂给 ExoPlayer，
        // 触发底层 MediaCodec 芯片硬件解码零拷贝秒开播放。MPV 缺乏 CENC 透明解密数据源，严禁路由至 MPV。
        if (isShortDrama) {
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
