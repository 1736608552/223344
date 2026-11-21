package org.moontechlab.selenetv.data.server

import android.util.Log
import org.moontechlab.selenetv.data.SourcesRepository
import org.moontechlab.selenetv.data.local.LocalStore
import org.moontechlab.selenetv.model.LiveSource
import org.moontechlab.selenetv.model.SearchResource
import org.moontechlab.selenetv.service.ApiService
import org.moontechlab.selenetv.service.AppDataService

/**
 * 服务端模式的源仓库实现：
 * v2.7.77: 为 /api/search/resources 增加 5 分钟内存缓存 + 异常降级兜底，
 * 避免每次进详情页都同步阻塞等待服务端列表、且防止服务端瞬时抖动导致 TV 端 0 源。
 */
object ServerSourcesRepository : SourcesRepository {
    private const val TAG = "ServerSourcesRepository"
    private const val CACHE_TTL_MS = 5 * 60 * 1000L

    @Volatile private var cachedServerKey: String = ""
    @Volatile private var cachedResources: List<SearchResource> = emptyList()
    @Volatile private var cachedAtMs: Long = 0L

    override fun getSearchResources(): List<SearchResource> {
        val serverKey = AppDataService.getServerUrlSync().orEmpty().trim()
        val now = System.currentTimeMillis()
        val mem = cachedResources
        if (serverKey == cachedServerKey && mem.isNotEmpty() && (now - cachedAtMs) < CACHE_TTL_MS) {
            return mem
        }

        return try {
            val fresh = ApiService.getSearchResources()
            if (fresh.isNotEmpty()) {
                cachedServerKey = serverKey
                cachedResources = fresh
                cachedAtMs = now
                fresh
            } else if (serverKey == cachedServerKey && mem.isNotEmpty()) {
                mem
            } else {
                LocalStore.getSearchSources().ifEmpty { fresh }
            }
        } catch (e: Exception) {
            Log.w(TAG, "获取服务端搜索源失败，尝试使用缓存/本地源兜底: ${e.message}")
            if (serverKey == cachedServerKey && mem.isNotEmpty()) {
                mem
            } else {
                val localFallback = LocalStore.getSearchSources()
                if (localFallback.isNotEmpty()) localFallback else throw e
            }
        }
    }

    override fun getLiveSources(): List<LiveSource> = ApiService.getLiveSources()
}
