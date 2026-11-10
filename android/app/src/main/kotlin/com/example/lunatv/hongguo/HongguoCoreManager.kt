// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.lunatv.hongguo

import android.content.Context
import android.os.Process
import android.util.Log
import okhttp3.Request
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 红果短剧本地解密代理服务管理器 (照搬 aston314/hongguo-tv 核心生产架构)
 * 启动 libhongguotv.so 本地常驻子进程，监听 127.0.0.1 随机端口。
 * 负责官方三路取流、设备自动轮换、同剧记忆、CENC AES-CTR透明解密与 moov 盒子修复，
 * 为播放器提供 100% 标准明文的 HTTP MP4 流，彻底根除 20 秒试看截断与硬件解码死锁。
 */
object HongguoCoreManager {
    private const val TAG = "HongguoCore"
    private const val READY_PREFIX = "HONGGUO_TV_READY "

    @Volatile
    private var process: java.lang.Process? = null

    @Volatile
    var endpoint: String? = null
        private set

    private var logThread: Thread? = null

    @Synchronized
    fun ensureStarted(context: Context): String? {
        val currentEp = endpoint
        val p = process
        if (currentEp != null && p != null && isAlive(p)) {
            return currentEp
        }

        stop()

        try {
            val binary = File(context.applicationInfo.nativeLibraryDir, "libhongguotv.so")
            if (!binary.exists() || !binary.canExecute()) {
                Log.w(TAG, "Native core binary missing or not executable: ${binary.absolutePath}")
                return null
            }

            val instanceId = UUID.randomUUID().toString()
            val playbackCache = File(context.cacheDir, "minireel").apply { mkdirs() }
            val dataDir = File(context.filesDir, "hongguo-tv").apply { mkdirs() }

            val builder = ProcessBuilder(
                binary.absolutePath,
                "-port", "0",
                "-instance-id", instanceId,
                "-parent-pid", Process.myPid().toString()
            ).redirectErrorStream(true)

            val env = builder.environment()
            env["MINIREEL_CACHE_DIR"] = playbackCache.absolutePath
            env["HONGGUO_TV_DATA_DIR"] = dataDir.absolutePath

            val proc = builder.start()
            process = proc

            val readyLatch = CountDownLatch(1)

            logThread = Thread({
                try {
                    BufferedReader(InputStreamReader(proc.inputStream)).use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            val l = line.orEmpty()
                            if (l.startsWith(READY_PREFIX)) {
                                val fields = l.substring(READY_PREFIX.length()).trim().split(" ")
                                if (fields.size == 2 && fields[1] == instanceId) {
                                    val port = fields[0].toIntOrNull()
                                    if (port != null && port in 1..65535) {
                                        endpoint = "http://127.0.0.1:$port"
                                        readyLatch.countDown()
                                        Log.i(TAG, "Hongguo Core ready at: $endpoint")
                                    }
                                }
                            } else {
                                Log.d(TAG, l)
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Core log thread interrupted: ${e.message}")
                } finally {
                    endpoint = null
                    readyLatch.countDown()
                }
            }, "HongguoCoreLog").apply { isDaemon = true }

            logThread?.start()

            // 最多等待 3.5 秒就绪
            readyLatch.await(3500, TimeUnit.MILLISECONDS)
            return endpoint
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Hongguo core", e)
            return null
        }
    }

    private fun isAlive(p: java.lang.Process): Boolean {
        return try {
            p.exitValue()
            false
        } catch (_: IllegalThreadStateException) {
            true
        }
    }

    @Synchronized
    fun stop() {
        endpoint = null
        try {
            process?.destroy()
        } catch (_: Exception) {}
        process = null
        try {
            logThread?.interrupt()
        } catch (_: Exception) {}
        logThread = null
    }

    /**
     * 极速解析视频流并完成本地透明解密准备 (对齐 aston314/hongguo-tv minireel-proxy 协议)
     */
    fun resolveMedia(context: Context, seriesId: String, vid: String, quality: Int = 1080): Map<String, Any?>? {
        val ep = ensureStarted(context) ?: return null
        val cleanSeriesId = seriesId.trim().removePrefix("hongguo:").trim()
        val cleanVid = vid.trim().removePrefix("hongguo:").trim()
        val qLabel = "${quality}P"
        val url = "$ep/minireel-proxy/resolve?series_id=$cleanSeriesId&vid=$cleanVid&quality=$qLabel"

        val req = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .build()

        try {
            HongguoStreamResolver.client.newCall(req).execute().use { resp ->
                if (resp.isSuccessful) {
                    val body = resp.body?.string().orEmpty()
                    if (body.isNotEmpty()) {
                        val json = JSONObject(body)
                        val path = json.optString("path")
                        if (path.isNotEmpty()) {
                            val streamUrl = "$ep$path"
                            val actualQ = json.optInt("video_height", quality)
                            val qStr = json.optString("quality", "${actualQ}P")
                            Log.i(TAG, "本地核心解密就绪: $streamUrl, quality=$qStr")
                            return mapOf(
                                "url" to streamUrl,
                                "decryptionKey" to "", // 本地核心已完成透明解密，播放器无需再解密
                                "quality" to qStr,
                                "actualQuality" to actualQ,
                                "qualities" to listOf(actualQ),
                                "multiMap" to mapOf(qStr to streamUrl),
                                "keys" to emptyMap<String, String>()
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "本地核心解析异常: ${e.message}")
        }
        return null
    }
}
