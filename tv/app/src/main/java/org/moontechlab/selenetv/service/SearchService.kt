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
 * v2.7.77:
 *  - 放宽单源 12s / 全局 16s 上限（配合 OkHttp 连接池，快源仍 <1s 秒出，慢源不再被 7s/9s 一刀切误杀）
 *  - 服务端 SSE 模式增加 2.5s 对冲本地直连 + 源数偏少(<5)自动补齐本地直连，并过滤无剧集空源
 *  - 任何异常/空源路径必发 SearchEvent.Complete，杜绝详情页永久卡骨架屏
 *  - 新增 stopSearchAndWait()，彻底杜绝上一次搜索的残留 Complete 事件串台
 */
object SearchService {
    private const val TAG = "SearchService"
    private const val SEARCH_TIMEOUT_MS = 16000L
    private const val SINGLE_SOURCE_TIMEOUT_MS = 12000L
    private const val SSE_CONNECT_TIMEOUT_MS = 5000
    private const val SSE_READ_TIMEOUT_MS = 10000
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
        Log.d(TAG, "startSearch query=\"$trimmedQuery\" origin=${origin.key}")
        _searchJob = serviceScope.launch {
            try {
                when (origin) {
                    AppDataService.SearchOrigin.TV_DIRECT -> localSearch(trimmedQuery, emitFinalComplete = true)
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
     * 本地搜索（并发搜索所有资源）
     */
    private suspend fun localSearch(query: String, emitFinalComplete: Boolean = true) = coroutineScope {
        try {
            // 获取搜索资源列表
            val allResources = org.moontechlab.selenetv.data.Repositories.sources().getSearchResources()
            val resources = allResources.filter { !it.disabled }

            if (resources.isEmpty()) {
                _eventFlow.emit(SearchEvent.Error("没有可用的搜索资源"))
                if (emitFinalComplete) {
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
            _eventFlow.emit(SearchEvent.Error("本地搜索异常: ${e.message}"))
            if (emitFinalComplete) {
                _eventFlow.emit(SearchEvent.Complete)
                _isSearching = false
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
            }.filter { it.episodes.isNotEmpty() }

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
                        completedSources = completed,
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
                    completedSources = completed,
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
                        completedSources = completed,
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
                        completedSources = completed,
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
     * 服务端聚合搜索（SSE 流式）+ 2.5s 本地直连对冲 + 低产自动补齐
     * 命中条件由调用方在 startSearch 中读 SearchOrigin 决定
     */
    private suspend fun serverAggregatedSearch(query: String) = coroutineScope {
        val localJobLock = Any()
        val localJobRef = AtomicReference<Deferred<Unit>?>(null)
        val sseEmittedSources = ConcurrentHashMap.newKeySet<String>()

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

        // 2.5s 对冲定时器：若服务端 SSE 2.5 秒内仍未吐出任何有效可播源，立刻并行启动客户端直连多源搜索
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
                    Log.w(TAG, "服务端 SSE 返回 HTTP $code，自动回退本地多源并发搜索")
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
                                    val parsed = arr.mapNotNull { el ->
                                        try {
                                            val decoded = json.decodeFromJsonElement(SearchResult.serializer(), el)
                                            // 过滤无剧集空条目，同时把服务端返回的 doubanId=0 归一化为 null
                                            if (decoded.episodes.isEmpty()) {
                                                null
                                            } else if (decoded.doubanId != null && decoded.doubanId <= 0L) {
                                                decoded.copy(doubanId = null)
                                            } else {
                                                decoded
                                            }
                                        } catch (e: Exception) {
                                            Log.w(TAG, "服务端搜索条目解析失败: ${e.message}")
                                            null
                                        }
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
            hedgeJob.cancel()
            localJobRef.get()?.cancel()
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "服务端 SSE 搜索异常 (${e.message})，自动回退本地多源并发搜索")
            if (!authExpired && isActive) {
                ensureLocalStarted()
            }
        } finally {
            hedgeJob.cancel()
            try { connection?.disconnect() } catch (_: Exception) {}
            _serverConnection = null
        }

        // 若 SSE 非正常结束或仅返回很少源（<5，如服务端未映射咕噜专线或部分源失效），自动补齐本地多源直连搜索
        if (!authExpired && isActive && (!completedNormally || sseEmittedSources.size < SSE_MIN_SOURCES_BEFORE_SUPPLEMENT)) {
            Log.d(
                TAG,
                "服务端 SSE 结束 (normal=$completedNormally, sources=${sseEmittedSources.size})，自动启动本地直连补齐全部可用源"
            )
            ensureLocalStarted()
        }

        // 等待对冲/补齐本地搜索完成，再统一发出唯一一次 Complete
        try {
            synchronized(localJobLock) { localJobRef.get() }?.await()
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
