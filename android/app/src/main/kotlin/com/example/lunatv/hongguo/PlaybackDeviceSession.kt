// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.lunatv.hongguo

import java.util.UUID
import okhttp3.OkHttpClient
import okhttp3.Request

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
        private const val REFRESH_COOLDOWN_MS = 12_000L
    }

    data class Profile(
        val values: Map<String, String>,
        val cookie: String,
        val isOfficialRegistered: Boolean = true,
    )

    @Volatile private var ready: Profile? = null
    @Volatile private var lastRefreshAtMs: Long = 0L

    private fun loadPersistedOfficialProfile(): Profile? {
        if (!VendorConstants.isOfficialRegistered()) return null
        val devId = VendorConstants.installDeviceId
        val iid = VendorConstants.installIid
        val cookie = VendorConstants.getOfficialCookie()
        return Profile(
            values = VendorConstants.device + mapOf(
                "device_id" to devId,
                "iid" to iid,
                "install_id" to iid,
                "cdid" to VendorConstants.cdid,
            ),
            cookie = cookie,
            isOfficialRegistered = true,
        )
    }

    fun profile(http: OkHttpClient): Profile {
        ready?.let { return it }
        synchronized(this) {
            ready?.let { return it }
            loadPersistedOfficialProfile()?.let { persisted ->
                ready = persisted
                return persisted
            }
            return register(http)
        }
    }

    @Synchronized
    fun invalidate(http: OkHttpClient? = null) {
        if (http != null) {
            try {
                http.connectionPool.evictAll()
            } catch (_: Throwable) {}
        }
    }

    @Synchronized
    fun rotate(http: OkHttpClient, failedDeviceId: String = ""): Profile {
        val previous = ready?.takeIf { it.isOfficialRegistered } ?: loadPersistedOfficialProfile()
        // 若另一并发线程已换发了新设备号，直接复用新设备号，绝不重复发起注册请求
        if (failedDeviceId.isNotBlank() && previous != null && previous.values["device_id"] != failedDeviceId) {
            ready = previous
            return previous
        }

        val now = System.currentTimeMillis()
        if (now - lastRefreshAtMs < REFRESH_COOLDOWN_MS && previous != null) {
            ready = previous
            return previous
        }
        lastRefreshAtMs = now
        if (failedDeviceId.isNotBlank()) {
            VendorConstants.clearPersistedIdentity(failedDeviceId)
            ready = null
        }

        try {
            http.connectionPool.evictAll()
        } catch (_: Throwable) {}

        val fresh = register(http)
        if (fresh.isOfficialRegistered) {
            ready = fresh
            return fresh
        }
        // 若注册未能成功且当前并非强制封禁换发，才退回之前的凭证
        if (failedDeviceId.isBlank() && previous != null) {
            ready = previous
            return previous
        }
        return fresh
    }

    @Synchronized
    fun resetAll(http: OkHttpClient): Profile {
        VendorConstants.clearPersistedIdentity()
        ready = null
        try {
            http.connectionPool.evictAll()
        } catch (_: Throwable) {}
        val fresh = register(http)
        ready = fresh
        return fresh
    }

    private fun register(http: OkHttpClient): Profile {
        val cdid = UUID.randomUUID().toString()
        val openudid = UUID.randomUUID().toString().replace("-", "").take(16)
        val clientudid = UUID.randomUUID().toString()

        var registeredDevice: DeviceRegister.Registered? = null
        var isOfficial = false

        // 1. 首选：官方原生加密注册（tt-data 体 + X-Gorgon/X-Argus）。
        //    明文 JSON 注册拿到的 did 没有风控签名背书，播放接口一律 200 空包。
        DeviceRegister.nativeRegister(http)?.let {
            registeredDevice = it
            isOfficial = true
        }

        // 2. 备用：明文 JSON 注册（原生通道被风控拒绝时的兜底）
        if (registeredDevice == null) {
            DeviceRegister.registerSingleRegistered(http)?.let {
                registeredDevice = it
                isOfficial = true
            }
        }

        // 3. 若本次因断网或 IP 冷却未拿到新号，优先回退使用本地已持久化的真实身份
        if (registeredDevice == null) {
            loadPersistedOfficialProfile()?.let { persisted ->
                HongguoDiagnostic.log("INFO", "session", "RESTORE_PERSISTED_PROFILE", "从本地存储复用上一次成功的注册身份: did=${persisted.values["device_id"]}")
                HongguoDiagnostic.updateReport(
                    stage = "session",
                    code = "RESTORE_OK",
                    summary = "复用本地有效设备身份 (did=${persisted.values["device_id"]})"
                )
                ready = persisted
                return persisted
            }
        }

        val device = registeredDevice ?: run {
            HongguoDiagnostic.log("WARN", "session", "FALLBACK_VIRTUAL_DEVICE", "所有注册通道均未返回有效设备，降级使用内置备用虚拟身份 (did=${VendorConstants.installDeviceId})")
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

        if (isOfficial) {
            VendorConstants.saveOfficialIdentity(
                deviceId = device.deviceId,
                iid = device.installId,
                cdidVal = cdid,
                openUdidVal = openudid,
                cookieVal = cookieHeader,
            )
        }

        val createdProfile = Profile(
            VendorConstants.device + mapOf(
                "device_id" to device.deviceId,
                "iid" to device.installId,
                "install_id" to device.installId,
                "cdid" to cdid,
                "openudid" to openudid,
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
