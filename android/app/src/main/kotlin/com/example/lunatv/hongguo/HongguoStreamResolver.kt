// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.lunatv.hongguo

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

object HongguoStreamResolver {
    val client = OkHttpClient.Builder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.SECONDS)
        .callTimeout(8, TimeUnit.SECONDS)
        .pingInterval(10, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    /**
     * 清理网络连接池 (在电视睡眠唤醒或网络波动重连时调用，彻底拔除已失效的僵尸 TCP Socket)
     */
    /**
     * App 内一键换发全新合法设备号。
     *
     * v2.7.98: 原实现顺手会拉上游清单「热更」协议参数与 V5 密钥，这条通道依赖
     *   GitHub（jsdelivr / ghproxy），国内电视基本连不上，等于每次点击白等一轮
     *   网络超时；而且真拉到新版参数时会把老 APK 的签名逻辑改到不兼容。现在
     *   参数只随 APK 版本走，这里只做「连接池驱逐 + 换发全新设备身份」。
     */
    fun resetDeviceSession(): Map<String, String> {
        evictConnections()
        val fresh = PlaybackDeviceSession.shared.resetAll(client)
        val devId = fresh.values["device_id"] ?: ""
        val iid = fresh.values["iid"] ?: ""
        val kernelVer = "${VendorConstants.mobileV5VersionName} (${VendorConstants.mobileV5VersionCode})"
        HongguoDiagnostic.log(
            "INFO", "context", "RESET_DEVICE_SESSION",
            "已换发全新设备身份: did=$devId"
        )
        HongguoDiagnostic.updateReport(
            stage = "device_session",
            code = "RESET_OK",
            summary = "已换发全新设备 did=$devId"
        )
        return mapOf(
            "deviceId" to devId,
            "installId" to iid,
            "cookie" to fresh.cookie,
            "kernelVersion" to kernelVer,
        )
    }

    fun evictConnections() {
        try {
            client.connectionPool.evictAll()
        } catch (_: Throwable) {}
        try {
            ContentRepository.defaultHttp.connectionPool.evictAll()
        } catch (_: Throwable) {}
    }

    private val signer = Signer()
    private val episodeVidsCache = java.util.concurrent.ConcurrentHashMap<String, List<String>>()
    private val seriesIntroCache = java.util.concurrent.ConcurrentHashMap<String, String>()

    /**
     * 外部预热/缓存短剧 VID 列表 (如搜索结果携带时提前写入，实现秒开)
     */
    fun cacheEpisodeVids(seriesId: String, vids: List<String>) {
        val cleanId = seriesId.trim().removePrefix("hongguo:").trim()
        if (cleanId.isNotEmpty() && vids.isNotEmpty()) {
            episodeVidsCache[cleanId] = vids
        }
    }

    /**
     * 外部预热/缓存短剧简介
     */
    fun cacheSeriesIntro(seriesId: String, intro: String) {
        val cleanId = seriesId.trim().removePrefix("hongguo:").trim()
        if (cleanId.isNotEmpty() && intro.isNotEmpty()) {
            seriesIntroCache[cleanId] = intro
        }
    }

    /**
     * 获取已缓存的短剧简介 (在 fetchEpisodeVids 解析 Web SSR 时自动提取并缓存)
     */
    fun getCachedSeriesIntro(seriesId: String): String {
        val cleanId = seriesId.trim().removePrefix("hongguo:").trim()
        return seriesIntroCache[cleanId] ?: ""
    }

    // 对齐 aston314/hongguo-tv 2026-11-07 工业级三大 Provider 与同剧成功路径记忆架构
    const val PROVIDER_MOBILE_V5 = "mobile_v5"
    const val PROVIDER_SINGLE_REGISTERED = "single_registered"
    const val PROVIDER_VIDEO_TAB = "video_tab"
    const val PROVIDER_MULTI_VIDEO_MODEL = "multi_video_model"
    const val PROVIDER_SINGLE_VIDEO_MODEL = "video_model"

    /** video_model 接口的 v5 query 顺序，对齐官方 7.4.5.32（31 个设备字段 + video_id）。 */
    private val SINGLE_MODEL_V5_KEYS = listOf(
        "device_platform", "os", "ssmix", "_rticket", "cdid", "channel", "aid", "app_name",
        "version_code", "version_name", "manifest_version_code", "update_version_code",
        "resolution", "dpi", "device_type", "device_brand", "language", "os_api", "os_version",
        "ac", "host_abi", "dragon_device_type", "pv_player", "compliance_status",
        "need_personal_recommend", "player_so_load", "is_android_pad_screen", "rom_version",
        "device_id", "iid", "klink_egdi", "video_id", "video_id_type"
    )

    private data class SourceMemoryEntry(val provider: String, val timestamp: Long)
    private val seriesSourceMemory = java.util.concurrent.ConcurrentHashMap<String, SourceMemoryEntry>()
    private val resolveLock = java.util.concurrent.locks.ReentrantLock(true)

    fun recordSourceSuccess(seriesId: String, provider: String) {
        val clean = seriesId.trim().removePrefix("hongguo:").trim()
        if (clean.isNotEmpty()) {
            seriesSourceMemory[clean] = SourceMemoryEntry(provider, System.currentTimeMillis())
        }
    }

    private fun getPreferredProvider(seriesId: String): String? {
        val clean = seriesId.trim().removePrefix("hongguo:").trim()
        if (clean.isEmpty()) return null
        val entry = seriesSourceMemory[clean] ?: return null
        return if (System.currentTimeMillis() - entry.timestamp <= 30 * 60 * 1000L) {
            entry.provider
        } else {
            seriesSourceMemory.remove(clean)
            null
        }
    }

    /**
     * 获取短剧剧情简介 (若缓存未命中则自动请求解析)
     */
    fun fetchSeriesIntro(seriesId: String): String {
        val cleanId = seriesId.trim().removePrefix("hongguo:").trim()
        val cached = seriesIntroCache[cleanId]
        if (!cached.isNullOrEmpty()) return cached
        try {
            fetchEpisodeVids(cleanId)
        } catch (ignored: Exception) {}
        return seriesIntroCache[cleanId] ?: ""
    }

    /**
     * 深度括号匹配解析 Web 页面中的 _ROUTER_DATA JSON (对齐 hongguoTV 工业级实践，比单纯正则更抗复杂嵌套)
     */
    private fun extractRouter(html: String): JSONObject? {
        val marker = html.indexOf("_ROUTER_DATA")
        if (marker < 0) return null
        val first = html.indexOf('{', marker)
        if (first < 0) return null
        var depth = 0
        var quoted = false
        var escaped = false
        for (i in first until html.length) {
            val ch = html[i]
            if (quoted) {
                if (escaped) escaped = false else if (ch == '\\') escaped = true else if (ch == '"') quoted = false
                continue
            }
            when (ch) {
                '"' -> quoted = true
                '{', '[' -> depth++
                '}', ']' -> {
                    depth--
                    if (depth == 0) {
                        return try { JSONObject(html.substring(first, i + 1)) } catch (ignored: Exception) { null }
                    }
                }
            }
        }
        return null
    }

    /**
     * v2.7.94: 官方 `video_detail` 接口优先取全剧分集 vid 列表。
     *
     * 为什么要抢在抓网页前面：通道 1 依赖第三方站 hongguoduanju.com 的 SSR HTML，
     * 那个站随时可能改版/下线；而 `POST /novel/player/video_detail/v1/` 是官方接口，
     * 一次请求就把整部剧的 `video_list` 全量下发（实测 71 集剧回 71 条，字段
     * `vid` + `vid_index` 严格递增无缺口），并且带 `episode_cnt` 可用于完整性校验。
     *
     * 注意入参是**单数** `series_id`（19 位字符串）。曾经被误认为是 `series_ids`
     * 或在 `multi_video_detail` 上找，那条路只会回 `100001 series_ids invalid`。
     *
     * 返回空列表时表示「本通道不可用或不完整」，由上层回落到 HTML / 重试通道。
     */
    private fun fetchVidsFromVideoDetail(cleanId: String): List<String> {
        val profile = PlaybackDeviceSession.shared.profile(client)
        val payload = """{"series_id":"$cleanId"}""".toByteArray()
        val signed = signer.sign(
            "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_detail/v1/",
            profile.values,
            payload
        )
        val req = Request.Builder()
            .url(signed.url)
            .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))
        for ((k, v) in signed.headers) {
            req.header(k, v)
        }
        val resp = client.newCall(req.build()).execute()
        val bodyStr = resp.body?.string() ?: return emptyList()
        val json = JSONObject(bodyStr)
        if (json.optInt("Code", json.optInt("code", -1)) != 0) return emptyList()
        val videoData = json.optJSONObject("data")?.optJSONObject("video_data") ?: return emptyList()

        val videoList = videoData.optJSONArray("video_list") ?: return emptyList()
        val pairs = mutableListOf<Pair<Int, String>>()
        for (i in 0 until videoList.length()) {
            val item = videoList.optJSONObject(i) ?: continue
            val vid = item.optString("vid").ifEmpty { item.optString("video_id") }
            val idx = item.optInt("vid_index", i + 1)
            if (vid.matches(Regex("[0-9]{1,32}"))) {
                pairs.add(Pair(idx, vid))
            }
        }
        if (pairs.isEmpty()) return emptyList()
        pairs.sortBy { it.first }
        val vids = pairs.map { it.second }.distinct()

        // 完整性校验：只收全量列表。集数对不上（付费剧只下发免费集）就让上层回落到网页通道，
        // 避免把「前 3 集」当成「全剧」缓存下来，造成后面的集永远取不到。
        val expected = videoData.optInt("episode_cnt", 0)
        if (expected > 0 && vids.size < expected) {
            HongguoDiagnostic.log(
                "WARN", "stream_resolver", "VIDEO_DETAIL_INCOMPLETE",
                "video_detail 只回 ${vids.size}/${expected} 集，回落网页通道: $cleanId"
            )
            return emptyList()
        }

        if (!seriesIntroCache.containsKey(cleanId)) {
            val intro = videoData.optString("series_intro").trim()
            if (intro.isNotEmpty()) seriesIntroCache[cleanId] = intro
        }
        HongguoDiagnostic.log(
            "INFO", "stream_resolver", "VIDEO_DETAIL_OK",
            "video_detail 全量 ${vids.size} 集 (episode_cnt=$expected): $cleanId"
        )
        return vids
    }

    /**
     * 短剧全集分集 VID 列表拉取 (Web 官网 SSR 详情页优先保证全量 80~100+ 集 + 官方 App 签名兜底)
     */
    fun fetchEpisodeVids(seriesId: String): List<String> {
        val cleanId = seriesId.trim().removePrefix("hongguo:").trim()
        if (!cleanId.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid seriesId: $seriesId")
        }

        episodeVidsCache[cleanId]?.let { return it }

        // 通道 0 (v2.7.94 新增，优先级最高): 官方 video_detail 接口。
        //   不依赖第三方网页、一次请求拿全剧、带 episode_cnt 完整性校验。
        try {
            val apiVids = fetchVidsFromVideoDetail(cleanId)
            if (apiVids.isNotEmpty()) {
                episodeVidsCache[cleanId] = apiVids
                return apiVids
            }
        } catch (e: Exception) {
            HongguoDiagnostic.log(
                "WARN", "stream_resolver", "VIDEO_DETAIL_FAIL",
                "video_detail 通道失败，回落网页通道: ${e.message}"
            )
        }

        var lastErr: Exception? = null

        // 通道 1 (v2.7.94 起降为兜底): 从官网 SSR 详情页 _ROUTER_DATA 提取全剧 vid_list。
        //   只有在官方 video_detail 不可用或集数不完整时才会走到这里（依赖第三方站，易受改版影响）。
        try {
            val webUrl = "https://hongguoduanju.com/detail?series_id=$cleanId"
            val webReq = Request.Builder()
                .url(webUrl)
                .header("User-Agent", "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36")
                .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
                .header("Accept-Language", "zh-CN,zh;q=0.9")
                .build()
            val webResp = client.newCall(webReq).execute()
            if (webResp.isSuccessful) {
                val html = webResp.body?.string() ?: ""
                val vids = mutableListOf<String>()

                // 策略 A: 基于 _ROUTER_DATA 深度提取 (括号栈解析优先，正则兜底)
                val root = extractRouter(html) ?: run {
                    val regex = Regex("""_ROUTER_DATA\s*=\s*(\{.*?\});""", RegexOption.DOT_MATCHES_ALL)
                    val match = regex.find(html)
                    match?.let { try { JSONObject(it.groupValues[1]) } catch (ignored: Exception) { null } }
                }

                if (root != null) {
                    try {
                        val loaderData = root.optJSONObject("loaderData")
                        if (loaderData != null) {
                            val keys = loaderData.keys()
                            while (keys.hasNext()) {
                                val key = keys.next()
                                val page = loaderData.optJSONObject(key) ?: continue
                                val sd = page.optJSONObject("seriesDetail")
                                    ?: page.optJSONObject("video_data")
                                    ?: page.optJSONObject("detail")

                                // 提取剧情简介 (series_intro / intro / video_desc)
                                val intro = (sd?.optString("series_intro") ?: "")
                                    .ifEmpty { sd?.optString("intro") ?: "" }
                                    .ifEmpty { sd?.optString("video_desc") ?: "" }
                                    .ifEmpty { sd?.optString("abstract_text") ?: "" }
                                    .trim()
                                if (intro.isNotEmpty() && !seriesIntroCache.containsKey(cleanId)) {
                                    seriesIntroCache[cleanId] = intro
                                }

                                val vList = sd?.optJSONArray("vid_list") ?: page.optJSONArray("vid_list") ?: page.optJSONArray("video_list")
                                if (vList != null && vList.length() > 0) {
                                    for (i in 0 until vList.length()) {
                                        val v = vList.optString(i).trim()
                                        if (v.matches(Regex("[0-9]{1,32}"))) {
                                            vids.add(v)
                                        }
                                    }
                                    if (vids.isNotEmpty()) break
                                }
                            }
                        }
                    } catch (ignored: Exception) {}
                }

                // 策略 B: 正则快速扫描 vid_list 数组与 series_intro 兜底
                if (vids.isEmpty()) {
                    val rawListMatch = Regex("\"vid_list\"\\s*:\\s*\\[(.*?)\\]").find(html)
                    if (rawListMatch != null) {
                        val inner = rawListMatch.groupValues[1]
                        val matches = Regex("\"([0-9]{1,32})\"").findAll(inner)
                        for (m in matches) {
                            val v = m.groupValues[1].trim()
                            if (v.isNotEmpty()) vids.add(v)
                        }
                    }
                }
                if (!seriesIntroCache.containsKey(cleanId)) {
                    val rawIntroMatch = Regex("\"series_intro\"\\s*:\\s*\"(.*?)(?<!\\\\)\"").find(html)
                        ?: Regex("\"video_desc\"\\s*:\\s*\"(.*?)(?<!\\\\)\"").find(html)
                    if (rawIntroMatch != null) {
                        val rawIntro = rawIntroMatch.groupValues[1]
                        val unescaped = rawIntro.replace("\\\"", "\"").replace("\\n", "\n").replace("\\\\", "\\").trim()
                        if (unescaped.isNotEmpty()) {
                            seriesIntroCache[cleanId] = unescaped
                        }
                    }
                }

                val distinctVids = vids.distinct()
                if (distinctVids.isNotEmpty()) {
                    episodeVidsCache[cleanId] = distinctVids
                    return distinctVids
                }
            }
        } catch (e: Exception) {
            lastErr = e
        }

        // 通道 2 (官方 App 原生接口抖动重试兜底，使用合法会话设备身份)
        val devProfile = PlaybackDeviceSession.shared.profile(client)
        val payload = """{"series_id":"$cleanId"}""".toByteArray()
        for (attempt in 0..1) {
            try {
                val signed = signer.sign(
                    "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_detail/v1/",
                    devProfile.values,
                    payload
                )

                val req = Request.Builder()
                    .url(signed.url)
                    .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))

                for ((k, v) in signed.headers) {
                    req.header(k, v)
                }

                val resp = client.newCall(req.build()).execute()
                val bodyStr = resp.body?.string() ?: throw IOException("Empty response from video_detail")
                val json = JSONObject(bodyStr)
                if (json.optInt("Code", json.optInt("code", 0)) != 0) {
                    throw IOException("video_detail API error: " + json.optString("message"))
                }

                val videoData = json.optJSONObject("data")?.optJSONObject("video_data")
                    ?: throw IOException("No video_data in video_detail response")

                // 兜底提取剧情简介
                if (!seriesIntroCache.containsKey(cleanId)) {
                    val appIntro = (videoData.optString("series_intro"))
                        .ifEmpty { videoData.optString("video_desc") }
                        .ifEmpty { videoData.optString("intro") }
                        .ifEmpty { videoData.optString("abstract_text") }
                        .trim()
                    if (appIntro.isNotEmpty()) {
                        seriesIntroCache[cleanId] = appIntro
                    }
                }

                val videoList = videoData.optJSONArray("video_list")
                    ?: throw IOException("No video_list in video_detail response")

                val pairs = mutableListOf<Pair<Int, String>>()
                for (i in 0 until videoList.length()) {
                    val item = videoList.optJSONObject(i) ?: continue
                    val vid = item.optString("vid").ifEmpty { item.optString("video_id") }
                    val index = item.optInt("vid_index", i + 1)
                    if (vid.matches(Regex("[0-9]{1,32}"))) {
                        pairs.add(Pair(index, vid))
                    }
                }

                pairs.sortBy { it.first }
                val vids = pairs.map { it.second }.distinct()
                if (vids.isNotEmpty()) {
                    episodeVidsCache[cleanId] = vids
                    return vids
                }
            } catch (e: Exception) {
                lastErr = e
                try { Thread.sleep(200) } catch (ignored: InterruptedException) {}
            }
        }

        throw lastErr ?: IOException("Failed to fetch episode vids for $cleanId")
    }

    /**
     * 官方 App 弹幕列表拉取与解构 (支持 30秒滑动窗口及单集弹幕解析)
     * 请求 POST /novel/commentapi/comment/list/{vid}/v1/
     */
    fun fetchDanmaku(seriesId: String, vid: String, startMs: Long = 0L, durationMs: Long = 180000L): Map<String, Any?> {
        val cleanSeriesId = seriesId.trim().removePrefix("hongguo:").trim()
        val cleanVid = vid.trim().removePrefix("hongguo:").trim()
        if (!cleanVid.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid vid: $vid")
        }

        val actualSeriesId = if (cleanSeriesId.matches(Regex("[0-9]{1,32}"))) cleanSeriesId else ""
        val safeStart = if (startMs < 0) 0L else startMs
        val safeDuration = if (durationMs <= safeStart) safeStart + 180000L else durationMs

        val allItems = mutableListOf<Map<String, Any>>()
        val seenIds = mutableSetOf<String>()
        var totalCount = 0L

        // 官方弹幕按 30000ms (30秒) 为一个滑动窗口分页返回。
        // 若起播 (startMs == 0) 或需要全集弹幕，循环拉取整集所有窗口 (最多 6 个窗口 = 180秒) 彻底根治 30 秒后断档缺陷
        val windowStep = 30000L
        var curWindowStart = safeStart
        val maxWindowLimit = if (safeStart == 0L) (safeDuration.coerceAtMost(240000L)) else (safeStart + windowStep)

        while (curWindowStart < maxWindowLimit) {
            val payloadMap = JSONObject().apply {
                put("comment_source", 601)
                put("server_channel", 1000)
                put("group_id", cleanVid)
                put("group_type", 30)
                put("comment_type", 20)
                put("sort", 1)
                put("count", 90)
                put("cursor", "")
                put("aid", 8662)
                put("compliance_status", 0)
                put("business_param", JSONObject().apply {
                    if (actualSeriesId.isNotEmpty()) {
                        put("book_id", actualSeriesId)
                    }
                    put("start_offset_time", curWindowStart)
                    put("playlet_item_duration", safeDuration)
                    put("need_danmaku_guide_type", org.json.JSONArray(listOf(1, 3, 4, 2)))
                })
            }
            val payload = payloadMap.toString().toByteArray(Charsets.UTF_8)
            var windowSuccess = false

            for (attempt in 0..1) {
                try {
                    val signed = signer.sign(
                        "https://api5-normal-sinfonlineb.fqnovel.com/novel/commentapi/comment/list/$cleanVid/v1/",
                        VendorConstants.device,
                        payload
                    )

                    val req = Request.Builder()
                        .url(signed.url)
                        .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))

                    for (entry in signed.headers) {
                        req.header(entry.key, entry.value)
                    }
                    req.header("Comment-Source", "601")
                    req.header("Server-Channel", "1000")

                    val resp = client.newCall(req.build()).execute()
                    val bodyStr = resp.body?.string() ?: throw IOException("Empty response from comment/list")
                    val json = JSONObject(bodyStr)
                    val code = json.optInt("code", json.optJSONObject("BaseResp")?.optInt("StatusCode", 0) ?: 0)
                    if (code != 0) {
                        throw IOException("Danmaku API error code $code: " + json.optString("message"))
                    }

                    val data = json.optJSONObject("data") ?: JSONObject()
                    val dataList = data.optJSONArray("data_list") ?: org.json.JSONArray()

                    val cursorStr = data.optJSONObject("common_list_info")?.optString("cursor", "") ?: ""
                    if (cursorStr.isNotEmpty() && cursorStr.startsWith("{")) {
                        try {
                            val cursorJson = JSONObject(cursorStr)
                            val cnt = cursorJson.optLong("danmaku_count", 0L)
                            if (cnt > totalCount) totalCount = cnt
                        } catch (ignored: Exception) {}
                    }

                    for (i in 0 until dataList.length()) {
                        val row = dataList.optJSONObject(i) ?: continue
                        val comment = row.optJSONObject("comment") ?: continue
                        val common = comment.optJSONObject("common") ?: continue
                        val groupId = common.optString("group_id")
                        val status = common.optString("status", common.optInt("status", 1).toString())
                        if (groupId.isNotEmpty() && groupId != cleanVid) continue
                        if (status != "1") continue

                        val expand = comment.optJSONObject("expand")
                        val offsetTime = expand?.optLong("offset_time", -1L) ?: -1L
                        if (offsetTime < 0) continue

                        val textObj = common.optJSONObject("content")
                        var text = textObj?.optString("text") ?: ""
                        text = text.replace(Regex("[\\p{Cntrl}\\u2028\\u2029]"), " ").trim()
                        val id = comment.optString("comment_id")

                        if (id.isEmpty() || text.isEmpty() || seenIds.contains(id)) continue
                        if (text.length > 200) {
                            text = text.substring(0, 200) + "…"
                        }
                        seenIds.add(id)

                        allItems.add(mapOf(
                            "id" to id,
                            "text" to text,
                            "timeMs" to offsetTime
                        ))
                    }
                    windowSuccess = true
                    break
                } catch (e: Exception) {
                    try { Thread.sleep(150) } catch (ignored: InterruptedException) {}
                }
            }

            if (!windowSuccess && curWindowStart > safeStart) {
                // 后续窗口若偶发异常，平滑退出并保留已拉取到的前序窗口弹幕
                break
            }
            curWindowStart += windowStep
        }

        allItems.sortBy { (it["timeMs"] as? Long) ?: 0L }

        return mapOf(
            "episodeId" to cleanVid,
            "items" to allItems,
            "startMs" to safeStart,
            "nextMs" to curWindowStart,
            "total" to (if (totalCount > 0) totalCount else allItems.size.toLong())
        )
    }

    private data class VideoCandidate(
        val qNum: Int,
        val mainUrl: String,
        val spadeA: String,
        val vwidth: Int = 0,
        val vheight: Int = 0,
    )

    private fun isOddDimension(w: Int, h: Int): Boolean =
        (w > 0 && w != 540 && w % 8 != 0) || (h > 0 && h != 540 && h % 8 != 0)

    /**
     * Provider 00 (100% 对齐 aston314/hongguo-tv v0.2.173 minireel_mobile_v5.go & mobile-playback-v5.js):
     * 移动端 v5 (7.4.3.32 / PGT-AN10 / v04.10.03-ml-android) Gzip 压缩请求体 + F13 branch 12 X-Medusa/X-Helios 签名，
     * 彻底解决旧版 7.3.5.32 接口被服务端静默返回 HTTP 200 空包 (len=0) 的问题。
     */
    private fun executeMobileV5VideoModel(vid: String, initialProfile: PlaybackDeviceSession.Profile): JSONObject? {
        var currentProfile = initialProfile
        val ep = VendorConstants.mobileV5Endpoint
        val devLevel = VendorConstants.mobileV5DeviceLevel
        val rawPayload = """{"biz_param":{"detail_page_version":0,"device_level":$devLevel,"disable_digg_stat":false,"disable_video_relate_book":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["$vid"]},"dr_scene":"player"}""".toByteArray(Charsets.UTF_8)
        val gzipPayload = java.io.ByteArrayOutputStream().also { out ->
            java.util.zip.GZIPOutputStream(out).use { it.write(rawPayload) }
        }.toByteArray()

        for (attempt in 0..1) {
            val deviceId = currentProfile.values["device_id"] ?: ""
            val installId = currentProfile.values["iid"] ?: currentProfile.values["install_id"] ?: ""
            val cdid = currentProfile.values["cdid"] ?: VendorConstants.cdid
            if (deviceId.isBlank() || installId.isBlank() || deviceId == "0" || installId == "0") break

            val v5Params = linkedMapOf(
                "aid" to "8662",
                "app_name" to "novelread",
                "version_code" to VendorConstants.mobileV5VersionCode,
                "version_name" to VendorConstants.mobileV5VersionName,
                "manifest_version_code" to VendorConstants.mobileV5VersionCode,
                "channel" to VendorConstants.mobileV5Channel,
                "device_platform" to "android",
                "device_type" to VendorConstants.mobileV5DeviceType,
                "os_version" to VendorConstants.mobileV5OsVersion,
                "update_version_code" to VendorConstants.mobileV5VersionCode,
                "iid" to installId,
                "cdid" to cdid,
                "device_id" to deviceId,
            )

            var sawEmpty200 = false
            for (endpoint in listOf(ep, VendorConstants.ALTERNATE_V5_ENDPOINT).distinct()) {
                try {
                    val signed = signer.signPlaybackV5(endpoint, v5Params, gzipPayload)
                    val reqBuilder = Request.Builder()
                        .url(signed.url)
                        .post(gzipPayload.toRequestBody("application/json; charset=utf-8".toMediaType()))
                    for ((k, v) in signed.headers) {
                        reqBuilder.header(k, v)
                    }
                    reqBuilder.header("User-Agent", VendorConstants.mobileV5Ua)
                    reqBuilder.header("Accept", "application/json")
                    reqBuilder.header("Content-Type", "application/json; charset=utf-8")
                    reqBuilder.header("Content-Encoding", "gzip")

                    val resp = client.newCall(reqBuilder.build()).execute()
                    val statusCode = resp.code
                    val body = resp.body?.string().orEmpty()
                    HongguoDiagnostic.log(
                        if (statusCode == 200 && body.isNotBlank()) "INFO" else "WARN",
                        "stream_resolver",
                        "MOBILE_V5_RESP",
                        "mobile_v5 响应: ep=${endpoint.substringAfter("://").substringBefore("/")} code=$statusCode len=${body.length} preview=${body.take(80)}"
                    )
                    if (resp.isSuccessful && body.isNotBlank()) {
                        val root = JSONObject(body)
                        val code = root.optInt("Code", root.optInt("code", -1))
                        if (code == 0) {
                            val data = root.optJSONObject("data")
                            val entries = data?.optJSONObject("1004") ?: data
                            val entry = entries?.optJSONObject(vid)
                            val vm = entry?.opt("video_model")
                            val model = when (vm) {
                                is JSONObject -> vm
                                is String -> {
                                    val trimmed = vm.trim()
                                    if (trimmed.startsWith("{")) {
                                        runCatching { JSONObject(trimmed) }.getOrNull()
                                    } else {
                                        runCatching { JSONObject(String(decode64(trimmed), Charsets.UTF_8)) }.getOrNull()
                                    }
                                }
                                else -> null
                            }
                            if (model != null) return model
                        }
                    }
                    if (statusCode == 200 && body.isBlank()) {
                        sawEmpty200 = true
                    }
                } catch (e: Exception) {
                    android.util.Log.w("HongguoStreamResolver", "mobile_v5 异常: ${e.message}")
                }
            }
            if (sawEmpty200) {
                val recovered = recoverVideoTabV5(vid, currentProfile)
                if (recovered != null) return recovered
            }
            if (attempt == 0 && sawEmpty200) {
                val rotated = PlaybackDeviceSession.shared.rotate(client, failedDeviceId = deviceId)
                if (rotated.values["device_id"] != deviceId) {
                    currentProfile = rotated
                    continue
                }
            }
            break
        }
        return null
    }

    /**
     * 对齐 aston314/hongguo-tv v0.2.182 recoverVideoTab:
     * 当 V5 双主机均返回 200 空包时，使用同一已注册身份 + 7.4.3.32 参数 + V5 签名请求 video_tab 恢复。
     */
    private fun recoverVideoTabV5(vid: String, profile: PlaybackDeviceSession.Profile): JSONObject? {
        val deviceId = profile.values["device_id"] ?: return null
        val installId = profile.values["iid"] ?: profile.values["install_id"] ?: return null
        val cdid = profile.values["cdid"] ?: VendorConstants.cdid
        if (deviceId.isBlank() || installId.isBlank() || deviceId == "0" || installId == "0") return null

        // 对齐 upstream miniReelMobileV5VideoTabParams：13 个基础字段 + 9 个业务字段。
        // 旧实现只带 video_id/item_id/need_all_video_definition，而签名用的 key 序列里
        // 根本没有 video_id —— 等于请求里不携带剧集 id，服务端只可能回 200 空包。
        val tabParams = linkedMapOf(
            "aid" to "8662",
            "app_name" to "novelread",
            "version_code" to VendorConstants.mobileV5VersionCode,
            "version_name" to VendorConstants.mobileV5VersionName,
            "manifest_version_code" to VendorConstants.mobileV5VersionCode,
            "channel" to VendorConstants.mobileV5Channel,
            "device_platform" to "android",
            "device_type" to VendorConstants.mobileV5DeviceType,
            "os_version" to VendorConstants.mobileV5OsVersion,
            "update_version_code" to VendorConstants.mobileV5VersionCode,
            "iid" to installId,
            "cdid" to cdid,
            "device_id" to deviceId,
            "video_id" to vid,
            "video_id_type" to "0",
            "device_level" to "1",
            "need_all_video_definition" to "1",
            "need_mp4_align" to "0",
            "use_os_player" to "0",
            "video_platform" to "1024",
            "source" to "0",
            "from_video_id" to "",
        )
        return try {
            val tabUrl = "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/video_model/v1/"
            val signed = signer.signPlaybackV5VideoTab(tabUrl, tabParams)
            val reqBuilder = Request.Builder().url(signed.url).get()
            for ((k, v) in signed.headers) {
                if (!k.equals("X-SS-STUB", ignoreCase = true)) {
                    reqBuilder.header(k, v)
                }
            }
            reqBuilder.header("User-Agent", VendorConstants.MOBILE_V5_RECOVERY_UA)
            reqBuilder.header("Accept", "application/json; charset=utf-8")
            reqBuilder.header("Accept-Language", "zh-CN,zh;q=0.9")

            val resp = client.newCall(reqBuilder.build()).execute()
            val statusCode = resp.code
            val body = resp.body?.string().orEmpty()
            HongguoDiagnostic.log(
                if (statusCode == 200 && body.isNotBlank()) "INFO" else "WARN",
                "stream_resolver",
                "MOBILE_V5_TAB_RECOVER",
                "mobile_v5 video_tab 恢复响应: code=$statusCode len=${body.length} preview=${body.take(80)}"
            )
            if (resp.isSuccessful && body.isNotBlank()) {
                val root = JSONObject(body)
                val code = root.optInt("Code", root.optInt("code", -1))
                if (code == 0) {
                    val model = videoModelFromTabRoot(root, vid)
                    if (model != null) attachTabExpireAt(root, model)
                    model
                } else {
                    null
                }
            } else {
                null
            }
        } catch (e: Exception) {
            android.util.Log.w("HongguoStreamResolver", "recoverVideoTabV5 异常: ${e.message}")
            null
        }
    }


    /**
     * Provider 0 (100% 对齐 1736608552/hongguo-tv single-registered-profile.js & minireel_single_registered.go):
     * 使用已注册设备凭据 + 3ccc X-Argus + X-Ladon + X-Gorgon 签名直连 /novel/player/video_model/v1/，
     * 一次请求稳定返回 360p/480p/540p/720p/1080p 全档位正片流与 CENC 密钥！
     */
    private fun executeSingleRegisteredVideoModel(vid: String, initialProfile: PlaybackDeviceSession.Profile): JSONObject? {
        var currentProfile = initialProfile
        val ep = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/"
        val payload = """{"video_id":"$vid","content_type":1,"biz_param":{"need_all_video_definition":true,"video_platform":3}}""".toByteArray(Charsets.UTF_8)

        for (attempt in 0..1) {
            val deviceId = currentProfile.values["device_id"] ?: ""
            val installId = currentProfile.values["iid"] ?: currentProfile.values["install_id"] ?: ""
            if (deviceId.isBlank() || installId.isBlank() || deviceId == "0" || installId == "0") break

            val queryParams = linkedMapOf(
                "aid" to "8662",
                "app_name" to "novelread",
                "version_code" to "73532",
                "version_name" to "7.3.5.32",
                "manifest_version_code" to "73532",
                "update_version_code" to "73532",
                "channel" to "update_64",
                "device_platform" to "android",
                "os" to "android",
                "ssmix" to "a",
                "device_type" to "23049RAD8C",
                "device_brand" to "Redmi",
                "language" to "zh",
                "os_api" to "34",
                "os_version" to "14",
                "resolution" to "1080*2400",
                "dpi" to "440",
                "ac" to "wifi",
                "device_id" to deviceId,
                "iid" to installId,
            )
            try {
                val signed = signer.signSingleRegistered(ep, queryParams, payload)
                val reqBuilder = Request.Builder()
                    .url(signed.url)
                    .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))
                for ((k, v) in signed.headers) {
                    reqBuilder.header(k, v)
                }
                val cookie = if (currentProfile.cookie.isNotBlank()) {
                    currentProfile.cookie
                } else {
                    "install_id=$installId; ttreq=1; store-region=cn; store-region-src=did"
                }
                reqBuilder.header("Cookie", cookie)
                val resp = client.newCall(reqBuilder.build()).execute()
                val statusCode = resp.code
                val body = resp.body?.string().orEmpty()
                HongguoDiagnostic.log(
                    if (statusCode == 200 && body.isNotBlank()) "INFO" else "WARN",
                    "stream_resolver",
                    "SINGLE_REG_RESP",
                    "single_registered 响应: code=$statusCode len=${body.length} preview=${body.take(80)}"
                )
                if (resp.isSuccessful && body.isNotBlank()) {
                    val root = JSONObject(body)
                    val code = root.optInt("Code", root.optInt("code", -1))
                    if (code == 0) {
                        val d = root.optJSONObject("data")
                        val vm = d?.opt("video_model") ?: root.opt("video_model")
                        val model = when (vm) {
                            is JSONObject -> vm
                            is String -> {
                                val trimmed = vm.trim()
                                if (trimmed.startsWith("{")) {
                                    runCatching { JSONObject(trimmed) }.getOrNull()
                                } else {
                                    runCatching { JSONObject(String(decode64(trimmed), Charsets.UTF_8)) }.getOrNull()
                                }
                            }
                            else -> if (d != null && (d.has("video_list") || d.has("fallback_api"))) d else null
                        }
                        if (model != null) return model
                    }
                }
                // 对齐 minireel_single_registered.go 第 101-106 行：
                // 仅当收到确认的 HTTP 200 空响应（单设备免费配额耗尽）时，原地极速换发新设备重试一次（0.3s 完成）
                if (attempt == 0 && statusCode == 200 && body.isBlank()) {
                    val rotated = PlaybackDeviceSession.shared.rotate(client, failedDeviceId = deviceId)
                    if (rotated.values["device_id"] != deviceId) {
                        currentProfile = rotated
                        continue
                    }
                }
                break
            } catch (e: Exception) {
                android.util.Log.w("HongguoStreamResolver", "single_registered 异常: ${e.message}")
                break
            }
        }
        return null
    }

    /**
     * Provider：官方 video_tab 无正文 GET（对齐 upstream miniReelMobileV5Source.recoverVideoTab）。
     *
     * 这条 GET 必须带 v5 信封签名（x-khronos / x-helios / x-medusa），且与 POST 共用同一台
     * 已注册设备；早期实现把它当「免签名通道」裸发，服务端一律回 HTTP 200 + 0 字节，
     * 诊断里的 VIDEO_TAB_RESP len=0 就是这么来的。
     */
    private fun executeVideoTab(vid: String, profile: PlaybackDeviceSession.Profile): JSONObject? {
        val deviceId = profile.values["device_id"] ?: ""
        val installId = profile.values["iid"] ?: profile.values["install_id"] ?: ""
        if (deviceId.isBlank() || installId.isBlank() || deviceId == "0" || installId == "0") return null

        // 顺序即签名顺序：13 个设备字段 + 9 个业务字段，_rticket 由签名器追加在最后。
        val queryParams = linkedMapOf(
            "aid" to "8662",
            "app_name" to "novelread",
            "version_code" to VendorConstants.mobileV5VersionCode,
            "version_name" to VendorConstants.mobileV5VersionName,
            "manifest_version_code" to VendorConstants.mobileV5VersionCode,
            "channel" to VendorConstants.mobileV5Channel,
            "device_platform" to "android",
            "device_type" to VendorConstants.mobileV5DeviceType,
            "os_version" to VendorConstants.mobileV5OsVersion,
            "update_version_code" to VendorConstants.mobileV5VersionCode,
            "iid" to installId,
            "cdid" to (profile.values["cdid"] ?: VendorConstants.cdid),
            "device_id" to deviceId,
            "video_id" to vid,
            "video_id_type" to "0",
            "device_level" to "1",
            "need_all_video_definition" to "1",
            "need_mp4_align" to "0",
            "use_os_player" to "0",
            "video_platform" to "1024",
            "source" to "0",
            "from_video_id" to ""
        )

        // v2.7.95: 路径必须是 video_tab/video_model/ —— 打 multi_video_model 这条
        // 服务端固定回 200 + 空 body（POST 与 GET 两种形态都试过，全空）。
        val signed = signer.signPlaybackV5VideoTab(
            "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/video_model/v1/",
            queryParams
        )
        val reqBuilder = Request.Builder()
            .url(signed.url)
            .get()
            .header("User-Agent", VendorConstants.MOBILE_V5_RECOVERY_UA)
            .header("Accept", "application/json; charset=utf-8")
            .header("Accept-Language", "zh-CN,zh;q=0.9")
        for ((k, v) in signed.headers) {
            if (k.equals("X-SS-STUB", ignoreCase = true)) continue
            reqBuilder.header(k, v)
        }

        try {
            val resp = client.newCall(reqBuilder.build()).execute()
            val statusCode = resp.code
            val body = resp.body?.string().orEmpty()
            HongguoDiagnostic.log(
                if (statusCode == 200 && body.isNotBlank()) "INFO" else "WARN",
                "stream_resolver",
                "VIDEO_TAB_RESP",
                "video_tab 响应: code=$statusCode len=${body.length} preview=${body.take(80)}"
            )
            if (!resp.isSuccessful || body.isBlank()) return null
            val root = JSONObject(body)
            val code = root.optInt("Code", root.optInt("code", 0))
            if (code != 0) return null

            val model = videoModelFromTabRoot(root, vid) ?: return null
            attachTabExpireAt(root, model)
            return model
        } catch (e: Exception) {
            android.util.Log.w("HongguoStreamResolver", "video_tab 请求异常: ${e.message}")
            return null
        }
    }

    /**
     * 从 video_tab 响应里取 video_model。
     *
     * 实测响应形态（2026-11-26 17:20，官方 7.4.5.32 参数）：
     * ```
     * {"code":0,"message":"SUCCESS","data":{
     *    "video_model":"{\"status\":10,...,\"video_list\":[...5 档...]}",
     *    "authorization":"...","video_width":1080,"video_height":1920,"expire_time":1795706390}}
     * ```
     * `data.video_model` 直接是**字符串**，不在 `data[vid]` 也不在 `data["1004"][vid]` 里。
     * 旧实现按 `data.video_model_data[vid].video_model` 取，永远拿到 null —— 这是
     * video_tab 通道即便路径对了也「解析失败」的原因。map 形态保留作兼容。
     */
    private fun videoModelFromTabRoot(root: JSONObject, vid: String): JSONObject? {
        val data = root.optJSONObject("data") ?: return null
        asVideoModelJson(data.opt("video_model"))?.let { return it }
        val containers = listOfNotNull(data.optJSONObject("video_model_data"), data.optJSONObject("1004"), data)
        for (c in containers) {
            val row = c.optJSONObject(vid) ?: continue
            asVideoModelJson(row.opt("video_model"))?.let { return it }
        }
        return null
    }

    private fun asVideoModelJson(v: Any?): JSONObject? = when (v) {
        is JSONObject -> v
        is String -> {
            val t = v.trim()
            if (t.startsWith("{")) {
                runCatching { JSONObject(t) }.getOrNull()
            } else {
                runCatching { JSONObject(String(decode64(t), Charsets.UTF_8)) }.getOrNull()
            }
        }
        else -> null
    }

    /** video_tab 把过期时间放在 `data.expire_time`（video_model 里没有），透传给 TTL 判断用。 */
    private fun attachTabExpireAt(root: JSONObject, model: JSONObject) {
        val exp = root.optJSONObject("data")?.optLong("expire_time", 0L) ?: 0L
        if (exp > 0) {
            runCatching { model.put("__expire_at", exp) }
        }
    }

    /**
     * Provider 2 (双域名高可用轮询 POST 接口):
     * 请求 multi_video_model 端点，全套企业级六签名头加持
     *
     * v2.7.95 起**不再参与调度**：2026-11-26 17:19 复测，`multi_video_model` 的
     * POST /novel/player/multi_video_model/v1/、POST .../player/v1/、
     * GET /reading/bookapi/video_tab/multi_video_model/v1/ 三种形态全部 200 + 空 body，
     * 而对同一 vid 打 video_model / video_tab 都正常。保留代码仅供对照排查，勿再加入序列。
     */
    @Suppress("unused")
    private fun executeMultiVideoModel(vid: String, profile: PlaybackDeviceSession.Profile): JSONObject? {
        val payload = """{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"dr_scene":"preload","mixed_video_id_map":{"1004":["$vid"]}}""".toByteArray()
        val candidateEndpoints = listOf(
            "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/",
            "https://api5-normal-hl.fqnovel.com/novel/player/multi_video_model/v1/"
        )

        for (ep in candidateEndpoints) {
            try {
                val signed = try {
                    signer.signPlayback(ep, profile.values, payload)
                } catch (_: Exception) {
                    signer.signStandard(ep, profile.values, payload)
                }
                val reqBuilder = Request.Builder()
                    .url(signed.url)
                    .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))

                for ((k, v) in signed.headers) {
                    if (!k.equals("x-medusa", ignoreCase = true)) {
                        reqBuilder.header(k, v)
                    }
                }
                val installId = profile.values["iid"] ?: profile.values["install_id"] ?: ""
                val cookie = if (profile.cookie.isNotBlank()) {
                    profile.cookie
                } else {
                    "install_id=$installId; ttreq=1; store-region=cn; store-region-src=did"
                }
                reqBuilder.header("Cookie", cookie)

                val resp = client.newCall(reqBuilder.build()).execute()
                val statusCode = resp.code
                val body = resp.body?.string().orEmpty()
                HongguoDiagnostic.log(
                    if (statusCode == 200 && body.isNotBlank()) "INFO" else "WARN",
                    "stream_resolver",
                    "MULTI_RESP",
                    "multi_video_model 响应: ep=${ep.substringAfter("https://").substringBefore("/")} code=$statusCode len=${body.length} preview=${body.take(80)}"
                )
                if (resp.isSuccessful && body.isNotBlank()) {
                    val root = JSONObject(body)
                    val code = root.optInt("Code", root.optInt("code", 0))
                    if (code == 0) {
                        val map = root.optJSONObject("data") ?: continue
                        val entry = map.optJSONObject(vid)
                            ?: map.keys().asSequence().mapNotNull { map.optJSONObject(it) }.firstOrNull()
                            ?: continue
                        val vm = entry.opt("video_model")
                        val model = when (vm) {
                            is JSONObject -> vm
                            is String -> try { JSONObject(vm) } catch (_: Exception) { null }
                            else -> null
                        }
                        if (model != null) return model
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w("HongguoStreamResolver", "multi_video_model $ep 异常: ${e.message}")
            }
        }
        return null
    }

    /**
     * Provider 3 (单集独立协议 video_model 终极兜底，对齐 aston314/hongguo-tv minireel_single_model.go):
     * 专属 Xiaomi 73932 配置与单集专用载荷，提供最纯粹的 1080P/720P 原画流解析
     */
    private fun executeSingleVideoModel(vid: String, profile: PlaybackDeviceSession.Profile): JSONObject? {
        // v2.7.92: 官方 7.4.5.32 dex 里明文是 `POST /novel/player/video_model/v1/`，body 必须带
        // video_id 且整包 gzip；旧实现用的 signPlayback（老式 X-Argus/X-Gorgon 信封）在这条接口上
        // 只会拿到 200 空包，换成 v5 信封（X-Khronos/X-Helios/X-Medusa/X-SS-STUB）后即正常返回模型。
        val rawPayload = """{"video_id":"$vid","video_id_type":0,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"video_platform":1024,"dr_scene":"player"}""".toByteArray()
        val payload = java.io.ByteArrayOutputStream().also { out ->
            java.util.zip.GZIPOutputStream(out).use { it.write(rawPayload) }
        }.toByteArray()
        val cdid = profile.values["cdid"] ?: VendorConstants.cdid
        val deviceId = profile.values["device_id"] ?: ""
        val installId = profile.values["iid"] ?: profile.values["install_id"] ?: ""
        val openudid = profile.values["openudid"] ?: ""

        val singleParams = linkedMapOf(
            "iid" to installId,
            "device_id" to deviceId,
            "ac" to "wifi",
            "channel" to "update_64",
            "aid" to "8662",
            "app_name" to "novelread",
            "cdid" to cdid,
            "version_code" to "73532",
            "version_name" to "7.3.5.32",
            "device_platform" to "android",
            "os" to "android",
            "ssmix" to "a",
            "device_type" to "23049RAD8C",
            "device_brand" to "Redmi",
            "language" to "zh",
            "os_api" to "34",
            "os_version" to "14",
            "manifest_version_code" to "73532",
            "resolution" to "1080*2400",
            "dpi" to "440",
            "update_version_code" to "73532",
            "host_abi" to "arm64-v8a",
            "dragon_device_type" to "phone",
            "pv_player" to "73532",
            "compliance_status" to "0",
            "need_personal_recommend" to "1",
            "player_so_load" to "1",
            "is_android_pad_screen" to "0",
            "openudid" to openudid,
            "rom_version" to (profile.values["rom_version"] ?: "V417IR+release-keys"),
            "klink_egdi" to (profile.values["klink_egdi"] ?: ""),
            "video_id" to vid,
            "video_id_type" to "0",
            "device_level" to "4",
            "need_all_video_definition" to "1",
            "need_mp4_align" to "0",
            "use_os_player" to "0",
            "video_platform" to "1024"
        )

        val ep = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/"
        try {
            val signed = signer.signPlaybackV5Keys(ep, singleParams, payload, SINGLE_MODEL_V5_KEYS)
            val reqBuilder = Request.Builder()
                .url(signed.url)
                .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))

            for ((k, v) in signed.headers) {
                reqBuilder.header(k, v)
            }
            // 只带 v5 信封真正需要的头。上一版额外塞了 X-Vc-Bdturing-Sdk-Version /
            // X-Tt-Request-Tag / X-Reading-Request / Lc 这些伪造值，网关识别为异常客户端后
            // 直接回 200 空包，反而不如干净请求。
            reqBuilder.header("User-Agent", VendorConstants.MOBILE_V5_UA)
            reqBuilder.header("Accept", "application/json")
            reqBuilder.header("Content-Encoding", "gzip")
            reqBuilder.header("X-SS-DP", "8662")
            val cookie = if (profile.cookie.isNotBlank()) {
                profile.cookie
            } else {
                "install_id=$installId; ttreq=1; store-region=cn; store-region-src=did"
            }
            reqBuilder.header("Cookie", cookie)

            val resp = client.newCall(reqBuilder.build()).execute()
            val statusCode = resp.code
            val body = resp.body?.string().orEmpty()
            HongguoDiagnostic.log(
                if (statusCode == 200 && body.isNotBlank()) "INFO" else "WARN",
                "stream_resolver",
                "SINGLE_MODEL_RESP",
                "video_model 响应: code=$statusCode len=${body.length} preview=${body.take(80)}"
            )
            if (resp.isSuccessful && body.isNotBlank()) {
                val root = JSONObject(body)
                val code = root.optInt("Code", root.optInt("code", 0))
                if (code == 0) {
                    val d = root.optJSONObject("data")
                    val vm = d?.opt("video_model") ?: root.opt("video_model")
                    val model = when (vm) {
                        is JSONObject -> vm
                        is String -> try { JSONObject(vm) } catch (_: Exception) { null }
                        else -> null
                    }
                    if (model != null) {
                        // v2.7.93: 直链有效期只有约 6 小时（data.expire_time 实测 = 请求时刻 + 21600s），
                        // 把到期时间塞进 model 透传给 Dart 层，用于缓存失效判断。
                        val expireAt = d?.optLong("expire_time", 0L) ?: 0L
                        if (expireAt > 0) {
                            try {
                                model.put("__expire_at", expireAt)
                            } catch (_: Exception) {}
                        }
                        return model
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("HongguoStreamResolver", "video_model 单集接口异常: ${e.message}")
        }
        return null
    }

    /**
     * 统一视频流解密与提取引擎 (兼容三种不同 Provider 的 video_model 结构)
     */
    private fun extractPlaybackOptions(model: JSONObject, vid: String, maxQuality: Int): Map<String, Any?>? {
        var seed = byteArrayOf()
        val seedStr = model.optString("key_seed")
        if (seedStr.isNotEmpty()) {
            seed = try { decode64(seedStr) } catch (_: Exception) { byteArrayOf() }
        }

        val candidateList = mutableListOf<VideoCandidate>()
        val rawVideoList = model.opt("video_list")
        if (rawVideoList is org.json.JSONArray) {
            for (i in 0 until rawVideoList.length()) {
                val item = rawVideoList.optJSONObject(i) ?: continue
                val meta = item.optJSONObject("video_meta") ?: JSONObject()
                val codec = meta.optString("codec_type", item.optString("codec_type")).lowercase()
                if (codec == "bytevc2" || codec == "bvc2") continue

                val mainUrl = item.optString("main_url").ifEmpty {
                    item.optString("backup_url_1").ifEmpty { item.optString("backup_url") }
                }
                if (mainUrl.isEmpty()) continue

                val defStr = meta.optString("definition").ifEmpty {
                    meta.optString("quality_desc").ifEmpty {
                        item.optString("quality_desc").ifEmpty {
                            meta.optString("vheight").ifEmpty {
                                meta.optString("height").ifEmpty { item.optString("height") }
                            }
                        }
                    }
                }
                var qNum = Regex("(\\d+)").find(defStr)?.groupValues?.get(1)?.toIntOrNull() ?: 0
                if (qNum == 0) {
                    val vh = meta.optInt("vheight", 0)
                    val vw = meta.optInt("vwidth", 0)
                    qNum = if (vw > 0 && (vh == 0 || vw < vh)) vw else vh
                }
                if (qNum == 0) qNum = 720

                val vw = meta.optInt("vwidth", meta.optInt("width", item.optInt("vwidth", item.optInt("width", 0))))
                val vh = meta.optInt("vheight", meta.optInt("height", item.optInt("vheight", item.optInt("height", 0))))
                val encInfo = item.optJSONObject("encrypt_info")
                val spadeA = encInfo?.optString("spade_a")?.ifEmpty { item.optString("spade_a") } ?: item.optString("spade_a")
                candidateList.add(VideoCandidate(qNum, mainUrl, spadeA, vw, vh))
            }
        } else if (rawVideoList is JSONObject) {
            val keys = rawVideoList.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                val item = rawVideoList.optJSONObject(k) ?: continue
                val meta = item.optJSONObject("video_meta") ?: JSONObject()
                val codec = meta.optString("codec_type", item.optString("codec_type")).lowercase()
                if (codec == "bytevc2" || codec == "bvc2") continue

                val mainUrl = item.optString("main_url").ifEmpty {
                    item.optString("backup_url_1").ifEmpty { item.optString("backup_url") }
                }
                if (mainUrl.isEmpty()) continue

                val defStr = meta.optString("definition").ifEmpty {
                    item.optString("definition").ifEmpty {
                        meta.optString("quality_desc").ifEmpty {
                            item.optString("quality_desc").ifEmpty {
                                item.optString("quality").ifEmpty { k }
                            }
                        }
                    }
                }
                var qNum = Regex("(\\d+)").find(defStr)?.groupValues?.get(1)?.toIntOrNull() ?: 0
                if (qNum == 0) {
                    val vh = meta.optInt("vheight", item.optInt("vheight", 0))
                    val vw = meta.optInt("vwidth", item.optInt("vwidth", 0))
                    qNum = if (vw > 0 && (vh == 0 || vw < vh)) vw else vh
                }
                if (qNum == 0) qNum = 720

                val vw = meta.optInt("vwidth", meta.optInt("width", item.optInt("vwidth", item.optInt("width", 0))))
                val vh = meta.optInt("vheight", meta.optInt("height", item.optInt("vheight", item.optInt("height", 0))))
                val encInfo = item.optJSONObject("encrypt_info")
                val spadeA = encInfo?.optString("spade_a")?.ifEmpty { item.optString("spade_a") } ?: item.optString("spade_a")
                candidateList.add(VideoCandidate(qNum, mainUrl, spadeA, vw, vh))
            }
        }

        // fallback_api 平滑降级 (对齐 minireel_codec_fallback.go: 仅当内联列表为空或全为 bytevc2 时请求 fallback_api，健康内联直链零额外请求秒开)
        if (candidateList.isEmpty()) {
            val rawFallback = model.opt("fallback_api")
            val fallback = when (rawFallback) {
                is JSONObject -> rawFallback.optString("fallback_api")
                is org.json.JSONArray -> rawFallback.optString(0)
                else -> runCatching { JSONObject(rawFallback.toString()).optString("fallback_api") }.getOrDefault(rawFallback?.toString() ?: "")
            }
            if (fallback.startsWith("https://") || fallback.startsWith("http://")) {
                try {
                    val fbReq = Request.Builder()
                        .url(fallback)
                        .header("User-Agent", VendorConstants.VIDEO_UA)
                        .build()
                    val fbResp = client.newCall(fbReq).execute()
                    val fbBody = fbResp.body?.string().orEmpty()
                    if (fbBody.isNotEmpty()) {
                        val info = JSONObject(fbBody).optJSONObject("video_info")?.optJSONObject("data")
                        val fbList = info?.optJSONObject("video_list")
                        if (fbList != null) {
                            val seedFb = info.optString("key_seed")
                            if (seedFb.isNotEmpty()) {
                                seed = try { decode64(seedFb) } catch (_: Exception) { seed }
                            }
                            val fKeys = fbList.keys()
                            while (fKeys.hasNext()) {
                                val k = fKeys.next()
                                val item = fbList.optJSONObject(k) ?: continue
                                val mainUrl = item.optString("main_url")
                                val codec = item.optString("codec_type").lowercase()
                                if (mainUrl.isEmpty() || codec == "bytevc2" || codec == "bvc2") continue

                                val qDesc = item.optString("definition").ifEmpty {
                                    item.optString("quality_desc")
                                }.ifEmpty {
                                    item.optString("height").ifEmpty {
                                        item.optString("vheight").ifEmpty {
                                            item.optString("quality").ifEmpty { k }
                                        }
                                    }
                                }
                                val qNum = Regex("(\\d+)").find(qDesc)?.groupValues?.get(1)?.toIntOrNull() ?: 720
                                val vw = item.optInt("vwidth", item.optInt("width", 0))
                                val vh = item.optInt("vheight", item.optInt("height", 0))
                                val spadeA = item.optString("spade_a")
                                candidateList.add(VideoCandidate(qNum, mainUrl, spadeA, vw, vh))
                            }
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.w("HongguoStreamResolver", "fallback_api 请求异常: ${e.message}")
                }

                // 多编码智能协商 (Codec Fallback): 若默认资源全为 ByteVC2，自动协商请求 H.265/H.264 全档位正片原画
                if (candidateList.isEmpty()) {
                    for (codec in listOf("codec_type=1", "codec_type=0&force_codec=h264", "codec_type=3")) {
                        try {
                            val parts = fallback.split("?", limit = 2)
                            val candFb = if (parts.size < 2) "$fallback?$codec" else parts[0] + "?" + (parts[1].split("&").filter { !it.startsWith("codec_type=") && !it.startsWith("force_codec=") } + codec).joinToString("&")
                            val cReq = Request.Builder().url(candFb).header("User-Agent", VendorConstants.VIDEO_UA).build()
                            val cResp = client.newCall(cReq).execute()
                            val cBody = cResp.body?.string().orEmpty()
                            if (cBody.isNotEmpty()) {
                                val cInfo = JSONObject(cBody).optJSONObject("video_info")?.optJSONObject("data")
                                val cList = cInfo?.optJSONObject("video_list")
                                if (cList != null) {
                                    val seedFb = cInfo.optString("key_seed")
                                    if (seedFb.isNotEmpty()) {
                                        seed = try { decode64(seedFb) } catch (_: Exception) { seed }
                                    }
                                    val fKeys = cList.keys()
                                    while (fKeys.hasNext()) {
                                        val k = fKeys.next()
                                        val item = cList.optJSONObject(k) ?: continue
                                        val mainUrl = item.optString("main_url")
                                        val codecType = item.optString("codec_type").lowercase()
                                        if (mainUrl.isEmpty() || codecType == "bytevc2" || codecType == "bvc2") continue
                                        val qDesc = item.optString("definition").ifEmpty {
                                    item.optString("quality_desc")
                                }.ifEmpty {
                                            item.optString("height").ifEmpty {
                                                item.optString("vheight").ifEmpty {
                                                    item.optString("quality").ifEmpty { k }
                                                }
                                            }
                                        }
                                        val qNum = Regex("(\\d+)").find(qDesc)?.groupValues?.get(1)?.toIntOrNull() ?: 720
                                        val vw = item.optInt("vwidth", item.optInt("width", 0))
                                        val vh = item.optInt("vheight", item.optInt("height", 0))
                                        val spadeA = item.optString("spade_a")
                                        candidateList.add(VideoCandidate(qNum, mainUrl, spadeA, vw, vh))
                                    }
                                    if (candidateList.isNotEmpty()) break
                                }
                            }
                        } catch (_: Exception) {}
                    }
                }
            }
        }

        if (candidateList.isEmpty()) return null
        candidateList.sortByDescending { it.qNum }

        val multiMap = mutableMapOf<String, String>()
        val keysMap = mutableMapOf<String, String>()
        val softDecMap = mutableMapOf<String, Boolean>()
        val qualityList = mutableListOf<Int>()

        for (cand in candidateList) {
            val qNum = cand.qNum
            var rawUrl = cand.mainUrl
            if (rawUrl.isNotEmpty()) {
                if (!rawUrl.startsWith("http://") && !rawUrl.startsWith("https://")) {
                    if (seed.isNotEmpty()) {
                        try {
                            val decrypted = MediaCrypto.decryptUrl(rawUrl, seed)
                            if (decrypted.startsWith("http")) {
                                rawUrl = decrypted
                            }
                        } catch (_: Exception) {}
                    }
                    if (!rawUrl.startsWith("http://") && !rawUrl.startsWith("https://")) {
                        try {
                            val b64Str = String(decode64(rawUrl), Charsets.UTF_8)
                            if (b64Str.startsWith("http://") || b64Str.startsWith("https://")) {
                                rawUrl = b64Str
                            }
                        } catch (_: Exception) {}
                    }
                }
            }
            if (rawUrl.startsWith("http")) {
                val qLabel = "${qNum}P"
                multiMap[qLabel] = rawUrl
                if (!qualityList.contains(qNum)) qualityList.add(qNum)
                softDecMap[qLabel] = isOddDimension(cand.vwidth, cand.vheight)

                // 按清晰度严格隔离密钥：明文流清除 keysMap 对应项，杜绝跨清晰度串用 AES Key 导致整段解码花屏
                val spadeA = cand.spadeA
                if (spadeA.isNotEmpty()) {
                    val derived = MediaCrypto.deriveKeyHex(spadeA)
                    if (derived.isNotEmpty()) {
                        keysMap[qLabel] = derived
                    } else {
                        keysMap.remove(qLabel)
                    }
                } else {
                    keysMap.remove(qLabel)
                }
            }
        }

        if (multiMap.isNotEmpty()) {
            val targetQuality = qualityList.firstOrNull { it <= maxQuality } ?: qualityList.first()
            val targetLabel = "${targetQuality}P"
            val primaryUrl = multiMap[targetLabel] ?: multiMap.values.first()
            val primaryKey = keysMap[targetLabel] ?: ""
            val needsSoft = softDecMap[targetLabel] == true
            multiMap["自动"] = primaryUrl
            softDecMap["自动"] = needsSoft

            return mapOf(
                "url" to primaryUrl,
                "decryptionKey" to primaryKey,
                "keys" to keysMap,
                "quality" to targetLabel,
                "actualQuality" to targetQuality,
                "qualities" to qualityList,
                "multiMap" to multiMap,
                "needsSoftwareDecode" to needsSoft,
                "softDecMap" to softDecMap,
                // v2.7.93: 直链到期时间（秒级），0 = 未知（则不做 TTL 判断）
                "expireAt" to model.optLong("__expire_at", 0L)
            )
        }
        return null
    }

    /**
     * 单集视频流模型与 CENC 解密 Key 解析 (对齐 aston314/hongguo-tv 2026-11-07 工业级三路协同体系)
     * 1. 记忆首选：若命中 seriesId 成功通道缓存，优先直连秒开 (0.3 秒无感起播)
     * 2. video_tab GET 免风控通道优先
     * 3. multi_video_model 双域名 POST 轮询
     * 4. video_model 单集六签名高可用终极兜底
     * 5. 官方 Web 试看直链平滑保障
     */
    fun resolve(vid: String, maxQuality: Int = 1080, seriesId: String = ""): Map<String, Any?> {
        resolveLock.lock()
        try {
            return doResolve(vid, maxQuality, seriesId)
        } finally {
            resolveLock.unlock()
        }
    }

    private fun doResolve(vid: String, maxQuality: Int = 1080, seriesId: String = ""): Map<String, Any?> {
        val cleanVid = vid.trim()
        if (!cleanVid.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid vid: $vid")
        }

        // v2.7.95: video_tab 提到第一位。实测（2026-11-26 17:20）：
        //   video_tab/video_model GET → 5 档 360/480/540/720/1080P，且不需 POST body / gzip
        //   video_model POST          → 只有 1 档 720P（即使 need_all_video_definition=true）
        // 因此旧顺序下画质切换的 multiMap 里永远只有一档，1080P 实际拿不到。
        // multi_video_model 已从序列中移除：POST 与 GET(tab) 两种形态实测都固定返回 200 空包。
        val allProviders = listOf(
            PROVIDER_VIDEO_TAB,
            PROVIDER_SINGLE_VIDEO_MODEL,
            PROVIDER_MOBILE_V5,
            PROVIDER_SINGLE_REGISTERED,
        )
        val preferred = getPreferredProvider(seriesId)
        val providers = if (preferred != null && allProviders.contains(preferred)) {
            listOf(preferred) + allProviders.filter { it != preferred }
        } else {
            allProviders
        }

        var identity = PlaybackDeviceSession.shared.profile(client)
        val resolveStart = System.currentTimeMillis()
        HongguoDiagnostic.log(
            "INFO", "stream_resolver", "RESOLVE_START",
            "开始取流解析: vid=$cleanVid, maxQuality=${maxQuality}P, seriesId=$seriesId, did=${identity.values["device_id"]}"
        )

        fun tryExecuteProvider(p: String, prof: PlaybackDeviceSession.Profile): Map<String, Any?>? {
            val pStart = System.currentTimeMillis()
            HongguoDiagnostic.log("INFO", "stream_resolver", "TRY_PROVIDER", "尝试通道: $p (did=${prof.values["device_id"]})")
            val model = when (p) {
                PROVIDER_MOBILE_V5 -> executeMobileV5VideoModel(cleanVid, prof)
                PROVIDER_SINGLE_REGISTERED -> executeSingleRegisteredVideoModel(cleanVid, prof)
                PROVIDER_VIDEO_TAB -> executeVideoTab(cleanVid, prof)
                PROVIDER_MULTI_VIDEO_MODEL -> executeMultiVideoModel(cleanVid, prof)
                PROVIDER_SINGLE_VIDEO_MODEL -> executeSingleVideoModel(cleanVid, prof)
                else -> null
            }
            val elapsed = System.currentTimeMillis() - pStart
            if (model == null) {
                HongguoDiagnostic.log("WARN", "stream_resolver", "PROVIDER_FAIL", "通道 $p 未返回有效模型 (耗时 ${elapsed}ms)")
                return null
            }
            val opts = extractPlaybackOptions(model, cleanVid, maxQuality)
            if (opts != null) {
                val q = opts["quality"] as? String ?: "${maxQuality}P"
                val kLen = (opts["decryptionKey"] as? String)?.length ?: 0
                HongguoDiagnostic.log(
                    "INFO", "stream_resolver", "PROVIDER_OK",
                    "通道 $p 解析成功: 画质=$q, keyLen=$kLen (耗时 ${elapsed}ms)"
                )
            } else {
                HongguoDiagnostic.log("WARN", "stream_resolver", "EXTRACT_FAIL", "通道 $p 提取播放参数失败 (耗时 ${elapsed}ms)")
            }
            return opts
        }

        // 按智能优先级序列依次尝试四大通道（single_registered 内置空响应极速换号）
        for (provider in providers) {
            // 每次尝试读取最新会话身份（若在前序通道中已触发换号则自动同步）
            identity = PlaybackDeviceSession.shared.profile(client)
            val result = tryExecuteProvider(provider, identity)
            if (result != null) {
                recordSourceSuccess(seriesId, provider)
                val totalElapsed = System.currentTimeMillis() - resolveStart
                android.util.Log.i("HongguoStreamResolver", "取流成功 [通道: $provider, 画质: ${result["quality"]}, seriesId: $seriesId]")
                HongguoDiagnostic.log("INFO", "stream_resolver", "RESOLVE_OK", "取流成功 [通道: $provider, 画质: ${result["quality"]}, 总耗时: ${totalElapsed}ms]")
                HongguoDiagnostic.updateReport(
                    stage = "stream_resolver",
                    code = "RESOLVE_OK",
                    elapsedMs = totalElapsed,
                    summary = "取流成功: 通道 $provider · ${result["quality"]}"
                )
                return result
            }
        }

        // 若记忆通道失效，清除旧通道记忆并尝试受冷却锁保护的单次设备刷新重试首选通道
        if (preferred != null) {
            seriesSourceMemory.remove(seriesId.trim().removePrefix("hongguo:").trim())
        }
        val oldDevId = identity.values["device_id"] ?: ""
        val rotated = PlaybackDeviceSession.shared.rotate(client, failedDeviceId = oldDevId)
        if (rotated.values["device_id"] != oldDevId) {
            for (provider in listOf(PROVIDER_VIDEO_TAB, PROVIDER_SINGLE_VIDEO_MODEL, PROVIDER_MOBILE_V5, PROVIDER_SINGLE_REGISTERED)) {
                val result = tryExecuteProvider(provider, rotated)
                if (result != null) {
                    recordSourceSuccess(seriesId, provider)
                    val totalElapsed = System.currentTimeMillis() - resolveStart
                    android.util.Log.i("HongguoStreamResolver", "刷新设备后取流成功 [通道: $provider, 画质: ${result["quality"]}]")
                    HongguoDiagnostic.log("INFO", "stream_resolver", "RESOLVE_ROTATE_OK", "刷新设备后取流成功 [通道: $provider, 画质: ${result["quality"]}, 总耗时: ${totalElapsed}ms]")
                    HongguoDiagnostic.updateReport(
                        stage = "stream_resolver",
                        code = "RESOLVE_OK",
                        elapsedMs = totalElapsed,
                        summary = "刷新设备后取流成功: 通道 $provider · ${result["quality"]}"
                    )
                    return result
                }
            }
        }

        val totalElapsed = System.currentTimeMillis() - resolveStart
        val failSummary = "取流失败: 四大通道均未能获取视频流 (vid=$cleanVid, did=${identity.values["device_id"]})"
        HongguoDiagnostic.log("ERROR", "stream_resolver", "RESOLVE_EMPTY", failSummary, mapOf("totalElapsed" to "${totalElapsed}ms"))
        HongguoDiagnostic.updateReport(
            stage = "stream_resolver",
            code = "RESOLVE_EMPTY",
            elapsedMs = totalElapsed,
            summary = failSummary,
            lastError = "All providers returned empty response"
        )
        throw IOException(failSummary)
    }
}
