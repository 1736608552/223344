// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.hongguo

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

object HongguoStreamResolver {
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private val signer = Signer()
    private val episodeVidsCache = java.util.concurrent.ConcurrentHashMap<String, List<String>>()
    private val seriesIntroCache = java.util.concurrent.ConcurrentHashMap<String, String>()

    /**
     * 获取已缓存的短剧简介 (在 fetchEpisodeVids 解析 Web SSR 时自动提取并缓存)
     */
    fun getCachedSeriesIntro(seriesId: String): String {
        val cleanId = seriesId.trim().removePrefix("hongguo:").trim()
        return seriesIntroCache[cleanId] ?: ""
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
     * 短剧全集分集 VID 列表拉取 (Web 官网 SSR 详情页优先保证全量 80~100+ 集 + 官方 App 签名兜底)
     */
    fun fetchEpisodeVids(seriesId: String): List<String> {
        val cleanId = seriesId.trim().removePrefix("hongguo:").trim()
        if (!cleanId.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid seriesId: $seriesId")
        }

        episodeVidsCache[cleanId]?.let { return it }

        var lastErr: Exception? = null

        // 通道 1 (首选最高优先级，彻底突破试看 3 集限制):
        // 从官网 SSR 详情页 _ROUTER_DATA 提取全剧完整 vid_list (可一次性获取全部 80~100+ 集)
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

    private data class VideoCandidate(val qNum: Int, val mainUrl: String, val spadeA: String)

    /**
     * 单集视频流模型与 CENC 解密 Key 解析 (官方 multi_video_model 1080P 原画 + 注册设备身份会话 + 0/700/1500ms 退避重试)
     * 对齐 jycao2/hongguoTV 0.23.0 工业级标准实现，彻底解决随机伪造设备号导致的服务端空响应与报错。
     */
    fun resolve(vid: String, maxQuality: Int = 1080): Map<String, Any?> {
        val cleanVid = vid.trim()
        if (!cleanVid.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid vid: $vid")
        }

        val payload = """{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["$cleanVid"]}}""".toByteArray()
        var lastErr: Exception? = null

        // 统一由 PlaybackDeviceSession 提供进程内常驻且已注册/验证的设备身份与 Cookie，只换时间戳不换设备身份
        val identity = PlaybackDeviceSession.shared.profile(client)
        var bodyStr = ""

        // 策略 1 (首选，对齐 hongguoTV): 直接请求官方 multi_video_model/v1/ 携带合法设备身份与 Cookie (0/700/1500ms 智能退避重试)
        val delays = listOf(0L, 700L, 1500L)
        for (attempt in 0..2) {
            val delayMs = delays[attempt]
            if (delayMs > 0) {
                try { Thread.sleep(delayMs) } catch (ignored: InterruptedException) {}
            }
            try {
                val now = System.currentTimeMillis()
                val queryParams = identity.values.toMutableMap()
                queryParams["_rticket"] = now.toString()
                val queryString = queryParams.entries.joinToString("&") { (k, v) ->
                    java.net.URLEncoder.encode(k, "UTF-8") + "=" + java.net.URLEncoder.encode(v, "UTF-8")
                }
                val url = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?$queryString"

                val req = Request.Builder()
                    .url(url)
                    .header("User-Agent", PlaybackDeviceSession.PLAYBACK_UA)
                    .header("Accept", "application/json; charset=utf-8,application/x-protobuf")
                    .apply {
                        if (identity.cookie.isNotBlank()) {
                            header("Cookie", identity.cookie)
                        }
                    }
                    .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))
                    .build()

                val resp = client.newCall(req).execute()
                if (resp.isSuccessful) {
                    val content = resp.body?.string().orEmpty()
                    if (content.isNotBlank()) {
                        val testJson = try { JSONObject(content) } catch (ignored: Exception) { null }
                        val code = testJson?.optInt("Code", testJson.optInt("code", 0)) ?: -1
                        if (code == 0) {
                            bodyStr = content
                            break
                        }
                    }
                }
            } catch (e: Exception) {
                lastErr = e
                android.util.Log.w("HongguoStreamResolver", "multi_video_model/v1 请求尝试 $attempt 异常: ${e.message}")
            }
        }

        // 策略 2 (双保险兜底): 若 v1 暂未返回，使用带签名的 preload/v1 尝试抓取
        if (bodyStr.isBlank()) {
            try {
                val signed = signer.sign(
                    "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/preload/v1/",
                    identity.values,
                    payload
                )
                val reqBuilder = Request.Builder()
                    .url(signed.url)
                    .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))
                for (entry in signed.headers) {
                    reqBuilder.header(entry.key, entry.value)
                }
                val resp = client.newCall(reqBuilder.build()).execute()
                val content = resp.body?.string().orEmpty()
                if (content.isNotBlank()) {
                    val testJson = try { JSONObject(content) } catch (ignored: Exception) { null }
                    if (testJson?.optInt("Code", testJson.optInt("code", 0)) == 0) {
                        bodyStr = content
                    }
                }
            } catch (e: Exception) {
                lastErr = e
                android.util.Log.w("HongguoStreamResolver", "preload/v1 兜底请求异常: ${e.message}")
            }
        }

        if (bodyStr.isBlank()) {
            throw lastErr ?: IOException("Empty response from multi_video_model for vid $cleanVid")
        }

        val data = JSONObject(bodyStr)
        if (data.optInt("Code", data.optInt("code", 0)) != 0) {
            throw IOException("Video model API returned error: " + data.optString("message"))
        }

        val map = data.optJSONObject("data") ?: throw IOException("Empty data in video model")
        val entry = map.optJSONObject(cleanVid)
            ?: map.keys().asSequence().mapNotNull { map.optJSONObject(it) }.firstOrNull()
            ?: throw IOException("No entry found for vid $cleanVid")

        val model = entry.optJSONObject("video_model") ?: JSONObject(entry.optString("video_model", "{}"))

        var seed = byteArrayOf()
        val seedStr = model.optString("key_seed")
        if (seedStr.isNotEmpty()) {
            seed = try { decode64(seedStr) } catch (ignored: Exception) { byteArrayOf() }
        }

        val candidateList = mutableListOf<VideoCandidate>()

        // 通道 A (最高优先级，官方原生 1080P 原画直出，彻底杜绝 360P 降级):
        // 直接从 video_model 中的 video_list 提取各清晰度原画流与 spade_a
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

                        val encInfo = item.optJSONObject("encrypt_info")
                        val spadeA = encInfo?.optString("spade_a")?.ifEmpty { item.optString("spade_a") } ?: item.optString("spade_a")
                        candidateList.add(VideoCandidate(qNum, mainUrl, spadeA))
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
                            item.optString("quality_desc").ifEmpty {
                                item.optString("height").ifEmpty {
                                    item.optString("vheight").ifEmpty {
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

                        val encInfo = item.optJSONObject("encrypt_info")
                        val spadeA = encInfo?.optString("spade_a")?.ifEmpty { item.optString("spade_a") } ?: item.optString("spade_a")
                        candidateList.add(VideoCandidate(qNum, mainUrl, spadeA))
                    }
                }

                // 通道 B (平滑降级): 仅在 video_list 为空时，作为备选请求 fallback_api
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
                            val fbBody = fbResp.body?.string() ?: ""
                            if (fbBody.isNotEmpty()) {
                                val info = JSONObject(fbBody).optJSONObject("video_info")?.optJSONObject("data")
                                val fbList = info?.optJSONObject("video_list")
                                if (fbList != null) {
                                    val seedFb = info.optString("key_seed")
                                    if (seedFb.isNotEmpty()) {
                                        seed = try { decode64(seedFb) } catch (ignored: Exception) { seed }
                                    }
                                    val fKeys = fbList.keys()
                                    while (fKeys.hasNext()) {
                                        val k = fKeys.next()
                                        val item = fbList.optJSONObject(k) ?: continue
                                        val mainUrl = item.optString("main_url")
                                        val codec = item.optString("codec_type").lowercase()
                                        if (mainUrl.isEmpty() || codec == "bytevc2" || codec == "bvc2") continue

                                        val qDesc = item.optString("quality_desc").ifEmpty {
                                            item.optString("height").ifEmpty {
                                                item.optString("vheight").ifEmpty {
                                                    item.optString("quality").ifEmpty { k }
                                                }
                                            }
                                        }
                                        val qNum = Regex("(\\d+)").find(qDesc)?.groupValues?.get(1)?.toIntOrNull() ?: 720
                                        val spadeA = item.optString("spade_a")
                                        candidateList.add(VideoCandidate(qNum, mainUrl, spadeA))
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("HongguoStreamResolver", "fallback_api 请求异常: ${e.message}")
                        }
                    }
                }

                if (candidateList.isEmpty()) {
                    throw IOException("No video stream candidate found for vid $cleanVid")
                }

                candidateList.sortByDescending { it.qNum }

                val multiMap = mutableMapOf<String, String>()
                val keysMap = mutableMapOf<String, String>()
                val qualityList = mutableListOf<Int>()
                var fallbackKey = ""

                for (cand in candidateList) {
                    val qNum = cand.qNum
                    var rawUrl = cand.mainUrl
                    if (rawUrl.isNotEmpty()) {
                        // 1. 若已经是 http/https 直链，直接可用
                        if (!rawUrl.startsWith("http://") && !rawUrl.startsWith("https://")) {
                            // 2. 尝试使用 seed 进行 AES 解密 (火山 0xa8 密文)
                            if (seed.isNotEmpty()) {
                                try {
                                    val decrypted = MediaCrypto.decryptUrl(rawUrl, seed)
                                    if (decrypted.startsWith("http")) {
                                        rawUrl = decrypted
                                    }
                                } catch (ignored: Exception) {}
                            }
                            // 3. 尝试标准 Base64 解码 (若未加密仅是 Base64 包装)
                            if (!rawUrl.startsWith("http://") && !rawUrl.startsWith("https://")) {
                                try {
                                    val b64Str = String(decode64(rawUrl), Charsets.UTF_8)
                                    if (b64Str.startsWith("http://") || b64Str.startsWith("https://")) {
                                        rawUrl = b64Str
                                    }
                                } catch (ignored: Exception) {}
                            }
                        }
                    }
                    if (rawUrl.startsWith("http")) {
                        val qLabel = "${qNum}P"
                        multiMap[qLabel] = rawUrl
                        if (!qualityList.contains(qNum)) qualityList.add(qNum)

                        val spadeA = cand.spadeA
                        if (spadeA.isNotEmpty()) {
                            val derived = MediaCrypto.deriveKeyHex(spadeA)
                            if (derived.isNotEmpty()) {
                                keysMap[qLabel] = derived
                                if (fallbackKey.isEmpty()) {
                                    fallbackKey = derived
                                }
                            }
                        }
                    }
                }

        if (multiMap.isNotEmpty()) {
            val targetQuality = qualityList.firstOrNull { it <= maxQuality } ?: qualityList.first()
            val targetLabel = "${targetQuality}P"
            val primaryUrl = multiMap[targetLabel] ?: multiMap.values.first()
            val primaryKey = keysMap[targetLabel] ?: fallbackKey

            multiMap["自动"] = primaryUrl

            return mapOf(
                "url" to primaryUrl,
                "decryptionKey" to primaryKey,
                "keys" to keysMap,
                "quality" to targetLabel,
                "actualQuality" to targetQuality,
                "qualities" to qualityList,
                "multiMap" to multiMap
            )
        }

        throw IOException("No playable stream url found for vid $cleanVid")
    }
}
