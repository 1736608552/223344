// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.hongguo

import java.io.IOException
import java.util.UUID
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * 专门给播放链路准备一套注册过的设备参数。
 * 100% 对齐 1736608552/hongguo-tv (single-registered-profile.js & PlaybackDeviceSession.kt):
 * 优先采用 novelread 7.3.5.32 官方明文注册协议获取真实非 0 device_id 与 install_id，
 * 若遇极端网络抖动再尝试 ttEncrypt 多域名容灾与预置活跃设备兜底。
 */
class PlaybackDeviceSession {
    companion object {
        val shared = PlaybackDeviceSession()
        const val PLAYBACK_UA = "com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)"
    }

    data class Profile(
        val values: Map<String, String>,
        val cookie: String,
        val isOfficialRegistered: Boolean = true,
    )

    @Volatile private var ready: Profile? = null

    fun profile(http: OkHttpClient): Profile {
        ready?.let { return it }
        synchronized(this) {
            ready?.let { return it }
            return register(http)
        }
    }

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
    fun rotate(http: OkHttpClient): Profile {
        ready = null
        VendorConstants.regenerate()
        try {
            http.connectionPool.evictAll()
        } catch (_: Throwable) {}
        return register(http)
    }

    private fun register(http: OkHttpClient): Profile {
        val cdid = UUID.randomUUID().toString()
        val template =
            VendorConstants.device +
                mapOf(
                    "cdid" to cdid,
                    "openudid" to UUID.randomUUID().toString().replace("-", "").take(16),
                    "clientudid" to UUID.randomUUID().toString(),
                )

        var registeredDevice: DeviceRegister.Registered? = null
        var isOfficial = false

        // 1. 优先使用 hongguo-tv 验证 100% 成功的 single-registered 协议注册真实设备身份
        for (attempt in 0 until 2) {
            val singleReg = DeviceRegister.registerSingleRegistered(http)
            if (singleReg != null) {
                registeredDevice = singleReg
                isOfficial = true
                break
            }
        }

        // 2. 备用：若明文注册受阻，尝试 ttEncrypt 加密通道
        if (registeredDevice == null) {
            val candidateUrls = DeviceRegister.urls()
            for (attempt in 0 until 2) {
                val targetUrl = candidateUrls[attempt % candidateUrls.size]
                try {
                    val now = System.currentTimeMillis()
                    val body = DeviceRegister.payload(template, now)
                    val request =
                        Request.Builder()
                            .url(targetUrl)
                            .apply { DeviceRegister.headers(body, template, now).forEach(::header) }
                            .post(body.toRequestBody("application/octet-stream;tt-data=a".toMediaType()))
                            .build()
                    val parsed = RequestScope.execute(http.newCall(request)) { response ->
                        DeviceRegister.parse(
                            readRegisterBody(response),
                            response.headers("Set-Cookie"),
                        )
                    }
                    if (parsed != null) {
                        registeredDevice = parsed
                        isOfficial = true
                        break
                    }
                } catch (_: Exception) {
                }
            }
        }

        // 3. 终极兜底：使用本地独立持久化设备参数
        val device = registeredDevice ?: run {
            VendorConstants.regenerate()
            DeviceRegister.Registered(
                deviceId = VendorConstants.installDeviceId,
                installId = VendorConstants.installIid,
                cookies = mapOf(
                    "install_id" to VendorConstants.installIid,
                    "store-region" to "cn",
                    "store-region-src" to "did"
                )
            )
        }

        val cookieHeader = device.cookies
            .filterKeys {
                it in setOf("install_id", "ttreq", "store-region", "store-region-src")
            }
            .entries
            .joinToString("; ") { (name, value) -> "$name=$value" }
            .ifBlank { "install_id=${device.installId}; store-region=cn; store-region-src=did" }

        val createdProfile = Profile(
            VendorConstants.device + mapOf(
                "device_id" to device.deviceId,
                "iid" to device.installId,
                "install_id" to device.installId,
                "cdid" to cdid,
            ),
            cookieHeader,
            isOfficialRegistered = isOfficial
        )

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
