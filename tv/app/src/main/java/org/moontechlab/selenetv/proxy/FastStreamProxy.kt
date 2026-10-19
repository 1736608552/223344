// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.proxy

import android.net.Uri
import android.util.Log
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Collections
import java.util.LinkedHashMap
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.regex.Matcher
import java.util.regex.Pattern
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * 咕噜咕噜 (GuluGuluTV) 同款流媒体极速本地环回加速代理 (集成中插随机广告无缝智能切除引擎)
 * 
 * 核心特性：
 * 1. 腾讯/咕噜咕噜同款极速多路 TCP 并发预抓取：后台并发预拉取后续 3~4 个切片入纯内存 LRU 切片池，把宽带拉满，彻底消灭转圈；
 * 2. 咕噜咕噜同款中插随机广告无缝智能切除：基于断点区间时间测谎与广告特征指纹，在内存中精准剪除中插广告，正片无缝贴合；
 * 3. 完美支持 Master Playlist 多级变体清晰度自动识别与递归代理；
 * 4. 完美兼容 AES-128 解密 (#EXT-X-KEY) 与 fMP4 (#EXT-X-MAP) 绝对路径解析；
 * 5. 内置 Fail-Safe 302 自动容灾降级：若本地代理拉取超时，秒级 302 重定向至源站，永不黑屏；
 * 6. 纯内存环形切片池 (LRU Cache)，绝不写电视慢速 eMMC 闪存；
 * 7. 全局忽略不规范 SSL 证书与防盗链 Origin Referer 自动伪装，通行全网主流影视采集源。
 */
object FastStreamProxy {
    private const val TAG = "FastStreamProxy"
    const val PROXY_PORT = 28258

    private val URI_PATTERN = Pattern.compile("URI=\"([^\"]+)\"")
    private val mPlaylistSegments = ConcurrentHashMap<String, List<String>>()
    private val mCachePool = SegmentCachePool(32 * 1024 * 1024) // 32MB 纯内存环形缓存

    // 咕噜咕噜四大黑科技：6 路多并发 TCP 爆破线程池
    private val mPreloadExecutor: ExecutorService = Executors.newFixedThreadPool(6) { r ->
        Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            r.run()
        }, "FastStreamProxy-Preload").apply { isDaemon = true }
    }

    // 解密自咕噜咕噜官方核心库的白名单 UA 伪装库（华为、夸克、小米主流安卓内核，突破采集站 QoS 恶意限速）
    private val WHITELIST_USER_AGENTS = arrayOf(
        "Mozilla/5.0 (Linux; Android 14; 22081212C Build/UP1A.231005.007); AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.6778.260 Mobile Safari/537.36 Quark/7.4.3.700",
        "Mozilla/5.0 (Linux; Android 12; JY-960 Build/SP1.210811.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.4324.93 HuaweiBrowser/12.0.1.302 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 13; 23049RAD8C Build/TKQ1.221114.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 12; HarmonyOS; NOH-AN00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.88 Mobile Safari/537.36"
    )
    private val mUaRandom = SecureRandom()

    private fun getRandomWhitelistUa(): String {
        return WHITELIST_USER_AGENTS[mUaRandom.nextInt(WHITELIST_USER_AGENTS.size)]
    }

    private var mServerSocket: ServerSocket? = null
    @Volatile
    private var mIsRunning = false

    init {
        // 全局忽略不规范的 SSL 证书，解决安卓电视因根证书过期导致的播放失败
        try {
            val trustAllCerts = arrayOf<TrustManager>(object : X509TrustManager {
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
                override fun checkClientTrusted(certs: Array<X509Certificate>?, authType: String?) {}
                override fun checkServerTrusted(certs: Array<X509Certificate>?, authType: String?) {}
            })
            val sc = SSLContext.getInstance("TLS")
            sc.init(null, trustAllCerts, SecureRandom())
            HttpsURLConnection.setDefaultSSLSocketFactory(sc.socketFactory)
            HttpsURLConnection.setDefaultHostnameVerifier { _, _ -> true }
        } catch (_: Exception) {}

        System.setProperty("http.keepAlive", "true")
        System.setProperty("http.maxConnections", "16")
    }

    @Synchronized
    fun start() {
        if (mIsRunning) return
        mIsRunning = true
        Thread({
            try {
                mServerSocket = ServerSocket(PROXY_PORT, 64, InetAddress.getByName("127.0.0.1"))
                Log.i(TAG, "FastStreamProxy server started on 127.0.0.1:$PROXY_PORT")
                while (mIsRunning && mServerSocket?.isClosed == false) {
                    val client = mServerSocket?.accept() ?: break
                    client.tcpNoDelay = true
                    mPreloadExecutor.execute { handleClient(client) }
                }
            } catch (e: Exception) {
                if (mIsRunning) {
                    Log.w(TAG, "FastStreamProxy listener stopped: ${e.message}")
                }
            }
        }, "FastStreamProxy-Listener").apply { isDaemon = true }.start()
    }

    @Synchronized
    fun stop() {
        mIsRunning = false
        try {
            mServerSocket?.close()
        } catch (_: Exception) {}
        mServerSocket = null
        mCachePool.clear()
        mPlaylistSegments.clear()
    }

    fun getProxyUrl(rawUrl: String?): String {
        if (rawUrl.isNullOrEmpty()) return rawUrl.orEmpty()
        if (rawUrl.startsWith("http://127.0.0.1:$PROXY_PORT")) return rawUrl

        // 仅对 http/https 的流媒体自动启用极速环回代理
        if (rawUrl.startsWith("http://") || rawUrl.startsWith("https://")) {
            val lower = rawUrl.lowercase()
            if (lower.contains(".m3u8") || lower.contains("/hls/") || lower.contains("live=1")) {
                return try {
                    start() // 确保服务在活跃状态
                    "http://127.0.0.1:$PROXY_PORT/playlist.m3u8?url=" + URLEncoder.encode(rawUrl, "UTF-8")
                } catch (_: Exception) {
                    rawUrl
                }
            }
        }
        return rawUrl
    }

    private fun handleClient(socket: Socket) {
        try {
            socket.use { s ->
                val isStream = s.getInputStream()
                val osStream = s.getOutputStream()
                val reader = BufferedReader(InputStreamReader(isStream, StandardCharsets.UTF_8))
                val line = reader.readLine() ?: return
                if (!line.startsWith("GET ")) return

                val parts = line.split(" ")
                if (parts.size < 2) return
                val path = parts[1]
                val uri = Uri.parse("http://127.0.0.1:$PROXY_PORT$path")

                when {
                    path.startsWith("/playlist.m3u8") -> handleM3u8Request(uri, osStream)
                    path.startsWith("/segment") -> handleSegmentRequest(uri, osStream)
                    else -> osStream.write("HTTP/1.1 404 Not Found\r\n\r\n".toByteArray(StandardCharsets.UTF_8))
                }
            }
        } catch (_: Exception) {}
    }

    private fun handleM3u8Request(uri: Uri, os: OutputStream) {
        val targetUrlRaw = uri.getQueryParameter("url") ?: return
        var targetUrl = targetUrlRaw
        try {
            targetUrl = URLDecoder.decode(targetUrl, "UTF-8")
            val m3u8Bytes = fetchBytes(targetUrl, 5000)
            if (m3u8Bytes == null || m3u8Bytes.isEmpty()) {
                sendRedirect(os, targetUrl)
                return
            }

            val body = String(m3u8Bytes, StandardCharsets.UTF_8)
            val rawLines = body.split("\n")
            val isMasterPlaylist = body.contains("#EXT-X-STREAM-INF")

            // 执行智能去广告清洗
            val cleanedLines = if (!isMasterPlaylist) {
                removeRandomAdSegments(rawLines)
            } else {
                rawLines.map { it.trim() }.filter { it.isNotEmpty() }
            }

            val rewritten = StringBuilder()
            val segmentUrls = mutableListOf<String>()

            for (rawLine in cleanedLines) {
                var l = rawLine
                if (l.startsWith("#")) {
                    // 处理 #EXT-X-KEY 与 #EXT-X-MAP 绝对路径转换
                    if (l.contains("URI=\"")) {
                        try {
                            val matcher = URI_PATTERN.matcher(l)
                            val sb = StringBuffer()
                            while (matcher.find()) {
                                val relUri = matcher.group(1)
                                if (relUri != null) {
                                    val absUri = resolveUrl(targetUrl, relUri)
                                    matcher.appendReplacement(sb, Matcher.quoteReplacement("URI=\"$absUri\""))
                                }
                            }
                            matcher.appendTail(sb)
                            l = sb.toString()
                        } catch (_: Exception) {}
                    }
                    rewritten.append(l).append("\n")
                } else {
                    val absUrl = resolveUrl(targetUrl, l)
                    if (isMasterPlaylist || absUrl.lowercase().contains(".m3u8")) {
                        // 子清晰度 M3U8，继续代理为 playlist.m3u8
                        val proxySubUrl = "http://127.0.0.1:$PROXY_PORT/playlist.m3u8?url=" +
                                URLEncoder.encode(absUrl, "UTF-8")
                        rewritten.append(proxySubUrl).append("\n")
                    } else {
                        // 普通正片分片：重写为本地 /segment，开启多路 TCP 并发预抓取与内存缓冲加速
                        val segIdx = segmentUrls.size
                        segmentUrls.add(absUrl)
                        val proxySegUrl = "http://127.0.0.1:$PROXY_PORT/segment?url=" +
                                URLEncoder.encode(absUrl, "UTF-8") +
                                "&idx=" + segIdx +
                                "&group=" + URLEncoder.encode(targetUrl, "UTF-8")
                        rewritten.append(proxySegUrl).append("\n")
                    }
                }
            }

            if (segmentUrls.isNotEmpty()) {
                mPlaylistSegments[targetUrl] = segmentUrls
                // 收到 m3u8 后立即启动前 4 片的主动预拉取，实现秒开起播！
                triggerPreload(targetUrl, 0, 4)
            }

            val outBytes = rewritten.toString().toByteArray(StandardCharsets.UTF_8)
            val header = "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: application/vnd.apple.mpegurl\r\n" +
                    "Content-Length: " + outBytes.size + "\r\n" +
                    "Access-Control-Allow-Origin: *\r\n" +
                    "Connection: close\r\n\r\n"
            os.write(header.toByteArray(StandardCharsets.UTF_8))
            os.write(outBytes)
            os.flush()
        } catch (_: Exception) {
            try {
                sendRedirect(os, targetUrl)
            } catch (_: Exception) {}
        }
    }

    /**
     * 咕噜咕噜同款中插随机广告无缝剔除算法核心
     */
    private fun removeRandomAdSegments(lines: List<String>): List<String> {
        val blocks = mutableListOf<MutableList<String>>()
        var currentBlock = mutableListOf<String>()

        for (line in lines) {
            val l = line.trim()
            if (l.isEmpty()) continue
            if (l == "#EXT-X-DISCONTINUITY") {
                if (currentBlock.isNotEmpty()) {
                    blocks.add(currentBlock)
                    currentBlock = mutableListOf()
                }
                blocks.add(mutableListOf("#EXT-X-DISCONTINUITY"))
            } else {
                currentBlock.add(l)
            }
        }
        if (currentBlock.isNotEmpty()) {
            blocks.add(currentBlock)
        }

        var totalSegments = 0
        for (b in blocks) {
            for (l in b) {
                if (!l.startsWith("#")) totalSegments++
            }
        }
        if (totalSegments < 15) {
            return blocks.flatten()
        }

        val cleanedLines = mutableListOf<String>()
        var i = 0
        while (i < blocks.size) {
            val b = blocks[i]
            if (b.size == 1 && b[0] == "#EXT-X-DISCONTINUITY") {
                if (i + 2 < blocks.size && blocks[i + 2].size == 1 && blocks[i + 2][0] == "#EXT-X-DISCONTINUITY") {
                    val midBlock = blocks[i + 1]
                    var duration = 0.0f
                    var segCount = 0
                    var hasAdKeyword = false

                    for (ml in midBlock) {
                        if (ml.startsWith("#EXTINF:")) {
                            try {
                                val dStr = ml.substring(8).split(",")[0].trim()
                                duration += dStr.toFloat()
                                segCount++
                            } catch (_: Exception) {}
                        } else if (!ml.startsWith("#")) {
                            val lowerUrl = ml.lowercase()
                            if (lowerUrl.contains("/ad/") || lowerUrl.contains("/adv/") || lowerUrl.contains("ad_") ||
                                lowerUrl.contains("guanggao") || lowerUrl.contains("casino") || lowerUrl.contains("bet")) {
                                hasAdKeyword = true
                            }
                        }
                    }

                    if ((duration in 1.0f..28.0f && segCount <= 6) || (hasAdKeyword && duration <= 35.0f)) {
                        Log.i(TAG, "已成功识别并无缝切除中插广告！广告时长: ${duration}s, 切片数: $segCount")
                        i += 3
                        continue
                    }
                }
                cleanedLines.addAll(b)
                i++
            } else {
                cleanedLines.addAll(b)
                i++
            }
        }
        return cleanedLines
    }

    private fun handleSegmentRequest(uri: Uri, os: OutputStream) {
        val segmentUrlRaw = uri.getQueryParameter("url") ?: return
        val idxStr = uri.getQueryParameter("idx")
        val group = uri.getQueryParameter("group")
        var segmentUrl = segmentUrlRaw

        try {
            segmentUrl = URLDecoder.decode(segmentUrl, "UTF-8")
            val cachedData = mCachePool.get(segmentUrl)

            if (cachedData != null) {
                // 内存命中：0ms 极速输出！
                sendSegmentResponse(os, cachedData, segmentUrl)
            } else {
                // 咕噜咕噜管道穿透黑科技：流式边下边推直通 (Streaming Pipe)
                // 首 32KB/64KB 数据到达即刻推入播放器硬件解码器，消灭整片死等等待；同时收集入 32MB 内存池
                val streamedOk = streamAndCacheSegment(os, segmentUrl)
                if (!streamedOk) {
                    // 容灾机制：若本地流式拉取异常或超时，秒级 302 重定向至源站真实 CDN，永不黑屏！
                    sendRedirect(os, segmentUrl)
                    return
                }
            }

            // 咕噜咕噜黑科技：触发后续切片并发预拉取（预抓接下来的 6 个切片）
            if (idxStr != null && group != null) {
                val currentIdx = idxStr.toIntOrNull() ?: 0
                val groupUrl = URLDecoder.decode(group, "UTF-8")
                triggerPreload(groupUrl, currentIdx + 1, 6)
            }
        } catch (_: Exception) {
            try {
                sendRedirect(os, segmentUrl)
            } catch (_: Exception) {}
        }
    }

    /**
     * 咕噜咕噜管道穿透黑科技：边下边推直通 (Streaming Pipe)
     * 首 32KB/64KB 数据到达即刻推入 ExoPlayer 硬件解码器，彻底消灭首片等待时延；
     * 同时流式写入内存环形池 (mCachePool)，供后续回退/复用 0ms 秒开。
     */
    private fun streamAndCacheSegment(os: OutputStream, segmentUrl: String): Boolean {
        var redirects = 0
        var curUrl = segmentUrl

        while (redirects < 5) {
            var conn: HttpURLConnection? = null
            try {
                val url = URL(curUrl)
                conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "GET"
                conn.connectTimeout = 3500
                conn.readTimeout = 8000
                conn.instanceFollowRedirects = false

                // 注入解密自咕噜咕噜官方库的白名单 UA 伪装，突破防盗链与 QoS 恶意限速
                conn.setRequestProperty("User-Agent", getRandomWhitelistUa())
                conn.setRequestProperty("Referer", "${url.protocol}://${url.host}/")
                conn.setRequestProperty("Accept", "*/*")
                conn.setRequestProperty("Connection", "keep-alive")

                val code = conn.responseCode
                if (code == HttpURLConnection.HTTP_MOVED_PERM || code == HttpURLConnection.HTTP_MOVED_TEMP ||
                    code == 307 || code == 308) {
                    val loc = conn.getHeaderField("Location")
                    if (!loc.isNullOrEmpty()) {
                        curUrl = resolveUrl(curUrl, loc)
                        redirects++
                        conn.disconnect()
                        continue
                    }
                }

                if (code in 200..399) {
                    val contentLength = conn.contentLengthLong
                    val remoteContentType = conn.contentType
                    val contentType = if (!remoteContentType.isNullOrEmpty() && !remoteContentType.contains("text/html")) {
                        remoteContentType
                    } else if (curUrl.lowercase().contains(".mp4") || curUrl.lowercase().contains(".m4s")) {
                        "video/mp4"
                    } else {
                        "video/MP2T"
                    }

                    // 1. 立即向客户端写入 HTTP 200 响应头并 flush，ExoPlayer 管道立即激活！
                    val headerBuilder = StringBuilder()
                    headerBuilder.append("HTTP/1.1 200 OK\r\n")
                    headerBuilder.append("Content-Type: ").append(contentType).append("\r\n")
                    if (contentLength > 0) {
                        headerBuilder.append("Content-Length: ").append(contentLength).append("\r\n")
                    }
                    headerBuilder.append("Access-Control-Allow-Origin: *\r\n")
                    headerBuilder.append("Connection: close\r\n\r\n")

                    os.write(headerBuilder.toString().toByteArray(StandardCharsets.UTF_8))
                    os.flush()

                    // 2. 边下边推：32KB 管道缓冲区，首包到达即出画面，同时收集进缓存池
                    val inStream = conn.inputStream
                    val bos = ByteArrayOutputStream(if (contentLength in 1..8_000_000) contentLength.toInt() else 65536)
                    val buffer = ByteArray(32768) // 32KB 极速吞吐缓冲区
                    var bytesRead: Int
                    var totalRead = 0L

                    inStream.use { input ->
                        while (input.read(buffer).also { bytesRead = it } != -1) {
                            os.write(buffer, 0, bytesRead)
                            os.flush() // 立即推送给播放器内核
                            if (totalRead + bytesRead <= 12 * 1024 * 1024) { // 单片不超过 12MB 存入缓存
                                bos.write(buffer, 0, bytesRead)
                            }
                            totalRead += bytesRead
                        }
                    }

                    // 3. 完整下载后推入 32MB 内存切片池
                    val fullBytes = bos.toByteArray()
                    if (fullBytes.isNotEmpty() && (contentLength <= 0 || totalRead >= contentLength)) {
                        mCachePool.put(segmentUrl, fullBytes)
                    }
                    return true
                }
                return false
            } catch (_: Exception) {
                return false
            } finally {
                try {
                    conn?.disconnect()
                } catch (_: Exception) {}
            }
        }
        return false
    }

    private fun sendSegmentResponse(os: OutputStream, data: ByteArray, url: String) {
        val contentType = if (url.lowercase().contains(".mp4") || url.lowercase().contains(".m4s")) {
            "video/mp4"
        } else {
            "video/MP2T"
        }
        val header = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: $contentType\r\n" +
                "Content-Length: ${data.size}\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Connection: close\r\n\r\n"
        os.write(header.toByteArray(StandardCharsets.UTF_8))
        os.write(data)
        os.flush()
    }

    private fun sendRedirect(os: OutputStream, targetUrl: String) {
        val header = "HTTP/1.1 302 Found\r\n" +
                "Location: $targetUrl\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Connection: close\r\n\r\n"
        os.write(header.toByteArray(StandardCharsets.UTF_8))
        os.flush()
    }

    private fun triggerPreload(playlistUrl: String, startIdx: Int, count: Int) {
        val list = mPlaylistSegments[playlistUrl] ?: return
        if (list.isEmpty()) return

        val end = minOf(startIdx + count, list.size)
        for (i in startIdx until end) {
            val segUrl = list[i]
            if (mCachePool.contains(segUrl)) continue

            mPreloadExecutor.execute {
                if (mCachePool.contains(segUrl)) return@execute
                try {
                    val data = fetchBytes(segUrl, 5000)
                    if (data != null && data.isNotEmpty()) {
                        mCachePool.put(segUrl, data)
                    }
                } catch (_: Exception) {}
            }
        }
    }

    private fun resolveUrl(baseUrl: String, relativeUrl: String): String {
        return try {
            URL(URL(baseUrl), relativeUrl).toString()
        } catch (_: Exception) {
            if (relativeUrl.startsWith("http://") || relativeUrl.startsWith("https://")) {
                relativeUrl
            } else if (relativeUrl.startsWith("/")) {
                val u = Uri.parse(baseUrl)
                u.scheme + "://" + u.authority + relativeUrl
            } else {
                val lastSlash = baseUrl.lastIndexOf('/')
                if (lastSlash != -1) {
                    baseUrl.substring(0, lastSlash + 1) + relativeUrl
                } else {
                    "$baseUrl/$relativeUrl"
                }
            }
        }
    }

    private fun fetchBytes(urlString: String, timeout: Int): ByteArray? {
        var redirects = 0
        var curUrl = urlString

        while (redirects < 5) {
            try {
                val url = URL(curUrl)
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "GET"
                conn.connectTimeout = timeout
                conn.readTimeout = timeout * 2
                conn.instanceFollowRedirects = false

                // 统一注入白名单 UA 伪装库
                conn.setRequestProperty("User-Agent", getRandomWhitelistUa())
                conn.setRequestProperty("Referer", "${url.protocol}://${url.host}/")
                conn.setRequestProperty("Connection", "keep-alive")

                val code = conn.responseCode
                if (code == HttpURLConnection.HTTP_MOVED_PERM || code == HttpURLConnection.HTTP_MOVED_TEMP ||
                    code == 307 || code == 308) {
                    val loc = conn.getHeaderField("Location")
                    if (!loc.isNullOrEmpty()) {
                        curUrl = resolveUrl(curUrl, loc)
                        redirects++
                        conn.disconnect()
                        continue
                    }
                }

                if (code in 200..399) {
                    conn.inputStream.use { inStream ->
                        ByteArrayOutputStream().use { bos ->
                            val buf = ByteArray(16384)
                            var r: Int
                            while (inStream.read(buf).also { r = it } != -1) {
                                bos.write(buf, 0, r)
                            }
                            return bos.toByteArray()
                        }
                    }
                }
                return null
            } catch (_: Exception) {
                return null
            }
        }
        return null
    }

    private class SegmentCachePool(private val mMaxSizeBytes: Int) {
        private var mCurrentSizeBytes = 0
        private val mMap = LinkedHashMap<String, ByteArray>(32, 0.75f, true)

        @Synchronized
        fun contains(key: String): Boolean = mMap.containsKey(key)

        @Synchronized
        fun get(key: String): ByteArray? = mMap[key]

        @Synchronized
        fun put(key: String, data: ByteArray?) {
            if (data == null || data.size > mMaxSizeBytes) return
            if (mMap.containsKey(key)) {
                val old = mMap.remove(key)
                if (old != null) mCurrentSizeBytes -= old.size
            }
            while (mCurrentSizeBytes + data.size > mMaxSizeBytes && mMap.isNotEmpty()) {
                val oldest = mMap.entries.iterator().next()
                mCurrentSizeBytes -= oldest.value.size
                mMap.remove(oldest.key)
            }
            mMap[key] = data
            mCurrentSizeBytes += data.size
        }

        @Synchronized
        fun clear() {
            mMap.clear()
            mCurrentSizeBytes = 0
        }
    }
}
