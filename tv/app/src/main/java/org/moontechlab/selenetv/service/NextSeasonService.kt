package org.moontechlab.selenetv.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.moontechlab.selenetv.model.SearchResult
import org.moontechlab.selenetv.model.VideoInfo
import java.util.concurrent.ConcurrentHashMap

/**
 * 下一季/连播推荐候选数据模型
 */
data class NextSeasonCandidate(
    val title: String,
    val seasonNumber: Int,
    val seasonLabel: String,
    val poster: String,
    val year: String,
    val desc: String,
    val totalEpisodes: Int,
    val source: String,
    val sourceName: String,
    val isNextSeason: Boolean,
    val bannerTitle: String,
    val bannerSubtitle: String,
    val targetSource: SearchResult,
)

/**
 * TV 端全分类下一季与智能推荐连播服务 (对齐 YouTube / Netflix 交互规范)
 */
object NextSeasonService {
    private const val TAG = "NextSeasonService"
    private val cache = ConcurrentHashMap<String, NextSeasonCandidate?>()

    data class ParsedSeason(
        val baseTitle: String,
        val currentSeason: Int,
        val nextSeason: Int,
    )

    private val cnNumMap = mapOf(
        "一" to 1, "二" to 2, "三" to 3, "四" to 4, "五" to 5,
        "六" to 6, "七" to 7, "八" to 8, "九" to 9, "十" to 10
    )
    private val numToCn = mapOf(
        1 to "一", 2 to "二", 3 to "三", 4 to "四", 5 to "五",
        6 to "六", 7 to "七", 8 to "八", 9 to "九", 10 to "十"
    )

    fun parseSeason(title: String): ParsedSeason {
        val t = title.trim()
        val seasonRegex = Regex("""(?:第\s*([0-9]+|[一二三四五六七八九十]+)\s*[季部期])|(?:Season\s*([0-9]+))|(?:S([0-9]+))""", RegexOption.IGNORE_CASE)
        val match = seasonRegex.find(t)
        if (match != null) {
            val numStr = match.groupValues[1].ifEmpty { match.groupValues[2] }.ifEmpty { match.groupValues[3] }
            val currentSeason = numStr.toIntOrNull() ?: cnNumMap[numStr] ?: 1
            val base = t.replace(match.value, "").trim()
            return ParsedSeason(base, currentSeason, currentSeason + 1)
        }
        val tailNumRegex = Regex("""[:：\s]*([2-9])\s*$""")
        val tailMatch = tailNumRegex.find(t)
        if (tailMatch != null) {
            val s = tailMatch.groupValues[1].toIntOrNull() ?: 2
            val base = t.replace(tailNumRegex, "").trim()
            return ParsedSeason(base, s, s + 1)
        }
        return ParsedSeason(t, 1, 2)
    }

    /**
     * 寻找下一季或推荐候选 (支持短剧、长剧、番剧、电影等全分类)
     */
    suspend fun findNextSeason(
        title: String,
        currentSource: String,
        doubanId: String? = null,
        isMovie: Boolean = false,
        cover: String = "",
        year: String = "2026",
    ): NextSeasonCandidate? = withContext(Dispatchers.IO) {
        val cleanTitle = title.trim()
        if (cleanTitle.isEmpty()) return@withContext null
        val cacheKey = "${currentSource}_$cleanTitle"
        if (cache.containsKey(cacheKey)) {
            return@withContext cache[cacheKey]
        }

        try {
            val isShortDrama = currentSource == "hongguo" || currentSource == "shortdrama"
            var candidate: NextSeasonCandidate? = null

            // 1. 若非单集电影，严谨多通道穷尽检索真实的下一季
            if (!isMovie) {
                val parsed = parseSeason(cleanTitle)
                val base = parsed.baseTitle
                val nextSeasonNum = parsed.nextSeason
                val nextSeasonCn = numToCn[nextSeasonNum] ?: nextSeasonNum.toString()

                if (isShortDrama) {
                    candidate = findNextSeasonShortDrama(base, nextSeasonCn, nextSeasonNum)
                }
                if (candidate == null && !isShortDrama) {
                    candidate = findNextSeasonGeneral(base, nextSeasonNum, nextSeasonCn)
                }
            }

            // 2. ★ 只有在完全没有下一季的前提下，才智能推导同类高分好片/爆款推荐
            if (candidate == null) {
                candidate = findRecommendation(cleanTitle, isShortDrama, isMovie, doubanId, cover, year)
            }

            cache[cacheKey] = candidate
            return@withContext candidate
        } catch (e: Exception) {
            Log.w(TAG, "查找下一季/推荐异常: ${e.message}")
            cache[cacheKey] = null
            return@withContext null
        }
    }

