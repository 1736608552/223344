package org.moontechlab.selenetv.service

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.moontechlab.selenetv.model.SearchResource
import org.moontechlab.selenetv.model.SearchResult
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException
import java.net.URLEncoder
import java.nio.charset.Charset
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * 分页搜索结果
 */
data class SearchPageResult(
    val results: List<SearchResult>,
    val pageCount: Int
)

/**
 * 下游搜索服务
 * 用于从第三方API搜索视频资源
 * v2.7.77:
 *  - 全面切换为 OkHttp 异步长连接池 + 协程即时取消 (call.cancel)，彻底消灭旧 HttpURLConnection 阻塞拖垮 Dispatchers.IO 线程池导致刷新不出源
 *  - 修复 vod_douban_id == 0 被误解析为 0L 导致 SourceFilter 误杀大半采集源
 *  - 合理放宽单页超时至 10s（配合 SearchCacheService 超时仅短缓存 15s）
 */
object DownstreamService {
    private const val TAG = "DownstreamService"
    private const val MAX_SEARCH_PAGES = 2
    private const val UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.7727.139 Safari/537.36"

    private val PUNCT_NORM_REGEX = Regex("""[\s\u3000:：·\-—_'"‘’“”()（）\[\]【】《》!！?？,，.。/\\~～]+""")

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    /**
     * 专用多源并发搜索 OkHttpClient：
     * 复用 MediaHttp 的信任全证书 SSLContext 与 ConnectionPool，
     * 独立高并发 Dispatcher (maxRequests=96, maxRequestsPerHost=12)，绝不与播放器抢连接队列。
     */
    private val searchHttpClient: OkHttpClient by lazy {
        val dispatcher = Dispatcher().apply {
            maxRequests = 96
            maxRequestsPerHost = 12
        }
        MediaHttp.httpClient.newBuilder()
            .dispatcher(dispatcher)
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .callTimeout(12, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .retryOnConnectionFailure(true)
            .build()
    }

    /**
     * 服务端聚合 HTTP JSON 搜索 (/api/search?q=...) 专用 OkHttpClient：
     * 对齐手机端 ApiService.fetchSourcesData（20s 上限），复用全证书信任 SSL，避免国内宽带直连 CMS 被阻断仅出 4 个源。
     */
    private val serverSearchHttpClient: OkHttpClient by lazy {
        MediaHttp.httpClient.newBuilder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(16, TimeUnit.SECONDS)
            .callTimeout(18, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .retryOnConnectionFailure(true)
            .build()
    }

    /**
     * 咕噜咕噜官方专线映射表 (对齐 Web 端 downstream.ts 与官方 GuluGuluTV 架构)
     * 将代理解析接口（如 1ljx.com/?url=、jx.playerjy.com/?url=、jx.xmflv.com/?url= 等）
     * 自动映射为对应高可用直连秒播切片 CMS 接口
     */
    private data class GuluMapping(
        val match: (key: String, name: String, api: String) -> Boolean,
        val targetApi: String
    )

    private val GULUGULU_MAPPINGS = listOf(
        // 01_glgl_live: 咕噜直连切片代理 / glgl.tv (Live M3U8) -> 光速专线 (高并发节点)
        GuluMapping(
            match = { key, name, api ->
                api.contains("glgl.tv") || key.contains("glgl") ||
                name.contains("咕噜专线代理解析") || name.contains("咕噜直连切片")
            },
            targetApi = "https://api.guangsuapi.com/api.php/provide/vod/"
        ),
        // 02_1ljx_main & 03_1ljx_api: 咕噜1号官方专线 / 1ljx.com 主力解析及 API 直连 -> 量子专线 (秒播切片 / 新咕噜4K)
        GuluMapping(
            match = { key, name, api ->
                api.contains("1ljx.com") || key.contains("1ljx") ||
                name.contains("1号线路") || name.contains("咕噜1号")
            },
            targetApi = "https://cj.lziapi.com/api.php/provide/vod/"
        ),
        // 04_xmflv_jx: 虾米极速秒播解析 / xmflv.com -> 红牛资源 (超清综合 / 鲸宝4K)
        GuluMapping(
            match = { key, name, api ->
                api.contains("xmflv.com") || key.contains("xmflv") ||
                name.contains("虾米") || name.contains("极速秒播解析")
            },
            targetApi = "https://www.hongniuzy2.com/api.php/provide/vod/"
        ),
        // 05_playerjy_jx: 金鹰蓝光大片解析 / playerjy.com -> 金鹰影视 (蓝光大片 / VIP4K)
        GuluMapping(
            match = { key, name, api ->
                api.contains("playerjy.com") || key.contains("playerjy") ||
                name.contains("金鹰") || name.contains("优质蓝光解析")
            },
            targetApi = "https://jyzyapi.com/api.php/provide/vod/"
        ),
        // UC影音加速专线 / ucyy.cn -> 暴风专线 (高速秒播)
        GuluMapping(
            match = { key, name, api ->
                api.contains("ucyy.cn") || key.contains("ucyy") ||
                name.contains("uc影音") || name.contains("uc_speed")
            },
            targetApi = "https://bfzyapi.com/api.php/provide/vod/"
        )
    )

    /**
     * 获取资源真实生效的 API 基础地址（支持专线映射解析）
     */
    fun resolveEffectiveApi(resource: SearchResource): String {
        val rawApi = resource.api.trim()
        val key = resource.key.lowercase()
        val name = resource.name.lowercase()
        val apiLower = rawApi.lowercase()

        for (m in GULUGULU_MAPPINGS) {
            if (m.match(key, name, apiLower)) {
                return m.targetApi
            }
        }
        return rawApi
    }

    /**
     * 安全构建请求 URL，避免 ?url= 或已含 ? 时拼出畸形 URL
     */
    private fun buildSafeUrl(api: String, queryParam: String): String {
        val trimmed = api.trim()
        val sep = if (trimmed.contains("?")) "&" else "?"
        return "$trimmed$sep$queryParam"
    }

    private data class HttpPayload(
        val code: Int,
        val contentType: String?,
        val bytes: ByteArray
    )

    /**
     * 可即时取消的 OkHttp 异步请求（协程取消/超时瞬间关闭底层连接，绝不泄漏阻塞线程）
     */
    private suspend fun executeCancellable(
        url: String,
        accept: String,
        cookie: String? = null,
        client: OkHttpClient = searchHttpClient
    ): HttpPayload =
        suspendCancellableCoroutine { cont ->
            val reqBuilder = Request.Builder()
                .url(url)
                .get()
                .header("User-Agent", UA)
                .header("Accept", accept)
                .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
            if (!cookie.isNullOrBlank()) {
                reqBuilder.header("Cookie", cookie)
            }
            val call = client.newCall(reqBuilder.build())
            cont.invokeOnCancellation {
                try { call.cancel() } catch (_: Throwable) {}
            }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) {
                        cont.resumeWithException(e)
                    }
                }

                override fun onResponse(call: Call, response: Response) {
                    try {
                        response.use { resp ->
                            val payload = HttpPayload(
                                code = resp.code,
                                contentType = resp.header("Content-Type"),
                                bytes = resp.body?.bytes() ?: ByteArray(0)
                            )
                            if (cont.isActive) {
                                cont.resume(payload)
                            }
                        }
                    } catch (e: Throwable) {
                        if (cont.isActive) {
                            cont.resumeWithException(e)
                        }
                    }
                }
            })
        }

    private fun decodeResponseBody(bytes: ByteArray, contentType: String?): String {
        val charset = contentType?.let {
            Regex("charset=([^;]+)").find(it)?.groupValues?.get(1)?.lowercase()?.trim()
        }
        return when (charset) {
            "gbk", "gb2312" -> {
                try {
                    String(bytes, Charset.forName("GBK"))
                } catch (_: Exception) {
                    String(bytes, Charsets.UTF_8)
                }
            }
            else -> {
                try {
                    String(bytes, Charsets.UTF_8)
                } catch (_: Exception) {
                    try {
                        String(bytes, Charset.forName("GBK"))
                    } catch (_: Exception) {
                        String(bytes)
                    }
                }
            }
        }
    }

    /**
     * 从指定的搜索资源API搜索
     */
    suspend fun searchFromApi(
        resource: SearchResource,
        query: String
    ): List<SearchResult> = withContext(Dispatchers.IO) {
        try {
            val apiBaseUrl = resolveEffectiveApi(resource)
            val apiUrl = buildSafeUrl(apiBaseUrl, "ac=videolist&wd=${URLEncoder.encode(query, "UTF-8")}")

            // 搜索第一页
            val firstPageResult = searchPage(resource, query, 1, apiUrl)
            val results = firstPageResult.results.toMutableList()
            val pageCountFromFirst = firstPageResult.pageCount

            // 第 1 页已命中精准剧名直接短路，避免冗余翻页拖慢详情页出源
            val normQ = PUNCT_NORM_REGEX.replace(query.trim().lowercase(), "")
            val hasExactHitOnPage1 = normQ.isNotEmpty() && results.any { r ->
                r.episodes.isNotEmpty() && run {
                    val t = PUNCT_NORM_REGEX.replace(r.title.trim().lowercase(), "")
                    t == normQ || t.startsWith(normQ) || normQ.startsWith(t)
                }
            }
            val pagesToFetch = if (hasExactHitOnPage1) {
                0
            } else {
                minOf(pageCountFromFirst - 1, MAX_SEARCH_PAGES - 1)
            }

            // 并发获取其他页面
            if (pagesToFetch > 0) {
                val additionalResults = (2..pagesToFetch + 1).map { page ->
                    async {
                        val pageUrl = buildSafeUrl(apiBaseUrl, "ac=videolist&wd=${URLEncoder.encode(query, "UTF-8")}&pg=$page")
                        searchPage(resource, query, page, pageUrl).results
                    }
                }.awaitAll()

                additionalResults.forEach { pageResults ->
                    if (pageResults.isNotEmpty()) {
                        results.addAll(pageResults)
                    }
                }
            }

            // 过滤包含黄色关键词的结果
            results.filter { result ->
                !ContentFilterService.shouldFilter(result.typeName)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "搜索失败: ${e.message}", e)
            emptyList()
        }
    }

    /**
     * 清理 HTML 标签
     */
    private fun cleanHtmlTags(text: String?): String {
        if (text.isNullOrBlank()) return ""
        return text
            .replace(Regex("<[^>]+>"), "\n")
            .replace(Regex("\n+"), "\n")
            .replace(Regex("[ \t]+"), " ")
            .replace(Regex("^\n+|\n+$"), "")
            .trim()
            .let { decodeHtmlEntities(it) }
    }

    /**
     * 解码 HTML 实体
     */
    private fun decodeHtmlEntities(text: String): String {
        return text
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&nbsp;", " ")
    }

    /**
     * 分页搜索
     */
    private suspend fun searchPage(
        resource: SearchResource,
        query: String,
        page: Int,
        url: String
    ): SearchPageResult {
        // 先查缓存
        val cached = SearchCacheService.getCachedSearchPage(resource.key, query, page)
        if (cached != null) {
            return if (cached.status == CachedPageStatus.OK) {
                SearchPageResult(cached.data, cached.pageCount ?: 1)
            } else {
                SearchPageResult(emptyList(), 1)
            }
        }

        try {
            val payload = executeCancellable(url, "application/json")

            // 检查 403 状态码，短缓存 forbidden
            if (payload.code == 403) {
                SearchCacheService.setCachedSearchPage(
                    resource.key, query, page,
                    CachedPageStatus.FORBIDDEN, emptyList()
                )
                return SearchPageResult(emptyList(), 1)
            }

            if (payload.code !in 200..299) {
                return SearchPageResult(emptyList(), 1)
            }

            val responseBody = decodeResponseBody(payload.bytes, payload.contentType)
            if (responseBody.isBlank()) {
                return SearchPageResult(emptyList(), 1)
            }

            val data = json.parseToJsonElement(responseBody).jsonObject
            val list = data["list"]?.jsonArray

            if (list == null || list.isEmpty()) {
                return SearchPageResult(emptyList(), 1)
            }

            val allResults = list.mapNotNull { itemElement ->
                parseSearchResultItem(itemElement.jsonObject, resource)
            }

            // 过滤出有剧集的结果
            val results = allResults.filter { it.episodes.isNotEmpty() }
            val pageCount = if (page == 1) {
                data["pagecount"]?.jsonPrimitive?.intOrNull ?: 1
            } else 1

            // 缓存成功的搜索结果
            SearchCacheService.setCachedSearchPage(
                resource.key, query, page,
                CachedPageStatus.OK, results,
                if (page == 1) pageCount else null
            )

            return SearchPageResult(results, pageCount)
        } catch (e: CancellationException) {
            throw e
        } catch (e: SocketTimeoutException) {
            // 超时仅短缓存 15s（由 SearchCacheService 控制）
            SearchCacheService.setCachedSearchPage(
                resource.key, query, page,
                CachedPageStatus.TIMEOUT, emptyList()
            )
            return SearchPageResult(emptyList(), 1)
        } catch (e: InterruptedIOException) {
            SearchCacheService.setCachedSearchPage(
                resource.key, query, page,
                CachedPageStatus.TIMEOUT, emptyList()
            )
            return SearchPageResult(emptyList(), 1)
        } catch (e: Exception) {
            // 其他异常不缓存，直接返回空结果
            Log.e(TAG, "搜索页面失败(${resource.key}): ${e.message}")
            return SearchPageResult(emptyList(), 1)
        }
    }

    /**
     * 解析单个搜索结果项
     */
    private fun parseSearchResultItem(
        item: JsonObject,
        resource: SearchResource
    ): SearchResult? {
        var episodes = mutableListOf<String>()
        var titles = mutableListOf<String>()

        val vodPlayUrl = item["vod_play_url"]?.jsonPrimitive?.contentOrNull
        if (!vodPlayUrl.isNullOrBlank()) {
            val vodPlayUrlArray = vodPlayUrl.split("$$$")
            var bestScore = -1

            for (group in vodPlayUrlArray) {
                val matchEpisodes = mutableListOf<String>()
                val matchTitles = mutableListOf<String>()
                val titleUrlArray = group.split("#")

                for (titleUrl in titleUrlArray) {
                    val episodeTitleUrl = titleUrl.split("$")
                    val epUrl = if (episodeTitleUrl.size >= 2) episodeTitleUrl.last().trim() else titleUrl.trim()
                    val epTitle = if (episodeTitleUrl.size >= 2) episodeTitleUrl.first().trim() else "第${matchEpisodes.size + 1}集"

                    if (epUrl.startsWith("http://") || epUrl.startsWith("https://")) {
                        matchTitles.add(epTitle)
                        matchEpisodes.add(epUrl)
                    }
                }

                if (matchEpisodes.isNotEmpty()) {
                    // 画质加权选择：集数基础分 + m3u8直链加权 + 4K/原画/蓝光 极高加权 (对齐 Web 与手机端)
                    var score = matchEpisodes.size * 10
                    val groupText = group.take(300).lowercase()
                    if (groupText.contains(".m3u8")) {
                        score += 100 // 优先原生 m3u8 切片，防止误选 /share/ 网页
                    }
                    if (groupText.contains("4k") || groupText.contains("2160") ||
                        groupText.contains("原画") || groupText.contains("蓝光") ||
                        groupText.contains("uhd")) {
                        score += 500
                    } else if (groupText.contains("2k") || groupText.contains("1440")) {
                        score += 200
                    } else if (groupText.contains("1080") || groupText.contains("超清") || groupText.contains("fhd")) {
                        score += 50
                    }

                    if (score > bestScore) {
                        bestScore = score
                        episodes = matchEpisodes
                        titles = matchTitles
                    }
                }
            }
        }

        val vodYear = item["vod_year"]?.jsonPrimitive?.contentOrNull
        val year = if (!vodYear.isNullOrBlank()) {
            Regex("\\d{4}").find(vodYear)?.value ?: "unknown"
        } else "unknown"

        val vodId = item["vod_id"]?.jsonPrimitive?.contentOrNull ?: return null
        val vodName = item["vod_name"]?.jsonPrimitive?.contentOrNull ?: return null
        // v2.7.77: 采集站未填豆瓣 ID 时普遍返回 vod_douban_id=0，必须转为 null 避免被 SourceFilter 当成错误豆瓣 ID 误杀！
        val validDoubanId = item["vod_douban_id"]?.jsonPrimitive?.longOrNull?.takeIf { it > 0L }

        return SearchResult(
            id = vodId,
            title = vodName.trim().replace(Regex("\\s+"), " "),
            poster = item["vod_pic"]?.jsonPrimitive?.contentOrNull ?: "",
            episodes = episodes,
            episodesTitles = titles,
            source = resource.key,
            sourceName = resource.name,
            classType = item["vod_class"]?.jsonPrimitive?.contentOrNull,
            year = year,
            desc = cleanHtmlTags(item["vod_content"]?.jsonPrimitive?.contentOrNull),
            typeName = item["type_name"]?.jsonPrimitive?.contentOrNull,
            doubanId = validDoubanId
        )
    }

    /**
     * 通过 source+id 直接向下游 API 精确拉取单条详情。
     * 用于：详情页来自播放记录/收藏夹（带 source+id），但按标题搜索未命中该具体源时，
     * 精确补齐这一条加入结果集。失败返回 null。
     * 迁移自 mobile SearchService.getDetailSync。
     */
    suspend fun getDetailBySourceId(source: String, id: String): SearchResult? =
        withContext(Dispatchers.IO) {
            try {
                val resource = org.moontechlab.selenetv.data.Repositories.sources().getSearchResources()
                    .firstOrNull { it.key == source }
                if (resource == null) {
                    Log.w(TAG, "getDetailBySourceId: 未找到源 key=$source")
                    return@withContext null
                }

                // 优先走标准 JSON 详情接口（?ac=videolist&ids=），绝大多数 CMS 源此接口可用，
                // 且能像搜索那样自动挑选 m3u8 播放组。仅当它拿不到剧集时再回退 HTML 抓取。
                val fromJson = fetchJsonDetail(id, resource)
                if (fromJson != null && fromJson.episodes.isNotEmpty()) {
                    return@withContext fromJson
                }

                if (!resource.detail.isNullOrBlank()) {
                    val sp = fetchSpecialSourceDetail(id, resource)
                    if (sp != null && sp.episodes.isNotEmpty()) {
                        return@withContext sp
                    }
                    Log.w(TAG, "getDetailBySourceId: JSON 与 HTML 均无可用剧集 key=$source id=$id")
                }
                fromJson // 可能为 null 或 episodes 为空（交由调用方决定是否使用）
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "getDetailBySourceId 失败: ${e.message}", e)
                null
            }
        }

    /**
     * 标准 JSON 详情接口（?ac=videolist&ids=）解析为单条 SearchResult。无果返回 null。
     */
    private suspend fun fetchJsonDetail(id: String, resource: SearchResource): SearchResult? {
        val effectiveApi = resolveEffectiveApi(resource)
        val detailUrl = buildSafeUrl(effectiveApi, "ac=videolist&ids=$id")
        val body = httpGet(detailUrl, "application/json") ?: return null

        val list = try {
            json.parseToJsonElement(body).jsonObject["list"]?.jsonArray
        } catch (e: Exception) {
            Log.w(TAG, "fetchJsonDetail: 响应非 JSON url=$detailUrl 前 120 字符=${body.take(120)}")
            return null
        }
        if (list.isNullOrEmpty()) return null

        val item = list[0].jsonObject
        // 复用搜索项解析；强制 id 为请求值，避免下游详情返回的 vod_id 与请求不一致
        val base = parseSearchResultItem(item, resource)?.copy(id = id) ?: return null

        // 播放源为空时，从 vod_content 兜底抓取 m3u8（迁移自 mobile）
        if (base.episodes.isEmpty()) {
            val content = item["vod_content"]?.jsonPrimitive?.contentOrNull
            if (!content.isNullOrBlank()) {
                val m3u8 = Regex("""https?://[^\s<>"]+\.m3u8""")
                    .findAll(content).map { it.value }.toList()
                if (m3u8.isNotEmpty()) {
                    return base.copy(
                        episodes = m3u8,
                        episodesTitles = m3u8.indices.map { (it + 1).toString() },
                    )
                }
            }
        }
        return base
    }

    /**
     * 特殊源详情（detail 非空）：抓取 HTML 详情页并正则解析 m3u8/标题/封面等。
     * 迁移自 mobile SearchService._handleSpecialSourceDetail。
     */
    private suspend fun fetchSpecialSourceDetail(id: String, resource: SearchResource): SearchResult? {
        val detailUrl = "${resource.detail}/index.php/vod/detail/id/$id.html"
        val html = httpGet(detailUrl, "text/html") ?: return null

        // ffzy 源使用更严格的正则，其余源/未命中时退回通用 m3u8 正则
        var matches: List<String> = if (resource.key == "ffzy") {
            Regex("""\$(https?://[^"'\s]+?/\d{8}/\d+_[a-f0-9]+/index\.m3u8)""")
                .findAll(html).map { it.value }.toList()
        } else emptyList()

        if (matches.isEmpty()) {
            matches = Regex("""\$(https?://[^"'\s]+?\.m3u8)""")
                .findAll(html).map { it.value }.toList()
        }

        // 去重并清理链接前缀（去掉开头的 $ 与可能的括号后缀）
        val episodes = matches.toSet().toList().map { link ->
            val l = link.substring(1)
            val paren = l.indexOf('(')
            if (paren > 0) l.substring(0, paren) else l
        }
        if (episodes.isEmpty()) return null

        val titles = episodes.indices.map { (it + 1).toString() }
        val title = Regex("""<h1[^>]*>([^<]+)</h1>""").find(html)?.groupValues?.get(1)?.trim() ?: ""
        val desc = Regex("""<div[^>]*class=["']sketch["'][^>]*>([\s\S]*?)</div>""")
            .find(html)?.groupValues?.get(1)?.let { cleanHtmlTags(it) } ?: ""
        val cover = Regex("""https?://[^"'\s]+?\.jpg""").find(html)?.value?.trim() ?: ""
        val year = Regex(""">(\d{4})<""").find(html)?.groupValues?.get(1) ?: "unknown"

        return SearchResult(
            id = id,
            title = title.replace(Regex("\\s+"), " ").trim(),
            poster = cover,
            episodes = episodes,
            episodesTitles = titles,
            source = resource.key,
            sourceName = resource.name,
            classType = "",
            year = year,
            desc = desc,
            typeName = "",
            doubanId = null,
        )
    }

    /**
     * 简单 GET（复用搜索 OkHttp 长连接池），失败/非 2xx 返回 null。
     */
    private suspend fun httpGet(url: String, accept: String): String? {
        return try {
            val payload = executeCancellable(url, accept)
            if (payload.code !in 200..299) {
                Log.w(TAG, "httpGet 非 2xx: ${payload.code} url=$url")
                return null
            }
            decodeResponseBody(payload.bytes, payload.contentType)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "httpGet 失败: $url ${e.message}")
            null
        }
    }

    /**
     * 服务端鉴权失效标记异常（HTTP 401）
     */
    internal class ServerAuthExpiredException(message: String = "登录状态失效，请重新登录") : Exception(message)

    private fun JsonObject.optString(key: String): String? {
        val prim = this[key] as? JsonPrimitive ?: return null
        if (prim is JsonNull) return null
        return prim.contentOrNull
    }

    private fun JsonObject.optStringList(key: String): List<String> {
        val arr = this[key] as? JsonArray ?: return emptyList()
        return arr.mapNotNull { el ->
            val prim = el as? JsonPrimitive ?: return@mapNotNull null
            if (prim is JsonNull) null else prim.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
        }
    }

    /**
     * 容错解析服务端 (/api/search 或 /api/search/ws) 返回的单条 SearchResult JSON。
     * 彻底避免 kotlinx.serialization 默认解码遇到 episodes_titles=null / poster=null / douban_id="" / id=Int
     * 时抛 SerializationException 静默丢弃大半播放源。
     */
    internal fun parseServerSearchResult(el: JsonElement): SearchResult? {
        val obj = el as? JsonObject ?: return null
        val episodes = obj.optStringList("episodes")
        if (episodes.isEmpty()) return null

        val typeName = obj.optString("type_name")
        if (ContentFilterService.shouldFilter(typeName)) return null

        val id = obj.optString("id")?.trim().orEmpty()
        val rawTitle = obj.optString("title")?.trim().orEmpty()
        val source = obj.optString("source")?.trim().orEmpty()
        if (rawTitle.isEmpty() || source.isEmpty()) return null

        val sourceName = obj.optString("source_name")?.trim()?.takeIf { it.isNotEmpty() } ?: source
        val poster = obj.optString("poster")?.trim().orEmpty()
        val episodesTitles = obj.optStringList("episodes_titles")
        val rawYear = obj.optString("year")?.trim().orEmpty()
        val year = if (rawYear.isNotEmpty()) {
            Regex("\\d{4}").find(rawYear)?.value ?: rawYear
        } else {
            "unknown"
        }
        val doubanId = (obj["douban_id"] as? JsonPrimitive)
            ?.takeIf { it !is JsonNull }
            ?.let { prim -> prim.longOrNull ?: prim.contentOrNull?.trim()?.toLongOrNull() }
            ?.takeIf { it > 0L }

        return SearchResult(
            id = id.ifEmpty { "${source}_${rawTitle.hashCode()}" },
            title = rawTitle.replace(Regex("\\s+"), " "),
            poster = poster,
            episodes = episodes,
            episodesTitles = episodesTitles,
            source = source,
            sourceName = sourceName,
            classType = obj.optString("class"),
            year = year,
            desc = obj.optString("desc"),
            typeName = typeName,
            doubanId = doubanId
        )
    }

    /**
     * 调用服务端标准 HTTP JSON 聚合搜索接口 GET /api/search?q=...（与手机端 ApiService.fetchSourcesData 1:1 对齐）。
     * 服务端运行在云服务器/VPS/NAS 网络环境，可畅通访问全部 20+ 采集站，彻底突破国内宽带 TV 直连被 DNS 污染/CF 拦截只剩 4 源的问题。
     */
    suspend fun searchServerHttpApi(
        baseUrl: String,
        cookies: String,
        query: String
    ): List<SearchResult> = withContext(Dispatchers.IO) {
        val cleanBase = baseUrl.trim().trimEnd('/')
        val cacheKey = "__server_http__::$cleanBase"
        val cached = SearchCacheService.getCachedSearchPage(cacheKey, query, 1)
        if (cached != null && cached.status == CachedPageStatus.OK && cached.data.isNotEmpty()) {
            return@withContext cached.data
        }

        val url = "$cleanBase/api/search?q=${URLEncoder.encode(query, "UTF-8")}"
        try {
            val payload = executeCancellable(
                url = url,
                accept = "application/json",
                cookie = cookies,
                client = serverSearchHttpClient
            )
            if (payload.code == 401) {
                throw ServerAuthExpiredException()
            }
            if (payload.code !in 200..299) {
                Log.w(TAG, "服务端 /api/search 返回 HTTP ${payload.code}")
                return@withContext emptyList()
            }
            val body = decodeResponseBody(payload.bytes, payload.contentType)
            if (body.isBlank()) return@withContext emptyList()

            val root = json.parseToJsonElement(body)
            val arr: JsonArray = when (root) {
                is JsonObject -> root["results"] as? JsonArray ?: return@withContext emptyList()
                is JsonArray -> root
                else -> return@withContext emptyList()
            }
            val parsed = arr.mapNotNull { el -> parseServerSearchResult(el) }
            if (parsed.isNotEmpty()) {
                SearchCacheService.setCachedSearchPage(
                    cacheKey, query, 1,
                    CachedPageStatus.OK, parsed, 1
                )
            }
            Log.d(TAG, "服务端 /api/search 命中 ${parsed.size} 条有效可播源 (query=\"$query\")")
            parsed
        } catch (e: CancellationException) {
            throw e
        } catch (e: ServerAuthExpiredException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "服务端 /api/search 请求异常: ${e.message}")
            emptyList()
        }
    }
}
