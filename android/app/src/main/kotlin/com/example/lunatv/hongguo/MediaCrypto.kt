// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.lunatv.hongguo

object MediaCrypto {
    fun deriveKey(value: String): ByteArray {
        val raw = decode64(value)
        require(raw.size >= 3) { "内容密钥格式异常" }
        val length = minOf(raw.size - (raw[0].u() xor raw[1].u() xor raw[2].u()) + 47, raw.size - 1)
        require(length >= 33)
        val work = raw.copyOfRange(1, 1 + length)
        var a = 85
        var b = 246
        for (i in work.indices) {
            val old = work[i].u()
            val previous = if (i and 1 != 0) a else b
            if (i and 1 != 0) a = old else b = old
            work[i] = (-21 - Integer.bitCount(i) + (previous xor old)).toByte()
        }
        return hex(String(work.copyOfRange(1, 33), Charsets.US_ASCII)).also { require(it.size == 16) }
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
}
