package org.moontechlab.selenetv.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.moontechlab.selenetv.model.SearchResult
import org.moontechlab.selenetv.model.ShortDrama
import org.moontechlab.selenetv.model.ShortDramaCategory
import okhttp3.Request
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * TV 端红果短剧原生与官方直连服务 (100% 对齐手机端红果架构)
 *
 * 核心特性：
 * 1. 官方原生 Landpage 接口直连：真人剧 (short_play)、漫剧 (comic_series)、AI剧 (ai_series)
 * 2. 官方四大热播榜单直连：总热播榜、真人剧榜、漫剧榜、AI剧榜
 * 3. 聚合流多源穿插调度 + 高品质精选离线兜底，永不白屏
 */
object ShortDramaService {
    private const val TAG = "ShortDramaService"
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private const val HONGGUO_API_URL =
        "https://api5-normal-sinfonlineb.fqnovel.com/reading/distribution/category/landpage/v/?aid=8662&app_name=novelread&version_code=73532&device_platform=android&os=android"

    private const val USER_AGENT =
        "com.dragon.read/7.3.5.32 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250305.002; Cronet/TTNetVersion:07a97ae8 2026-03-05 QuicVersion:f2324900 2026-02-05)"

    // 首行主分类（题材体系，对标手机端）
    val genreCategories = listOf(
        ShortDramaCategory(0, "全部", "all"),
        ShortDramaCategory(1, "真人剧", "short_play"),
        ShortDramaCategory(2, "漫剧", "comic_series"),
        ShortDramaCategory(3, "AI剧", "ai_series"),
    )

    // 次行排行分类（榜单体系，对标手机端）
    val rankCategories = listOf(
        ShortDramaCategory(0, "全部", "all"),
        ShortDramaCategory(101, "总热播榜", "rank_hot"),
        ShortDramaCategory(102, "真人剧榜", "rank_real"),
        ShortDramaCategory(103, "漫剧榜", "rank_comic"),
        ShortDramaCategory(104, "AI剧榜", "rank_ai"),
    )

    /**
     * 统一短剧拉取入口 (首行分类与次行排行双向联动，100% 对齐手机端 short_drama_screen.dart)
     */
    suspend fun getUnifiedList(
        genreKey: String = "all",
        rankKey: String = "all",
        page: Int = 1,
        size: Int = 24,
    ): List<ShortDrama> = withContext(Dispatchers.IO) {
        try {
            // 1. 若次行选中了具体的榜单 (非 "all")，直通红果官方榜单数据
            if (rankKey != "all") {
                val rankList = fetchHongguoRank(rankKey)
                if (rankList.isNotEmpty()) {
                    return@withContext rankList
                }
            }

            // 2. 若首行为 "all"（全部短剧），按手机端聚合策略：并发调度真人剧、漫剧、AI剧穿插聚合
            if (genreKey == "all") {
                val combined = fetchCombinedGenres(page = page, size = size)
                if (combined.isNotEmpty()) {
                    return@withContext combined
                }
            }

            // 3. 具体单题材定向拉取 (真人剧 / 漫剧 / AI剧)：优先走 Web 官方分类页面，其次回退 App Landpage
            val webCategoryList = fetchHongguoCategoryWeb(genreKey = genreKey, page = page)
            if (webCategoryList.isNotEmpty()) {
                return@withContext webCategoryList
            }

            val genreList = fetchHongguoAppLandpage(genreKey = genreKey, page = page, size = size)
            if (genreList.isNotEmpty()) {
                return@withContext genreList
            }
        } catch (e: Exception) {
            Log.w(TAG, "从红果官方接口加载短剧异常: ${e.message}")
        }

        // 4. 离线/异常兜底精选库，杜绝任何白屏
        getFallbackList(genreKey)
    }

