// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.lunatv.hongguo

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import org.json.JSONObject
import org.json.JSONArray
import java.io.IOException
import java.util.concurrent.TimeUnit

internal fun JSONArray.objects() = (0 until length()).mapNotNull { optJSONObject(it) }
internal fun JSONObject.str(key: String) = if (isNull(key)) "" else optString(key, "").trim()
internal fun cleanUrl(s: String) = s.replace("\\/","/").replace("\\u002F","/",ignoreCase=true).replace("\\u0026","&").replace("&amp;","&")
data class Series(val id: String, val title: String, val cover: String = "", val description: String = "", val badge: String = "", val tags: String = "") {
    fun toJson() = JSONObject().put("id",id).put("title",title).put("cover",cover).put("description",description).put("badge",badge).put("tags",tags)
    companion object { fun fromJson(o: JSONObject) = Series(o.str("id"),o.str("title"),o.str("cover"),o.str("description"),o.str("badge"),o.str("tags")) }
}
data class Detail(val series: Series, val episodes: List<String>)
data class StreamInfo(val url: String, val key: ByteArray?, val quality: String)

/** 站点 CDN 在重定向时下发 ttwid 并拦截无 Cookie 的后续请求，内存 Cookie 罐使其自动流转。 */
class MemoryCookies : okhttp3.CookieJar {
    private val store = java.util.concurrent.ConcurrentHashMap<String, MutableList<okhttp3.Cookie>>()
    private fun List<okhttp3.Cookie>.replacedBy(cookies: List<okhttp3.Cookie>) =
        filter { kept -> cookies.none { it.name == kept.name && it.domain == kept.domain && it.path == kept.path } }
            .toMutableList().also { it += cookies }

    override fun saveFromResponse(url: okhttp3.HttpUrl, cookies: List<okhttp3.Cookie>) {
        if (cookies.isEmpty()) return
        store.compute(url.host) { _, kept -> kept.orEmpty().replacedBy(cookies) }
    }

    override fun loadForRequest(url: okhttp3.HttpUrl): List<okhttp3.Cookie> {
        val now = System.currentTimeMillis()
        return store[url.host].orEmpty().filter { it.expiresAt > now }
    }
}

