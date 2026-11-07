// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.hongguo

import java.io.IOException
import java.util.UUID
import okhttp3.CookieJar
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * 匿名播放设备身份会话管理器 (参考 jycao2/hongguoTV 0.23.0 工业级标准实现)
 *
 * 平台按「注册过的 device_id + install_id」放行播放接口。
 * 进程启动后统一注册一次并在进程内长效复用，取流时只换请求时间戳不换设备身份。
 * 当网络原因注册失败时，自动平滑兜底采用高可用预置合法设备身份，绝不中断播放。
 */
class PlaybackDeviceSession(
    private val register: (OkHttpClient) -> DeviceRegister.Registered? = { http ->
        var registered: DeviceRegister.Registered? = null
        // 睡眠唤醒防抖：增加 2 次微退避重试，确保电视休眠唤醒网络刚连上时能顺利注册
        for (attempt in 0..2) {
            try {
                val body = DeviceRegister.payload(VendorConstants.device)
                val request = Request.Builder().url(DeviceRegister.url())
                DeviceRegister.headers(body, VendorConstants.device).forEach { (key, value) ->
                    request.header(key, value)
                }
                request.post(body.toRequestBody("application/octet-stream".toMediaType()))
                val transport = http.newBuilder()
                    .cookieJar(CookieJar.NO_COOKIES)
                    .retryOnConnectionFailure(true)
                    .build()
                transport.newCall(request.build()).execute().use { response ->
                    val bodyStr = readRegisterBody(response)
                    registered = DeviceRegister.parse(bodyStr, response.headers("Set-Cookie"))
                }
                if (registered != null && registered.deviceId.isNotBlank() && registered.deviceId != "0") {
                    break
                }
            } catch (e: Exception) {
                android.util.Log.w("PlaybackDeviceSession", "官方设备注册请求异常 (attempt $attempt): ${e.message}")
                if (attempt < 2) {
                    try { Thread.sleep(300L * (attempt + 1)) } catch (_: InterruptedException) {}
                }
            }
        }
        registered
    }
) {
    companion object {
        val shared = PlaybackDeviceSession()
        const val PLAYBACK_UA = "com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)"
    }

    data class Profile(val values: Map<String, String>, val cookie: String, val isOfficialRegistered: Boolean = true)

    private val cdid: String get() = VendorConstants.cdid
    @Volatile
    private var ready: Profile? = null

    @Synchronized
    fun invalidate(http: OkHttpClient? = null) {
        ready = null
        VendorConstants.regenerate()
        if (http != null) {
            try {
                http.connectionPool.evictAll()
            } catch (_: Throwable) {}
        }
    }

    @Synchronized
    fun profile(http: OkHttpClient): Profile {
        ready?.let { return it }

        var isOfficial = true
        val device = try {
            register(http)
        } catch (ignored: Exception) {
            null
        } ?: run {
            isOfficial = false
            VendorConstants.regenerate()
            DeviceRegister.Registered(
                deviceId = VendorConstants.installDeviceId,
                installId = VendorConstants.installIid,
                cookies = mapOf(
                    "install_id" to VendorConstants.installIid,
                    "store-region" to "cn",
                    "store-region-src" to "fallback"
                )
            )
        }

        val cookieHeader = device.cookies
            .filterKeys {
                it in setOf("install_id", "ttreq", "store-region", "store-region-src")
            }
            .entries
            .joinToString("; ") { (name, value) -> "$name=$value" }

        val createdProfile = Profile(
            VendorConstants.device + mapOf(
                "device_id" to device.deviceId,
                "iid" to device.installId,
                "cdid" to cdid,
            ),
            cookieHeader,
            isOfficialRegistered = isOfficial
        )

        // 核心自愈法则：仅当真正获得官方注册通过的设备身份时才常驻缓存至 ready！
        // 若因休眠未连网等走 fallback，严禁缓存，确保网络恢复后下一次调用立即自动发起合法官方注册！
        if (isOfficial) {
            ready = createdProfile
        }
        return createdProfile
    }
}

private fun readRegisterBody(response: okhttp3.Response): String {
    if (!response.isSuccessful) throw IOException("播放设备注册失败（HTTP ${response.code}）")
    val body = response.body ?: throw IOException("播放设备注册响应为空")
    val limit = 2L * 1024 * 1024
    if (body.contentLength() > limit) throw IOException("播放设备注册响应过大")
    val input = body.byteStream()
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (out.size() <= limit) {
        val n = input.read(buffer)
        if (n < 0) break
        out.write(buffer, 0, n)
    }
    val bytes = out.toByteArray()
    if (bytes.size > limit) throw IOException("播放设备注册响应过大")
    val text = String(bytes, Charsets.UTF_8)
    if (text.isBlank()) throw IOException("播放设备注册返回空响应")
    return text
}
