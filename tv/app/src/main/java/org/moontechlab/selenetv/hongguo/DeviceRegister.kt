// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.hongguo

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URLEncoder
import java.util.UUID
import java.util.zip.GZIPOutputStream

object DeviceRegister {
    const val HOST = "https://log.snssdk.com"
    val REGISTER_HOSTS = listOf(
        "https://log.snssdk.com",
        "https://log5-applog-lq.fqnovel.com",
        "https://log5-applog-lf.fqnovel.com"
    )
    private const val PATH = "/service/2/device_register/"
    private const val QUERY =
        "?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"

    /** ttEncrypt 的固定前缀（libEncryptor.so 的魔数）。 */
    private val MAGIC = byteArrayOf(0x74, 0x63, 0x05, 0x10, 0x00, 0x00)

    /** ttEncrypt 的 KDF 盐；与 MediaCrypto.decryptUrl 用的是同一份常量。 */
    private val KDF_SALT =
        hex(
            "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58"
        )

    const val SINGLE_REG_UA =
        "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

    /** 注册结果：平台下发的设备身份 + 需要回写的那几个 Cookie。 */
    data class Registered(
        val deviceId: String,
        val installId: String,
        val deviceToken: String = "",
        val newUser: Boolean = false,
        val cookies: Map<String, String> = emptyMap(),
    )

