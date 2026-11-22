package org.moontechlab.selenetv.service

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.moontechlab.selenetv.model.SearchResource
import org.moontechlab.selenetv.model.SearchResult
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * 搜索进度信息
 */
data class SearchProgress(
    val totalSources: Int,
    val completedSources: Int,
    val currentSource: String?,
    val isComplete: Boolean,
    val error: String? = null
)

/**
 * 搜索事件
 */
sealed class SearchEvent {
    data class Results(val results: List<SearchResult>) : SearchEvent()
    data class Progress(val progress: SearchProgress) : SearchEvent()
    data class Error(val message: String) : SearchEvent()
    data object Complete : SearchEvent()
}

/**
 * 流式搜索服务
 * 实现增量搜索结果推送
 * v2.7.78:
 *  - 服务端模式下（含默认 TV_DIRECT），并发双通道竞速合并：
 *    通道 A = 服务端标准 HTTP JSON /api/search?q=...（与手机端 1:1 对齐，突破国内宽带 TV 直连 DNS 污染/GFW/CF 阻断，出全 20+ 源）
 *    通道 B = 客户端 OkHttp 长连接并发直连多源（快源 0.3~0.8s 秒出 + 咕噜专线映射 + 红果短剧）
 *  - 服务端 SSE (/api/search/ws) 改用容错 JSON 解析器，并增加 1.8s /api/search HTTP JSON 对冲补齐，防止代理截断 SSE 或字段 null 导致丢源
 *  - 服务端已返足量源 (>=8) 时给本地直连 4.5s 宽限期后干净收尾，避免被国内不可达死域拖满 16s
 */
object SearchService {
    private const val TAG = "SearchService"
    private const val SEARCH_TIMEOUT_MS = 16000L
    private const val SINGLE_SOURCE_TIMEOUT_MS = 12000L
    private const val SERVER_HTTP_TIMEOUT_MS = 16000L
    private const val SERVER_RICH_SOURCE_THRESHOLD = 8
    private const val LOCAL_GRACE_TOTAL_MS = 4500L
    private const val LOCAL_GRACE_AFTER_SERVER_MS = 2000L
    private const val SSE_CONNECT_TIMEOUT_MS = 5000
    private const val SSE_READ_TIMEOUT_MS = 10000
    private const val SSE_HTTP_HEDGE_DELAY_MS = 1800L
    private const val SSE_HEDGE_DELAY_MS = 2500L
    private const val SSE_MIN_SOURCES_BEFORE_SUPPLEMENT = 5

    // 搜索运行在服务自有的 scope 上，stopSearch 才能真正持有并取消 Job
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    @Volatile private var _isSearching = false
    @Volatile private var _currentQuery: String? = null
    private val _completedSources = AtomicInteger(0)
    @Volatile private var _totalSources = 0
    private val _sourceErrors = ConcurrentHashMap<String, String>()
    @Volatile private var _searchJob: Job? = null
    // 服务端聚合搜索的 SSE 连接，stopSearch 时需主动 disconnect 才能让阻塞的 readLine 抛出
    @Volatile private var _serverConnection: HttpURLConnection? = null

    // 事件流：扩大缓冲至 256，防止 30+ 源并发吐出 Results + Progress 造成背压阻塞
    private val _eventFlow = MutableSharedFlow<SearchEvent>(extraBufferCapacity = 256)
    val eventFlow: SharedFlow<SearchEvent> = _eventFlow.asSharedFlow()

    val isSearching: Boolean get() = _isSearching
    val currentQuery: String? get() = _currentQuery
    val sourceErrors: Map<String, String> get() = _sourceErrors.toMap()

    /**
     * 别名与口语化搜词智能纠偏字典（自动对齐 CMS 官方入库剧名）
     */
    private fun resolveSearchAlias(raw: String): String {
        var q = raw.trim()
        if (q.contains("欢迎光临龙餐馆")) {
            q = q.replace("欢迎光临龙餐馆", "欢迎来龙餐馆")
        }
        return q
    }

    /**
     * 当前是否处于已登录服务端模式且具备调用 /api/search?q=... 的凭据
     */
    private fun canUseServerSearch(): Boolean {
        if (AppDataService.isLocalModeSync()) return false
        val baseUrl = AppDataService.getServerUrlSync()
        val cookies = AppDataService.getCookiesSync()
        return !baseUrl.isNullOrBlank() && !cookies.isNullOrBlank()
    }

