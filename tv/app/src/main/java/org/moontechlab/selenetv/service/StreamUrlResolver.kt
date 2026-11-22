package org.moontechlab.selenetv.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.net.URI
import java.util.concurrent.TimeUnit

/**
 * v2.7.81: 网页播放页 → 真实流地址 解析器（TV 端专属补齐）
 *
 * 背景 / 根因：
 *   采集站的 `vod_play_url` 里，只有少数源给的是原生 m3u8 直链，其余大量源给的是
 *   **网页播放页**，例如：
 *     https://v.gsuus.com/play/dwpnp18e                  (DPlayer 模板)
 *     https://v.lfthirtytwo.com/share/957667...          (share 页)
 *     https://hn.bfvvs.com/play/av2m215a                 (hls.js 动态加载)
 *   这些地址返回的是 `text/html`，不是媒体容器。手机端有 M3U8Service._resolveSharePage
 *   会先把 HTML 里的 m3u8 抓出来再播，所以手机端正常；TV 端直接把 URL 交给 ExoPlayer，
 *   于是报 `ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED(3003)` —— 也就是用户看到的
 *   「此源播放失败，请尝试换源」。
 *
 * 本类把手机端 `_resolveSharePage` 的规则 1:1 移植到 Kotlin：
 *   1. `var main/url/playurl/src = "/xxx/index.m3u8"`（飞飞通用 / ffzy 非凡）
 *   2. `url: 'https://.../index.m3u8'`（DPlayer，光速 / 玉兔 / 部分镜像）
 *   3. `<meta http-equiv="refresh" content="0;url=https://...m3u8">`
 *   4. 任意 `"https://...m3u8"` 字符串
 *   5. 任意 `"/path/index.m3u8"` 相对路径
 *   6. 兜底：`pageUrl + "/index.m3u8"`（注意不能丢末段，见手机端 v2.3.28 修复）
 *   每个候选都会真实拉一次校验 `#EXTM3U`，避免把错误页当流地址。
 *
 * 解析失败时原样返回，行为和旧版一致（不会更差）。
 */
object StreamUrlResolver {

    private const val TAG = "StreamUrlResolver"

    private const val BROWSER_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    /** 单次请求超时（毫秒）。播放页本身很小，6~8 秒足够。 */
    private const val PAGE_TIMEOUT_MS = 8000L
    private const val CANDIDATE_TIMEOUT_MS = 6000L

    /** 只读前 256KB，避免个别错误页返回巨量内容时白占内存。 */
    private const val MAX_BODY_BYTES = 256L * 1024L

    data class Resolved(
        /** 最终交给播放器的地址 */
        val url: String,
        /** 解析途径，仅用于日志诊断 */
        val via: String,
    )

    private val RE_DPLAYER = Regex(
        """url\s*:\s*["'](https?://[^"']+\.m3u8[^"']*)["']""",
        RegexOption.IGNORE_CASE,
    )
    private val RE_ABS = Regex(
        """["'](https?://[^"']+\.m3u8[^"']*)["']""",
        RegexOption.IGNORE_CASE,
    )
    private val RE_VAR = Regex(
        """var\s+\w+\s*=\s*["'](/[^"']+\.m3u8[^"']*)["']""",
        RegexOption.IGNORE_CASE,
    )
    private val RE_REL = Regex(
        """["'](/[^"']+\.m3u8[^"']*)["']""",
        RegexOption.IGNORE_CASE,
    )
    private val RE_META = Regex(
        """http-equiv=["']?refresh["']?[^>]+url=([^"'>\s]+)""",
        RegexOption.IGNORE_CASE,
    )

    /**
     * 解析结果缓存：换源列表测速和真正开播会解析同一个地址，
     * 缓存后开播时不再重复握手（上限 64 条，超了整体清空即可）。
     */
    private val cache = HashMap<String, String>()

    private fun cacheGet(key: String): String? = synchronized(cache) { cache[key] }

    private fun cachePut(key: String, value: String) = synchronized(cache) {
        if (cache.size >= 64) cache.clear()
        cache[key] = value
    }