open class ContentRepository(
    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(45, TimeUnit.SECONDS)
        .cookieJar(MemoryCookies())
        .build(),
    private val clock: () -> Long = System::currentTimeMillis,
    private val playbackSession: PlaybackDeviceSession = PlaybackDeviceSession.shared
) {
    private val signer = Signer(clock)
    private val site = "https://hongguoduanju.com"

    private fun text(url: String, signed: Signer.Request? = null): String {
        val request = Request.Builder().url(url).header("User-Agent", VendorConstants.VIDEO_UA).header("Accept-Language", "zh-CN,zh;q=0.9")
        signed?.headers?.forEach { (k, v) -> request.header(k, v) }
        signed?.body?.let { request.post(it.toRequestBody("application/json; charset=utf-8".toMediaType())) }
        return RequestScope.execute(http.newCall(request.build())) { response ->
            if (!response.isSuccessful) throw IOException("内容请求失败（HTTP ${response.code}）")
            val body = response.body ?: throw IOException("内容响应为空")
            if (body.contentLength() > 16 * 1024 * 1024) throw IOException("内容响应过大")
            val input = body.byteStream()
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (out.size() <= 16 * 1024 * 1024) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
            }
            val bytes = out.toByteArray()
            if (bytes.size > 16 * 1024 * 1024) throw IOException("内容响应过大")
            String(bytes, Charsets.UTF_8)
        }
    }

    private fun router(url: String) = extractRouter(text(url)).getJSONObject("loaderData")

    private fun card(item: JSONObject): Series {
        val o = item.optJSONObject("video_data") ?: item
        val count = o.optInt("episode_cnt", o.optJSONObject("series_episode_info")?.optInt("episode_cnt", 0) ?: 0)
        val tags = o.optJSONArray("tags") ?: o.optJSONArray("category_list") ?: JSONArray()
        return Series(
            o.str("series_id"),
            o.str("series_name").ifEmpty { o.str("series_title").ifEmpty { item.str("name") } },
            cleanUrl(o.str("series_cover")),
            o.str("series_intro"),
            o.str("episode_right_text").ifEmpty { if (count > 0) "全 ${count} 集" else "" },
            (0 until minOf(tags.length(), 5)).joinToString(" · ") { tags.optJSONObject(it)?.str("name") ?: tags.optString(it) }
        )
    }

    fun detail(id: String): Detail {
        val cleanId = id.trim().removePrefix("hongguo:").trim()
        require(cleanId.matches(Regex("[0-9]{1,32}")))
        val o = router("$site/detail?series_id=$cleanId").optJSONObject("detail_page")?.optJSONObject("seriesDetail") ?: throw IOException("剧集详情暂不可用")
        val raw = o.optJSONArray("vid_list") ?: throw IOException("分集暂不可用")
        val episodes = (0 until raw.length()).map { raw.getString(it) }
        if (episodes.isEmpty() || episodes.any { !it.matches(Regex("[0-9]{1,32}")) } || episodes.distinct().size != episodes.size) throw IOException("分集数据异常")
        return Detail(card(o).copy(id = cleanId), episodes)
    }

    private fun buildCodecUrl(raw: String, codecParam: String): String {
        val parts = raw.split("?", limit = 2)
        if (parts.size < 2) return "$raw?$codecParam"
        val base = parts[0]
        val query = parts[1]
        val kept = query.split("&").filter { part ->
            val name = part.substringBefore("=")
            name != "codec_type" && name != "force_codec"
        }
        return base + "?" + (kept + codecParam).joinToString("&")
    }

    private fun extractPlayableRows(videoList: JSONObject): List<Triple<Int, String, JSONObject>> {
        return videoList.keys().asSequence().mapNotNull { k -> videoList.optJSONObject(k)?.let { k to it } }.filter {
            it.second.str("main_url").isNotEmpty() && it.second.str("codec_type").lowercase() !in setOf("bytevc2", "bvc2")
        }.map { (k, o) -> Triple(qualityNumber(o.str("quality_desc").ifEmpty { o.str("height").ifEmpty { o.str("vheight").ifEmpty { o.str("quality").ifEmpty { k } } } }), k, o) }.sortedByDescending { it.first }.toList()
    }

    /**
     * 播放信息接口退避读取（对齐原版 1736608552/hongguo-tv 核心生产设计）：
     * 接口间歇性返回 HTTP 200 空体；按 0/700/1500 毫秒退避最多读取三次，只换时间戳不换设备身份。
     */
    private fun playbackText(request: Request): String {
        var attempt = 0
        while (true) {
            val next = request.newBuilder()
                .url(request.url.newBuilder().setQueryParameter("_rticket", clock().toString()).build())
                .build()
            val body = RequestScope.execute(http.newCall(next)) { response ->
                if (!response.isSuccessful) throw IOException("播放接口请求失败（HTTP ${response.code}）")
                response.body?.string().orEmpty()
            }
            if (body.isNotBlank()) return body
            val delay = listOf(700L, 1500L).getOrNull(attempt) ?: throw IOException("播放接口暂时返回空响应，请稍后重试")
            if (Thread.currentThread().isInterrupted) throw java.io.InterruptedIOException("播放请求已取消")
            Thread.sleep(delay)
            attempt++
        }
    }

    /**
     * 取官方短剧单集正片播放直链与密钥（100% 对齐 1736608552/hongguo-tv 核心生产设计）：
     * 对齐 minireel_sign.go 三步尝试策略:
     * 1. 签名 Primary 端点 (剔除 x-medusa 避免 551 envelope 冲突空响应)
     * 2. 签名 Alternate 端点
     * 3. 原始未签名兼容端点
     * 4. 若全失败，自动调度 HongguoStreamResolver 进行高可用单集与三大通道兜底
     */
    fun stream(id: String, maxQuality: Int = 1080): StreamInfo {
        val cleanId = id.trim().removePrefix("hongguo:").trim()
        require(cleanId.matches(Regex("[0-9]{1,32}")))
        val payload = """{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["$cleanId"]}}""".toByteArray()
        val identity = playbackSession.profile(http)

        val endpoints = listOf(
            "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/",
            "https://api5-normal-hl.fqnovel.com/novel/player/multi_video_model/v1/",
            "https://api5-normal-lq.fqnovel.com/novel/player/multi_video_model/v1/"
        )

        var lastError: Exception? = null
        for ((attempt, base) in endpoints.withIndex()) {
            try {
                val reqBuilder = Request.Builder()
                if (attempt < 2) {
                    val signed = signer.signPlayback(base, identity.values, payload)
                    reqBuilder.url(signed.url)
                    for ((k, v) in signed.headers) {
                        if (!k.equals("x-medusa", ignoreCase = true)) {
                            reqBuilder.header(k, v)
                        }
                    }
                } else {
                    val query = Signer.encode(identity.values + ("_rticket" to clock().toString()))
                    reqBuilder.url("$base?$query")
                    reqBuilder.header("User-Agent", PlaybackDeviceSession.PLAYBACK_UA)
                    reqBuilder.header("Accept", "application/json; charset=utf-8,application/x-protobuf")
                }
                if (identity.cookie.isNotBlank()) {
                    reqBuilder.header("Cookie", identity.cookie)
                }
                reqBuilder.post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))

                val respText = playbackText(reqBuilder.build())
                if (respText.isNotBlank()) {
                    val data = JSONObject(respText)
                    val code = data.optInt("Code", data.optInt("code", 0))
                    if (code == 0) {
                        val map = data.optJSONObject("data")
                        val entry = map?.optJSONObject(cleanId) ?: map?.keys()?.asSequence()?.mapNotNull { map.optJSONObject(it) }?.firstOrNull()
                        val model = entry?.optJSONObject("video_model") ?: entry?.str("video_model")?.takeIf { it.isNotBlank() }?.let { JSONObject(it) }
                        if (model != null) {
                            val raw = model.opt("fallback_api")
                            val fallback = when (raw) {
                                is JSONObject -> raw.str("fallback_api")
                                is JSONArray -> raw.optString(0)
                                else -> runCatching { JSONObject(raw.toString()).str("fallback_api") }.getOrDefault(raw.toString())
                            }
                            if (fallback.startsWith("https://")) {
                                var info = JSONObject(text(fallback)).optJSONObject("video_info")?.optJSONObject("data") ?: continue
                                var videoList = info.optJSONObject("video_list") ?: JSONObject()
                                var rows = extractPlayableRows(videoList)
                                if (rows.isEmpty()) {
                                    for (codec in listOf("codec_type=1", "codec_type=0&force_codec=h264", "codec_type=3")) {
                                        try {
                                            val candidateUrl = buildCodecUrl(fallback, codec)
                                            val candidateInfo = JSONObject(text(candidateUrl)).optJSONObject("video_info")?.optJSONObject("data")
                                            val candidateList = candidateInfo?.optJSONObject("video_list")
                                            if (candidateList != null) {
                                                val candidateRows = extractPlayableRows(candidateList)
                                                if (candidateRows.isNotEmpty()) {
                                                    info = candidateInfo
                                                    videoList = candidateList
                                                    rows = candidateRows
                                                    break
                                                }
                                            }
                                        } catch (_: Exception) {}
                                    }
                                }
                                if (rows.isNotEmpty()) {
                                    val selected = rows.firstOrNull { it.first <= maxQuality } ?: rows.lastOrNull() ?: continue
                                    val item = selected.third
                                    var url = cleanUrl(item.str("main_url"))
                                    val seed = info.str("key_seed")
                                    if (seed.isNotEmpty()) url = MediaCrypto.decryptUrl(url, decode64(seed))
                                    if (url.startsWith("https://") || url.startsWith("http://")) {
                                        val key = item.str("spade_a").takeIf { it.isNotEmpty() }?.let(MediaCrypto::deriveKey)
                                        val quality = if (selected.first > 0) "${selected.first}P" + (if (selected.first > maxQuality) "（兼容资源）" else "") else "自动"
                                        return StreamInfo(url, key, quality)
                                    }
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                lastError = e
            }
        }

        // 终极兜底：调用 HongguoStreamResolver 跨通道兜底解析
        try {
            val resolved = HongguoStreamResolver.resolve(cleanId, maxQuality)
            val streamUrl = resolved["url"] as? String ?: ""
            val keyHex = resolved["decryptionKey"] as? String ?: ""
            val keyBytes = if (keyHex.length == 32) {
                keyHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            } else null
            val quality = resolved["quality"] as? String ?: "${maxQuality}P"
            if (streamUrl.isNotBlank()) {
                return StreamInfo(streamUrl, keyBytes, quality)
            }
        } catch (_: Exception) {}

        throw (lastError ?: IOException("播放接口暂时返回空响应，请稍后重试"))
    }

    companion object {
        fun extractRouter(html: String): JSONObject {
            val marker = html.indexOf("_ROUTER_DATA")
            if (marker < 0) throw IOException("页面没有内容数据")
            val first = html.indexOf('{', marker)
            if (first < 0) throw IOException("页面数据格式错误")
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
                        if (depth == 0) return JSONObject(html.substring(first, i + 1))
                    }
                }
            }
            throw IOException("页面数据不完整")
        }

        fun qualityNumber(value: String): Int =
            Regex("2160|1440|1080|720|576|540|480|360").find(value)?.value?.toInt()
                ?: mapOf("1920" to 1080, "1280" to 720, "1024" to 576, "854" to 480, "640" to 360)[value]
                ?: value.toIntOrNull()
                ?: 0
    }
}