    /**
     * 停止上一次搜索并等待其协程彻底结束（避免残留 Complete/Results 事件污染新页面）
     */
    suspend fun stopSearchAndWait() {
        try { _serverConnection?.disconnect() } catch (_: Exception) {}
        _serverConnection = null
        val oldJob = _searchJob
        _searchJob = null
        if (oldJob != null) {
            try { oldJob.cancelAndJoin() } catch (_: Exception) {}
        }
        _isSearching = false
        _currentQuery = null
    }

    /**
     * 开始搜索
     */
    suspend fun startSearch(query: String) {
        val trimmedQuery = resolveSearchAlias(query.trim())
        if (trimmedQuery.isEmpty()) {
            throw IllegalArgumentException("搜索查询不能为空")
        }

        // 先关旧连接再取消等待，避免阻塞中的 SSE 拖延 cancelAndJoin
        try { _serverConnection?.disconnect() } catch (_: Exception) {}
        _serverConnection = null
        _searchJob?.cancelAndJoin()

        _currentQuery = trimmedQuery
        _isSearching = true
        _completedSources.set(0)
        _totalSources = 0
        _sourceErrors.clear()

        val origin = AppDataService.getSearchOriginSync()
        val serverAvailable = canUseServerSearch()
        Log.d(TAG, "startSearch query=\"$trimmedQuery\" origin=${origin.key} serverAvailable=$serverAvailable")
        _searchJob = serviceScope.launch {
            try {
                when (origin) {
                    AppDataService.SearchOrigin.TV_DIRECT -> {
                        if (serverAvailable) {
                            dualChannelDirectAndServerSearch(trimmedQuery)
                        } else {
                            localSearch(trimmedQuery, emitFinalComplete = true)
                        }
                    }
                    AppDataService.SearchOrigin.SERVER_AGGREGATED -> serverAggregatedSearch(trimmedQuery)
                }
            } catch (e: CancellationException) {
                Log.d(TAG, "搜索被取消")
                _isSearching = false
            } catch (e: Exception) {
                _eventFlow.emit(SearchEvent.Error("搜索失败: ${e.message}"))
                _eventFlow.emit(SearchEvent.Complete)
                _isSearching = false
            }
        }
    }

    /**
     * 服务端 HTTP JSON 聚合搜索通道（GET /api/search?q=...，与手机端 ApiService.fetchSourcesData 1:1 对齐）。
     * 返回去重后的源数量；若鉴权失效返回 -1；其余失败返回 0。
     */
    private suspend fun fetchAndEmitServerHttpSearch(query: String): Int {
        val baseUrl = AppDataService.getServerUrlSync()
        val cookies = AppDataService.getCookiesSync()
        if (baseUrl.isNullOrBlank() || cookies.isNullOrBlank()) return 0

        return try {
            val results = withTimeoutOrNull(SERVER_HTTP_TIMEOUT_MS) {
                DownstreamService.searchServerHttpApi(baseUrl, cookies, query)
            } ?: emptyList()

            currentCoroutineContext().ensureActive()
            if (results.isNotEmpty()) {
                _eventFlow.emit(SearchEvent.Results(results))
            }
            val uniqueSources = results.mapNotNull { it.source.takeIf { s -> s.isNotBlank() } }.distinct().size
            Log.d(TAG, "服务端 HTTP /api/search 完成: 条目=${results.size} 独立源=$uniqueSources")
            uniqueSources
        } catch (e: CancellationException) {
            throw e
        } catch (e: DownstreamService.ServerAuthExpiredException) {
            Log.w(TAG, "服务端 HTTP /api/search 鉴权失效 (401)")
            -1
        } catch (e: Exception) {
            Log.w(TAG, "服务端 HTTP /api/search 通道异常: ${e.message}")
            0
        }
    }

    /**
     * 服务端模式默认双通道并发搜索：
     *  - 通道 A：服务端 HTTP JSON /api/search?q=...（云端网络畅通，一次吐出全部 20+ 源）
     *  - 通道 B：客户端直连多源并发（国内可达源/咕噜专线/红果短剧 0.3~0.8s 秒出）
     * 任一通道结果立即流式推送到 UI 并由 DetailScreen/SearchTab 去重合并。
     */
    private suspend fun dualChannelDirectAndServerSearch(query: String) = coroutineScope {
        val startMs = System.currentTimeMillis()
        val serverTask = async(Dispatchers.IO) {
            fetchAndEmitServerHttpSearch(query)
        }
        val localTask = async(Dispatchers.IO) {
            try {
                localSearch(query, emitFinalComplete = false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "双通道本地直连异常（不影响服务端结果）: ${e.message}")
            }
        }

        val serverSourceCount = try {
            serverTask.await()
        } catch (e: CancellationException) {
            localTask.cancel()
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "双通道服务端搜索异常: ${e.message}")
            0
        }