    /** 明显是媒体直链的类型，直接放行，不做任何网络探测。 */
    private fun isPlainMedia(url: String): Boolean {
        val u = url.substringBefore('?').lowercase()
        return u.endsWith(".mp4") || u.endsWith(".flv") || u.endsWith(".mkv") ||
            u.endsWith(".avi") || u.endsWith(".ts")
    }

    /**
     * 把分集地址解析成可直接播放的流地址。协程里调用（内部切 IO）。
     */
    suspend fun resolve(rawUrl: String): Resolved = withContext(Dispatchers.IO) {
        if (rawUrl.isBlank()) return@withContext Resolved(rawUrl, "empty")
        if (isPlainMedia(rawUrl)) return@withContext Resolved(rawUrl, "plain-media")

        cacheGet(rawUrl)?.let {
            return@withContext Resolved(it, "cache")
        }

        val page = fetch(rawUrl, PAGE_TIMEOUT_MS)
            ?: return@withContext Resolved(rawUrl, "fetch-failed")

        if (isM3u8Body(page.body)) {
            cachePut(rawUrl, page.finalUrl)
            return@withContext Resolved(page.finalUrl, "m3u8")
        }

        // 不是 m3u8 → 当成网页播放页，从 HTML 里挖真实地址
        val html = page.body
        for (candidate in candidates(html, page.finalUrl)) {
            if (candidate == rawUrl) continue
            val checked = fetch(candidate, CANDIDATE_TIMEOUT_MS) ?: continue
            if (isM3u8Body(checked.body)) {
                Log.i(TAG, "解析成功 ${rawUrl.take(70)} -> ${checked.finalUrl.take(100)}")
                cachePut(rawUrl, checked.finalUrl)
                return@withContext Resolved(checked.finalUrl, "html-parsed")
            }
        }

        Log.w(TAG, "解析失败，原样交给播放器: ${rawUrl.take(100)}")
        Resolved(rawUrl, "unresolved")
    }

    private fun isM3u8Body(body: String): Boolean =
        body.trimStart().startsWith("#EXTM3U")

    private class Fetched(val finalUrl: String, val body: String)

    private fun fetch(url: String, timeoutMs: Long): Fetched? {
        return try {
            val client = MediaHttp.httpClient.newBuilder()
                .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
                .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
                .followRedirects(true)
                .followSslRedirects(true)
                .build()
            val request = Request.Builder()
                .url(url)
                .header("User-Agent", BROWSER_UA)
                .header("Referer", originOf(url))
                .header("Accept", "*/*")
                .build()
            client.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) return null
                val body = resp.peekBody(MAX_BODY_BYTES).string()
                Fetched(resp.request.url.toString(), body)
            }
        } catch (e: Exception) {
            Log.w(TAG, "fetch 失败 ${url.take(80)}: ${e.message}")
            null
        }
    }

    private fun originOf(url: String): String = try {
        val u = URI(url)
        "${u.scheme}://${u.host}/"
    } catch (e: Exception) {
        ""
    }

    /** 按手机端顺序收集候选地址，去重后返回。 */
    private fun candidates(html: String, pageUrl: String): List<String> {
        val out = LinkedHashSet<String>()

        fun put(raw: String?) {
            if (raw.isNullOrBlank()) return
            val trimmed = raw.trim()
            out.add(absolutize(pageUrl, trimmed) ?: trimmed)
        }

        RE_DPLAYER.find(html)?.let { put(it.groupValues[1]) }
        RE_ABS.find(html)?.let { put(it.groupValues[1]) }
        RE_VAR.find(html)?.let { put(it.groupValues[1]) }
        RE_REL.find(html)?.let { put(it.groupValues[1]) }
        RE_META.find(html)?.let { m ->
            val refresh = m.groupValues[1]
            if (refresh.contains(".m3u8")) put(refresh)
        }
        // 兜底：pageUrl + /index.m3u8（不能丢末段，见手机端 v2.3.28）
        if (!pageUrl.contains(".m3u8")) put(pageUrl.trimEnd('/') + "/index.m3u8")

        return out.toList()
    }

    private fun absolutize(base: String, ref: String): String? = try {
        when {
            ref.startsWith("http://") || ref.startsWith("https://") -> ref
            else -> URI(base).resolve(ref).toString()
        }
    } catch (e: Exception) {
        null
    }
}
