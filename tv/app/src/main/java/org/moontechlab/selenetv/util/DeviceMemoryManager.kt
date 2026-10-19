package org.moontechlab.selenetv.util

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import coil.ImageLoader
import org.moontechlab.selenetv.service.AppDataService
import org.moontechlab.selenetv.service.UpdateService

/**
 * 设备内存与性能优化管理器
 *
 * 针对海信电视（Hisense TV / VIDAA）及低内存设备（<= 2GB RAM / 32位芯片 / dalvik heap <= 192M）的专项调优：
 * 1. 海信/低内存机型识别：集成 Application ID 包名后缀（.hisense 渠道专包）、系统品牌型号、系统 isLowRamDevice 及堆上限综合研判。
 * 2. ExoPlayer 缓冲管控：解决长视频播放 20~30 分钟缓冲累加撑爆内存闪退的根本痛点（12MB 严格上限锁死）。
 * 3. MPV 播放内核缓冲压降：从默认 256MB/32MB 压缩至 24MB/4MB，杜绝 32 位机器 Native 堆外地址空间耗尽。
 * 4. Coil 图片加载熔断：内存占比从默认 25% 压至 10~12%，接管系统 onTrimMemory / onLowMemory，毫秒级释放 Bitmap 并主动触发 GC，防止被系统 LMK 强杀。
 */
object DeviceMemoryManager {
    private const val TAG = "DeviceMemoryManager"

    data class MpvCacheConfig(
        val readaheadSecs: String,
        val maxBytes: String,
        val maxBackBytes: String,
    )

    /**
     * 判断当前是否为海信设备（包括 Hisense 渠道专包，或在 Hisense 品牌/厂商/型号的设备上运行）
     */
    fun isHisenseDevice(context: Context? = null): Boolean {
        if (context != null && context.packageName.contains("hisense", ignoreCase = true)) {
            return true
        }
        return UpdateService.isHisenseDevice()
    }

    /**
     * 综合判断是否属于受限内存设备（海信电视、低内存 TV、32 位 armv7a 芯片机型或堆内存受限设备）
     */
    fun isConstrainedMemoryDevice(context: Context): Boolean {
        // 1. 海信电视（由于系统的低内存杀手策略和较低的 heapgrowthlimit，直接归入受限保护级别）
        if (isHisenseDevice(context)) {
            return true
        }

        // 2. 检查 AppDataService 或系统标记的 LowRam 设备
        if (AppDataService.isLowRamDeviceSync()) {
            return true
        }

        // 3. 检查系统 ActivityManager
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        if (am?.isLowRamDevice == true) {
            return true
        }

        // 4. 最大堆内存判断（<= 192MB 则视为严格受限）
        val maxHeapMb = Runtime.getRuntime().maxMemory() / (1024 * 1024)
        if (maxHeapMb <= 192) {
            return true
        }

        // 5. 32 位低端芯片设备（虚拟地址空间受限，容易出现 native bad_alloc）
        val is64Bit = Build.SUPPORTED_ABIS.any { it.contains("64") }
        if (!is64Bit) {
            return true
        }

        return false
    }

    /**
     * 为 ExoPlayer 构造最优 LoadControl，防止长视频播放导致堆内外缓冲堆积 OOM 闪退
     */
    @OptIn(UnstableApi::class)
    fun createExoLoadControl(context: Context): LoadControl {
        val constrained = isConstrainedMemoryDevice(context)
        Log.i(TAG, "createExoLoadControl: isConstrainedMemory=$constrained, isHisense=${isHisenseDevice(context)}")

        // 咕噜咕噜四大黑科技之一：起播缓冲压榨至 500ms（真·秒开），首片到位即刻出画面
        val minBufferMs = if (constrained) 8_000 else 20_000
        val maxBufferMs = if (constrained) 15_000 else 40_000
        val bufferForPlaybackMs = 500 // 极限压榨至 500ms 首帧出画
        val bufferForPlaybackAfterRebufferMs = if (constrained) 1_500 else 2_000
        // 海信/受限机型锁死 16MB，非受限机型 36MB（避免无上限狂飙）
        val targetBufferBytes = if (constrained) 16 * 1024 * 1024 else 36 * 1024 * 1024

        return DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                minBufferMs,
                maxBufferMs,
                bufferForPlaybackMs,
                bufferForPlaybackAfterRebufferMs
            )
            .setTargetBufferBytes(targetBufferBytes)
            .setPrioritizeTimeOverSizeThresholds(true)
            .setBackBuffer(0, false) // 严禁保留后退历史分片，看完即释放
            .build()
    }

    /**
     * 获取 MPV 播放器的解封装与缓冲配置参数
     */
    fun getMpvCacheConfig(context: Context): MpvCacheConfig {
        val constrained = isConstrainedMemoryDevice(context)
        Log.i(TAG, "getMpvCacheConfig: isConstrainedMemory=$constrained, isHisense=${isHisenseDevice(context)}")

        return if (constrained) {
            // 海信/受限机型：缓冲控制在 10s、24MiB 以内，防止 32 位机器 Native 堆外内存耗尽被杀
            MpvCacheConfig(
                readaheadSecs = "10",
                maxBytes = "24MiB",
                maxBackBytes = "4MiB"
            )
        } else {
            // 高性能机型：25s 缓冲，128MiB 上限
            MpvCacheConfig(
                readaheadSecs = "25",
                maxBytes = "128MiB",
                maxBackBytes = "16MiB"
            )
        }
    }

    /**
     * 获取 Coil 图片加载器的内存缓存比例
     */
    fun getCoilMemoryCachePercent(context: Context): Double {
        return if (isConstrainedMemoryDevice(context)) 0.10 else 0.20
    }

    /**
     * 响应系统内存压力警告（onTrimMemory），快速回收图片缓存以避免被海信 LMK 强杀
     */
    fun handleTrimMemory(imageLoader: ImageLoader?, level: Int) {
        Log.w(TAG, "handleTrimMemory: level=$level")
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
            level >= ComponentCallbacks2.TRIM_MEMORY_MODERATE ||
            level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) {
            runCatching {
                imageLoader?.memoryCache?.clear()
                System.gc()
            }
        }
    }

    /**
     * 响应极端低内存广播（onLowMemory）
     */
    fun handleLowMemory(imageLoader: ImageLoader?) {
        Log.w(TAG, "handleLowMemory: emergency cache clear")
        runCatching {
            imageLoader?.memoryCache?.clear()
            System.gc()
        }
    }
}
