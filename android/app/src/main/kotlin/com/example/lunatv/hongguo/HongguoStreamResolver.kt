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

    fun resolve(vid: String, maxQuality: Int = 1080): Map<String, Any?> {
        if (!vid.matches(Regex("[0-9]{1,32}"))) {
            throw IllegalArgumentException("Invalid vid: $vid")
        }

        val payload = """{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["$vid"]}}""".toByteArray()
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
        val entry = map.optJSONObject(vid)
            ?: map.keys().asSequence().mapNotNull { map.optJSONObject(it) }.firstOrNull()
            ?: throw IOException("No entry found for vid $vid")

        val model = entry.optJSONObject("video_model") ?: JSONObject(entry.optString("video_model", "{}"))
        val rawFallback = model.opt("fallback_api")
        val fallback = when (rawFallback) {
            is JSONObject -> rawFallback.optString("fallback_api")
            is org.json.JSONArray -> rawFallback.optString(0)
            else -> runCatching { JSONObject(rawFallback.toString()).optString("fallback_api") }.getOrDefault(rawFallback.toString())
        }

        if (!fallback.startsWith("https://") && !fallback.startsWith("http://")) {
            throw IOException("Invalid fallback_api URL: $fallback")
        }

        val fbReq = Request.Builder()
            .url(fallback)
            .header("User-Agent", VendorConstants.VIDEO_UA)
            .build()
        val fbResp = client.newCall(fbReq).execute()
        val fbBody = fbResp.body?.string() ?: throw IOException("Empty response from fallback_api")

        val info = JSONObject(fbBody).optJSONObject("video_info")?.optJSONObject("data")
            ?: throw IOException("No video_info in fallback_api")
        val videoList = info.optJSONObject("video_list")
            ?: throw IOException("No video_list in fallback_api")

        val seedStr = info.optString("key_seed")
        val seed = if (seedStr.isNotEmpty()) decode64(seedStr) else byteArrayOf()

        val multiMap = mutableMapOf<String, String>()
        val qualityList = mutableListOf<Int>()
        var primaryUrl = ""
        var primaryKey = ""
        var actualQuality = 1080

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
                multiMap["${qNum}P"] = rawUrl
                if (!qualityList.contains(qNum)) qualityList.add(qNum)
                val spadeA = item.optString("spade_a")
                if (primaryUrl.isEmpty()) {
                    primaryUrl = rawUrl
                    actualQuality = qNum
                    if (spadeA.isNotEmpty()) {
                        try {
                            primaryKey = MediaCrypto.deriveKey(spadeA).hex()
                        } catch (_: Exception) {}
                    }
                }
            }
        }

        if (primaryUrl.isEmpty()) {
            throw IOException("No playable video URL decrypted")
        }

        multiMap["自动"] = primaryUrl

        return mapOf(
            "url" to primaryUrl,
            "decryptionKey" to primaryKey,
            "quality" to "${actualQuality}P",
            "actualQuality" to actualQuality,
            "qualities" to qualityList,
            "multiMap" to multiMap
        )
    }
}
