package org.moontechlab.selenetv.proxy

import android.util.Log
import java.net.URL

/**
 * v2.7.83: 「所有源默认最高分辨率播放」——HLS master playlist 最高档变体选择器。
 *
 * 为什么需要:
 *   - ExoPlayer 的 DefaultTrackSelector 默认是自适应 ABR：起播挑低码率、网络抖动
 *     就降档，观感上「明明源有 1080P，画面一直是糊的」。
 *   - 只在播放器里 `setForceHighestSupportedBitrate` 还不够：某些机顶盒的
 *     MediaCodec 能力上报不全，会把它认成「不支持高档」而回落到 720P。
 *   - 所以最稳的是在 URL 层解决：master playlist 里只留最高档，把「低档选项」
 *     从源头去掉，播放器无论怎么选都只能选到最高档。
 *
 * 选档规则（与手机端 `lib/services/hls_quality_selector.dart` 1:1）:
 *   1. 先比 RESOLUTION 面积（宽 × 高），大的优先；
 *   2. 面积相同比高度，再比 BANDWIDTH；
 *   3. 都没有 RESOLUTION 时退化为纯 BANDWIDTH 比较；
 *   4. 完全打平的保留先出现的那个（保持源站顺序）。
 *
 * 安全边界:
 *   - 只认 `#EXT-X-STREAM-INF:`，天然排除 `#EXT-X-I-FRAME-STREAM-INF:`
 *     （只有关键帧，交给播放器必然花屏/卡顿）；
 *   - 解析失败一律返回 null，调用方保持原有「多档全代理」的旧行为，不会更差。
 */
object HlsBestVariant {

    private const val TAG = "HlsBestVariant"

    data class Variant(
        /** 绝对地址 */
        val url: String,
        val width: Int,
        val height: Int,
        val bandwidth: Int,
    )

    private val RE_RESOLUTION = Regex("""RESOLUTION=(\d+)x(\d+)""", RegexOption.IGNORE_CASE)

    /** 注意 `AVERAGE-BANDWIDTH=` 也含 `BANDWIDTH=`，用后顾断言排除。 */
    private val RE_BANDWIDTH = Regex("""(?<![-A-Z])BANDWIDTH=(\d+)""", RegexOption.IGNORE_CASE)

    /** 是否多档 master playlist。 */
    fun isMaster(body: String): Boolean = body.contains("#EXT-X-STREAM-INF")

    /**
     * 返回最高档变体的绝对地址；不是 master 或解析不出时返回 null。
     */
    fun best(masterBody: String, baseUrl: String): String? = pick(masterBody, baseUrl)?.url

    fun pick(masterBody: String, baseUrl: String): Variant? {
        if (!isMaster(masterBody)) return null

        val lines = masterBody.split("\n")
        var best: Variant? = null
        var bestArea = -1
        var bestHeight = -1
        var bestBandwidth = -1

        for (i in lines.indices) {
            val line = lines[i].trim()
            if (!line.startsWith("#EXT-X-STREAM-INF:")) continue

            val attrs = line.substring("#EXT-X-STREAM-INF:".length)
            val resMatch = RE_RESOLUTION.find(attrs)
            val width = resMatch?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 0
            val height = resMatch?.groupValues?.getOrNull(2)?.toIntOrNull() ?: 0
            val bandwidth = RE_BANDWIDTH.find(attrs)?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 0

            var uri: String? = null
            for (j in i + 1 until lines.size) {
                val candidate = lines[j].trim()
                if (candidate.isEmpty()) continue
                if (candidate.startsWith("#")) continue
                uri = candidate
                break
            }
            if (uri.isNullOrEmpty()) continue

            val area = width * height
            val better = area > bestArea ||
                (area == bestArea && (height > bestHeight ||
                    (height == bestHeight && bandwidth > bestBandwidth)))
            if (!better) continue

            bestArea = area
            bestHeight = height
            bestBandwidth = bandwidth
            best = Variant(absolutize(baseUrl, uri), width, height, bandwidth)
        }

        best?.let {
            Log.i(
                TAG,
                "最高档变体 ${it.width}x${it.height} bw=${it.bandwidth} -> ${it.url.take(110)}"
            )
        }
        return best
    }

    private fun absolutize(baseUrl: String, reference: String): String = try {
        URL(URL(baseUrl), reference).toString()
    } catch (e: Exception) {
        reference
    }
}
