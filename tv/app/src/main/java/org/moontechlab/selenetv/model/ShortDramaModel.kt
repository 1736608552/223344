package org.moontechlab.selenetv.model

import kotlinx.serialization.Serializable

/**
 * 短剧分类数据模型
 */
@Serializable
data class ShortDramaCategory(
    val typeId: Int,
    val typeName: String,
)

/**
 * 短剧实体数据模型
 */
@Serializable
data class ShortDrama(
    val id: String,
    val dramaId: String = "",
    val name: String,
    val cover: String,
    val episodeCount: Int = 80,
    val score: Double = 9.6,
    val description: String = "",
    val author: String = "",
    val backdrop: String = "",
    val categoryName: String = "短剧",
    val updateTime: String = "",
)

/**
 * 将 ShortDrama 转换为 TV 端通用的 VideoInfo 实体，与全套播放/详情/收藏体系无缝契合
 */
fun ShortDrama.toVideoInfo(): VideoInfo {
    val realId = if (dramaId.isNotEmpty()) dramaId else id
    val scoreStr = if (score > 0) String.format("%.1f", score) else "9.6"
    return VideoInfo(
        id = realId,
        source = "shortdrama",
        title = name,
        sourceName = "短剧专区",
        year = if (updateTime.length >= 4) updateTime.substring(0, 4) else "2026",
        cover = cover,
        index = 0,
        totalEpisodes = if (episodeCount > 0) episodeCount else 80,
        playTime = 0L,
        totalTime = 0L,
        saveTime = System.currentTimeMillis(),
        searchTitle = name,
        rate = scoreStr,
        episodesTitles = null,
    )
}