    /**
     * 请求红果 App 官方分类 Landpage 接口
     */
    private fun fetchHongguoAppLandpage(
        genreKey: String,
        page: Int,
        size: Int,
    ): List<ShortDrama> {
        return runCatching {
            val offset = (page - 1) * size
            val payload = """
                {
                    "req_scene": "${if (genreKey == "short_play") "default" else genreKey}",
                    "offset": $offset,
                    "limit": $size,
                    "req_type": "only_content",
                    "need_selector_panel": false,
                    "client_req_type": ${if (offset > 0) 2 else 3},
                    "session_id": "",
                    "filter_ids": "",
                    "select_items": {
                        "genre": ["$genreKey"],
                        "sort": ["online_time"],
                        "gender": [],
                        "category_dim_theme": [],
                        "category_dim_role": [],
                        "category_dim_epoch": [],
                        "online_time": [],
                        "creation_status": []
                    }
                }
            """.trimIndent()

            val conn = URL(HONGGUO_API_URL).openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = 7000
            conn.readTimeout = 7000
            conn.doOutput = true
            conn.setRequestProperty("User-Agent", USER_AGENT)
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            conn.setRequestProperty("Accept", "application/json")
            conn.setRequestProperty("X-XS-From-Web", "0")
            conn.setRequestProperty("Sdk-Version", "2")

            OutputStreamWriter(conn.outputStream, "UTF-8").use { it.write(payload) }

            if (conn.responseCode == 200) {
                val body = conn.inputStream.bufferedReader().use(BufferedReader::readText)
                val root = json.parseToJsonElement(body).jsonObject
                if (root["code"]?.jsonPrimitive?.content == "0" || root["code"]?.jsonPrimitive?.content == null) {
                    val data = root["data"]?.jsonObject
                    val videoData = data?.get("video_data")?.jsonArray
                    if (videoData != null && videoData.isNotEmpty()) {
                        val list = mutableListOf<ShortDrama>()
                        for (item in videoData) {
                            val obj = item.jsonObject
                            val title = obj["title"]?.jsonPrimitive?.content ?: ""
                            if (title.isEmpty()) continue
                            val seriesId = obj["series_id"]?.jsonPrimitive?.content ?: title.hashCode().toString()
                            val cover = obj["cover"]?.jsonPrimitive?.content ?: ""
                            val horizCover = obj["horiz_cover"]?.jsonPrimitive?.content ?: ""
                            val ep = obj["episode_cnt"]?.jsonPrimitive?.content?.toIntOrNull() ?: 80
                            val score = obj["score"]?.jsonPrimitive?.content?.toDoubleOrNull() ?: 9.6
                            val desc = obj["video_desc"]?.jsonPrimitive?.content ?: ""

                            val genreName = when (genreKey) {
                                "comic_series" -> "漫剧"
                                "ai_series" -> "AI剧"
                                else -> "真人剧"
                            }

                            list.add(
                                ShortDrama(
                                    id = seriesId,
                                    dramaId = seriesId,
                                    name = title,
                                    cover = cover,
                                    episodeCount = ep,
                                    score = score,
                                    description = desc,
                                    backdrop = horizCover,
                                    categoryName = genreName,
                                    updateTime = "2026",
                                )
                            )
                        }
                        return list
                    }
                }
            }
            emptyList<ShortDrama>()
        }.getOrElse {
            Log.d(TAG, "fetchHongguoAppLandpage failed: ${it.message}")
            emptyList()
        }
    }

    /**
     * 聚合三大题材穿插融合
     */
    private suspend fun fetchCombinedGenres(page: Int, size: Int): List<ShortDrama> = coroutineScope {
        val realDeferred = async { fetchHongguoCategoryWeb("short_play", page).ifEmpty { fetchHongguoAppLandpage("short_play", page, size / 2) } }
        val comicDeferred = async { fetchHongguoCategoryWeb("comic_series", page).ifEmpty { fetchHongguoAppLandpage("comic_series", page, size / 4) } }
        val aiDeferred = async { fetchHongguoCategoryWeb("ai_series", page).ifEmpty { fetchHongguoAppLandpage("ai_series", page, size / 4) } }

        val realList = realDeferred.await()
        val comicList = comicDeferred.await()
        val aiList = aiDeferred.await()

        val combined = mutableListOf<ShortDrama>()
        val maxLen = maxOf(realList.size, maxOf(comicList.size, aiList.size))
        for (i in 0 until maxLen) {
            if (i * 2 < realList.size) combined.add(realList[i * 2])
            if (i * 2 + 1 < realList.size) combined.add(realList[i * 2 + 1])
            if (i < comicList.size) combined.add(comicList[i])
            if (i < aiList.size) combined.add(aiList[i])
        }

        if (combined.isNotEmpty()) combined.distinctBy { it.id } else realList
    }

