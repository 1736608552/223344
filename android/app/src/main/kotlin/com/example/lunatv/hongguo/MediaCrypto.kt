// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.lunatv.hongguo

import java.io.IOException
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 红果短剧容器解析与透明解密核心 (借鉴 hongguoTV 原生架构)
 * 能够将带有 CENC 加密的 MP4 容器在内存中还原为标准普通的 MP4 (消除 sinf, 还原 encv/enca)，
 * 并对分段音视频 sample 数据做 AES-128-CTR 解密，实现 MediaCodec 硬件加速零拷贝播放。
 */
object MediaCrypto {
    data class Sample(val start: Long, val end: Long, val iv: ByteArray, val encryptedOffset: Long = 0)
    data class Prepared(
        val header: ByteArray,
        val samples: List<Sample>,
        val secretKey: SecretKeySpec? = null,
    )

    fun deriveKey(value: String): ByteArray {
        val hexStr = deriveKeyHex(value)
        require(hexStr.isNotEmpty()) { "内容密钥解析失败" }
        return hex(hexStr)
    }

    /**
     * 稳健解析密钥字节（支持原始 base64 token 或 32 字符 hex 密钥）
     */
    fun resolveKeyBytes(keyStrOrHex: String): ByteArray? {
        val clean = keyStrOrHex.trim()
        if (clean.isEmpty()) return null
        if (clean.length == 32 && clean.matches(Regex("^[0-9a-fA-F]{32}$"))) {
            return try {
                hex(clean)
            } catch (_: Throwable) {
                null
            }
        }
        return try {
            deriveKey(clean)
        } catch (_: Throwable) {
            null
        }
    }

    fun deriveKeyHex(value: String): String {
        val clean = value.trim()
        if (clean.isEmpty()) return ""
        val raw = try {
            decode64(clean)
        } catch (_: Exception) {
            return ""
        }
        if (raw.size < 3) return ""

        // 尝试主派生算法 (对齐官方标准实现)
        try {
            val length = minOf(raw.size - (raw[0].u() xor raw[1].u() xor raw[2].u()) + 47, raw.size - 1)
            if (length >= 33) {
                val work = raw.copyOfRange(1, 1 + length)
                var a = 85
                var b = 246
                for (i in work.indices) {
                    val old = work[i].u()
                    val previous = if (i and 1 != 0) a else b
                    if (i and 1 != 0) a = old else b = old
                    work[i] = (-21 - Integer.bitCount(i) + (previous xor old)).toByte()
                }
                val hexCandidate = String(work.copyOfRange(1, 33), Charsets.US_ASCII)
                if (hexCandidate.matches(Regex("^[0-9a-fA-F]{32}$"))) {
                    return hexCandidate.lowercase()
                }
            }
        } catch (_: Exception) {}

        // 尝试备用派生算法 (变体兼容)
        try {
            val tagLen = (raw[0].u() xor raw[1].u() xor raw[2].u()) - 48
            val contentLen = raw.size - tagLen - 1
            if (tagLen in 1 until raw.size && contentLen >= 33) {
                val decoded = ByteArray(contentLen)
                var prevEven = 250
                var prevOdd = 85
                for (i in 0 until contentLen) {
                    val cur = raw[1 + i].u()
                    val prev = if (i % 2 == 0) prevEven else prevOdd
                    if (i % 2 == 0) prevEven = cur else prevOdd = cur
                    decoded[i] = ((prev xor cur) - 21 - Integer.bitCount(i)).toByte()
                }
                val hexCandidate = String(decoded.copyOfRange(1, 33), Charsets.US_ASCII)
                if (hexCandidate.matches(Regex("^[0-9a-fA-F]{32}$"))) {
                    return hexCandidate.lowercase()
                }
            }
        } catch (_: Exception) {}

        return ""
    }

