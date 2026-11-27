// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.hongguo

import android.util.Log
import okhttp3.OkHttpClient
import java.io.BufferedOutputStream
import java.io.BufferedReader
import java.io.Closeable
import java.io.IOException
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 红果短剧微型本地回环解密流服务 (Local MP4 Stream Loopback Server)
 * 100% 对齐标杆仓库 1736608552/hongguo-tv (minireel_range.go):
 * 针对火山引擎 CDN 的 ISO-BMFF CENC (encv/enca + AES-128-CTR) 加密短剧，
 * 在本地 127.0.0.1 端口启动微型 HTTP Range 代理服务。
 * 当播放器 (Flutter media_kit/libmpv, ExoPlayer 等) 请求分段数据时，
 * 透明完成 moov box 修复 (avc1/mp4a) 与媒体样本动态解密，向底层播放器输出
 * 完全标准的纯明文 MP4 字节流，彻底消灭黑屏、解码器不支持与起播转圈缺陷，实现毫秒级秒开。
 */
class HongguoLocalServer private constructor() {
    companion object {
        private const val TAG = "HongguoLocalServer"
        private const val BUFFER_CHUNK_SIZE = 256 * 1024 // 256KB 分块传输
        // v2.8.6: 16 → 24。v2.8.0 起每个档位的每条 CDN 线路都是独立 token，
        // 反复切档/切线路很容易把 16 撑满，一旦正在播的那条被淘汰，播放器下一次
        // Range 请求就直接 404（2004）。上限不设太高，避免车机上缓存过多解密块。
        private const val MAX_ACTIVE_STREAMS = 24

        val instance: HongguoLocalServer by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
            HongguoLocalServer().apply { start() }
        }
    }

    private var serverSocket: ServerSocket? = null
    @Volatile private var port: Int = 0
    private val isRunning = AtomicBoolean(false)
    private var acceptExecutor: ExecutorService? = null
    private var workerExecutor: ExecutorService? = null

    // Token -> RemoteVideo 缓存与淘汰
    private val activeStreams = ConcurrentHashMap<String, RemoteVideo>()
    private val streamAccessOrder = java.util.concurrent.CopyOnWriteArrayList<String>()

    @Synchronized
    fun start() {
        if (isRunning.get() && serverSocket != null && !serverSocket!!.isClosed) {
            return
        }
        try {
            // 绑定 127.0.0.1 本地回环接口，端口 0 由系统动态分配空闲端口
            val loopback = InetAddress.getByName("127.0.0.1")
            val socket = ServerSocket(0, 50, loopback)
            serverSocket = socket
            port = socket.localPort
            isRunning.set(true)

            acceptExecutor = Executors.newSingleThreadExecutor { r ->
                Thread(r, "HongguoLocalServer-Accept").apply { isDaemon = true }
            }
            workerExecutor = Executors.newCachedThreadPool { r ->
                Thread(r, "HongguoLocalServer-Worker").apply { isDaemon = true }
            }

            acceptExecutor?.submit {
                Log.i(TAG, "本地解密流服务启动成功，监听地址: http://127.0.0.1:$port")
                while (isRunning.get() && !socket.isClosed) {
                    try {
                        val client = socket.accept()
                        client.tcpNoDelay = true
                        client.soTimeout = 30000 // 30 秒超时
                        workerExecutor?.submit { handleClient(client) }
                    } catch (e: Exception) {
                        if (isRunning.get() && !socket.isClosed) {
                            Log.w(TAG, "接受客户端连接异常: ${e.message}")
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "本地流服务启动失败: ${e.message}", e)
        }
    }

    @Synchronized
    fun stop() {
        isRunning.set(false)
        try {
            serverSocket?.close()
        } catch (_: Exception) {}
        serverSocket = null
        acceptExecutor?.shutdownNow()
        workerExecutor?.shutdownNow()
        activeStreams.values.forEach { runCatching { it.close() } }
        activeStreams.clear()
        streamAccessOrder.clear()
        Log.i(TAG, "本地解密流服务已停止")
    }

    /**
     * 将 StreamInfo 注册到本地服务，返回标准明文 MP4 本地播放 URL
     */
    fun getPlayUrl(info: StreamInfo, http: OkHttpClient, eagerWarm: Boolean = true): String {
        // 若流未加密，直接返回原始 URL
        if (info.key == null || info.key.isEmpty()) {
            return info.url
        }

        start() // 确保服务活跃
        if (port <= 0) {
            Log.w(TAG, "服务端口无效，降级回原始直链")
            return info.url
        }

        // 以 URL 的哈希或确定性标识作为 token，复用已初始化的 RemoteVideo 避免重复握手。
        //
        // v2.8.6 关键修复：token **必须是纯 ASCII**。
        //   v2.8.0 引入多 CDN 线路后，档位标签变成了「1080P·线路2」「1080P·移动」这种含中文的串，
        //   原来直接把它拼进 URL → 播放器请求前会做百分号编码 → 服务端按原始字节比对 token
        //   永远匹配不上 → 返回 404 → ExoPlayer 抛 ERROR_CODE_IO_BAD_HTTP_STATUS(2004)。
        //   用户侧表现就是「切到线路 2 必报错」。这里改用档位标签的哈希，彻底与字符集解耦。
        val token = "stream_" + Integer.toHexString(info.url.hashCode()) +
            "_" + Integer.toHexString(info.quality.hashCode())

        val remote = activeStreams[token]
        if (remote == null) {
            val newRemote = RemoteVideo(http, info)
            registerRemote(token, newRemote)
            if (eagerWarm) {
                workerExecutor?.execute {
                    try {
                        newRemote.prepare()
                        newRemote.warm()
                    } catch (e: Exception) {
                        Log.w(TAG, "RemoteVideo 异步预热异常，后续按需重试: ${e.message}")
                    }
                }
            }
        } else {
            synchronized(activeStreams) {
                streamAccessOrder.remove(token)
                streamAccessOrder.add(token)
            }
        }

        val softSuffix = if (info.needsSoftwareDecode) "?softdec=1" else ""
        return "http://127.0.0.1:$port/hongguo/media/$token.mp4$softSuffix"
    }

    private fun registerRemote(token: String, remote: RemoteVideo) {
        synchronized(activeStreams) {
            // 淘汰超额的最老流
            while (streamAccessOrder.size >= MAX_ACTIVE_STREAMS) {
                val oldest = streamAccessOrder.removeAt(0)
                activeStreams.remove(oldest)?.let { old ->
                    runCatching { old.close() }
                }
            }
            activeStreams[token] = remote
            streamAccessOrder.add(token)
        }
    }

    private fun handleClient(socket: Socket) {
        try {
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.US_ASCII))
            val line = reader.readLine() ?: return
            val parts = line.split(" ")
            if (parts.size < 2) return
            val method = parts[0].uppercase()
            val rawPath = parts[1]

            val headers = mutableMapOf<String, String>()
            while (true) {
                val h = reader.readLine() ?: break
                if (h.isBlank()) break
                val idx = h.indexOf(':')
                if (idx > 0) {
                    headers[h.substring(0, idx).trim().lowercase()] = h.substring(idx + 1).trim()
                }
            }

            // 处理 CORS OPTIONS 预检请求
            if (method == "OPTIONS") {
                val out = BufferedOutputStream(socket.getOutputStream())
                out.write("HTTP/1.1 204 No Content\r\n".toByteArray())
                out.write("Access-Control-Allow-Origin: *\r\n".toByteArray())
                out.write("Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n".toByteArray())
                out.write("Access-Control-Allow-Headers: Range, Accept-Encoding, User-Agent\r\n".toByteArray())
                out.write("Content-Length: 0\r\n\r\n".toByteArray())
                out.flush()
                return
            }

            // 解析路由: /hongguo/media/{token}.mp4
            // 请求行里的 path 可能被播放器百分号编码过，必须解码后再比对 token，
            // 否则任何非 ASCII 字符都会让匹配失败（表现为 404 → 播放器 2004）。
            val cleanPath = runCatching {
                android.net.Uri.decode(rawPath.substringBefore('?'))
            }.getOrDefault(rawPath.substringBefore('?'))
            val prefix = "/hongguo/media/"
            if (!cleanPath.startsWith(prefix) || !cleanPath.endsWith(".mp4")) {
                sendNotFound(socket)
                return
            }

            val token = cleanPath.substring(prefix.length, cleanPath.length - 4)
            val remote = activeStreams[token]
            if (remote == null) {
                // 播放器侧只会看到 ERROR_CODE_IO_BAD_HTTP_STATUS(2004)，这里留下服务端真因：
                // 要么 token 拼错（编码/标签问题），要么该流已被 LRU 淘汰。
                Log.w(TAG, "未知流 token=$token，当前已注册 ${activeStreams.size} 条: ${activeStreams.keys.take(4)}")
                sendNotFound(socket)
                return
            }

            // 确保 remote 已完成 prepare
            try {
                remote.prepare()
            } catch (e: Exception) {
                Log.e(TAG, "远程流延迟准备失败: ${e.message}")
                HongguoDiagnostic.log("ERROR", "local_server", "REMOTE_PREPARE_FAIL", "本地代理流准备失败 token=$token: ${e.message}")
                HongguoDiagnostic.updateReport("local_server", "REMOTE_PREPARE_FAIL", summary = "本地代理流连接准备失败: ${e.message}", lastError = e.message)
                // v2.8.6: 摘掉这个坏实例，别让它继续留在缓存里。
                // 否则同一 token 的后续每一次请求都固定 502（播放器只看到 2004），
                // 直到被 LRU 淘汰为止；摘掉后下一次 getPlayUrl 会重建连接自愈。
                synchronized(activeStreams) {
                    if (activeStreams[token] === remote) {
                        activeStreams.remove(token)
                        streamAccessOrder.remove(token)
                    }
                }
                runCatching { remote.close() }
                sendError(socket, 502, "Bad Gateway")
                return
            }

            val total = remote.total
            if (total <= 0) {
                HongguoDiagnostic.log("ERROR", "local_server", "INVALID_LENGTH", "本地代理流长度无效 total=$total")
                sendError(socket, 500, "Invalid Stream Length")
                return
            }

            // 解析 HTTP Range 头
            val rangeHeader = headers["range"]
            var start = 0L
            var end = total - 1
            var isPartial = false

            if (!rangeHeader.isNullOrBlank() && rangeHeader.startsWith("bytes=")) {
                val rangeVal = rangeHeader.removePrefix("bytes=").trim()
                val dashIdx = rangeVal.indexOf('-')
                if (dashIdx >= 0) {
                    val sStr = rangeVal.substring(0, dashIdx).trim()
                    val eStr = rangeVal.substring(dashIdx + 1).trim()
                    if (sStr.isNotEmpty()) {
                        start = sStr.toLongOrNull() ?: 0L
                        if (eStr.isNotEmpty()) {
                            end = minOf(eStr.toLongOrNull() ?: (total - 1), total - 1)
                        }
                    } else if (eStr.isNotEmpty()) {
                        // suffix range: bytes=-500
                        val suffix = eStr.toLongOrNull() ?: 0L
                        start = maxOf(0L, total - suffix)
                    }
                    isPartial = true
                }
            }

            if (start < 0 || start >= total || end < start) {
                val out = BufferedOutputStream(socket.getOutputStream())
                out.write("HTTP/1.1 416 Range Not Satisfiable\r\n".toByteArray())
                out.write("Content-Range: bytes */$total\r\n\r\n".toByteArray())
                out.flush()
                return
            }

            val length = end - start + 1
            val out = BufferedOutputStream(socket.getOutputStream())

            if (isPartial) {
                out.write("HTTP/1.1 206 Partial Content\r\n".toByteArray())
                out.write("Content-Range: bytes $start-$end/$total\r\n".toByteArray())
            } else {
                out.write("HTTP/1.1 200 OK\r\n".toByteArray())
            }

            out.write("Content-Type: video/mp4\r\n".toByteArray())
            out.write("Accept-Ranges: bytes\r\n".toByteArray())
            out.write("Content-Length: $length\r\n".toByteArray())
            out.write("Access-Control-Allow-Origin: *\r\n".toByteArray())
            out.write("Cache-Control: private, max-age=3600\r\n".toByteArray())
            out.write("Connection: close\r\n\r\n".toByteArray())
            out.flush()

            if (method == "HEAD") {
                return
            }

            // 循环按 256KB 分块解密并流式下发
            var currentPos = start
            while (currentPos <= end && isRunning.get()) {
                val readLen = minOf(BUFFER_CHUNK_SIZE.toLong(), end - currentPos + 1).toInt()
                val chunk = remote.read(currentPos, readLen)
                if (chunk.isEmpty()) break
                out.write(chunk)
                currentPos += chunk.size
            }
            out.flush()
        } catch (_: SocketException) {
            // 客户端 Seek 或切集主动断开连接，属于正常播放行为
        } catch (_: IOException) {
            // 连接异常中止
        } catch (e: Exception) {
            Log.w(TAG, "流处理异常: ${e.message}")
            HongguoDiagnostic.log("WARN", "local_server", "STREAM_EXCEPTION", "本地代理流读取异常: ${e.message}")
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun sendNotFound(socket: Socket) {
        try {
            val out = socket.getOutputStream()
            out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".toByteArray())
            out.flush()
        } catch (_: Exception) {}
    }

    private fun sendError(socket: Socket, code: Int, msg: String) {
        try {
            val out = socket.getOutputStream()
            out.write("HTTP/1.1 $code $msg\r\nContent-Length: 0\r\n\r\n".toByteArray())
            out.flush()
        } catch (_: Exception) {}
    }
}
