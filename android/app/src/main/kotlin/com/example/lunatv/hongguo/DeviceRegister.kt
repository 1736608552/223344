// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.lunatv.hongguo

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
        cdidValue: String = "",
        openudidValue: String = "",
        clientudidValue: String = "",
        now: Long = System.currentTimeMillis(),
    ): Registered? {
        val reqId = UUID.randomUUID().toString()
        val openudid = openudidValue.ifBlank {
            VendorConstants.openUdid.ifBlank { UUID.randomUUID().toString().replace("-", "").take(16) }
        }
        val clientudid = clientudidValue.ifBlank { VendorConstants.clientUdid.ifBlank { UUID.randomUUID().toString() } }
        val cdid = cdidValue.ifBlank { VendorConstants.cdid.ifBlank { UUID.randomUUID().toString() } }

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

        // 仅向官方唯一支持明文 JSON 注册的 HOST (log.snssdk.com) 发起单次请求，
        // 严禁向 log5-applog-* 发送明文 JSON（避免必返 100 字节 device_id:0 消耗同 IP 注册风控配额）
        HongguoDiagnostic.log("INFO", "device_register", "START", "发起匿名播放设备注册 HOST=$HOST")
        val startTime = System.currentTimeMillis()
        try {
            val req = Request.Builder()
                .url("$HOST$PATH?$queryStr")
                .header("User-Agent", SINGLE_REG_UA)
                .header("Content-Type", "application/json; charset=utf-8")
                .header("Accept", "application/json")
                .post(bodyBytes.toRequestBody("application/json; charset=utf-8".toMediaType()))
                .build()
            val registered = RequestScope.execute(http.newCall(req)) { resp ->
                val code = resp.code
                val text = resp.body?.string().orEmpty()
                val respBytes = text.toByteArray(Charsets.UTF_8).size
                val elapsed = System.currentTimeMillis() - startTime
                if (resp.isSuccessful) {
                    val parsed = parse(text, resp.headers("Set-Cookie"))
                    if (parsed != null) {
                        HongguoDiagnostic.log(
                            "INFO", "device_register", "DEVICE_REGISTER_OK",
                            "设备注册成功 did=${parsed.deviceId} iid=${parsed.installId}",
                            mapOf("code" to code, "bytes" to respBytes, "elapsed" to "${elapsed}ms")
                        )
                        HongguoDiagnostic.updateReport(
                            stage = "device_register",
                            code = "DEVICE_REGISTER_OK",
                            httpStatus = code,
                            responseBytes = respBytes,
                            elapsedMs = elapsed,
                            summary = "匿名播放身份注册正常 (did=${parsed.deviceId})"
                        )
                        val mergedCookies = linkedMapOf(
                            "install_id" to parsed.installId,
                            "store-region" to "cn",
                            "store-region-src" to "did",
                        )
                        mergedCookies.putAll(parsed.cookies)
                        Registered(
                            deviceId = parsed.deviceId,
                            installId = parsed.installId,
                            deviceToken = parsed.deviceToken,
                            newUser = parsed.newUser,
                            cookies = mergedCookies,
                        )
                    } else {
                        val is100Bytes = text.contains("\"device_id\":0") || text.length in 90..130
                        val errCode = if (is100Bytes) "DEVICE_REGISTER_INVALID" else "DEVICE_REGISTER_EMPTY"
                        val summaryText = if (is100Bytes) {
                            "失败发生在“匿名播放身份注册”阶段。HTTP $code · 响应 $respBytes 字节 (DEVICE_REGISTER_INVALID)"
                        } else {
                            "设备注册响应解析失败: HTTP $code · 响应 $respBytes 字节"
                        }
                        HongguoDiagnostic.log(
                            "WARN", "device_register", errCode,
                            "设备注册返回空凭据: $summaryText 详情: ${text.take(120)}",
                            mapOf("code" to code, "bytes" to respBytes, "elapsed" to "${elapsed}ms")
                        )
                        HongguoDiagnostic.updateReport(
                            stage = "device_register",
                            code = errCode,
                            httpStatus = code,
                            responseBytes = respBytes,
                            elapsedMs = elapsed,
                            summary = summaryText,
                            lastError = text.take(120)
                        )
                        null
                    }
                } else {
                    HongguoDiagnostic.log(
                        "ERROR", "device_register", "DEVICE_REGISTER_HTTP",
                        "设备注册 HTTP 状态错误: code=$code",
                        mapOf("code" to code, "bytes" to respBytes, "elapsed" to "${elapsed}ms")
                    )
                    HongguoDiagnostic.updateReport(
                        stage = "device_register",
                        code = "DEVICE_REGISTER_HTTP",
                        httpStatus = code,
                        responseBytes = respBytes,
                        elapsedMs = elapsed,
                        summary = "设备注册接口返回 HTTP $code"
                    )
                    null
                }
            }
            if (registered != null) return registered
        } catch (e: Exception) {
            val elapsed = System.currentTimeMillis() - startTime
            HongguoDiagnostic.log(
                "ERROR", "device_register", "DEVICE_REGISTER_NETWORK_ERR",
                "设备注册网络异常: ${e.message}",
                mapOf("elapsed" to "${elapsed}ms", "error" to (e.message ?: ""))
            )
            HongguoDiagnostic.updateReport(
                stage = "device_register",
                code = "DEVICE_REGISTER_NETWORK_ERR",
                elapsedMs = elapsed,
                summary = "设备注册网络请求失败: ${e.message}",
                lastError = e.message
            )
        }
        return null
    }

    /** 原生加密注册的机型画像，对齐 upstream passport_device.go 的 passportDevice.payload。 */
    private const val NATIVE_APP_VERSION = "7.3.5.32"
    private const val NATIVE_VERSION_CODE = 73532
    private const val NATIVE_DEVICE_MODEL = "25053RT47C"

    /** upstream hongguo_client.go 的 defaultHongguoUA，注册/账号请求统一用它。 */
    const val NATIVE_UA =
        "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

    /**
     * 官方原生匿名注册（tt-data 加密体 + X-Gorgon + X-Argus）。
     *
     * 这是上游唯一在用的注册通道：明文 JSON 注册（[registerSingleRegistered]）虽然也能拿到
     * 非 0 的 device_id，但那台「设备」没有风控签名背书，后续 player/v1、video_tab
     * 无论信封多正确都只回 HTTP 200 + 0 字节 —— 短剧 len=0 的根就在这里。
     *
     * 请求结构 1:1 对齐 upstream passport_device.go 的 registerDeviceProfile：
     *  - query 走 aid / app_name / version_code / version_name / manifest_version_code /
     *    channel / device_type / device_brand / os_api / os_version / resolution / dpi / ac，
     *    再补 tt_data / ts / _rticket / package
     *  - body = ttEncrypt(明文 JSON)，Content-Encoding 仍标 gzip（官方客户端行为）
     *  - X-Argus 只是 le32(unix) 的 base64；X-Gorgon 覆盖 query + body
     */
    fun nativeRegister(
        http: OkHttpClient,
        cdidValue: String = "",
        openudidValue: String = "",
        clientudidValue: String = "",
        now: Long = System.currentTimeMillis(),
    ): Registered? {
        val stamp = now
        val ts = (now / 1000).toInt()
        // cdid / openudid / clientudid 必须与本次播放画像用的是同一组：上游 passportDevice
        // 就是一个对象同时喂注册请求和 playbackQuery，混用会导致 did 与 cdid 不配对。
        val cdid = cdidValue.ifBlank { VendorConstants.cdid.ifBlank { UUID.randomUUID().toString() } }
        val openudid = openudidValue.ifBlank {
            VendorConstants.openUdid.ifBlank { UUID.randomUUID().toString().replace("-", "").take(16) }
        }
        val clientudid = clientudidValue.ifBlank { VendorConstants.clientUdid.ifBlank { UUID.randomUUID().toString() } }

        val json = JSONObject().apply {
            put("magic_tag", "ss_app_log")
            put(
                "header",
                JSONObject().apply {
                    put("aid", 8662)
                    put("access", "wifi")
                    put("app_version", NATIVE_APP_VERSION)
                    put("app_version_minor", "")
                    put("channel", "update_64")
                    put("device_brand", "Redmi")
                    put("device_manufacturer", "Redmi")
                    put("device_model", NATIVE_DEVICE_MODEL)
                    put("device_category", "phone")
                    put("device_platform", "android")
                    put("os", "Android")
                    put("os_api", 36)
                    put("os_version", "16")
                    put("density_dpi", 520)
                    put("display_density", "xxxhdpi")
                    put("resolution", "2772x1280")
                    put("language", "zh")
                    put("timezone", 8)
                    put("tz_name", "Asia/Shanghai")
                    put("tz_offset", 28800)
                    put("region", "CN")
                    put("package", "com.phoenix.read")
                    put("version_code", NATIVE_VERSION_CODE)
                    put("manifest_version_code", NATIVE_VERSION_CODE)
                    put("update_version_code", NATIVE_VERSION_CODE)
                    put("apk_first_install_time", stamp)
                    put("cdid", cdid)
                    put("clientudid", clientudid)
                    put("openudid", openudid)
                    put("cpu_abi", "arm64-v8a")
                    put("display_name", "红果短剧")
                    put("sdk_version", "3.7.2")
                    put("sdk_target_version", 29)
                    put("sdk_flavor", "china")
                    put("guest_mode", 0)
                    put("is_system_app", 0)
                    put("not_request_sender", 0)
                    put("oaid_may_support", true)
                    put("ipv6_list", JSONArray())
                    put("sim_serial_number", JSONArray())
                    put(
                        "custom",
                        JSONObject().apply {
                            put("is_android_fold", 0)
                            put("filter_warn", 0)
                            put("web_ua", "")
                            put("is_android_pad", 0)
                            put("client_ipv4", "")
                        },
                    )
                },
            )
            put("_gen_time", stamp)
        }
        // upstream passportTTEncrypt 内部会先 gzip 再算 SHA512：body = MAGIC||seed||AES(SHA512(gz)||gz)。
        // 这里 ttEncrypt 不收 gzip 逻辑，因此必须先压再传，否则服务端解出来不是 gzip 流，直接判非法。
        val body = ttEncrypt(gzip(json.toString().toByteArray(Charsets.UTF_8)))

        val queryMap = linkedMapOf(
            "aid" to "8662",
            "app_name" to "novelread",
            "version_code" to NATIVE_VERSION_CODE.toString(),
            "version_name" to NATIVE_APP_VERSION,
            "manifest_version_code" to NATIVE_VERSION_CODE.toString(),
            "update_version_code" to NATIVE_VERSION_CODE.toString(),
            "channel" to "update_64",
            "device_platform" to "android",
            "os" to "android",
            "ssmix" to "a",
            "device_type" to NATIVE_DEVICE_MODEL,
            "device_brand" to "Redmi",
            "language" to "zh",
            "os_api" to "36",
            "os_version" to "16",
            "resolution" to "2772*1280",
            "dpi" to "520",
            "ac" to "wifi",
            "openudid" to openudid,
            "package" to "com.phoenix.read",
            "tt_data" to "a",
            "ts" to ts.toString(),
            "_rticket" to stamp.toString(),
        )
        val queryStr = encodeQuery(queryMap)

        val headers = linkedMapOf(
            "User-Agent" to NATIVE_UA,
            "Content-Type" to "application/octet-stream;tt-data=a",
            "Accept" to "application/json; charset=utf-8,application/x-protobuf",
            "Content-Encoding" to "gzip",
            "X-Tt-Request-Tag" to "t=0;n=1",
            "Log-Encode-Type" to "gzip",
            "Lc" to "102",
            "Sdk-Version" to "2",
            "Passport-Sdk-Version" to "60755",
            "Passport-Sdk-Settings" to "device_transfer_s_0,device_transfer_ab_1",
            "X-SS-DP" to "8662",
            "X-Vc-Bdturing-Sdk-Version" to "4.0.3.cn",
            "X-Tt-Store-Region" to "cn",
            "X-Tt-Store-Region-Src" to "did",
            "X-Khronos" to ts.toString(),
            "X-Argus" to le32(ts).base64(),
            "X-SS-Req-Ticket" to stamp.toString(),
            "X-SS-STUB" to digest("MD5", body).hex(),
            "X-Gorgon" to Signer().gorgon(queryStr, body, ts, (Math.random() * 65536).toInt()),
        )

        val startTime = System.currentTimeMillis()
        HongguoDiagnostic.log("INFO", "device_register", "START", "发起原生加密注册 HOST=$HOST")
        return try {
            val req = Request.Builder()
                .url("$HOST$PATH?$queryStr")
                .apply { headers.forEach { (k, v) -> header(k, v) } }
                .post(body.toRequestBody("application/octet-stream;tt-data=a".toMediaType()))
                .build()
            val registered = RequestScope.execute(http.newCall(req)) { resp ->
                val code = resp.code
                val raw = resp.body?.bytes() ?: ByteArray(0)
                val elapsed = System.currentTimeMillis() - startTime
                val plain = if (raw.size > 6 && raw.copyOf(6).contentEquals(MAGIC)) ttDecrypt(raw) else raw
                val text = plain?.toString(Charsets.UTF_8).orEmpty()
                val parsed = if (resp.isSuccessful && text.isNotBlank()) parse(text, resp.headers("Set-Cookie")) else null
                if (parsed != null) {
                    HongguoDiagnostic.log(
                        "INFO", "device_register", "DEVICE_REGISTER_NATIVE_OK",
                        "原生加密注册成功 did=${parsed.deviceId} iid=${parsed.installId}",
                        mapOf("code" to code, "bytes" to raw.size, "elapsed" to "${elapsed}ms")
                    )
                } else {
                    HongguoDiagnostic.log(
                        "WARN", "device_register", "DEVICE_REGISTER_NATIVE_FAIL",
                        "原生加密注册未返回有效身份: code=$code bytes=${raw.size} 详情: ${text.take(120)}",
                        mapOf("code" to code, "bytes" to raw.size, "elapsed" to "${elapsed}ms")
                    )
                }
                parsed
            }
            if (registered != null) {
                HongguoDiagnostic.updateReport(
                    stage = "device_register",
                    code = "DEVICE_REGISTER_OK",
                    summary = "原生加密身份注册正常 (did=${registered.deviceId})"
                )
            }
            registered
        } catch (e: Exception) {
            HongguoDiagnostic.log(
                "WARN", "device_register", "DEVICE_REGISTER_NATIVE_ERR",
                "原生加密注册异常: ${e.message}"
            )
            null
        }
    }

    private fun encodeQuery(map: Map<String, String>): String =
        map.entries.sortedBy { it.key }.joinToString("&") { (k, v) ->
            val ek = URLEncoder.encode(k, "UTF-8").replace("+", "%20").replace("%7E", "~").replace("*", "%2A")
            val ev = URLEncoder.encode(v, "UTF-8").replace("+", "%20").replace("%7E", "~").replace("*", "%2A")
            "$ek=$ev"
        }

    /** 解密官方加密响应体：MAGIC || seed[32] || AES-128-CBC(SHA512(z)||z)，z 为 gzip 后的 JSON。 */
    private fun ttDecrypt(raw: ByteArray): ByteArray? {
        if (raw.size <= 38 || (raw.size - 38) % 16 != 0) return null
        return try {
            val seed = raw.copyOfRange(6, 38)
            val derived = digest("SHA-512", digest("SHA-512", seed) + KDF_SALT)
            val decrypted = javax.crypto.Cipher.getInstance("AES/CBC/NoPadding").run {
                init(
                    javax.crypto.Cipher.DECRYPT_MODE,
                    javax.crypto.spec.SecretKeySpec(derived.copyOfRange(0, 16), "AES"),
                    javax.crypto.spec.IvParameterSpec(derived.copyOfRange(16, 32)),
                )
                doFinal(raw.copyOfRange(38, raw.size))
            }
            val pad = decrypted.last().toInt() and 255
            if (pad !in 1..16 || decrypted.size < pad + 64) return null
            val body = decrypted.copyOf(decrypted.size - pad)
            val hash = body.copyOfRange(0, 64)
            val payload = body.copyOfRange(64, body.size)
            if (!digest("SHA-512", payload).contentEquals(hash)) return null
            java.util.zip.GZIPInputStream(payload.inputStream()).use { it.readBytes() }
        } catch (_: Exception) {
            null
        }
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
