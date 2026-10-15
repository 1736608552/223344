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
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private val signer = Signer()

    /**
     * 官方 App 分集详情接口 (作为 Web 页面 404 或失效时的顶级原生兜底)
     * 请求 POST /novel/player/video_detail/v1/，返回按分集升序排序的纯数字 vid 列表
     */
    fun fetchEpisodeVids(seriesId: String): List<String> {
        val cleanId = seriesId.trim().removePrefix("hongguo:").trim()
        if (!cleanId.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid seriesId: $seriesId")
        }

        val payload = """{"series_id":"$cleanId"}""".toByteArray()
        var lastErr: Exception? = null

        // 抖动重试最多 2 次，规避服务端偶发拒签或网络波动
        for (attempt in 0..1) {
            try {
                val signed = signer.sign(
                    "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_detail/v1/",
                    VendorConstants.device,
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
                    return vids
                }
            } catch (e: Exception) {
                lastErr = e
                try { Thread.sleep(200) } catch (_: InterruptedException) {}
            }
        }
        throw lastErr ?: IOException("Failed to fetch episode vids for $cleanId")
    }

    private data class VideoCandidate(val qNum: Int, val mainUrl: String, val spadeA: String)

    /**
     * 单集视频流模型与 CENC 解密 Key 解析 (官方 preload/v1 1080P 原画 + 多清晰度 spade_a 派生 + 360P 安全兜底)
     */
    fun resolve(vid: String, maxQuality: Int = 1080): Map<String, Any?> {
        val cleanVid = vid.trim()
        if (!cleanVid.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid vid: $vid")
        }

        val payload = """{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["$cleanVid"]}}""".toByteArray()
        var lastErr: Exception? = null

        // 优先尝试官方 App 预加载高清端点 (带抖动重试最多 2 次)
        for (attempt in 0..1) {
            try {
                val signed = signer.sign("https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/preload/v1/", VendorConstants.device, payload)

                val reqBuilder = Request.Builder()
                    .url(signed.url)
                    .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))

                for ((k, v) in signed.headers) {
                    reqBuilder.header(k, v)
                }

                val resp = client.newCall(reqBuilder.build()).execute()
                val bodyStr = resp.body?.string() ?: throw IOException("Empty response from multi_video_model/preload")
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

                // 兜底情况: 若 video_model 缺少 video_list，尝试 fallback_api
                if (candidateList.isEmpty()) {
                    val rawFallback = model.opt("fallback_api")
                    val fallback = when (rawFallback) {
                        is JSONObject -> rawFallback.optString("fallback_api")
                        is org.json.JSONArray -> rawFallback.optString(0)
                        else -> runCatching { JSONObject(rawFallback.toString()).optString("fallback_api") }.getOrDefault(rawFallback?.toString() ?: "")
                    }

                    if (fallback.startsWith("https://") || fallback.startsWith("http://")) {
                        val fbReq = Request.Builder()
                            .url(fallback)
                            .header("User-Agent", VendorConstants.VIDEO_UA)
                            .build()
                        val fbResp = client.newCall(fbReq).execute()
                        val fbBody = fbResp.body?.string() ?: throw IOException("Empty response from fallback_api")

                        val info = JSONObject(fbBody).optJSONObject("video_info")?.optJSONObject("data")
                            ?: throw IOException("No video_info in fallback_api")
                        val fbList = info.optJSONObject("video_list")
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

                                val qDesc = item.optString("quality_desc").ifEmpty {
                                    item.optString("height").ifEmpty {
                                        item.optString("vheight").ifEmpty {
                                            item.optString("quality").ifEmpty { k }
                                        }
                                    }
                                }
                                val qNum = Regex("(\\d+)").find(qDesc)?.groupValues?.get(1)?.toIntOrNull() ?: 720
                                candidateList.add(VideoCandidate(qNum, mainUrl, item.optString("spade_a")))
                            }
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
                    if (seed.isNotEmpty() && rawUrl.isNotEmpty()) {
                        try {
                            rawUrl = MediaCrypto.decryptUrl(rawUrl, seed)
                        } catch (_: Exception) {}
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
            } catch (e: Exception) {
                lastErr = e
                try { Thread.sleep(200) } catch (_: InterruptedException) {}
            }
        }

        // 终极安全降级: 官方公开直链 (仅在官方预加载超清端点不可用时兜底，杜绝死机与黑屏)
        val directUrl = "https://hongguoduanju.com/video/public/$cleanVid/360p.mp4"
        try {
            val headReq = Request.Builder()
                .url(directUrl)
                .header("Referer", "https://hongguoduanju.com/")
                .header("User-Agent", VendorConstants.VIDEO_UA)
                .head()
                .build()
            val headResp = client.newCall(headReq).execute()
            if (headResp.isSuccessful) {
                val multiMap = mapOf(
                    "360P" to directUrl,
                    "标清" to directUrl,
                    "自动" to directUrl
                )
                return mapOf(
                    "url" to directUrl,
                    "decryptionKey" to "",
                    "keys" to emptyMap<String, String>(),
                    "quality" to "360P",
                    "qualities" to listOf(360),
                    "actualQuality" to 360,
                    "multiMap" to multiMap
                )
            }
        } catch (_: Exception) {}

        throw lastErr ?: IOException("Failed to resolve stream for vid $cleanVid")
    }
}