    fun decryptUrl(value: String, seed: ByteArray): String {
        val raw = decode64(value)
        require(raw.size >= 20 && raw[0].u() == 0xa8 && raw[2].u() == 1 && raw[3].u() == 0)
        val constants = hex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
        val h = digest("SHA-512", digest("SHA-512", seed) + constants)
        val bytes = aes("CBC", h.copyOfRange(0, 16), h.copyOfRange(16, 32), raw.copyOfRange(4, 4 + (raw.size - 4) / 16 * 16))
        var end = bytes.size
        val padding = bytes.last().u()
        if (padding in 1..16 && padding <= end) end -= padding
        while (end > 0 && bytes[end - 1].u() == 0) end--
        return String(bytes, 0, end, Charsets.UTF_8)
    }

    private data class Box(val start: Int, val end: Int, val body: Int, val type: String)

    private fun box(data: ByteArray, at: Int, limit: Int = data.size): Box? {
        if (at < 0 || at + 8 > limit) return null
        var size = data.u32(at)
        var header = 8
        if (size == 1L) {
            if (at + 16 > limit) return null
            size = data.i64(at + 8)
            header = 16
        }
        if (size == 0L) size = (limit - at).toLong()
        if (size < header || size > limit - at) return null
        return Box(at, at + size.toInt(), at + header, String(data, at + 4, 4, Charsets.US_ASCII))
    }

    private fun find(data: ByteArray, type: String, start: Int, limit: Int): Box? {
        for (at in start..limit - 8) {
            if (data[at + 4].toInt() == type[0].code) {
                val b = box(data, at, limit)
                if (b?.type == type) return b
            }
        }
        return null
    }

    fun headerEnd(first: ByteArray, total: Long): Int {
        if (first.size < 16 || String(first, 4, 4, Charsets.US_ASCII) != "ftyp") throw IOException("不支持的视频容器")
        val ftyp = first.u32(0)
        if (ftyp < 8 || ftyp + 8 > first.size || String(first, ftyp.toInt() + 4, 4, Charsets.US_ASCII) != "moov") throw IOException("视频索引不在文件开头")
        val size = first.u32(ftyp.toInt())
        val end = ftyp + size
        if (size < 8 || end > total || end > 8 * 1024 * 1024) throw IOException("视频索引大小异常")
        return end.toInt()
    }

