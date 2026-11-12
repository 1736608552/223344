// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.hongguo

import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.Closeable
import java.io.IOException

/** One playback stream. No listening socket or local HTTP service. */
class RemoteVideo(private val http: OkHttpClient, val info: StreamInfo): Closeable {
    @Volatile private var closed = false
    private val calls = mutableSetOf<Call>()
    data class Range(val bytes: ByteArray, val total: Long)
    var total: Long = 0; private set
    private lateinit var prepared: MediaCrypto.Prepared
    @Volatile private var prefix = byteArrayOf()

    private fun range(start: Long, end: Long): Range {
        if (closed) throw IOException("播放请求已取消")
        require(start >= 0 && end >= start && end - start < 8 * 1024 * 1024)
        val request = Request.Builder()
            .url(info.url)
            .header("User-Agent", VendorConstants.VIDEO_UA)
            .header("Referer", "https://novel.snssdk.com/")
            .header("Range", "bytes=$start-$end")
            .header("Accept-Encoding", "identity")
            .build()
        val call = http.newCall(request)
        synchronized(calls) { if (closed) throw IOException("播放请求已取消"); calls += call }
        try {
            return RequestScope.execute(call) { response ->
                if (response.code != 206 && response.code != 200) throw IOException("视频服务器不支持分段读取（HTTP ${response.code}）")
                val contentRange = response.header("Content-Range").orEmpty()
                val match = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(contentRange)
                val full = if (match != null) {
                    val (begin, finish, size) = match.destructured
                    val f = size.toLong()
                    val last = minOf(end, f - 1)
                    if (begin.toLong() != start || finish.toLong() != last || f <= 0) throw IOException("视频分段范围不匹配")
                    f
                } else {
                    val cl = response.body?.contentLength() ?: -1L
                    if (cl > 0 && start == 0L) cl else if (total > 0L) total else throw IOException("视频分段响应异常")
                }
                if (total != 0L && full != total) throw IOException("视频资源已变化，请重试")
                val last = minOf(end, full - 1)
                val n = (last - start + 1).toInt()
                val body = response.body ?: throw IOException("视频分段为空")
                val bytes = body.source().readByteArray(n.toLong())
                Range(bytes, full)
            }
        } finally { synchronized(calls) { calls -= call } }
    }

    @Synchronized fun prepare(): RemoteVideo {
        if (::prepared.isInitialized) return this
        val first = range(0, 256 * 1024 - 1); total = first.total
        prefix = first.bytes
        val end = MediaCrypto.headerEnd(first.bytes, total)
        val header = if (end > first.bytes.size) {
            (first.bytes + range(first.bytes.size.toLong(), end - 1L).bytes).also { prefix = it }
        } else {
            first.bytes.copyOf(end)
        }
        prepared = MediaCrypto.prepare(header, info.key)
        if (prepared.samples.any { it.end > total }) throw IOException("视频样本超出资源大小")
        return this
    }

    /** Bounded warm-up. Retains raw bytes so decryption still uses the absolute sample offset. */
    @Synchronized fun warm(): RemoteVideo {
        prepare()
        val size = minOf(total, 1024 * 1024L).toInt()
        if (prefix.size < size) prefix = prefix + range(prefix.size.toLong(), size - 1L).bytes
        return this
    }

    fun read(start: Long, length: Int): ByteArray {
        require(length in 1..8 * 1024 * 1024 && start >= 0)
        if (closed) throw IOException("播放请求已取消")
        if (start >= total) return byteArrayOf()
        val cached = prefix; val end = minOf(total, start + length)
        val available = (minOf(end, cached.size.toLong()) - start).coerceAtLeast(0).toInt()
        val first = if (available > 0) cached.copyOfRange(start.toInt(), start.toInt() + available) else byteArrayOf()
        val raw = if (start + available < end) first + range(start + available, end - 1).bytes else first
        return MediaCrypto.decrypt(raw, start, info.key, prepared)
    }

    override fun close() { synchronized(calls) { closed = true; calls.toList().forEach { it.cancel() }; calls.clear() } }
}
