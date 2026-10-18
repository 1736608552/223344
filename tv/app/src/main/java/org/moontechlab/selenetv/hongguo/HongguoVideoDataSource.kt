// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.hongguo

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import java.io.EOFException
import java.io.IOException

/**
 * 供 ExoPlayer / Media3 原生硬解消费的短剧 DataSource 适配器 (借鉴 hongguoTV 原生架构)
 * 将经过 HongguoRemoteVideo 透明解密与容器修复的标准 MP4 字节流直接喂给 ExoPlayer，
 * 触发机顶盒底层最高优先级的 MediaCodec 原生硬件加速，彻底终结卡顿、音画失步与黑屏问题。
 */
@UnstableApi
class HongguoVideoDataSource(
    private val video: HongguoRemoteVideo,
) : BaseDataSource(/* isNetwork = */ true) {

    private var position = 0L
    private var remaining = 0L
    private var buffer = byteArrayOf()
    private var offset = 0
    private var opened = false
    private var uri: Uri? = null

    override fun open(spec: DataSpec): Long {
        transferInitializing(spec)
        uri = spec.uri
        position = spec.position

        // 在 ExoPlayer 后台加载线程中执行首段拉取与 moov 索引解析
        video.prepare()

        if (position > video.total) {
            throw IOException("读取位置超出视频长度: position=$position, total=${video.total}")
        }

        remaining = if (spec.length == C.LENGTH_UNSET.toLong()) {
            video.total - position
        } else {
            minOf(spec.length, video.total - position)
        }

        buffer = byteArrayOf()
        offset = 0
        opened = true
        transferStarted(spec)
        return remaining
    }

    override fun read(target: ByteArray, targetOffset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT

        if (offset >= buffer.size) {
            val toRead = minOf(1024 * 1024L, remaining).toInt()
            buffer = video.read(position, toRead)
            offset = 0
        }

        if (buffer.isEmpty()) {
            throw EOFException("视频数据分段意外结束")
        }

        val count = minOf(length, buffer.size - offset, remaining.toInt())
        buffer.copyInto(target, targetOffset, offset, offset + count)
        offset += count
        position += count
        remaining -= count
        bytesTransferred(count)
        return count
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        buffer = byteArrayOf()
        uri = null
        if (opened) {
            opened = false
            transferEnded()
        }
    }

    class Factory(
        private val video: HongguoRemoteVideo,
    ) : DataSource.Factory {
        override fun createDataSource(): DataSource = HongguoVideoDataSource(video)
    }
}