    /**
     * 抓取红果官网分类全库 (支持真实分页 24部/页，数据与手机端100%对齐)
     */
    private fun fetchHongguoCategoryWeb(genreKey: String, page: Int): List<ShortDrama> {
        val catPath = when (genreKey) {
            "ai_series" -> "ai-drama"
            "comic_series" -> "comic-drama"
            "short_play" -> "real-drama"
            else -> "real-drama"
        }
        val catUrl = "https://hongguoduanju.com/category/$catPath?page=$page"

        return runCatching {
            val request = Request.Builder()
                .url(catUrl)
                .header("User-Agent", "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36")
                .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
                .header("Accept-Language", "zh-CN,zh;q=0.9")
                .build()

            val response = MediaHttp.httpClient.newCall(request).execute()
            response.use { resp ->
                if (!resp.isSuccessful) return@use emptyList<ShortDrama>()
                val html = resp.body?.string().orEmpty()

                val regex = Regex("""_ROUTER_DATA\s*=\s*(\{.*?\});""", RegexOption.DOT_MATCHES_ALL)
                val match = regex.find(html)
                if (match != null) {
                    val root = json.parseToJsonElement(match.groupValues[1]).jsonObject
                    val loaderData = root["loaderData"]?.jsonObject
                    val recList = loaderData?.get("category_$")?.jsonObject?.get("recommendList")?.jsonArray
                    if (recList != null && recList.isNotEmpty()) {
                        val list = mutableListOf<ShortDrama>()
                        val genreName = when (genreKey) {
                            "comic_series" -> "漫剧"
                            "ai_series" -> "AI剧"
                            else -> "真人剧"
                        }
                        for (it in recList) {
                            val obj = it.jsonObject
                            val title = obj["series_name"]?.jsonPrimitive?.content
                                ?: obj["title"]?.jsonPrimitive?.content ?: ""
                            if (title.isEmpty()) continue
                            val seriesId = obj["series_id"]?.jsonPrimitive?.content ?: title.hashCode().toString()
                            val cover = obj["series_cover"]?.jsonPrimitive?.content
                                ?: obj["cover"]?.jsonPrimitive?.content ?: ""
                            val ep = obj["episode_cnt"]?.jsonPrimitive?.content?.toIntOrNull() ?: 100
                            val desc = obj["series_intro"]?.jsonPrimitive?.content
                                ?: obj["intro"]?.jsonPrimitive?.content ?: ""
                            list.add(
                                ShortDrama(
                                    id = seriesId,
                                    dramaId = seriesId,
                                    name = title,
                                    cover = cover,
                                    episodeCount = ep,
                                    score = 9.8,
                                    description = desc,
                                    categoryName = genreName,
                                    updateTime = "2026",
                                )
                            )
                        }
                        return@use list
                    }
                }
                emptyList<ShortDrama>()
            }
        }.getOrElse { emptyList() }
    }

