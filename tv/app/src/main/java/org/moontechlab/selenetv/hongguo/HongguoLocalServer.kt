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
 * TV 端红果短剧微型本地回环解密流服务 (Local MP4 Stream Loopback Server)
 * 100% 对齐标杆仓库 1736608552/hongguo-tv (minireel_range.go):
 * 针对火山引擎 CDN 的 ISO-BMFF CENC (encv/enca + AES-128-CTR) 加密短剧，
 * 在本地 127.0.0.1 端口启动微型 HTTP Range 代理服务。
 * 当 ExoPlayer 请求分段数据时，透明完成 moov box 修复 (avc1/mp4a) 与媒体样本动态解密，
 * 输出完全标准的纯明文 MP4 字节流，为电视端提供零黑屏、零崩溃的硬解秒开体验。
 */
class HongguoLocalServer private constructor() {
    companion object {
        private const val TAG = "HongguoLocalServer"
        private const val BUFFER_CHUNK_SIZE = 256 * 1024 // 256KB 分块传输
        private const val MAX_ACTIVE_STREAMS = 16

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
            val loopback = InetAddress.getByName("127.0.0.1")
            val socket = ServerSocket(0, 50, loopback)
            serverSocket = socket
            port = socket.localPort
            isRunning.set(true)

            acceptExecutor = Executors.newSingleThreadExecutor { r ->
                Thread(r, "HongguoLocalServer-TV-Accept").apply { isDaemon = true }
            }
            workerExecutor = Executors.newFixedThreadPool(8) { r ->
                Thread(r, "HongguoLocalServer-TV-Worker").apply { isDaemon = true }
            }

            acceptExecutor?.submit {
                Log.i(TAG, "TV 本地解密流服务启动成功，监听地址: http://127.0.0.1:$port")
                while (isRunning.get() && !socket.isClosed) {
                    try {
                        val client = socket.accept()
                        client.tcpNoDelay = true
                        client.soTimeout = 30000
                        workerExecutor?.submit { handleClient(client) }
                    } catch (e: Exception) {
                        if (isRunning.get() && !socket.isClosed) {
                            Log.w(TAG, "接受客户端连接异常: ${e.message}")
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "TV 本地流服务启动失败: ${e.message}", e)
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
        Log.i(TAG, "TV 本地解密流服务已停止")
    }

    /**
     * 将 StreamInfo 注册到本地服务，返回标准明文 MP4 本地播放 URL
     */
    fun getPlayUrl(info: StreamInfo, http: OkHttpClient): String {
        if (info.key == null || info.key.isEmpty()) {
            return info.url
        }

        start()
        if (port <= 0) {
            Log.w(TAG, "服务端口无效，降级回原始直链")
            return info.url
        }

        val token = "stream_" + Integer.toHexString(info.url.hashCode()) + "_" + (info.quality.filter { it.isLetterOrDigit() })
        
        var remote = activeStreams[token]
        if (remote == null) {
            val newRemote = RemoteVideo(http, info)
            try {
                newRemote.prepare()
                newRemote.warm()
            } catch (e: Exception) {
                Log.w(TAG, "TV RemoteVideo prepare 预热异常: ${e.message}")
            }
            registerRemote(token, newRemote)
        } else {
            streamAccessOrder.remove(token)
            streamAccessOrder.add(token)
        }

        return "http://127.0.0.1:$port/hongguo/media/$token.mp4"
    }

    private fun registerRemote(token: String, remote: RemoteVideo) {
        synchronized(activeStreams) {
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

            val cleanPath = rawPath.substringBefore('?')
            val prefix = "/hongguo/media/"
            if (!cleanPath.startsWith(prefix) || !cleanPath.endsWith(".mp4")) {
                sendNotFound(socket)
                return
            }

            val token = cleanPath.substring(prefix.length, cleanPath.length - 4)
            val remote = activeStreams[token]
            if (remote == null) {
                sendNotFound(socket)
                return
            }

            try {
                remote.prepare()
            } catch (e: Exception) {
                Log.e(TAG, "TV 远程流准备失败: ${e.message}")
                sendError(socket, 502, "Bad Gateway")
                return
            }

            val total = remote.total
            if (total <= 0) {
                sendError(socket, 500, "Invalid Stream Length")
                return
            }

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
        } catch (_: IOException) {
        } catch (e: Exception) {
            Log.w(TAG, "TV 流处理异常: ${e.message}")
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
