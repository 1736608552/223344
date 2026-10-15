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

    /**
     * 单集视频流模型与 CENC 解密 Key 解析 (支持 key_seed + 多清晰度 spade_a 派生)
     */
    fun resolve(vid: String, maxQuality: Int = 1080): Map<String, Any?> {
        val cleanVid = vid.trim()
        if (!cleanVid.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid vid: $vid")
        }

        val payload = """{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["$cleanVid"]}}""".toByteArray()
        var lastErr: Exception? = null

        // 抖动重试最多 2 次
        for (attempt in 0..1) {
            try {
                val signed = signer.sign("https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/", VendorConstants.device, payload)

                val reqBuilder = Request.Builder()
                    .url(signed.url)
                    .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))

                for ((k, v) in signed.headers) {
                    reqBuilder.header(k, v)
                }

                val resp = client.newCall(reqBuilder.build()).execute()
                val bodyStr = resp.body?.string() ?: throw IOException("Empty response from multi_video_model")
                val data = JSONObject(bodyStr)
                if (data.optInt("Code", data.optInt("code", 0)) != 0) {
                    throw IOException("Video model API returned error: " + data.optString("message"))
                }

                val map = data.optJSONObject("data") ?: throw IOException("Empty data in video model")
                val entry = map.optJSONObject(cleanVid)
                    ?: map.keys().asSequence().mapNotNull { map.optJSONObject(it) }.firstOrNull()
                    ?: throw IOException("No entry found for vid $cleanVid")

                val model = entry.optJSONObject("video_model") ?: JSONObject(entry.optString("video_model", "{}"))

                var videoList: JSONObject? = null
                var seed = byteArrayOf()

                // 情况 1: video_model 中直接自带 video_list
                if (model.has("video_list") && model.optJSONObject("video_list") != null) {
                    videoList = model.optJSONObject("video_list")
                    val seedStr = model.optString("key_seed")
                    if (seedStr.isNotEmpty()) {
                        seed = try { decode64(seedStr) } catch (_: Exception) { byteArrayOf() }
                    }
                }

                // 情况 2: 走 fallback_api 请求真实 video_list
                if (videoList == null || videoList.length() == 0) {
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
                        videoList = info.optJSONObject("video_list")
                            ?: throw IOException("No video_list in fallback_api")

                        val seedStr = info.optString("key_seed")
                        if (seedStr.isNotEmpty()) {
                            seed = try { decode64(seedStr) } catch (_: Exception) { byteArrayOf() }
                        }
                    }
                }

                if (videoList == null || videoList.length() == 0) {
                    throw IOException("No video_list available for vid $cleanVid")
                }

                val multiMap = mutableMapOf<String, String>()
                val keysMap = mutableMapOf<String, String>()
                val qualityList = mutableListOf<Int>()

                val keys = videoList.keys()
                val candidateList = mutableListOf<Triple<Int, String, JSONObject>>()
                while (keys.hasNext()) {
                    val k = keys.next()
                    val o = videoList.optJSONObject(k) ?: continue
                    val mainUrl = o.optString("main_url")
                    val codec = o.optString("codec_type").lowercase()
                    if (mainUrl.isEmpty() || codec == "bytevc2" || codec == "bvc2") continue

                    val qDesc = o.optString("quality_desc").ifEmpty {
                        o.optString("height").ifEmpty {
                            o.optString("vheight").ifEmpty {
                                o.optString("quality").ifEmpty { k }
                            }
                        }
                    }
                    val qNum = Regex("(\\d+)").find(qDesc)?.groupValues?.get(1)?.toIntOrNull() ?: 720
                    candidateList.add(Triple(qNum, k, o))
                }

                candidateList.sortByDescending { it.first }

                var fallbackKey = ""

                for (cand in candidateList) {
                    val qNum = cand.first
                    val item = cand.third
                    var rawUrl = item.optString("main_url")
                    if (seed.isNotEmpty() && rawUrl.isNotEmpty()) {
                        try {
                            rawUrl = MediaCrypto.decryptUrl(rawUrl, seed)
                        } catch (_: Exception) {}
                    }
                    if (rawUrl.startsWith("http")) {
                        val qLabel = "${qNum}P"
                        multiMap[qLabel] = rawUrl
                        if (!qualityList.contains(qNum)) qualityList.add(qNum)

                        val spadeA = item.optString("spade_a")
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

                if (multiMap.isEmpty()) {
                    throw IOException("No playable video URL decrypted for vid $cleanVid")
                }

                // 按 maxQuality 寻找最佳可用清晰度，若未找到匹配则取最高清晰度
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
            } catch (e: Exception) {
                lastErr = e
                try { Thread.sleep(200) } catch (_: InterruptedException) {}
            }
        }
        throw lastErr ?: IOException("Failed to resolve stream for vid $cleanVid")
    }
}