    /**
     * 短剧专网推导下一季
     */
    private suspend fun findNextSeasonShortDrama(
        baseTitle: String,
        nextSeasonCn: String,
        nextSeasonNum: Int,
    ): NextSeasonCandidate? = withContext(Dispatchers.IO) {
        val queries = listOf(
            "${baseTitle}第${nextSeasonCn}季",
            "${baseTitle} 第${nextSeasonCn}季",
            "${baseTitle}第二季",
            "${baseTitle} 第二季",
            "${baseTitle}第${nextSeasonCn}部",
            "${baseTitle}第${nextSeasonNum}季",
            "${baseTitle}2",
            "${baseTitle} 2"
        ).distinct()

        for (q in queries) {
            try {
                val results = withTimeoutOrNull(4000) { ShortDramaService.searchDramas(q) } ?: emptyList()
                val matched = results.firstOrNull { r ->
                    val t = r.title.trim()
                    if (t.contains("预告") || t.contains("花絮") || t.contains("解说")) return@firstOrNull false
                    val p = parseSeason(t)
                    val baseMatch = p.baseTitle == baseTitle || p.baseTitle.contains(baseTitle) || baseTitle.contains(p.baseTitle)
                    val seasonMatch = p.currentSeason == nextSeasonNum ||
                        (nextSeasonNum == 2 && (t.contains("第二季") || t.contains("第二部") || t.contains("第2季") || t.contains("第2部") || t.endsWith("2") || t.contains("${baseTitle}2") || t.contains("${baseTitle} 2")))

                    baseMatch && seasonMatch && r.episodes.isNotEmpty()
                }
                if (matched != null) {
                    return@withContext NextSeasonCandidate(
                        title = matched.title,
                        seasonNumber = nextSeasonNum,
                        seasonLabel = "第${nextSeasonCn}季",
                        poster = matched.poster,
                        year = matched.year,
                        desc = matched.desc.ifBlank { "精彩短剧连播，5秒后自动开启下一季第一集" },
                        totalEpisodes = matched.episodes.size,
                        source = matched.source,
                        sourceName = matched.sourceName,
                        isNextSeason = true,
                        bannerTitle = "即将播放下一季 · 第 ${nextSeasonNum} 季",
                        bannerSubtitle = "为您连播下一季第一集，5秒后自动开播",
                        targetSource = matched,
                    )
                }
            } catch (e: Exception) {
                Log.d(TAG, "短剧下一季检索跳过: ${e.message}")
            }
        }
        null
    }