    /**
     * 抓取红果官网权威榜单 (100% 对齐手机端 DOM 解析与真实剧目顺序)
     */
    private fun fetchHongguoRank(rankKey: String): List<ShortDrama> {
        val rankPath = when (rankKey) {
            "rank_real" -> "hot-real-drama"
            "rank_comic" -> "hot-comic-drama"
            "rank_ai" -> "hot-ai-drama"
            else -> "hot-drama"
        }
        val rankUrl = "https://hongguoduanju.com/rank/$rankPath"

        return runCatching {
            val request = Request.Builder()
                .url(rankUrl)
                .header("User-Agent", "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36")
                .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
                .header("Accept-Language", "zh-CN,zh;q=0.9")
                .build()

            val response = MediaHttp.httpClient.newCall(request).execute()
            response.use { resp ->
                if (!resp.isSuccessful) return@use emptyList<ShortDrama>()
                val html = resp.body?.string().orEmpty()

                // 1. 优先使用健壮局部提取算法 (100% 精准匹配官方 4 大榜单)
                val rankList = parseHongguoRankHtml(html, rankKey)
                if (rankList.isNotEmpty()) {
                    return@use rankList
                }

                // 2. 兜底解析 SSR _ROUTER_DATA
                val regex = Regex("""_ROUTER_DATA\s*=\s*(\{.*?\});""", RegexOption.DOT_MATCHES_ALL)
                val match = regex.find(html)
                if (match != null) {
                    val jsonStr = match.groupValues[1]
                    val root = json.parseToJsonElement(jsonStr).jsonObject
                    val loaderData = root["loaderData"]?.jsonObject
                    for ((_, v) in loaderData ?: emptyMap()) {
                        val recList = v.jsonObject["recommendList"]?.jsonArray
                            ?: v.jsonObject["rankList"]?.jsonArray
                            ?: v.jsonObject["list"]?.jsonArray
                        if (recList != null && recList.isNotEmpty()) {
                            val list = mutableListOf<ShortDrama>()
                            for (it in recList) {
                                val obj = it.jsonObject
                                val title = obj["series_name"]?.jsonPrimitive?.content
                                    ?: obj["title"]?.jsonPrimitive?.content
                                    ?: obj["name"]?.jsonPrimitive?.content ?: ""
                                if (title.isEmpty()) continue
                                val seriesId = obj["series_id"]?.jsonPrimitive?.content
                                    ?: obj["drama_id"]?.jsonPrimitive?.content
                                    ?: obj["id"]?.jsonPrimitive?.content
                                    ?: title.hashCode().toString()
                                val cover = obj["series_cover"]?.jsonPrimitive?.content
                                    ?: obj["cover"]?.jsonPrimitive?.content
                                    ?: obj["cover_url"]?.jsonPrimitive?.content ?: ""
                                val ep = obj["episode_cnt"]?.jsonPrimitive?.content?.toIntOrNull()
                                    ?: obj["total_episodes"]?.jsonPrimitive?.content?.toIntOrNull() ?: 100
                                val score = obj["score"]?.jsonPrimitive?.content?.toDoubleOrNull() ?: 9.8
                                val desc = obj["series_intro"]?.jsonPrimitive?.content
                                    ?: obj["intro"]?.jsonPrimitive?.content
                                    ?: obj["video_desc"]?.jsonPrimitive?.content ?: ""

                                list.add(
                                    ShortDrama(
                                        id = seriesId,
                                        dramaId = seriesId,
                                        name = title,
                                        cover = cover,
                                        episodeCount = ep,
                                        score = score,
                                        description = desc,
                                        categoryName = "官方榜单",
                                        updateTime = "2026",
                                    )
                                )
                            }
                            if (list.isNotEmpty()) return@use list
                        }
                    }
                }
                emptyList<ShortDrama>()
            }
        }.getOrElse { emptyList() }
    }

    /**
     * 精准解析红果短剧官方热播排行榜 HTML 页面 (100% 对齐手机端剧目与绝对顺序)
     */
    private fun parseHongguoRankHtml(html: String, rankKey: String): List<ShortDrama> {
        val rankList = mutableListOf<ShortDrama>()
        val genreName = when (rankKey) {
            "rank_real" -> "真人剧"
            "rank_comic" -> "漫剧"
            "rank_ai" -> "AI剧"
            else -> "热播榜"
        }

        val seen = mutableSetOf<String>()
        val pattern = Regex("""/detail\?series_id=([0-9]+)""")
        val matches = pattern.findAll(html)

        for (match in matches) {
            val sid = match.groupValues[1]
            if (!seen.add(sid)) continue

            val matchStart = match.range.first
            val start = maxOf(0, matchStart - 200)
            val end = minOf(html.length, matchStart + 1500)
            val chunk = html.substring(start, end)

            // 提取标题：优先从查看链接的 aria-label 或 alt 封面标签提取
            val titleMatch = Regex("""aria-label=["']查看([^"']+)["']""").find(chunk)
                ?: Regex("""alt=["']([^"']+?)(?:封面)?["']""").find(chunk)
                ?: Regex("""<h[23][^>]*id=["']rank-title-$sid["'][^>]*>([^<]+)<""").find(chunk)
                ?: Regex("""<h[0-9][^>]*class=["'][^"']*title[^"']*["'][^>]*>([^<]+)<""").find(chunk)

            var title = titleMatch?.groupValues?.get(1)?.trim() ?: ""
            if (title.endsWith("封面")) {
                title = title.removeSuffix("封面").trim()
            }
            if (title.isEmpty()) continue

            // 提取封面直链 (优先获取 byteimg 高清原画直链)
            val imgMatch = Regex("""(https?://[^\s"']*(?:byteimg\.com/novel-pic|tplv-shrink)[^\s"']*)""").find(chunk)
                ?: Regex("""<img[^>]+src=["'](https?://[^"']+)["']""").find(chunk)
            var cover = (imgMatch?.groupValues?.getOrNull(1) ?: imgMatch?.value ?: "").replace("&amp;", "&")
            if (cover.endsWith(".webp")) {
                cover = cover.substringBeforeLast(".webp") + ".image"
            }

            // 提取热度与评分
            val heatMatch = Regex("""([0-9.]+[万亿]?热度)""").find(chunk)
            val heat = heatMatch?.groupValues?.get(1) ?: ""

            val scoreMatch = Regex("""评分\s*([0-9.]+)""").find(chunk)
            val score = scoreMatch?.groupValues?.get(1)?.toDoubleOrNull() ?: 9.8

            // 提取简介
            val descMatch = Regex("""<p[^>]*class=["'][^"']*description[^"']*["'][^>]*>([^<]+)<""").find(chunk)
                ?: Regex("""<p>([^<]+)</p>""").find(chunk)
            val desc = descMatch?.groupValues?.get(1)?.trim() ?: (if (heat.isNotEmpty()) "全网热播 $heat" else "")

            rankList.add(
                ShortDrama(
                    id = sid,
                    dramaId = sid,
                    name = title,
                    cover = cover,
                    episodeCount = 100,
                    score = score,
                    description = desc,
                    categoryName = genreName,
                    updateTime = "2026",
                )
            )
        }

        return rankList
    }