    fun prepare(data: ByteArray, key: ByteArray?): Prepared {
        if (key == null) return Prepared(data.copyOf(), emptyList())
        val moov = box(data, data.u32(0).toInt()) ?: throw IOException("视频索引不完整")
        require(moov.type == "moov")
        val samples = mutableListOf<Sample>()
        val header = data.copyOf()
        var cursor = moov.body
        while (cursor < moov.end) {
            val track = box(data, cursor, moov.end) ?: throw IOException("视频轨道格式异常")
            cursor = track.end
            if (track.type != "trak") continue
            val stbl = find(data, "stbl", track.body, track.end) ?: continue
            val saiz = find(data, "saiz", stbl.body, stbl.end) ?: continue
            val saio = find(data, "saio", stbl.body, stbl.end) ?: throw IOException("视频加密索引缺失")
            val stsz = find(data, "stsz", stbl.body, stbl.end) ?: throw IOException("样本索引缺失")
            val stsc = find(data, "stsc", stbl.body, stbl.end) ?: throw IOException("块索引缺失")
            val chunks = find(data, "stco", stbl.body, stbl.end) ?: find(data, "co64", stbl.body, stbl.end) ?: throw IOException("块偏移缺失")
            fun count(at: Int, limit: Int): Int {
                if (at + 4 > limit) throw IOException("索引越界")
                return data.u32(at).also { if (it > 200000) throw IOException("索引数量过大") }.toInt()
            }
            val n = count(stsz.body + 8, stsz.end)
            val defaultSize = data.u32(stsz.body + 4)
            if (defaultSize == 0L && stsz.body + 12 + n.toLong() * 4 > stsz.end) throw IOException("样本索引截断")
            val sizes = LongArray(n) { if (defaultSize > 0) defaultSize else data.u32(stsz.body + 12 + it * 4) }
            val chunkCount = count(chunks.body + 4, chunks.end)
            val width = if (chunks.type == "co64") 8 else 4
            if (chunks.body + 8 + chunkCount.toLong() * width > chunks.end) throw IOException("块偏移截断")
            val offsets = LongArray(chunkCount) { if (width == 8) data.i64(chunks.body + 8 + it * width) else data.u32(chunks.body + 8 + it * width) }
            val entryCount = count(stsc.body + 4, stsc.end)
            if (stsc.body + 8 + entryCount.toLong() * 12 > stsc.end || entryCount == 0) throw IOException("块索引截断")
            val entries = (0 until entryCount).map { data.u32(stsc.body + 8 + it * 12) to data.u32(stsc.body + 12 + it * 12) }
            // ISO BMFF auxiliary-info
            val sizeBase = saiz.body + 4 + (if (data.i32(saiz.body) and 1 != 0) 8 else 0)
            if (sizeBase + 5 > saiz.end) throw IOException("辅助索引截断")
            val auxDefault = data[sizeBase].u()
            val auxCount = count(sizeBase + 1, saiz.end)
            if (auxCount != n || (auxDefault == 0 && sizeBase + 5 + n > saiz.end)) throw IOException("辅助索引数量不一致")
            val auxSizes = IntArray(n) { if (auxDefault > 0) auxDefault else data[sizeBase + 5 + it].u() }
            val offsetBase = saio.body + 4 + (if (data.i32(saio.body) and 1 != 0) 8 else 0)
            val offsetWidth = if (data[saio.body].u() == 1) 8 else 4
            if (count(offsetBase, saio.end) != 1 || offsetBase + 4 + offsetWidth > saio.end) throw IOException("不支持的辅助索引布局")
            var aux = if (offsetWidth == 8) data.i64(offsetBase + 4) else data.u32(offsetBase + 4)
            val auxEnd = aux + auxSizes.sumOf { it.toLong() }
            if (aux < 0 || auxEnd > data.size) throw IOException("辅助数据超出索引范围")
            var sampleIndex = 0
            var entry = 0
            for (chunk in offsets.indices) {
                while (entry + 1 < entries.size && entries[entry + 1].first <= chunk + 1) entry++
                val count = entries[entry].second
                if (count > n - sampleIndex || entries[entry].first > chunk + 1) throw IOException("样本与块数量不一致")
                var position = offsets[chunk]
                repeat(count.toInt()) {
                    val length = sizes[sampleIndex]
                    val auxSize = auxSizes[sampleIndex]
                    if (position < 0 || length <= 0 || position > Long.MAX_VALUE - length || auxSize < 8) throw IOException("样本索引异常")
                    val iv = data.copyOfRange(aux.toInt(), aux.toInt() + 8) + ByteArray(8)
                    if (auxSize == 8) {
                        samples += Sample(position, position + length, iv)
                    } else {
                        if (auxSize < 10) throw IOException("不支持的加密样本格式")
                        val subs = (data[aux.toInt() + 8].u() shl 8) or data[aux.toInt() + 9].u()
                        if (auxSize != 10 + subs * 6) throw IOException("加密子样本索引异常")
                        var offset = position
                        var encrypted = 0L
                        for (sub in 0 until subs) {
                            val at = aux.toInt() + 10 + sub * 6
                            val clear = (data[at].u() shl 8) or data[at + 1].u()
                            val size = data.u32(at + 2)
                            offset += clear
                            if (offset + size > position + length) throw IOException("加密子样本越界")
                            if (size > 0) samples += Sample(offset, offset + size, iv, encrypted)
                            encrypted += size
                            offset += size
                        }
                        if (offset != position + length) throw IOException("加密子样本长度异常")
                    }
                    position += length
                    aux += auxSize
                    sampleIndex++
                }
            }
            if (sampleIndex != n) throw IOException("视频样本不完整")
            // 还原 frma 编码 (AVC 和 HEVC)，修复 encv/enca，消除 sinf 盒子为 free
            var at = stbl.body
            while (at + 8 <= stbl.end) {
                val sinf = find(data, "sinf", at, stbl.end) ?: break
                val frma = find(data, "frma", sinf.body, sinf.end) ?: throw IOException("原始编码格式缺失")
                if (frma.body + 4 > frma.end) throw IOException("原始编码格式无效")
                val original = data.copyOfRange(frma.body, frma.body + 4)
                var entryAt = sinf.start - 1
                while (entryAt >= stbl.body) {
                    val type = String(data, entryAt, 4, Charsets.US_ASCII)
                    if (type == "encv" || type == "enca") {
                        original.copyInto(header, entryAt)
                        break
                    }
                    entryAt--
                }
                "free".toByteArray().copyInto(header, sinf.start + 4)
                header.fill(0, sinf.body, sinf.end)
                at = sinf.end
            }
        }
        if (samples.isEmpty()) throw IOException("视频加密索引不可用")
        val sorted = samples.sortedBy { it.start }
        if (sorted.zipWithNext().any { (a, b) -> a.end > b.start }) throw IOException("视频样本重叠")
        val secretKey = key?.let { SecretKeySpec(it, "AES") }
        return Prepared(header, sorted, secretKey)
    }