        if (serverSourceCount >= SERVER_RICH_SOURCE_THRESHOLD) {
            // 服务端已返回足量源（如 20+ 源）：给本地直连合理宽限期以收齐可达快源/咕噜专线/红果短剧，随后释放死域等待
            val elapsed = System.currentTimeMillis() - startMs
            val graceMs = maxOf(LOCAL_GRACE_TOTAL_MS - elapsed, LOCAL_GRACE_AFTER_SERVER_MS)
            val finishedInGrace = withTimeoutOrNull(graceMs) {
                localTask.await()
                true
            }
            if (finishedInGrace == null) {
                Log.d(TAG, "服务端已出 $serverSourceCount 源且本地宽限期(${graceMs}ms)结束，取消剩余慢/不可达直连源")
                localTask.cancel()
            }
        } else {
            // 服务端未返足量源或超时：完整等待本地多源直连跑完
            try {
                localTask.await()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "等待本地直连结束异常: ${e.message}")
            }
        }

        if (isActive) {
            val total = _totalSources.coerceAtLeast(1)
            _eventFlow.emit(
                SearchEvent.Progress(
                    SearchProgress(
                        totalSources = total,
                        completedSources = total,
                        currentSource = null,
                        isComplete = true
                    )
                )
            )
            _eventFlow.emit(SearchEvent.Complete)
            _isSearching = false
        }
    }

    /**
     * 本地搜索（并发搜索所有资源）
     */
    private suspend fun localSearch(query: String, emitFinalComplete: Boolean = true) = coroutineScope {
        try {
            // 获取搜索资源列表
            val allResources = org.moontechlab.selenetv.data.Repositories.sources().getSearchResources()
            val resources = allResources.filter { !it.disabled }

            if (resources.isEmpty()) {
                if (emitFinalComplete) {
                    _eventFlow.emit(SearchEvent.Error("没有可用的搜索资源"))
                    _eventFlow.emit(SearchEvent.Complete)
                    _isSearching = false
                }
                return@coroutineScope
            }

            _totalSources = resources.size + 1
            _completedSources.set(0)

            // 发送初始进度
            _eventFlow.emit(
                SearchEvent.Progress(
                    SearchProgress(
                        totalSources = _totalSources,
                        completedSources = 0,
                        currentSource = null,
                        isComplete = false
                    )
                )
            )

            // 设置超时
            val searchWithTimeout = async {
                withTimeout(SEARCH_TIMEOUT_MS) {
                    // 并发搜索所有常规采集源 + 独立红果精品短剧专网源
                    val tasks = mutableListOf<Deferred<Unit>>()
                    tasks.addAll(resources.map { resource ->
                        async {
                            searchSingleResource(resource, query)
                        }
                    })
                    tasks.add(async {
                        searchShortDramaResource(query)
                    })
                    tasks.awaitAll()
                }
            }

            try {
                searchWithTimeout.await()
            } catch (e: TimeoutCancellationException) {
                if (emitFinalComplete) {
                    handleTimeout()
                }
                return@coroutineScope
            }

            if (emitFinalComplete) {
                // 发送完成事件
                _eventFlow.emit(
                    SearchEvent.Progress(
                        SearchProgress(
                            totalSources = _totalSources,
                            completedSources = _totalSources,
                            currentSource = null,
                            isComplete = true
                        )
                    )
                )
                _eventFlow.emit(SearchEvent.Complete)
                _isSearching = false
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (emitFinalComplete) {
                _eventFlow.emit(SearchEvent.Error("本地搜索异常: ${e.message}"))
                _eventFlow.emit(SearchEvent.Complete)
                _isSearching = false
            } else {
                Log.w(TAG, "本地搜索通道异常: ${e.message}")
            }
        }
    }

    /**
     * 搜索单个资源
     */
    private suspend fun searchSingleResource(resource: SearchResource, query: String) {
        try {
            val results = withTimeout(SINGLE_SOURCE_TIMEOUT_MS) {
                DownstreamService.searchFromApi(resource, query)
            }
            currentCoroutineContext().ensureActive()
            val completed = _completedSources.incrementAndGet()

            // 发送结果事件（只发送增量有效结果）
            if (results.isNotEmpty()) {
                _eventFlow.emit(SearchEvent.Results(results))
            }

            // 发送进度更新
            _eventFlow.emit(
                SearchEvent.Progress(
                    SearchProgress(
                        totalSources = _totalSources,
                        completedSources = completed.coerceAtMost(_totalSources.coerceAtLeast(completed)),
                        currentSource = resource.name,
                        isComplete = false
                    )
                )
            )
        } catch (e: TimeoutCancellationException) {
            handleSourceError(resource, "搜索超时")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            handleSourceError(resource, e.message ?: "未知错误")
        }
    }

    /**
     * 处理单个资源搜索错误
     */
    private suspend fun handleSourceError(resource: SearchResource, errorMessage: String) {
        val completed = _completedSources.incrementAndGet()
        _sourceErrors[resource.key] = errorMessage

        _eventFlow.emit(
            SearchEvent.Progress(
                SearchProgress(
                    totalSources = _totalSources,
                    completedSources = completed.coerceAtMost(_totalSources.coerceAtLeast(completed)),
                    currentSource = resource.name,
                    isComplete = false,
                    error = errorMessage
                )
            )
        )
    }

    /**
     * 搜索独立红果精品短剧专网源
     */
    private suspend fun searchShortDramaResource(query: String) {
        try {
            val dramaResults = ShortDramaService.searchDramas(query).filter { it.episodes.isNotEmpty() }
            currentCoroutineContext().ensureActive()
            val completed = _completedSources.incrementAndGet()

            if (dramaResults.isNotEmpty()) {
                _eventFlow.emit(SearchEvent.Results(dramaResults))
            }

            _eventFlow.emit(
                SearchEvent.Progress(
                    SearchProgress(
                        totalSources = _totalSources,
                        completedSources = completed.coerceAtMost(_totalSources.coerceAtLeast(completed)),
                        currentSource = "精品短剧",
                        isComplete = false
                    )
                )
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val completed = _completedSources.incrementAndGet()
            Log.w(TAG, "精品短剧搜索失败: ${e.message}")
            _eventFlow.emit(
                SearchEvent.Progress(
                    SearchProgress(
                        totalSources = _totalSources,
                        completedSources = completed.coerceAtMost(_totalSources.coerceAtLeast(completed)),
                        currentSource = "精品短剧",
                        isComplete = false
                    )
                )
            )
        }
    }

    /**
     * 处理超时
     */
    private suspend fun handleTimeout() {
        if (_completedSources.get() < _totalSources) {
            _completedSources.set(_totalSources)
        }

        _eventFlow.emit(
            SearchEvent.Progress(
                SearchProgress(
                    totalSources = _totalSources,
                    completedSources = _completedSources.get(),
                    currentSource = null,
                    isComplete = true
                )
            )
        )
        _eventFlow.emit(SearchEvent.Error("部分源响应超时"))
        _eventFlow.emit(SearchEvent.Complete)
        _isSearching = false
    }

    /**
     * 服务端聚合搜索（SSE 流式）+ 1.8s 服务端 HTTP JSON (/api/search) 对冲 + 本地直连对冲补齐
     * 命中条件由调用方在 startSearch 中读 SearchOrigin 决定
     */
    private suspend fun serverAggregatedSearch(query: String) = coroutineScope {
        val localJobLock = Any()
        val localJobRef = AtomicReference<Deferred<Unit>?>(null)
        val serverHttpJobLock = Any()
        val serverHttpJobRef = AtomicReference<Deferred<Int>?>(null)
        val sseEmittedSources = ConcurrentHashMap.newKeySet<String>()

        fun ensureServerHttpStarted() {
            synchronized(serverHttpJobLock) {
                if (serverHttpJobRef.get() == null) {
                    serverHttpJobRef.set(
                        async(Dispatchers.IO) {
                            fetchAndEmitServerHttpSearch(query)
                        }
                    )
                }
            }
        }

        fun ensureLocalStarted() {
            synchronized(localJobLock) {
                if (localJobRef.get() == null) {
                    localJobRef.set(
                        async(Dispatchers.IO) {
                            localSearch(query, emitFinalComplete = false)
                        }
                    )
                }
            }
        }

        // 1.8s 服务端 HTTP JSON 对冲定时器：若代理/CF 缓冲 SSE 导致迟迟未出足量源，立刻并行拉取标准 /api/search?q=...
        val httpHedgeJob = launch(Dispatchers.IO) {
            delay(SSE_HTTP_HEDGE_DELAY_MS)
            if (sseEmittedSources.size < SSE_MIN_SOURCES_BEFORE_SUPPLEMENT && isActive) {
                Log.w(TAG, "服务端 SSE ${SSE_HTTP_HEDGE_DELAY_MS}ms 内仅出 ${sseEmittedSources.size} 源，并行启动 HTTP /api/search 对冲")
                ensureServerHttpStarted()
            }
        }

        // 2.5s 本地直连对冲定时器：若服务端 SSE 2.5 秒内仍未吐出任何有效可播源，立刻并行启动客户端直连多源搜索
        val hedgeJob = launch(Dispatchers.IO) {
            delay(SSE_HEDGE_DELAY_MS)
            if (sseEmittedSources.isEmpty() && isActive) {
                Log.w(TAG, "服务端 SSE ${SSE_HEDGE_DELAY_MS}ms 内尚未吐出有效源，并行启动本地多源直连对冲")
                ensureLocalStarted()
            }
        }

        var connection: HttpURLConnection? = null
        var authExpired = false
        var completedNormally = false

        try {
            withContext(Dispatchers.IO) {
                val baseUrl = AppDataService.getServerUrlSync()
                    ?: throw IllegalStateException("未配置服务器地址")
                val cookies = AppDataService.getCookiesSync()
                    ?: throw IllegalStateException("未登录，请先登录")
                val cleanBase = if (baseUrl.endsWith("/")) baseUrl.dropLast(1) else baseUrl
                val url = "$cleanBase/api/search/ws?q=${URLEncoder.encode(query, "UTF-8")}"

                connection = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = SSE_CONNECT_TIMEOUT_MS
                    readTimeout = SSE_READ_TIMEOUT_MS
                    setRequestProperty("Accept", "text/event-stream")
                    setRequestProperty("Cache-Control", "no-cache")
                    setRequestProperty("Cookie", cookies)
                }
                _serverConnection = connection

                val code = connection!!.responseCode
                if (code == 401) {
                    authExpired = true
                    _eventFlow.emit(SearchEvent.Error("登录状态失效，请重新登录"))
                    return@withContext
                }
                if (code < 200 || code >= 300) {
                    Log.w(TAG, "服务端 SSE 返回 HTTP $code，自动回退 HTTP /api/search + 本地多源并发搜索")
                    ensureServerHttpStarted()
                    ensureLocalStarted()
                    return@withContext
                }

                Log.d(TAG, "服务端 SSE 已连接 code=$code url=$url")
                connection!!.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                    while (isActive) {
                        val line = try {
                            reader.readLine()
                        } catch (_: IOException) {
                            null
                        } ?: break

                        if (!line.startsWith("data:")) continue
                        val payload = line.removePrefix("data:").trim()
                        if (payload.isEmpty()) continue

                        val obj = try {
                            json.parseToJsonElement(payload).jsonObject
                        } catch (_: Exception) {
                            continue
                        }

                        when (obj["type"]?.jsonPrimitive?.contentOrNull) {
                            "start" -> {
                                _totalSources = obj["totalSources"]?.jsonPrimitive?.intOrNull ?: 0
                                _completedSources.set(0)
                                _eventFlow.emit(SearchEvent.Progress(SearchProgress(
                                    totalSources = _totalSources,
                                    completedSources = 0,
                                    currentSource = null,
                                    isComplete = false
                                )))
                            }
                            "source_result" -> {
                                val sourceName = obj["sourceName"]?.jsonPrimitive?.contentOrNull
                                val arr = obj["results"]?.jsonArray
                                if (arr != null && arr.isNotEmpty()) {
                                    // 使用容错解析器，杜绝 null 字段/空字符串 douban_id 导致静默丢源
                                    val parsed = arr.mapNotNull { el ->
                                        DownstreamService.parseServerSearchResult(el)
                                    }
                                    if (parsed.isNotEmpty()) {
                                        parsed.forEach { if (it.source.isNotBlank()) sseEmittedSources.add(it.source) }
                                        _eventFlow.emit(SearchEvent.Results(parsed))
                                    }
                                }
                                val completed = _completedSources.incrementAndGet()
                                _eventFlow.emit(SearchEvent.Progress(SearchProgress(
                                    totalSources = _totalSources,
                                    completedSources = completed,
                                    currentSource = sourceName,
                                    isComplete = false
                                )))
                            }
                            "source_error" -> {
                                val sourceKey = obj["source"]?.jsonPrimitive?.contentOrNull.orEmpty()
                                val sourceName = obj["sourceName"]?.jsonPrimitive?.contentOrNull ?: sourceKey
                                val errMsg = obj["error"]?.jsonPrimitive?.contentOrNull ?: "未知错误"
                                if (sourceKey.isNotEmpty()) _sourceErrors[sourceKey] = errMsg
                                val completed = _completedSources.incrementAndGet()
                                _eventFlow.emit(SearchEvent.Progress(SearchProgress(
                                    totalSources = _totalSources,
                                    completedSources = completed,
                                    currentSource = sourceName,
                                    isComplete = false,
                                    error = errMsg
                                )))
                            }
                            "complete" -> {
                                completedNormally = true
                                break
                            }
                        }
                    }
                }
            }
        } catch (e: CancellationException) {
            httpHedgeJob.cancel()
            hedgeJob.cancel()
            serverHttpJobRef.get()?.cancel()
            localJobRef.get()?.cancel()
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "服务端 SSE 搜索异常 (${e.message})，自动回退 HTTP /api/search + 本地多源并发搜索")
            if (!authExpired && isActive) {
                ensureServerHttpStarted()
                ensureLocalStarted()
            }
        } finally {
            httpHedgeJob.cancel()
            hedgeJob.cancel()
            try { connection?.disconnect() } catch (_: Exception) {}
            _serverConnection = null
        }

        // 若 SSE 非正常结束或仅返回很少源（<5），先补齐标准 HTTP /api/search，再补齐本地多源直连
        if (!authExpired && isActive && (!completedNormally || sseEmittedSources.size < SSE_MIN_SOURCES_BEFORE_SUPPLEMENT)) {
            Log.d(
                TAG,
                "服务端 SSE 结束 (normal=$completedNormally, sources=${sseEmittedSources.size})，启动 HTTP /api/search 与本地直连补齐"
            )
            ensureServerHttpStarted()
            ensureLocalStarted()
        }

        // 等待对冲/补齐通道完成，再统一发出唯一一次 Complete
        val serverHttpCount = try {
            synchronized(serverHttpJobLock) { serverHttpJobRef.get() }?.await() ?: 0
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "服务端 HTTP 对冲异常: ${e.message}")
            0
        }

        try {
            val localDeferred = synchronized(localJobLock) { localJobRef.get() }
            if (localDeferred != null) {
                if (sseEmittedSources.size + serverHttpCount >= SERVER_RICH_SOURCE_THRESHOLD) {
                    val finished = withTimeoutOrNull(LOCAL_GRACE_AFTER_SERVER_MS) {
                        localDeferred.await()
                        true
                    }
                    if (finished == null) {
                        localDeferred.cancel()
                    }
                } else {
                    localDeferred.await()
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "本地兜底搜索异常: ${e.message}")
        }

        if (isActive) {
            _eventFlow.emit(SearchEvent.Progress(SearchProgress(
                totalSources = _totalSources,
                completedSources = _totalSources,
                currentSource = null,
                isComplete = true
            )))
            _eventFlow.emit(SearchEvent.Complete)
            _isSearching = false
        }
    }

    /**
     * 停止搜索
     */
    fun stopSearch() {
        // 先关连接才能让阻塞中的 readLine 立即抛 IOException 返回
        try { _serverConnection?.disconnect() } catch (_: Exception) {}
        _serverConnection = null
        _searchJob?.cancel()
        _searchJob = null
        _isSearching = false
        _currentQuery = null
    }

    /**
     * 合并和去重搜索结果
     */
    fun deduplicateResults(results: List<SearchResult>): List<SearchResult> {
        val seen = mutableSetOf<String>()
        return results.filter { result ->
            val key = "${result.source}+${result.id}"
            if (seen.contains(key)) {
                false
            } else {
                seen.add(key)
                true
            }
        }
    }

    /**
     * 清理资源
     */
    fun dispose() {
        stopSearch()
    }
}