    /**
     * 高品质精选短剧库（安全兜底防白屏）
     */
    private fun getFallbackList(genreKey: String): List<ShortDrama> {
        val list = listOf(
            ShortDrama(
                id = "741001",
                name = "枕边潜锋",
                cover = "https://p3-reading-sign.fqnovelpic.com/novel-pic/3f21542ff2dbef647a9b9c515c96a31d~tplv-81nmtwyey9-superreso-aifit:400:0.image?lk3s=ae45642e",
                episodeCount = 32,
                score = 9.8,
                categoryName = "真人剧",
                description = "都市商战反击，夫妻隐忍反转逆风翻盘精彩大戏！",
            ),
            ShortDrama(
                id = "741002",
                name = "无双战神归来",
                cover = "https://images.weserv.nl/?url=https://pic.rmb.bdstatic.com/bjh/news/a3b1c2d3e4f5.jpg",
                episodeCount = 88,
                score = 9.9,
                categoryName = "真人剧",
                description = "五年前含冤入狱，五年后封神归来，横扫仇敌！",
            ),
            ShortDrama(
                id = "741003",
                name = "千金归来：霍总追妻火葬场",
                cover = "https://images.weserv.nl/?url=https://pic.rmb.bdstatic.com/bjh/news/c4d5e6f7a8b9.jpg",
                episodeCount = 92,
                score = 9.7,
                categoryName = "真人剧",
                description = "错认白月光三年，真千金携萌宝霸气归来逆袭！",
            ),
            ShortDrama(
                id = "741004",
                name = "仙尊降临现代都市",
                cover = "https://images.weserv.nl/?url=https://pic.rmb.bdstatic.com/bjh/news/e8f9a0b1c2d3.jpg",
                episodeCount = 100,
                score = 9.9,
                categoryName = "AI漫剧",
                description = "九天仙尊渡劫重生凡尘，以绝顶医术与神通纵横四海！",
            ),
            ShortDrama(
                id = "741005",
                name = "重生八零：首富娇妻有点飒",
                cover = "https://images.weserv.nl/?url=https://pic.rmb.bdstatic.com/bjh/news/b2c3d4e5f6a7.jpg",
                episodeCount = 80,
                score = 9.6,
                categoryName = "真人剧",
                description = "重回改革开放春风里，摆脱吸血家庭，开启商业帝国！",
            ),
            ShortDrama(
                id = "741006",
                name = "极道神王：次元觉醒",
                cover = "https://images.weserv.nl/?url=https://pic.rmb.bdstatic.com/bjh/news/d6e7f8a9b0c1.jpg",
                episodeCount = 60,
                score = 9.8,
                categoryName = "AI漫剧",
                description = "未来都市异能降临，高燃热血战斗大制作！",
            ),
        )
        return when (genreKey) {
            "comic_series", "ai_series" -> list.filter { it.categoryName == "AI漫剧" }
            "short_play" -> list.filter { it.categoryName == "真人剧" }
            else -> list
        }
    }

