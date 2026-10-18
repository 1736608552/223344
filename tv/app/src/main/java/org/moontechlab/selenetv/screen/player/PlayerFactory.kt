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
    fun create(context: Context, userAgent: String? = null, preferMpv: Boolean = false): VideoPlayer {
        val decode = AppDataService.getDecodeModeSync()
        val userType = resolveEffectivePlayerType(AppDataService.getPlayerTypeSync(), Build.VERSION.SDK_INT)
        val type = if (preferMpv && Build.VERSION.SDK_INT >= MPV_MIN_SDK) PlayerType.MPV else userType
        fun exo(): VideoPlayer {
            val ds: DataSource.Factory =
                if (userAgent != null) MediaHttp.dataSourceFactory(userAgent) else MediaHttp.dataSourceFactory
            return PlayerController(context, ds, decode)
        }
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