    private val ctrCipherThreadLocal = object : ThreadLocal<Cipher?>() {
        override fun initialValue(): Cipher? {
            return try {
                Cipher.getInstance("AES/CTR/NoPadding")
            } catch (_: Throwable) {
                null
            }
        }
    }

    /**
     * 高性能无分配 128 位大端无符号进位递增计算（纳秒级，彻底消除 BigInteger 对象创建与 GC 抖动）
     */
    private fun computeCtrIv(baseIv: ByteArray, blockOffset: Long, outIv: ByteArray) {
        baseIv.copyInto(outIv, 0, 0, 16)
        if (blockOffset == 0L) return
        var carry = blockOffset
        for (i in 15 downTo 0) {
            val sum = (outIv[i].toLong() and 0xFFL) + (carry and 0xFFL)
            outIv[i] = sum.toByte()
            carry = (carry ushr 8) + (sum ushr 8)
            if (carry == 0L) break
        }
    }

    /**
     * 高吞吐透明解密引擎：稳健兼容全版本机顶盒底层，加固异常防护，杜绝闪退
     */
    fun decrypt(data: ByteArray, start: Long, key: ByteArray?, prepared: Prepared): ByteArray {
        require(start >= 0)
        val result = data.copyOf()
        val end = start + data.size
        if (start < prepared.header.size) {
            prepared.header.copyInto(result, 0, start.toInt(), minOf(end, prepared.header.size.toLong()).toInt())
        }
        if (key == null) return result
        val samples = prepared.samples
        var low = 0
        var high = samples.size
        while (low < high) {
            val middle = (low + high) ushr 1
            if (samples[middle].end <= start) low = middle + 1 else high = middle
        }
        if (low >= samples.size) return result

        val secretKey = prepared.secretKey ?: SecretKeySpec(key, "AES")
        val cipher = ctrCipherThreadLocal.get() ?: try {
            Cipher.getInstance("AES/CTR/NoPadding")
        } catch (_: Throwable) {
            return result
        }
        val ivBuffer = ByteArray(16)

        for (i in low until samples.size) {
            val sample = samples[i]
            if (sample.start >= end) break
            val begin = maxOf(start, sample.start)
            val stop = minOf(end, sample.end)
            if (begin >= stop) continue

            val relative = begin - sample.start + sample.encryptedOffset
            val skip = (relative % 16).toInt()
            val blockOffset = relative / 16

            val segStart = (begin - start).toInt()
            val segLen = (stop - begin).toInt()

            try {
                computeCtrIv(sample.iv, blockOffset, ivBuffer)
                val ivSpec = IvParameterSpec(ivBuffer)
                cipher.init(Cipher.DECRYPT_MODE, secretKey, ivSpec)

                if (skip == 0) {
                    val decrypted = cipher.doFinal(result, segStart, segLen)
                    decrypted.copyInto(result, segStart)
                } else {
                    val padded = ByteArray(skip + segLen)
                    result.copyInto(padded, skip, segStart, segStart + segLen)
                    val decrypted = cipher.doFinal(padded)
                    decrypted.copyInto(result, segStart, skip, skip + segLen)
                }
            } catch (e: Throwable) {
                // 防御性静默降级保护：记录日志，绝对不抛出致命异常导致播放器进程闪退
                android.util.Log.w("MediaCrypto", "Sample 解密跳过保护: offset=$begin, len=$segLen", e)
            }
        }
        return result
    }
}