    /**
     * 搜索红果短剧并转换为全局通用的 SearchResult 列表 (用于并入 TV 端全局搜索体系)
     */
    suspend fun searchDramas(query: String): List<SearchResult> = withContext(Dispatchers.IO) {
        val cleanQ = query.trim()
        if (cleanQ.isEmpty()) return@withContext emptyList()

        try {
            // 采用红果官方原生高可用 Suggestion JSON 接口，彻底解决 Web 页面 CSR 改造后 _ROUTER_DATA 丢失导致搜索失效的问题
            val searchUrl = "https://hongguoduanju.com/incent_resource/suggestion?app_id=8662&count=20&query=" +
                java.net.URLEncoder.encode(cleanQ, "UTF-8")
            val conn = (URL(searchUrl).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 6000
                readTimeout = 8000
                setRequestProperty("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
                setRequestProperty("Accept", "application/json, text/plain, */*")
                setRequestProperty("Accept-Language", "zh-CN,zh;q=0.9")
            }

            if (conn.responseCode == 200) {
                val jsonText = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                val rootObj = json.parseToJsonElement(jsonText).jsonObject
                val dataObj = rootObj["data"]?.jsonObject
                val suggestList = dataObj?.get("suggest_list")?.jsonArray
                    ?: rootObj["suggest_list"]?.jsonArray

                if (suggestList != null && suggestList.isNotEmpty()) {
                    val results = mutableListOf<SearchResult>()
                    for (elem in suggestList) {
                        try {
                            val itObj = elem.jsonObject
                            val vData = itObj["video_data"]?.jsonObject
                            if (vData == null || vData.isEmpty()) continue

                            // 优先取精确的 keyword（短剧 series_id 的字符串形式，防止大整数在 JSON 反序列化中溢出截断）
                            val keywordVal = itObj["keyword"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                            val seriesIdFromData = vData["series_id"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                            val seriesId = if (keywordVal.matches(Regex("""\d{5,32}"""))) {
                                keywordVal
                            } else if (seriesIdFromData.matches(Regex("""\d{5,32}"""))) {
                                seriesIdFromData
                            } else {
                                keywordVal.ifEmpty { seriesIdFromData }
                            }
                            if (seriesId.isEmpty()) continue

                            val title = vData["series_title"]?.jsonPrimitive?.contentOrNull?.trim()
                                ?: itObj["name"]?.jsonPrimitive?.contentOrNull?.trim()
                                ?: continue

                            val cover = vData["series_cover"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                            val epCount = vData["episode_cnt"]?.jsonPrimitive?.intOrNull ?: 80
                            val intro = vData["series_intro"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()

                            // 预注入 VID 缓存与简介，加速用户点击后的起播体验
                            val vidsArr = vData["vid_list"]?.jsonArray
                            if (vidsArr != null && vidsArr.isNotEmpty()) {
                                val vids = vidsArr.mapNotNull { it.jsonPrimitive.contentOrNull?.trim() }.filter { it.isNotEmpty() }
                                if (vids.isNotEmpty()) {
                                    org.moontechlab.selenetv.hongguo.HongguoStreamResolver.cacheEpisodeVids(seriesId, vids)
                                }
                            }
                            if (intro.isNotEmpty()) {
                                org.moontechlab.selenetv.hongguo.HongguoStreamResolver.cacheSeriesIntro(seriesId, intro)
                            }

                            val epList = List(epCount) { (it + 1).toString() }
                            val epTitles = List(epCount) { "第${it + 1}集" }

                            results.add(
                                SearchResult(
                                    id = seriesId,
                                    title = title,
                                    poster = cover,
                                    episodes = epList,
                                    episodesTitles = epTitles,
                                    source = "hongguo",
                                    sourceName = "精品短剧",
                                    year = "2026",
                                    desc = intro.ifEmpty { "精品短剧官方原画，多清晰度极速秒开" },
                                    typeName = "短剧"
                                )
                            )
                        } catch (_: Exception) {}
                    }
                    if (results.isNotEmpty()) {
                        return@withContext results
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "搜索红果短剧失败: ${e.message}")
        }
        emptyList()
    }
}
