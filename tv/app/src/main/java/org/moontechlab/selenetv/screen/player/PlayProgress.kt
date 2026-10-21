package org.moontechlab.selenetv.screen.player

import org.moontechlab.selenetv.model.PlayRecord
import org.moontechlab.selenetv.model.SearchResult
import java.net.URLEncoder

/**
 * 播放进度相关的纯逻辑（无副作用、可单元测试）：
 * URL 代理拼接、PlayRecord 映射、定时保存守卫。
 */
object PlayProgress {

    /** m3u8 代理拼接：代理为空返回原 URL，否则 URL-encode 后加前缀。 */
    fun buildPlayUrl(rawUrl: String, proxyUrl: String): String {
        if (proxyUrl.isBlank()) return rawUrl
        // 用 String 重载而非 Charset 重载：后者需 API 33，minSdk 23 会触发 NewApi lint 错误
        return proxyUrl + URLEncoder.encode(rawUrl, "UTF-8")
    }

    /** 由当前源 + 进度构造播放记录。play_time/total_time 单位为秒（MoonTV 约定）。 */
    fun buildRecord(
        source: SearchResult,
        title: String,
        episodeIndex: Int,
        positionMs: Long,
        durationMs: Long,
        nowMs: Long = System.currentTimeMillis(),
    ): PlayRecord = PlayRecord(
        id = source.id,
        source = source.source,
        title = title,
        sourceName = source.sourceName,
        year = source.year,
        cover = source.poster,
        index = episodeIndex + 1,
        totalEpisodes = source.episodes.size.coerceAtLeast(1),
        playTime = positionMs / 1000,
        totalTime = durationMs / 1000,
        saveTime = nowMs,
        searchTitle = title,
    )

    /** 是否应保存：<1s 一律不存（含强制）；满 1s 后强制必存；否则需距上次≥10s 且位置有变化。 */
    fun shouldSave(
        force: Boolean,
        positionMs: Long,
        lastSavedPositionMs: Long,
        elapsedSinceLastSaveMs: Long,
    ): Boolean {
        if (positionMs < 1000) return false
        if (force) return true
        if (elapsedSinceLastSaveMs < 10_000) return false
        if (positionMs == lastSavedPositionMs) return false
        return true
    }

    /**
     * 智能规整跨端播放记录的时间戳（秒 vs 毫秒）：
     * 手机端存入的是毫秒 (如 70000ms)，TV 端此前存入的是秒 (如 70s)。
     * 短剧单集一般 1~3 分钟 (60~180s)，若大于 600 则必定已经是毫秒；
     * 传统影视单集很少超过 4 小时 (14400s)，若大于 20000 则必定已经是毫秒。
     * 防止对已经是毫秒的数据再次 ×1000 放大导致起播越界挂死与 -19:15:34 倒数异常。
     */
    fun normalizePlayTimeMs(rawTime: Long, isShortDrama: Boolean): Long {
        if (rawTime <= 0L) return 0L
        val isAlreadyMs = if (isShortDrama) rawTime > 600L else rawTime > 20_000L
        val ms = if (isAlreadyMs) rawTime else rawTime * 1000L
        val maxLimit = if (isShortDrama) 10 * 60 * 1000L else 8 * 3600 * 1000L
        return ms.coerceIn(0L, maxLimit)
    }
}
