package org.moontechlab.selenetv.service.danmaku

import org.json.JSONObject
import org.moontechlab.selenetv.hongguo.HongguoStreamResolver
import org.moontechlab.selenetv.model.DanmakuComment
import org.moontechlab.selenetv.service.ShortDramaService
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

/**
 * 红果精品短剧官方弹幕源 (对齐手机端短剧弹幕体系)
 *
 * - 检索 (search): 支持剧名短剧专网检索及 ID 直连，精准提取短剧信息
 * - 分集 (getEpisodes): 调取官方分集列表，生成 cleanId:vid 复合集标识
 * - 弹幕 (getComments): 双轨通道——原生签名高速通道 (通道0) + 官方网页端弹幕数据提取通道兜底 (通道2)
 * - 表现：全量解析 150+ 种官方短剧 Emoji 表情混排，无弹幕时保持真实纯净空态，杜绝假弹幕
 */
class HongguoDanmakuSource : DanmakuSource {
    override val providerName = "hongguo"

    override fun search(keyword: String): List<DanmakuMedia> {
        val kw = keyword.trim()
        if (kw.isEmpty()) return emptyList()

        val cleanId = kw.removePrefix("hongguo:").trim()
        if (cleanId.matches(Regex("[0-9]{1,32}"))) {
            return listOf(
                DanmakuMedia(
                    provider = providerName,
                    mediaId = cleanId,
                    title = kw,
                    type = "shortdrama",
                    episodeCount = 80
                )
            )
        }

        return runCatching {
            // 同步执行短剧全库检索
            val dramas = kotlinx.coroutines.runBlocking {
                ShortDramaService.searchDramas(kw)
            }
            dramas.map { drama ->
                DanmakuMedia(
                    provider = providerName,
                    mediaId = drama.id.removePrefix("hongguo:").trim(),
                    title = drama.title,
                    type = "shortdrama",
                    episodeCount = drama.episodes.size.takeIf { it > 0 } ?: 80
                )
            }
        }.getOrDefault(emptyList())
    }

    override fun getEpisodes(mediaId: String): List<DanmakuEpisode> {
        val cleanId = mediaId.trim().removePrefix("hongguo:").trim()
        if (cleanId.isEmpty()) return emptyList()

        return runCatching {
            val vids = HongguoStreamResolver.fetchEpisodeVids(cleanId)
            if (vids.isNotEmpty()) {
                vids.mapIndexed { index, vid ->
                    DanmakuEpisode(
                        provider = providerName,
                        episodeId = "$cleanId:$vid",
                        title = "第${index + 1}集",
                        episodeIndex = index + 1
                    )
                }
            } else {
                emptyList()
            }
        }.getOrDefault(emptyList())
    }

    override fun getComments(episodeId: String): List<DanmakuComment> =
        getComments(episodeId, 0, 0)

    override fun getComments(episodeId: String, startSec: Int, endSec: Int): List<DanmakuComment> {
        val epId = episodeId.trim()
        if (epId.isEmpty()) return emptyList()

        var seriesId = ""
        var vid = epId
        if (epId.contains(":")) {
            val parts = epId.split(":")
            if (parts.size >= 2) {
                seriesId = parts[0].trim()
                vid = parts[1].trim()
            }
        }

        val startMs = if (startSec > 0) startSec * 1000L else 0L
        val durationMs = if (endSec > startSec) (endSec - startSec) * 1000L else 180000L

        // 通道 0: 官方 App 原生签名通道 (最高优先级，直接打通真实观众弹幕)
        val commentsFromSigner = runCatching {
            val res = HongguoStreamResolver.fetchDanmaku(
                seriesId = seriesId,
                vid = vid,
                startMs = startMs,
                durationMs = durationMs
            )
            @Suppress("UNCHECKED_CAST")
            val items = res["items"] as? List<Map<String, Any>> ?: emptyList()
            items.mapNotNull { item ->
                val text = (item["text"] as? String)?.trim() ?: return@mapNotNull null
                val timeMs = (item["timeMs"] as? Long) ?: (item["timeMs"] as? Number)?.toLong() ?: 0L
                if (text.isEmpty()) return@mapNotNull null
                DanmakuComment(
                    timeMs = timeMs,
                    mode = DanmakuComment.MODE_SCROLL,
                    color = 0xFFFFFFL,
                    content = HongguoDanmakuEmojis.formatHongguoDanmakuText(text)
                )
            }
        }.getOrNull()

        if (!commentsFromSigner.isNullOrEmpty()) {
            return commentsFromSigner
        }

        // 通道 2: 官方网页端弹幕数据提取通道兜底
        if (seriesId.isNotEmpty() && vid.isNotEmpty()) {
            val commentsFromWeb = runCatching {
                fetchDanmakuWebFallback(seriesId, vid)
            }.getOrDefault(emptyList())
            if (commentsFromWeb.isNotEmpty()) {
                return commentsFromWeb
            }
        }

        // 若均未拉到，保持真实纯净空态，绝不造假
        return commentsFromSigner ?: emptyList()
    }

    private fun fetchDanmakuWebFallback(cleanId: String, vid: String): List<DanmakuComment> {
        val conn = (URL("https://hongguoduanju.com/player/$cleanId/$vid").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 6000
            readTimeout = 8000
            setRequestProperty("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
            setRequestProperty("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        }
        val html = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { it.readText() }
        val m = Regex("""_ROUTER_DATA\s*=\s*(\{.*?\});""").find(html) ?: return emptyList()
        val root = JSONObject(m.groupValues[1])
        val loaderData = root.optJSONObject("loaderData") ?: return emptyList()
        var pageData: JSONObject? = null
        val keys = loaderData.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            if (k.contains("player_") && k.endsWith("/page")) {
                pageData = loaderData.optJSONObject(k)
                break
            }
        }
        if (pageData == null) {
            pageData = loaderData.optJSONObject("player_(series_id)/(vid)/page") ?: loaderData.optJSONObject("player_page")
        }
        val commentsRaw = pageData?.optJSONArray("danmaku_list") ?: pageData?.optJSONArray("comment_list") ?: return emptyList()
        val comments = mutableListOf<DanmakuComment>()
        for (i in 0 until commentsRaw.length()) {
            val c = commentsRaw.optJSONObject(i) ?: continue
            val text = (c.optString("text").ifEmpty { c.optString("content") }).trim()
            val timeMs = c.optLong("time", c.optLong("offset_time", -1L))
            if (text.isEmpty() || timeMs < 0) continue
            comments.add(
                DanmakuComment(
                    timeMs = timeMs,
                    mode = DanmakuComment.MODE_SCROLL,
                    color = 0xFFFFFFL,
                    content = HongguoDanmakuEmojis.formatHongguoDanmakuText(text)
                )
            )
        }
        return comments
    }
}