    /**
     * 100% 对齐 1736608552/hongguo-tv (single-registered-profile.js / minireel_single_registered.go):
     * 采用 novelread 7.3.5.32 标准明文 JSON 注册协议，稳定返回非 0 真实 device_id 与 install_id。
     */
    fun registerSingleRegistered(
        http: OkHttpClient,
        now: Long = System.currentTimeMillis(),
    ): Registered? {
        val reqId = UUID.randomUUID().toString()
        val openudid = UUID.randomUUID().toString().replace("-", "").take(16)
        val clientudid = UUID.randomUUID().toString()
        val cdid = UUID.randomUUID().toString()

        val queryMap = linkedMapOf(
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
            "device_type" to "25053RT47C",
            "device_brand" to "Redmi",
            "language" to "zh",
            "os_api" to "36",
            "os_version" to "16",
            "resolution" to "1280*2772",
            "dpi" to "520",
            "ac" to "wifi",
            "_rticket" to now.toString(),
            "req_id" to reqId,
        )
        val queryStr = queryMap.entries
            .sortedBy { it.key }
            .joinToString("&") { (k, v) ->
                val ek = URLEncoder.encode(k, "UTF-8").replace("+", "%20").replace("%7E", "~").replace("*", "%2A")
                val ev = URLEncoder.encode(v, "UTF-8").replace("+", "%20").replace("%7E", "~").replace("*", "%2A")
                "$ek=$ev"
            }

        val payloadJson = JSONObject().apply {
            put("magic_tag", "ss_app_log")
            put(
                "header",
                JSONObject().apply {
                    put("display_name", "红果免费短剧")
                    put("aid", 8662)
                    put("app_name", "novelread")
                    put("channel", "update_64")
                    put("package", "com.phoenix.read")
                    put("app_version", "7.3.5.32")
                    put("version_code", 73532)
                    put("update_version_code", 73532)
                    put("manifest_version_code", 73532)
                    put("os", "Android")
                    put("os_version", "16")
                    put("os_api", 36)
                    put("device_model", "25053RT47C")
                    put("device_brand", "Redmi")
                    put("device_manufacturer", "Xiaomi")
                    put("cpu_abi", "arm64-v8a")
                    put("density_dpi", 520)
                    put("display_density", "xxhdpi")
                    put("resolution", "2772x1280")
                    put("language", "zh")
                    put("mc", "02:00:00:00:00:00")
                    put("timezone", 8)
                    put("access", "wifi")
                    put("not_request_sender", 0)
                    put("carrier", "China Mobile")
                    put("mcc_mnc", "46000")
                    put("rom", "OS2.0")
                    put("rom_version", "BP2A.250605.031.A3")
                    put("openudid", openudid)
                    put("clientudid", clientudid)
                    put("cdid", cdid)
                    put("req_id", reqId)
                    put("region", "CN")
                    put("tz_name", "Asia/Shanghai")
                    put("tz_offset", 28800)
                    put("sim_region", "cn")
                    put("device_platform", "android")
                },
            )
            put("_gen_time", now)
        }
        val bodyBytes = payloadJson.toString().toByteArray(Charsets.UTF_8)

        for (host in REGISTER_HOSTS) {
            try {
                val req = Request.Builder()
                    .url("$host$PATH?$queryStr")
                    .header("User-Agent", SINGLE_REG_UA)
                    .header("Content-Type", "application/json; charset=utf-8")
                    .header("Accept", "application/json")
                    .post(bodyBytes.toRequestBody("application/json; charset=utf-8".toMediaType()))
                    .build()
                RequestScope.execute(http.newCall(req)) { resp ->
                    if (resp.isSuccessful) {
                        val text = resp.body?.string().orEmpty()
                        val parsed = parse(text, resp.headers("Set-Cookie"))
                        if (parsed != null) {
                            val mergedCookies = linkedMapOf(
                                "install_id" to parsed.installId,
                                "store-region" to "cn",
                                "store-region-src" to "did",
                            )
                            mergedCookies.putAll(parsed.cookies)
                            return Registered(
                                deviceId = parsed.deviceId,
                                installId = parsed.installId,
                                deviceToken = parsed.deviceToken,
                                newUser = parsed.newUser,
                                cookies = mergedCookies,
                            )
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
        return null
    }

    /**
     * ttEncrypt：MAGIC || rnd[32] || AES-128-CBC(SHA512(SHA512(rnd)+KDF_SALT) 前 32 字节, PKCS7(SHA512(data)||data))。
     */
    fun ttEncrypt(data: ByteArray): ByteArray {
        val rnd = ByteArray(32).also { java.util.Random().nextBytes(it) }
        val derived = digest("SHA-512", digest("SHA-512", rnd) + KDF_SALT)
        val body = digest("SHA-512", data) + data
        val padding = 16 - (body.size % 16)
        val padded = body + ByteArray(padding) { padding.toByte() }
        val encrypted =
            javax.crypto.Cipher.getInstance("AES/CBC/NoPadding").run {
                init(
                    javax.crypto.Cipher.ENCRYPT_MODE,
                    javax.crypto.spec.SecretKeySpec(derived.copyOfRange(0, 16), "AES"),
                    javax.crypto.spec.IvParameterSpec(derived.copyOfRange(16, 32)),
                )
                doFinal(padded)
            }
        return MAGIC + rnd + encrypted
    }

    private fun gzip(data: ByteArray): ByteArray {
        val raw = ByteArrayOutputStream()
            .also { out -> GZIPOutputStream(out).use { it.write(data) } }
            .toByteArray()
        if (raw.size >= 10) {
            raw[9] = 0
        }
        return raw
    }

    /** 组装注册请求体：ttEncrypt(gzip(JSON))。device_id / install_id 由服务端下发。 */
    fun payload(device: Map<String, String>, now: Long = System.currentTimeMillis()): ByteArray {
        fun value(key: String, fallback: String) =
            device[key]?.takeIf { it.isNotBlank() } ?: fallback
        val json = JSONObject()
        json.put("magic_tag", "ss_app_log")
        json.put(
            "header",
            JSONObject().apply {
                put("display_name", "红果免费短剧")
                put("update_version_code", 73932)
                put("manifest_version_code", 73932)
                put("app_version_minor", "7.3.9.32")
                put("aid", 8662)
                put("channel", value("channel", "69310258a"))
                put("package", "com.phoenix.read")
                put("app_version", "7.3.9.32")
                put("version_code", 73932)
                put("sdk_version", "3.7.0-rc.34-fanqie-xiaoshuo")
                put("sdk_target_version", 29)
                put("git_hash", "3a88f4e")
                put("os", "Android")
                put("os_version", value("os_version", "12"))
                put("os_api", value("os_api", "32").toIntOrNull() ?: 32)
                put("device_model", value("device_type", "AOSP on Intel Platform"))
                put("device_brand", value("device_brand", "SAMSUNG"))
                put("device_manufacturer", value("device_brand", "Intel"))
                put("cpu_abi", value("host_abi", "arm64-v8a"))
                put("release_build", "b5e187f")
                put("density_dpi", value("dpi", "360").toIntOrNull() ?: 360)
                put("display_density", "mdpi")
                put("resolution", value("resolution", "1440x2560").replace("*", "x"))
                put("language", "zh")
                put("timezone", 8)
                put("access", "wifi")
                put("not_request_sender", 0)
                put("carrier", "CHINA MOBILE")
                put("mcc_mnc", "46000")
                put("rom", "eng.root.20231116.160340")
                put("rom_version", value("rom_version", "W528JS release-keys"))
                put("cdid", value("cdid", UUID.randomUUID().toString()))
                put("sig_hash", "56a962410c494bbaf0b58dba20cae56f")
                put(
                    "openudid",
                    value("openudid", UUID.randomUUID().toString().replace("-", "").take(16)),
                )
                put("clientudid", value("clientudid", UUID.randomUUID().toString()))
                put("ipv6_list", JSONArray())
                put("region", "CN")
                put("tz_name", "Asia/Shanghai")
                put("tz_offset", 28800)
                put("sim_region", "cn")
                put("sim_serial_number", JSONArray())
                put("oaid_may_support", false)
                put("req_id", UUID.randomUUID().toString())
                put("device_platform", "android")
                put(
                    "custom",
                    JSONObject().apply {
                        put("account_region_src", "fallback")
                        put("host_bit", 64)
                        put("account_region", "cn")
                        put("dragon_device_type", value("dragon_device_type", "pad"))
                    },
                )
                put("pre_installed_channel", "")
                put("apk_first_install_time", now)
                put("is_system_app", 0)
                put("sdk_flavor", "china")
                put("guest_mode", 0)
            },
        )
        json.put("_gen_time", now)
        return ttEncrypt(gzip(json.toString().toByteArray(Charsets.UTF_8)))
    }

    /** 注册请求的头，刻意不加签名头。 */
    fun headers(
        body: ByteArray,
        device: Map<String, String>,
        now: Long = System.currentTimeMillis(),
    ): Map<String, String> =
        linkedMapOf(
            "User-Agent" to
                (device["user_agent"]?.takeIf { it.isNotBlank() } ?: VendorConstants.APP_UA),
            "Content-Type" to "application/octet-stream;tt-data=a",
            "log-encode-type" to "gzip",
            "x-ss-dp" to "8662",
            "x-ss-req-ticket" to now.toString(),
            "x-vc-bdturing-sdk-version" to "4.0.3.cn",
            "lc" to "101",
            "sdk-version" to "2",
            "passport-sdk-version" to "5051452",
            "x-neptune" to "-8|50:51:59:30:40:47:49:39",
            "x-ss-stub" to digest("MD5", body).hex().uppercase(),
        )

    fun url() = HOST + PATH + QUERY
    fun urls(): List<String> = REGISTER_HOSTS.map { it + PATH + QUERY }

    /** 解析注册响应；device_id / install_id 数字或字符串都认，全为 0 表示被拒。 */
    fun parse(body: String, setCookies: List<String> = emptyList()): Registered? {
        val json = runCatching { JSONObject(body) }.getOrNull() ?: return null
        val device =
            json.opt("device_id_str")?.toString()?.takeIf { it.isNotBlank() }
                ?: json.opt("device_id")?.toString().orEmpty()
        val install =
            json.opt("install_id_str")?.toString()?.takeIf { it.isNotBlank() }
                ?: json.opt("install_id")?.toString().orEmpty()
        if (device.isBlank() || install.isBlank() || device == "0" || install == "0") return null
        val cookies = linkedMapOf<String, String>()
        setCookies.forEach { header ->
            header
                .split(';')
                .firstOrNull()
                ?.trim()
                ?.takeIf { it.contains('=') }
                ?.let { pair ->
                    val name = pair.substringBefore('=').trim()
                    val value = pair.substringAfter('=').trim()
                    if (name.isNotEmpty() && value.isNotEmpty()) cookies[name] = value
                }
        }
        return Registered(
            device,
            install,
            json.optString("device_token", ""),
            json.optInt("new_user", 0) == 1,
            cookies,
        )
    }
}
