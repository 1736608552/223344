// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.hongguo

import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.Closeable
import java.io.IOException

/**
 * 红果短剧单路流式网络传输与透明解密控制器 (借鉴 hongguoTV 原生架构)
 * 采用纯内存 HTTP Range 切片拉取 + moov 盒子透明修复 + AES-128-CTR 分段解密，
 * 绝不开启本地 HTTP Socket 代理，杜绝机顶盒端口冲突与多路死锁。
 */
class HongguoRemoteVideo(
    private val http: OkHttpClient,
    val url: String,
    val key: ByteArray?,
    private val headers: Map<String, String>? = null,
) : Closeable {

    @Volatile
    private var closed = false
    private val calls = mutableSetOf<Call>()

    data class Range(val bytes: ByteArray, val total: Long)

    var total: Long = 0
        private set

    private lateinit var prepared: MediaCrypto.Prepared

    @Volatile
    private var prefix = byteArrayOf()

    @Volatile
    private var isPrepared = false

    private fun range(start: Long, end: Long): Range {
        if (closed) throw IOException("短剧播放请求已取消")
        require(start >= 0 && end >= start && end - start < 8 * 1024 * 1024) { "请求切片范围异常: $start-$end" }

        val requestBuilder = Request.Builder()
            .url(url)
            .header("User-Agent", headers?.get("User-Agent") ?: VendorConstants.VIDEO_UA)
            .header("Referer", headers?.get("Referer") ?: "https://novel.snssdk.com/")
            .header("Range", "bytes=$start-$end")
            .header("Accept-Encoding", "identity")

        headers?.forEach { (k, v) ->
            if (k !in listOf("User-Agent", "Referer", "Range", "Accept-Encoding")) {
                requestBuilder.header(k, v)
            }
        }

        val request = requestBuilder.build()
        val call = http.newCall(request)
        synchronized(calls) {
            if (closed) throw IOException("短剧播放请求已取消")
            calls += call
        }

        try {
            val response = call.execute()
            response.use { resp ->
                if (resp.code != 206 && resp.code != 200) {
                    throw IOException("视频服务器不支持分段读取（HTTP ${resp.code}）")
                }
                val contentRange = resp.header("Content-Range").orEmpty()
                val match = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(contentRange)
                val full = if (match != null) {
                    val (begin, finish, size) = match.destructured
                    val f = size.toLong()
                    val last = minOf(end, f - 1)
                    if (begin.toLong() != start || finish.toLong() != last || f <= 0) {
                        throw IOException("视频分段范围不匹配: $contentRange, expected $start-$end")
                    }
                    f
                } else {
                    val cl = resp.body?.contentLength() ?: -1L
                    if (cl > 0 && start == 0L) cl else if (total > 0L) total else throw IOException("视频分段缺少 Content-Range")
                }

                if (total != 0L && full != total) {
                    throw IOException("视频资源大小变化，请重新加载")
                }

                val body = resp.body ?: throw IOException("视频分段内容为空")
                val n = (minOf(end, full - 1) - start + 1).toInt()
                val bytes = body.source().readByteArray(n.toLong())
                return Range(bytes, full)
            }
        } finally {
            synchronized(calls) { calls -= call }
        }
    }

    companion object {
        private const val CHUNK_SIZE = 2 * 1024 * 1024 // 2MB 高性能滑动缓冲块
    }

    private class DecryptedChunk(
        val start: Long,
        val data: ByteArray,
    ) {
        val end: Long get() = start + data.size
        fun contains(reqStart: Long, reqEnd: Long): Boolean =
            reqStart >= start && reqEnd <= end
    }

    @Volatile
    private var decryptedPrefix = byteArrayOf()

    @Volatile
    private var currentChunk: DecryptedChunk? = null

    @Synchronized
    fun prepare(): HongguoRemoteVideo {
        if (isPrepared) return this
        val first = range(0, 256 * 1024 - 1)
        total = first.total
        prefix = first.bytes
        val end = MediaCrypto.headerEnd(first.bytes, total)
        val header = if (end > first.bytes.size) {
            first.bytes + range(first.bytes.size.toLong(), end - 1L).bytes
        } else {
            first.bytes.copyOf(end)
        }
        prepared = MediaCrypto.prepare(header, key)
        if (prepared.samples.any { it.end > total }) {
            throw IOException("视频样本超出资源大小")
        }
        // 预解密头部首段（包含 ftyp/moov 及起始样本），首帧直接从内存拷贝，毫秒级起播
        decryptedPrefix = MediaCrypto.decrypt(prefix, 0L, key, prepared)
        isPrepared = true
        return this
    }

    /**
     * 预热前 1MB 数据，提升起播与首帧速度
     */
    @Synchronized
    fun warm(): HongguoRemoteVideo {
        prepare()
        val size = minOf(total, 1024 * 1024L).toInt()
        if (prefix.size < size) {
            prefix = prefix + range(prefix.size.toLong(), size - 1L).bytes
            decryptedPrefix = MediaCrypto.decrypt(prefix, 0L, key, prepared)
        }
        return this
    }

    /**
     * 高速流式数据读取：双级高速内存缓存（头部常驻 + 2MB 滑动窗口），99% 请求零网络与零加解密瞬时返回
     */
    fun read(start: Long, length: Int): ByteArray {
        require(length in 1..8 * 1024 * 1024 && start >= 0)
        if (closed) throw IOException("短剧播放请求已取消")
        if (start >= total) return byteArrayOf()
        val reqEnd = minOf(total, start + length)
        val reqLen = (reqEnd - start).toInt()

        // 1. 优先命中常驻内存的已解密头部数据
        val pref = decryptedPrefix
        if (start < pref.size) {
            if (reqEnd <= pref.size) {
                return pref.copyOfRange(start.toInt(), reqEnd.toInt())
            }
        }

        // 2. 检查 2MB 滑动窗口缓存，命中则零 IO、零解密瞬时返回
        val chunk = currentChunk
        if (chunk != null && chunk.contains(start, reqEnd)) {
            val offsetInChunk = (start - chunk.start).toInt()
            return chunk.data.copyOfRange(offsetInChunk, offsetInChunk + reqLen)
        }

        // 3. 缓存未命中（顺序跨块或拖动 Seek）：拉取 2MB 大块并解密存入高速缓存
        synchronized(this) {
            if (closed) throw IOException("短剧播放请求已取消")
            // 双重校验锁（DCL）
            val doubleCheckChunk = currentChunk
            if (doubleCheckChunk != null && doubleCheckChunk.contains(start, reqEnd)) {
                val offsetInChunk = (start - doubleCheckChunk.start).toInt()
                return doubleCheckChunk.data.copyOfRange(offsetInChunk, offsetInChunk + reqLen)
            }

            val pullStart = start
            val pullLen = maxOf(CHUNK_SIZE.toLong(), reqEnd - pullStart)
            val pullEnd = minOf(total, pullStart + pullLen)
            val raw = range(pullStart, pullEnd - 1).bytes
            val decrypted = MediaCrypto.decrypt(raw, pullStart, key, prepared)
            val newChunk = DecryptedChunk(pullStart, decrypted)
            currentChunk = newChunk

            val returnLen = minOf(reqLen, decrypted.size)
            return decrypted.copyOfRange(0, returnLen)
        }
    }

    override fun close() {
        synchronized(calls) {
            closed = true
            calls.toList().forEach { runCatching { it.cancel() } }
            calls.clear()
            currentChunk = null
            decryptedPrefix = byteArrayOf()
            prefix = byteArrayOf()
        }
    }
}
