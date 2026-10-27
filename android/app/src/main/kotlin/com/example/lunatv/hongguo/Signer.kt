// Kotlin port of drpys 22261adfa31435e3b3ef5a730b8a2a75bcaf1715; GPL-3.0-only.
// Only hash branch 0 is emitted: adjust the request ticket before signing.
package org.moontechlab.lunatv.hongguo

import java.io.ByteArrayOutputStream
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class Signer(private val clock: () -> Long = System::currentTimeMillis, private val random: () -> Double = Math::random) {
    data class Request(val url: String, val headers: Map<String, String>, val body: ByteArray?)
    private fun rand() = (random() * 4294967296.0).toLong().toInt()
    private fun unsigned(v: Int) = v.toLong() and 0xffffffffL
    private fun varint(value: Long): ByteArray {
        var n = value
        return ByteArrayOutputStream().apply { while (n > 127) { write(((n and 127) or 128).toInt()); n = n ushr 7 }; write(n.toInt()) }.toByteArray()
    }
    private data class Field(val tag: Int, val value: Any, val type: String = "string")
    private fun f(tag: Int, value: Any, type: String = "string") = Field(tag, value, type)
    private fun proto(vararg fields: Field): ByteArray = ByteArrayOutputStream().apply {
        for ((tag, value, type) in fields) {
            when (type) {
                "sint" -> { val n = (value as Number).toLong(); write(varint(tag.toLong() shl 3)); write(varint(if (n < 0) -n * 2 - 1 else n * 2)) }
                "float" -> { write(varint((tag.toLong() shl 3) or 5)); write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat((value as Number).toFloat()).array()) }
                else -> { val bytes = if (value is ByteArray) value else value.toString().toByteArray(); if (bytes.isNotEmpty()) { write(varint((tag.toLong() shl 3) or 2)); write(varint(bytes.size.toLong())); write(bytes) } }
            }
        }
    }.toByteArray()
    private fun getIv(initial: Int, data: ByteArray): Int {
        var value = initial
        for (i in data.indices) value = if (i and 1 == 0) (value ushr 4) xor value xor (value shl 6) xor data[i].u() else ((value ushr 7) xor value xor (data[i].u() or (value shl 12))).inv()
        return value
    }
    private fun iv(query: ByteArray, body: ByteArray, ts: Int) = getIv(getIv(getIv(0x20230928, query), body), le32(ts))
    fun branch(query: String, body: ByteArray?, ts: Int): Int = (iv(sm3(query.toByteArray()), body?.let { digest("MD5", it) } ?: ByteArray(16), ts) and 15) % 3
    private fun sumMd5(data: ByteArray): Int {
        var check = 0x20220420
        for (i in 0 until 12) {
            val temp = (check ushr (if (i and 1 == 0) 3 else 5)) xor check
            check = if (i and 1 == 0) data[i].u() xor (check shl 7) else (data[i].u() or (check shl 11)).inv()
            check = check xor temp
        }
        return (check or 4) xor 0x1000000
    }
    fun hashF13(query: ByteArray, body: ByteArray, ts: Int): ByteArray {
        val index = (iv(query, body, ts) and 15) / 3
        require((iv(query, body, ts) and 15) % 3 == 0) { "Unsupported hash branch" }
        val ivV1 = intArrayOf(0xc4a78580.toInt(),0xb3c0fd39.toInt(),0xc58c5686.toInt(),0xc9aa3ba7.toInt(),0xf5a7adf2.toInt(),0x963c2ed1.toInt())[index]
        val count = ivV1 + ts
        val tt = VendorConstants.hashTable.map { ror(it, (count + 1) and 255) }
        val shift = (count + 2) and 7
        val pad = intArrayOf(0xfa,0x45,0x61,0xd7).map { ((it or (it shl 8)) shr shift).toByte() }.toByteArray()
        val data = query + body + le32(ts) + pad + hex("00000000000001a0")
        val di = (data.indices step 4).map { data.i32(it) }.toMutableList()
        for (i in 0 until 112) {
            val x = di[i + 1]; val y = di[i + 14]
            di.add(di[i] + di[i + 9] + (rol(x,14) xor rol(x,25) xor (x ushr 3)) + (rol(y,13) xor rol(y,15) xor (y ushr 10)))
        }
        val initial = intArrayOf(0x7aba4fc8,0x67166507,0x6403fa00,0x340f512f,984304912,3005047866L.toInt(),2874125293L.toInt(),2152413264L.toInt()).map { ror(it, count) }
        val chosen = arrayOf(intArrayOf(101,5,7,6,3,2,1,0,5,4,3),intArrayOf(96,0,6,7,5,3,2,1,5,4,4),intArrayOf(96,7,6,2,1,4,0,5,4,3,5),intArrayOf(99,3,6,2,4,5,1,0,0,7,6),intArrayOf(96,0,5,6,7,3,1,2,5,4,4),intArrayOf(100,2,0,3,5,4,6,7,2,1,5))[index]
        val d = initial.toMutableList()
        for (i in 0 until chosen[0]) {
            val base = ivV1 + i
            val n1 = ((d[chosen[3]] xor d[chosen[4]]) and d[chosen[1]]) xor d[chosen[3]]
            val n2 = rol(d[chosen[1]],26) xor rol(d[chosen[1]],21) xor rol(d[chosen[1]],7)
            val n4 = di[base and 127] + n1 + n2 + tt[base and 63] + d[chosen[5]]
            val n5 = rol(d[chosen[2]],30) xor rol(d[chosen[2]],19) xor rol(d[chosen[2]],10)
            val n6 = (d[chosen[2]] and d[chosen[6]]) or ((d[chosen[2]] or d[chosen[6]]) and d[chosen[7]])
            val old = d[chosen[9]]
            d.add(0,d.removeAt(7)); d[chosen[10]] = n5 + n6 + n4; d[chosen[8]] = old + n4
        }
        val ret = (0..7).fold(byteArrayOf()) { a, i -> a + be32(d[i] + initial[i]) }
        val folded = xor(ret.copyOfRange(0,16),ret.copyOfRange(16,32))
        return folded + le32(sumMd5(folded))
    }
    fun gorgon(query: String, body: ByteArray?, ts: Int, random: Int): String {
        val input = digest("MD5",query.toByteArray()).copyOf(4) + (body?.let { digest("MD5",it).copyOf(4) } ?: ByteArray(4)) + ByteArray(4) + le32(67503104) + be32(ts)
        val key = intArrayOf(0x4a,0x40,0x16,(random shr 8) and 255,0x47,0x6c,1,random and 255)
        val s = IntArray(256) { it }; var j = 0
        for (i in 0..255) { j = (j + s[i] + key[i % 8]) and 255; s[i] = s[j] }
        j = 0
        val out = ByteArray(input.size) { n -> val i = n + 1; j += s[i]; val y = s[j and 255]; s[i] = y; (input[n].u() xor s[(y + y) and 255]).toByte() }
        for (i in out.indices) {
            val value = ((out[i].u() shr 4) or (out[i].u() shl 4)) and 255
            val next = out[if (i + 1 < out.size) i + 1 else 0].u()
            val reversed = Integer.reverse((next xor value) and 255) ushr 24
            out[i] = (reversed xor 20).inv().toByte()
        }
        return (hex("8404") + byteArrayOf(random.toByte(),(random shr 8).toByte(),0x40,1) + out).hex()
    }
    private fun deviceProto() = proto(
        f(1, 1, "sint"),
        f(2, 2, "sint"),
        f(3, "8662"),
        f(4, VendorConstants.device.getValue("device_id")),
        f(5, VendorConstants.processNonce),
        f(6, "!noperm!"),
        f(7, -888888, "sint"),
        f(8, -888888, "sint"),
        f(9, 3, "sint"),
        f(10, -888888, "sint"),
        f(11, "!notset!"),
        f(12, "Asia/Shanghai,8"),
        f(13, "zh_CN"),
        f(14, 4, "sint"),
        f(16, 255.24993896484375, "float"),
        f(17, 35.58599090576172, "float"),
        f(18, 3.467449188232422, "float"),
        f(19, 3.467449188232422, "float"),
        f(20, 255.1754913330078, "float"),
        f(21, 42.17544174194336, "float"),
        f(22, "16"),
        f(23, 41, "sint"),
        f(24, 36, "sint"),
        f(25, VendorConstants.processStarted, "sint"),
        f(26, VendorConstants.processStarted, "sint"),
        f(27, VendorConstants.processStarted, "sint"),
        f(28, VendorConstants.processStarted + 2, "sint"),
        f(29, -1, "sint"),
        f(30, "25053RT47C"),
        f(31, "Redmi"),
        f(32, "25053RT47C"),
        f(33, "25053RT47C"),
        f(34, "Xiaomi"),
        f(35, "Redmi"),
        f(36, "Redmi"),
        f(38, 31, "sint")
    )
    private fun xmxor(data: ByteArray, key: ByteArray): ByteArray {
        val encoded = IntArray(data.size)
        for (i in data.indices) {
            val at = (i * 4) and 28; val d0 = key[at].u(); val d1 = key[at + 1].u(); val v = data[i].u()
            var d2 = (((v shl 4) or (v ushr 4)) and 255) + d0
            d2 = d2.inv() xor d1; d2 = (((d2 and 255) shl 3) or ((d2 and 255) ushr 5)) and 255
            d2 = (d2 + d1) and 255; d2 = (d2 xor d0) and 255; encoded[data.size-i-1] = d2.inv() and 255
        }
        val last = encoded.last() xor encoded[encoded.size-2]; val first = encoded[0]
        encoded[0] = (first - last - 1) and 255
        encoded[1] = (encoded[0] xor encoded.last() xor 254) + encoded[1] and 255
        encoded[2] = (encoded[2] + ((last - first) xor (((encoded[1] shl 3) or (encoded[1] ushr 5)) and 255) xor 2)) and 255
        for (i in 0 until encoded.size - 4) {
            val temp = (((encoded[i + 2] shl 3) or (encoded[i + 2] ushr 5)) and 255) xor encoded[i + 1] xor (i + 3)
            encoded[i + 3] = (encoded[i + 3] - temp - 1) and 255
        }
        encoded[encoded.size - 1] = encoded[encoded.size - 1] xor encoded[encoded.size - 2]
        var sum = 0
        for (i in 0 until encoded.size - 1) sum += encoded[i + 1]
        encoded[0] = ((encoded[0] xor encoded[1]) + sum) and 255
        return encoded.map { it.toByte() }.toByteArray()
    }
    fun medusa(query: String, body: ByteArray?, ts: Int, random: Int): String {
        val bodyMd5 = body?.let { digest("MD5", it) } ?: ByteArray(16)
        val querySm3 = sm3(query.toByteArray())
        val queryBodyTs = hashF13(querySm3, bodyMd5, ts)
        val env = proto(f(1,114,"sint"),f(2,146331399,"sint"),f(3,146331396,"sint"),f(5,7,"sint"),f(6,"v04.06.04.03-bugfix"),f(7,11309,"sint"),f(12,deviceProto(),"message"),f(13,proto(f(1,ts,"sint"),f(2,-2,"sint"),f(4,200,"sint")),"message"),f(14,VendorConstants.device.getValue("version_name")))
        val message = proto(f(1,hex("f7e85ffad7d7dc3bd62ac87057cf6118"),"bytes"),f(2,3,"sint"),f(3,rand(),"sint"),f(4,"8662"),f(5,VendorConstants.device.getValue("device_id")),f(6,"1588093228"),f(7,VendorConstants.device.getValue("version_name")),f(8,"v04.06.04-ml-android"),f(9,67503104,"sint"),f(10,hex("4001000000000000"),"bytes"),f(12,ts,"sint"),f(13,queryBodyTs,"bytes"),f(14,querySm3.copyOf(6),"bytes"),f(15,proto(f(1,111,"sint"),f(2,10,"sint"),f(3,694367,"sint"),f(5,586952199,"sint")),"message"),f(16,"AXYQOS6n2m60x1fVZHIrH3iol"),f(17,ts,"sint"),f(19,sm3(query.toByteArray() + bodyMd5 + "none".toByteArray()),"bytes"),f(20,"none"),f(21,312,"sint"),f(23,env,"message"),f(24,"{\"cmr\":16777216,\"cmr2\":16777216,\"un_h\":1879194040,\"vpn\":0,\"kd\":0,\"fkd\":3672518972,\"pd\":-1872573247,\"dyn\":\"\",\"do\":0,\"tk\":true}"))
        val signKey = hex("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
        val hash = sm3(signKey + le32(random) + signKey)
        val d1 = (random shr 16) and 255
        val seed = le32(((((d1 shl 11) or (random ushr 24)) xor (d1 shr 5) xor d1).inv()))
        val transformed = xor((hex("4001000000000000") + xmxor(message, hash)).reversedArray(), ByteArray(message.size + 8) { seed[(it.inv()) and 3] })
        val check = ((querySm3[0].u() and 63) shl 14) or 0x18000001 or ((queryBodyTs[0].u() and 63) shl 8)
        val packed = byteArrayOf(0x35) + le32(rand()) + le32(check) + transformed + byteArrayOf((random shr 16).toByte(),(random shr 24).toByte())
        val encrypted = AesV3(hex("f1593376766ea98d34f31b057a9d5be4"), ts).encrypt(packed, hex("1fe109a4125283f418de9e051a969e12"))
        val prefix = ByteArray(20).apply { for (i in 0..4) ByteBuffer.wrap(this, i * 4, 4).order(ByteOrder.LITTLE_ENDIAN).putInt((hex("03000000f7e85ffad7d7dc3bd62ac87057cf6118").i32(i * 4, true) xor ts)) }
        return (prefix + byteArrayOf((random and 255).toByte(), ((random shr 8) and 255).toByte(), 0, 1) + encrypted).base64()
    }
    fun helios(ts: Int): String {
        val random = rand()
        val ascii = digest("MD5", le32(random) + "8662".toByteArray()).hex().toByteArray(Charsets.US_ASCII)
        val words = (0 until 4).map { ByteBuffer.wrap(ascii, it * 8, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong() }.toMutableList()
        val table = mutableListOf(words[0])
        var b0 = words[0]; var b8 = words[1]; words.removeAt(0); words.removeAt(0)
        for (i in 0 until 34) {
            val x8 = ((b8.rotateRight(8) + b0) xor i.toULong())
            words.add(x8)
            val x8New = x8 xor b0.rotateRight(61)
            table.add(x8New)
            b0 = x8New; b8 = words.removeAt(0)
        }
        val text = "$ts-1588093228-8662".toByteArray()
        val pad = text.copyOf((text.size / 16 + 1) * 16).apply { fill((16 - text.size % 16).toByte(), text.size) }
        val output = ByteArrayOutputStream()
        for (at in pad.indices step 16) {
            var a = ByteBuffer.wrap(pad, at, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
            var b = ByteBuffer.wrap(pad, at + 8, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
            for (i in 0 until 34) {
                b = table[i] xor (a + b.rotateRight(8))
                a = b xor a.rotateRight(61)
            }
            output.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(a.toLong()).array())
            output.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(b.toLong()).array())
        }
        return (le32(random) + output.toByteArray()).base64()
    }
    fun signHongguo(queryString: String, body: ByteArray?, nowMs: Long): Map<String, String> {
        val ts = (nowMs / 1000).toInt()
        val queryHash = digest("MD5", queryString.toByteArray(Charsets.UTF_8))
        val payload = ByteArray(20)
        System.arraycopy(queryHash, 0, payload, 0, 4)
        var bodyStub = ""
        if (body != null && body.isNotEmpty()) {
            val bodyHash = digest("MD5", body)
            System.arraycopy(bodyHash, 0, payload, 4, 4)
            bodyStub = bodyHash.hex().uppercase()
        }
        payload[12] = 0
        payload[13] = 6
        payload[14] = 11
        payload[15] = 28
        val tsBytes = be32(ts)
        System.arraycopy(tsBytes, 0, payload, 16, 4)

        val key = intArrayOf(
            0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93,
            0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f
        )
        for (i in 0 until 20) {
            payload[i] = (payload[i].u() xor key[i]).toByte()
        }
        for (i in 0 until 20) {
            val cur = payload[i].u()
            val rot = ((cur shl 4) or (cur ushr 4)) and 0xff
            val mixed = rot xor payload[(i + 1) % 20].u()
            val rev = Integer.reverse(mixed) ushr 24
            payload[i] = (rev xor 0xff xor 20).toByte()
        }
        val prefix = byteArrayOf(0x84.toByte(), 0x04.toByte(), 0x40.toByte(), 0x1c.toByte(), 0, 0)
        val fullSig = prefix + payload
        val gorgonHex = fullSig.hex()

        val headers = mutableMapOf(
            "X-Khronos" to ts.toString(),
            "X-Gorgon" to gorgonHex,
            "X-SS-Req-Ticket" to nowMs.toString()
        )
        if (bodyStub.isNotEmpty()) {
            headers["X-SS-STUB"] = bodyStub
        }
        return headers
    }

    fun signStandard(base: String, values: Map<String, String>, body: ByteArray? = null): Request {
        val now = clock()
        val query = encode(values + mapOf("_rticket" to now.toString()))
        val signHeaders = signHongguo(query, body, now)
        val url = "$base?$query"
        val headers = linkedMapOf(
            "User-Agent" to (if (body != null) VendorConstants.VIDEO_UA else VendorConstants.APP_UA),
            "Accept" to "application/json",
            "Content-Type" to "application/json; charset=utf-8",
            "X-XS-From-Web" to "0",
            "Sdk-Version" to "2"
        )
        headers.putAll(signHeaders)
        return Request(url, headers, body)
    }

    fun sign(base: String, values: Map<String, String>, body: ByteArray? = null): Request {
        val now = clock()
        val ts = (now / 1000).toInt()
        var ticket = now
        var query = ""
        var found = false
        // 阶段 1: 0..127 递增偏移抖动锁定 Branch 0
        for (offset in 0..127) {
            ticket = now + offset
            query = encode(values + mapOf("ts" to ts.toString(), "_rticket" to ticket.toString()))
            if (branch(query, body, ts) == 0) {
                found = true
                break
            }
        }
        // 阶段 2: 极低概率兜底，随机抖动直到 100% 命中 Branch 0 (消除服务端拒签与Unsupported hash branch)
        if (!found) {
            for (retry in 0..255) {
                ticket = now + 128 + (random() * 20000).toLong()
                query = encode(values + mapOf("ts" to ts.toString(), "_rticket" to ticket.toString()))
                if (branch(query, body, ts) == 0) {
                    found = true
                    break
                }
            }
        }
        val random = (random() * 65536).toInt()
        val url = "$base?$query"
        val headers = linkedMapOf(
            "User-Agent" to (if (body != null) VendorConstants.VIDEO_UA else VendorConstants.APP_UA),
            "Accept" to "application/json; charset=utf-8,application/x-protobuf",
            "x-ss-req-ticket" to ticket.toString(),
            "x-tt-request-tag" to "t=0;n=0",
            "sdk-version" to "2",
            "passport-sdk-version" to "50561",
            "x-xs-from-web" to "0",
            "x-khronos" to ts.toString(),
            "x-ladon" to be32(ts).base64(),
            "x-argus" to le32(ts).base64(),
            "x-gorgon" to gorgon(query, body, ts, random),
            "x-helios" to helios(ts),
            "x-medusa" to medusa(query, body, ts, rand()),
            "x-tt-dt" to ""
        )
        if (body != null) {
            headers["Content-Type"] = "application/json; charset=UTF-8"
            headers["x-vc-bdturing-sdk-version"] = "3.7.2.cn"
            headers["x-ss-stub"] = digest("MD5", body).hex().uppercase()
        }
        return Request(url, headers, body)
    }

    companion object {
        fun encode(values: Map<String, String>): String =
            values.entries.joinToString("&") { (k, v) -> "${encode(k)}=${encode(v)}" }

        fun encode(value: String): String =
            URLEncoder.encode(value, "UTF-8").replace("+", "%20").replace("%7E", "~").replace("*", "%2A")
    }
}