    /**
     * 通用全网检索推导下一季 (电视剧 / 动漫 / 综艺等长视频全网多源聚合)
     */
    private suspend fun findNextSeasonGeneral(
        baseTitle: String,
        nextSeasonNum: Int,
        nextSeasonCn: String,
    ): NextSeasonCandidate? = withContext(Dispatchers.IO) {
        val queries = listOf(
            "$baseTitle 第${nextSeasonCn}季",
            "$baseTitle 第${nextSeasonNum}季",
            "$baseTitle 第二季",
            "$baseTitle 第${nextSeasonCn}部",
            "$baseTitle 2",
            "$baseTitle Season $nextSeasonNum",
            "$baseTitle S$nextSeasonNum"
        ).distinct()

        val allResources = runCatching {
            org.moontechlab.selenetv.data.Repositories.sources().getSearchResources().filter { !it.disabled }
        }.getOrDefault(emptyList())
        val topResources = allResources.take(6)

        if (topResources.isNotEmpty()) {
            for (q in queries) {
                try {
                    val deferredList = topResources.map { res ->
                        async {
                            runCatching {
                                withTimeoutOrNull(3500) {
                                    DownstreamService.searchFromApi(res, q)
                                }
                            }.getOrNull() ?: emptyList()
                        }
                    }
                    val allResults = deferredList.awaitAll().flatten()
                    if (allResults.isNotEmpty()) {
                        for (r in allResults) {
                            val rTitle = r.title.trim()
                            if (rTitle.contains("预告") || rTitle.contains("花絮") || rTitle.contains("解说") || rTitle.contains("看点")) {
                                continue
                            }
                            val p = parseSeason(rTitle)
                            val baseMatch = p.baseTitle == baseTitle || p.baseTitle.contains(baseTitle) || baseTitle.contains(p.baseTitle)
                            val seasonMatch = p.currentSeason == nextSeasonNum ||
                                (nextSeasonNum == 2 && (rTitle.contains("第二季") || rTitle.contains("第二部") || rTitle.endsWith("2") || rTitle.contains("${baseTitle}2") || rTitle.contains("${baseTitle} 2")))

                            if (baseMatch && seasonMatch && r.episodes.isNotEmpty()) {
                                return@withContext NextSeasonCandidate(
                                    title = rTitle,
                                    seasonNumber = nextSeasonNum,
                                    seasonLabel = "第${nextSeasonCn}季",
                                    poster = r.poster,
                                    year = r.year,
                                    desc = r.desc.ifBlank { "即将为您连播《$rTitle》第一集，精彩不断档。" },
                                    totalEpisodes = r.episodes.size,
                                    source = r.source,
                                    sourceName = r.sourceName,
                                    isNextSeason = true,
                                    bannerTitle = "即将播放下一季 · 第 ${nextSeasonNum} 季",
                                    bannerSubtitle = "为您连播下一季第一集，5秒后自动开播",
                                    targetSource = r,
                                )
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "通用长剧下一季检索跳过: ${e.message}")
                }
            }
        }
        null
    }

    /**
     * 若无下一季或电影场景，寻找相关爆款或豆瓣推荐
     */
    private suspend fun findRecommendation(
        currentTitle: String,
        isShortDrama: Boolean,
        isMovie: Boolean,
        doubanId: String?,
        fallbackCover: String,
        fallbackYear: String,
    ): NextSeasonCandidate? = withContext(Dispatchers.IO) {
        val categoryLabel = if (isMovie) "本片已完结 · 为你推荐精彩好片" else "本剧已完结 · 为你推荐精彩好剧"
        val categorySub = if (isMovie) "为您精选全网高分好片，5秒后自动连播" else "为您精选爆款好剧，5秒后自动连播"

        // 1. 短剧场景：毫秒级直取红果短剧排行榜第一条不重复剧集
        if (isShortDrama) {
            try {
                val hotList = ShortDramaService.getUnifiedList("all", "rank_hot", 1, 10)
                val best = hotList.firstOrNull {
                    !it.name.contains(currentTitle) && !currentTitle.contains(it.name)
                }
                if (best != null) {
                    val epCount = if (best.episodeCount > 0) best.episodeCount else 80
                    val source = SearchResult(
                        id = if (best.dramaId.isNotEmpty()) best.dramaId else best.id,
                        title = best.name,
                        poster = best.cover,
                        episodes = List(epCount) { (it + 1).toString() },
                        episodesTitles = List(epCount) { "第${it + 1}集" },
                        source = "hongguo",
                        sourceName = "精品短剧",
                        year = if (best.updateTime.length >= 4) best.updateTime.substring(0, 4) else "2026",
                        desc = best.description.ifBlank { "爆款短剧原画极速连播" },
                        typeName = "短剧"
                    )
                    return@withContext NextSeasonCandidate(
                        title = best.name,
                        seasonNumber = 1,
                        seasonLabel = "热门推荐",
                        poster = best.cover,
                        year = source.year,
                        desc = source.desc,
                        totalEpisodes = epCount,
                        source = "hongguo",
                        sourceName = "精品短剧",
                        isNextSeason = false,
                        bannerTitle = categoryLabel,
                        bannerSubtitle = categorySub,
                        targetSource = source,
                    )
                }
            } catch (e: Exception) {
                Log.d(TAG, "短剧推荐拉取异常: ${e.message}")
            }
        }

        // 2. 长剧与电影场景：兜底提供热门力作推荐
        try {
            val hotDramas = ShortDramaService.getUnifiedList("all", "rank_hot", 1, 6)
            val rec = hotDramas.firstOrNull { !it.name.contains(currentTitle) }
            if (rec != null) {
                val epCount = if (rec.episodeCount > 0) rec.episodeCount else 80
                val src = SearchResult(
                    id = if (rec.dramaId.isNotEmpty()) rec.dramaId else rec.id,
                    title = rec.name,
                    poster = rec.cover,
                    episodes = List(epCount) { (it + 1).toString() },
                    episodesTitles = List(epCount) { "第${it + 1}集" },
                    source = "hongguo",
                    sourceName = "精品短剧",
                    year = "2026",
                    desc = rec.description.ifBlank { "全网力作精彩推荐，5秒后自动开播" },
                    typeName = "短剧"
                )
                return@withContext NextSeasonCandidate(
                    title = rec.name,
                    seasonNumber = 1,
                    seasonLabel = "热门推荐",
                    poster = rec.cover,
                    year = src.year,
                    desc = src.desc,
                    totalEpisodes = epCount,
                    source = "hongguo",
                    sourceName = "精品短剧",
                    isNextSeason = false,
                    bannerTitle = categoryLabel,
                    bannerSubtitle = categorySub,
                    targetSource = src,
                )
            }
        } catch (_: Exception) {}

        null
    }
}
