// Kotlin port of drpys 22261adfa31435e3b3ef5a730b8a2a75bcaf1715 & hongguo-tv passport-sign.js; GPL-3.0-only.
package org.moontechlab.selenetv.hongguo

import java.io.ByteArrayOutputStream
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

internal class Signer(private val clock: () -> Long = System::currentTimeMillis, private val random: () -> Double = Math::random) {
    data class Request(val url: String, val headers: Map<String, String>, val body: ByteArray?)

    private fun rand() = (random() * 4294967296.0).toLong().toInt()
    private fun unsigned(v: Int) = v.toLong() and 0xffffffffL

    private fun varint(value: Long): ByteArray {
        var n = value
        return ByteArrayOutputStream().apply {
            while (n > 127L || n < 0L) {
                write(((n and 127L) or 128L).toInt())
                n = n ushr 7
            }
            write(n.toInt())
        }.toByteArray()
    }

    private data class Field(val tag: Int, val value: Any, val type: String = "string")
    private fun f(tag: Int, value: Any, type: String = "string") = Field(tag, value, type)
    private fun proto(vararg fields: Field): ByteArray = ByteArrayOutputStream().apply {
        for ((tag, value, type) in fields) {
            when (type) {
                "sint" -> { val n = (value as Number).toLong(); write(varint(tag.toLong() shl 3)); write(varint(if (n < 0) -n * 2 - 1 else n * 2)) }
                "uint" -> { val n = (value as Number).toLong() and 0xffffffffL; write(varint(tag.toLong() shl 3)); write(varint(n)) }
                "float" -> { write(varint((tag.toLong() shl 3) or 5)); write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat((value as Number).toFloat()).array()) }
                "raw_bytes" -> { val bytes = value as ByteArray; write(varint((tag.toLong() shl 3) or 2)); write(varint(bytes.size.toLong())); write(bytes) }
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
        val rawIv = iv(query, body, ts)
        val index = (rawIv and 15) / 3
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

    private fun deviceProto(values: Map<String, String>? = null) = proto(
        f(1, 1, "sint"),
        f(2, 2, "sint"),
        f(3, "8662"),
        f(4, values?.get("device_id")?.ifEmpty { null } ?: VendorConstants.device.getValue("device_id")),
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
        f(22, "14"),
        f(23, 41, "sint"),
        f(24, 34, "sint"),
        f(25, VendorConstants.processStarted, "sint"),
        f(26, VendorConstants.processStarted, "sint"),
        f(27, VendorConstants.processStarted, "sint"),
        f(28, VendorConstants.processStarted + 2, "sint"),
        f(29, -1, "sint"),
        f(30, "23049RAD8C"),
        f(31, "Redmi"),
        f(32, "23049RAD8C"),
        f(33, "23049RAD8C"),
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

    fun medusa(query: String, body: ByteArray?, ts: Int, random: Int, values: Map<String, String>? = null): String {
        val bodyMd5 = body?.let { digest("MD5", it) } ?: ByteArray(16)
        val querySm3 = sm3(query.toByteArray())
        val queryBodyTs = hashF13(querySm3, bodyMd5, ts)
        val effectiveDevId = values?.get("device_id")?.ifEmpty { null } ?: VendorConstants.device.getValue("device_id")
        val effectiveVerName = values?.get("version_name")?.ifEmpty { null } ?: VendorConstants.device.getValue("version_name")
        val env = proto(f(1,114,"sint"),f(2,146331399,"sint"),f(3,146331396,"sint"),f(5,7,"sint"),f(6,"v04.06.04.03-bugfix"),f(7,11309,"sint"),f(12,deviceProto(values),"message"),f(13,proto(f(1,ts,"sint"),f(2,-2,"sint"),f(4,200,"sint")),"message"),f(14,effectiveVerName))
        val message = proto(f(1,hex("f7e85ffad7d7dc3bd62ac87057cf6118"),"bytes"),f(2,3,"sint"),f(3,rand(),"sint"),f(4,"8662"),f(5,effectiveDevId),f(6,"1588093228"),f(7,effectiveVerName),f(8,"v04.06.04-ml-android"),f(9,67503104,"sint"),f(10,hex("4001000000000000"),"bytes"),f(12,ts,"sint"),f(13,queryBodyTs,"bytes"),f(14,querySm3.copyOf(6),"bytes"),f(15,proto(f(1,111,"sint"),f(2,10,"sint"),f(3,694367,"sint"),f(5,586952199,"sint")),"message"),f(16,"AXYQOS6n2m60x1fVZHIrH3iol"),f(17,ts,"sint"),f(19,sm3(query.toByteArray() + bodyMd5 + "none".toByteArray()),"bytes"),f(20,"none"),f(21,312,"sint"),f(23,env,"message"),f(24,"""{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}"""))
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

    // --- 1736608552/hongguo-tv playback 551 & single-registered Argus / Ladon ---

    private fun playbackPad(data: ByteArray): ByteArray {
        val n = 16 - (data.size % 16)
        return data + ByteArray(n) { n.toByte() }
    }

    private fun playbackParam(query: String, name: String): String {
        for (part in query.split('&')) {
            val at = part.indexOf('=')
            val k = if (at < 0) part else part.substring(0, at)
            val v = if (at < 0) "" else part.substring(at + 1)
            try {
                if (java.net.URLDecoder.decode(k, "UTF-8") == name) {
                    return java.net.URLDecoder.decode(v, "UTF-8")
                }
            } catch (_: Exception) {}
        }
        return ""
    }

    private fun playbackSimonKeys(seed: ByteArray?): ULongArray {
        val raw = seed ?: hex("fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304")
        val sequence = 0x3dc94c3a046d678bUL
        val keys = ULongArray(72)
        for (i in 0 until 4) {
            keys[i] = ByteBuffer.wrap(raw, i * 8, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
        }
        for (i in 4 until 72) {
            val x = keys[i - 1].rotateRight(3) xor keys[i - 3]
            val bit = (sequence.rotateRight((i - 4) % 62) and 1UL)
            keys[i] = keys[i - 4].inv() xor x xor x.rotateRight(1) xor (bit xor 3UL)
        }
        return keys
    }

    private fun aesCbcEncrypt(key: ByteArray, ivBytes: ByteArray, data: ByteArray): ByteArray =
        Cipher.getInstance("AES/CBC/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(ivBytes))
            doFinal(data)
        }

    fun playbackArgus(
        query: String,
        body: ByteArray?,
        ts: Int,
        nonce: Int = rand(),
        registered: Boolean = false,
    ): String {
        val bodyHashInput = if (body != null && body.isNotEmpty()) digest("MD5", body) else ByteArray(16)
        val queryHashInput = if (query.isNotEmpty()) query.toByteArray(Charsets.UTF_8) else ByteArray(16)

        val counters = proto(
            f(1, 1L, "uint"),
            f(2, 1L, "uint"),
            f(3, 1L, "uint"),
            f(7, 0xc792ecccL, "uint"),
        )
        val device = if (registered) {
            proto(
                f(1, "23049RAD8C"),
                f(2, "14"),
                f(3, "update_64"),
                f(4, 2147483648L, "uint"),
            )
        } else {
            proto(
                f(1, "NX551J"),
                f(2, 8196L, "uint"),
                f(4, 0x80e0d800L, "uint"),
            )
        }

        val pFields = mutableListOf(
            f(1, 1077940818L, "uint"),
            f(2, 2L, "uint"),
            f(3, (if (registered) (nonce and 0x7fffffff) else nonce).toLong() and 0xffffffffL, "uint"),
            f(4, playbackParam(query, "aid").ifEmpty { "1967" }),
            f(5, playbackParam(query, "device_id").toByteArray(Charsets.UTF_8), "raw_bytes"),
            f(6, "1611921764"),
            f(7, playbackParam(query, "version_name").toByteArray(Charsets.UTF_8), "raw_bytes"),
            f(8, if (registered) "v04.07.01-ml-android" else "v04.04.05-ov-android"),
            f(9, if (registered) 135135744L else 134744640L, "uint"),
            f(10, ByteArray(8), "raw_bytes"),
            f(11, 0L, "uint"),
            f(12, ((ts shl 1).toLong() and 0xffffffffL), "uint"),
            f(13, sm3(bodyHashInput).copyOf(6), "raw_bytes"),
            f(14, sm3(queryHashInput).copyOf(6), "raw_bytes"),
            f(15, counters, "raw_bytes"),
            f(16, (if (registered) "" else playbackParam(query, "iid")).toByteArray(Charsets.UTF_8), "raw_bytes"),
            f(20, "none"),
            f(21, 738L, "uint"),
            f(23, device, "raw_bytes"),
            f(25, 2L, "uint"),
        )
        val pBytes = proto(*pFields.toTypedArray())
        val registeredKey = hex("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c")
        val plain = playbackPad(pBytes)
        val keys = playbackSimonKeys(
            if (registered) sm3(registeredKey + hex("3ccc567b") + registeredKey) else null
        )

        for (at in plain.indices step 16) {
            var a = ByteBuffer.wrap(plain, at, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
            var b = ByteBuffer.wrap(plain, at + 8, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
            for (i in keys.indices) {
                val r1 = b.rotateLeft(1)
                val r8 = b.rotateLeft(8)
                val next = a xor (r1 and r8) xor b.rotateLeft(2) xor keys[i]
                a = b
                b = next
            }
            ByteBuffer.wrap(plain, at, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(a.toLong())
            ByteBuffer.wrap(plain, at + 8, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(b.toLong())
        }

        if (registered) {
            val registeredMask = hex("d04ffdffd04ffdff")
            for (i in plain.indices) {
                plain[i] = (plain[i].u() xor registeredMask[i % 8].u()).toByte()
            }
            val revFrame = (registeredMask + plain).reversedArray()
            val paddedFrame = playbackPad(hex("a6e783ee7001100918") + revFrame + hex("567b"))
            val enc = aesCbcEncrypt(
                digest("MD5", registeredKey.copyOfRange(0, 16)),
                digest("MD5", registeredKey.copyOfRange(16, 32)),
                paddedFrame,
            )
            return (hex("3ccc") + enc).base64()
        }

        val mask = hex("f2f7fcfff2f7fcff")
        val frame = mask + plain + hex("eafb2cfe8568519154")
        for (i in 8 until frame.size) {
            frame[i] = (frame[i].u() xor mask[i % 8].u()).toByte()
        }
        val revFrame = frame.reversedArray()
        val paddedFrame = playbackPad(revFrame + byteArrayOf(0x61, 0x6f))
        val enc = aesCbcEncrypt(
            hex("d31e3718288a1027baab59f146a09a9c"),
            hex("ea180a0336ed352fcd24e4d50018ae54"),
            paddedFrame,
        )
        return (byteArrayOf(0xf2.toByte(), 0x81.toByte()) + enc).base64()
    }

    fun playbackLadon(ts: Int, aid: String = "8662", nonce: Int = rand()): String {
        val seed = le32(nonce)
        val raw = digest("MD5", seed + aid.toByteArray(Charsets.UTF_8)).hex().toByteArray(Charsets.US_ASCII)
        var k = ByteBuffer.wrap(raw, 0, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
        val pending = mutableListOf(
            ByteBuffer.wrap(raw, 8, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong(),
            ByteBuffer.wrap(raw, 16, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong(),
            ByteBuffer.wrap(raw, 24, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong(),
        )
        val keys = ULongArray(34)
        for (i in 0 until 34) {
            keys[i] = k
            val x = (pending[0].rotateRight(8) + k) xor i.toULong()
            pending[0] = pending[1]
            pending[1] = pending[2]
            pending[2] = x
            k = x xor k.rotateLeft(3)
        }
        val plain = playbackPad("$ts-1611921764-$aid".toByteArray(Charsets.UTF_8))
        for (at in plain.indices step 16) {
            var a = ByteBuffer.wrap(plain, at, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
            var b = ByteBuffer.wrap(plain, at + 8, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
            for (i in keys.indices) {
                b = keys[i] xor (a + b.rotateRight(8))
                a = b xor a.rotateLeft(3)
            }
            ByteBuffer.wrap(plain, at, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(a.toLong())
            ByteBuffer.wrap(plain, at + 8, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(b.toLong())
        }
        return (seed + plain).base64()
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

    /**
     * 100% 对齐 1736608552/hongguo-tv (passport-sign.js -> signSingleRegistered):
     * 针对已注册设备调用 /novel/player/video_model/v1/，生成 3ccc 帧头的 X-Argus + X-Ladon + X-Gorgon 签名。
     */
    fun signSingleRegistered(base: String, values: Map<String, String>, body: ByteArray? = null): Request {
        val stamp = clock()
        val ts = (stamp / 1000).toInt()
        val sortedParams = (values + mapOf("_rticket" to stamp.toString())).toSortedMap()
        val query = sortedParams.entries.joinToString("&") { (k, v) -> "${encode(k)}=${encode(v)}" }
        val baseSig = signHongguo(query, body, stamp)
        val headers = linkedMapOf(
            "User-Agent" to DeviceRegister.SINGLE_REG_UA,
            "Accept" to "application/json",
            "Content-Type" to "application/json; charset=utf-8",
            "X-XS-From-Web" to "0",
            "Sdk-Version" to "2",
            "X-Argus" to playbackArgus(query, body, ts, rand(), registered = true),
            "X-Ladon" to playbackLadon(ts, values["aid"] ?: "8662", rand()),
            "X-Gorgon" to (baseSig["X-Gorgon"] ?: ""),
            "X-Khronos" to ts.toString(),
            "X-SS-Req-Ticket" to stamp.toString(),
        )
        baseSig["X-SS-STUB"]?.let { headers["X-SS-STUB"] = it }
        return Request("$base?$query", headers, body)
    }

    fun sign(base: String, values: Map<String, String>, body: ByteArray? = null): Request {
        val now = clock()
        val ts = (now / 1000).toInt()
        var ticket = now
        var query = ""
        var found = false
        for (offset in 0..127) {
            ticket = now + offset
            query = encode(values + mapOf("ts" to ts.toString(), "_rticket" to ticket.toString()))
            if (branch(query, body, ts) == 0) {
                found = true
                break
            }
        }
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
            "x-ladon" to playbackLadon(ts, values["aid"] ?: "8662", rand()),
            "x-argus" to playbackArgus(query, body, ts, rand(), registered = false),
            "x-gorgon" to gorgon(query, body, ts, random),
            "x-helios" to helios(ts),
            "x-medusa" to medusa(query, body, ts, rand(), values),
            "x-tt-dt" to ""
        )
        if (body != null) {
            headers["Content-Type"] = "application/json; charset=UTF-8"
            headers["x-vc-bdturing-sdk-version"] = "3.7.2.cn"
            headers["x-ss-stub"] = digest("MD5", body).hex().uppercase()
        }
        return Request(url, headers, body)
    }

    /**
     * 官方短剧播放接口专属签名 (100% 对齐 1736608552/hongguo-tv passport-sign.js -> signPlayback)：
     * 1. 锁定 branch == 2 并对 query 参数按字母序规范化编码；
     * 2. 注入完整 551 协议 X-Argus 与 Simon64/128 X-Ladon 签名；
     * 3. 显式不发送 X-Medusa，避免与播放端 551 envelope 冲突返回空包。
     */
    fun signPlayback(base: String, values: Map<String, String>, body: ByteArray? = null): Request {
        val now = clock()
        val ts = (now / 1000).toInt()
        var ticket = now
        var query = ""
        for (offset in 0..255) {
            ticket = now + offset
            val params = (values + mapOf("ts" to ts.toString(), "_rticket" to ticket.toString())).toSortedMap()
            query = params.entries.joinToString("&") { (k, v) -> "${encode(k)}=${encode(v)}" }
            if (branch(query, body, ts) == 2) {
                break
            }
        }
        val random = (random() * 65536).toInt()
        val aid = values["aid"]?.ifEmpty { "8662" } ?: "8662"
        val headers = linkedMapOf(
            "User-Agent" to (if (body != null) VendorConstants.VIDEO_UA else VendorConstants.APP_UA),
            "Accept" to "application/json; charset=utf-8,application/x-protobuf",
            "X-SS-Req-Ticket" to ticket.toString(),
            "X-Tt-Request-Tag" to "t=0;n=0",
            "Sdk-Version" to "2",
            "Passport-Sdk-Version" to "50561",
            "X-Xs-From-Web" to "0",
            "X-Khronos" to ts.toString(),
            "X-Argus" to playbackArgus(query, body, ts, rand(), registered = false),
            "X-Ladon" to playbackLadon(ts, aid, rand()),
            "X-Gorgon" to gorgon(query, body, ts, random),
            "X-Helios" to helios(ts),
            "X-Tt-Dt" to "",
            "X-Tt-Store-Region" to "cn",
            "X-Tt-Store-Region-Src" to "did",
        )
        if (body != null) {
            headers["Content-Type"] = "application/json; charset=UTF-8"
            headers["X-Vc-Bdturing-Sdk-Version"] = "3.7.2.cn"
            headers["X-SS-STUB"] = digest("MD5", body).hex().uppercase()
        }
        return Request("$base?$query", headers, body)
    }


    // --- 1736608552/hongguo-tv & aston314/hongguo-tv v0.2.173 Mobile V5 (v04.10.03-ml-android) ---

    fun playbackV5F13(q: ByteArray, m: ByteArray, ts: Int): ByteArray {
        val seed = 0x9d4a97c2.toInt()
        val count = seed + ts
        val shift = (count + 2) and 7
        val pad = intArrayOf(0xfa, 0x45, 0x61, 0xd7)
            .map { ((it * 257) ushr shift).toByte() }
            .toByteArray()
        val data = q.copyOf(32) + m.copyOf(16) + le32(ts) + pad + hex("00000000000001a0")
        val words = IntArray(128)
        for (i in 0 until 16) {
            words[i] = data.i32(i * 4)
        }
        for (i in 0 until 112) {
            val x = words[i + 1]
            val y = words[i + 14]
            words[i + 16] = words[i] + words[i + 9] +
                (rol(x, 14) xor rol(x, 25) xor (x ushr 3)) +
                (rol(y, 13) xor rol(y, 15) xor (y ushr 10))
        }
        val initial = intArrayOf(
            0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f,
            984304912, 3005047866L.toInt(), 2874125293L.toInt(), 2152413264L.toInt()
        ).map { ror(it, count and 31) }.toIntArray()
        val d = initial.copyOf()
        for (i in 0 until 96) {
            val base = seed + i
            val n1 = ((d[4] xor d[0]) and d[1]) xor d[4]
            val n2 = rol(d[1], 26) xor rol(d[1], 21) xor rol(d[1], 7)
            val n4 = words[base and 127] + n1 + n2 +
                ror(VendorConstants.hashTable[base and 63], (count + 1) and 31) + d[6]
            val n5 = rol(d[3], 30) xor rol(d[3], 19) xor rol(d[3], 10)
            val n6 = (d[3] and d[5]) or ((d[3] or d[5]) and d[2])
            val old = d[7]
            for (j in 7 downTo 1) {
                d[j] = d[j - 1]
            }
            d[7] = n5 + n6 + n4
            d[0] = old + n4
        }
        val ret = ByteArray(32)
        for (i in 0 until 8) {
            be32(d[i] + initial[i]).copyInto(ret, i * 4)
        }
        val out = ByteArray(16) { i -> (ret[i].u() xor ret[i + 16].u()).toByte() }
        var check = 0x20220420
        for (i in 0 until 12) {
            val x = out[i].u()
            check = if (i and 1 == 0) {
                (check ushr 3) xor check xor x xor (check shl 7)
            } else {
                (check ushr 5) xor check xor (x or (check shl 11)).inv()
            }
        }
        return out + le32(((check or 4) xor 0x1000000) or 0x20)
    }

    private fun playbackV5Proto(
        values: Map<String, String>,
        ts: Int,
        nonce: Int,
        q: ByteArray,
        f13: ByteArray,
    ): ByteArray {
        val devId = values["device_id"] ?: ""
        val osVer = values["os_version"] ?: "12"
        val devType = values["device_type"] ?: "PGT-AN10"
        val channel = values["channel"] ?: "vivo_8662_64"
        val verName = values["version_name"] ?: "7.4.3.32"
        val device = proto(
            f(1, 1L, "sint"),
            f(2, 2L, "sint"),
            f(3, "8662"),
            f(4, devId),
            f(5, VendorConstants.processNonce),
            f(6, "!noperm!"),
            f(12, "Asia/Shanghai,8"),
            f(13, "zh_CN"),
            f(22, osVer),
            f(25, VendorConstants.processStarted, "sint"),
            f(30, devType),
            f(31, "HONOR"),
            f(32, devType),
            f(34, "HONOR"),
        )
        val env = proto(
            f(6, "v04.10.03.04-bugfix"),
            f(8, channel),
            f(12, device, "raw_bytes"),
            f(14, verName),
        )
        val count = proto(
            f(1, 1L, "sint"),
            f(2, 1L, "sint"),
            f(3, 1L, "sint"),
            f(5, 1L, "sint"),
        )
        return proto(
            f(1, VendorConstants.playbackV5Magic, "raw_bytes"),
            f(2, 5L, "sint"),
            f(3, nonce.toLong() and 0xffffffffL, "sint"),
            f(4, "8662"),
            f(5, devId),
            f(6, "646637794"),
            f(7, verName),
            f(8, "v04.10.03-ml-android"),
            f(9, 0x040a0300L, "sint"),
            f(10, ByteArray(8), "raw_bytes"),
            f(12, ts.toLong() and 0xffffffffL, "sint"),
            f(13, f13, "raw_bytes"),
            f(14, q.copyOf(6), "raw_bytes"),
            f(15, count, "raw_bytes"),
            f(17, ts.toLong() and 0xffffffffL, "sint"),
            f(20, "none"),
            // proof marker：v04.10.03 期望线值 738（sint 369）。旧值 754（sint 377）会让
            // 服务端直接回 HTTP 200 + 空 body，上层看到的就是 len=0。
            // 对齐 upstream aston314/hongguo-tv bc2e41cd「restore v5 proof marker」。
            f(21, 369L, "sint"),
            f(23, env, "raw_bytes"),
            f(24, """{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}"""),
        )
    }

    private fun playbackV5AES(data: ByteArray, ts: Int, key: ByteArray, iv: ByteArray): ByteArray {
        require(data.size >= 248 && key.size == 16 && iv.size == 16) { "signature payload is too short" }
        val branch = ts and 3
        val box = VendorConstants.playbackV5SBox.copyOfRange(branch * 256, (branch + 1) * 256).map { it.u() }
        val con = arrayOf(
            intArrayOf(2, 0, 3, 1),
            intArrayOf(1, 3, 2, 0),
            intArrayOf(3, 2, 1, 0),
            intArrayOf(2, 3, 1, 0),
        )[branch]
        val order = arrayOf(
            intArrayOf(0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11),
            intArrayOf(0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7),
            intArrayOf(0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7),
            intArrayOf(0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7),
        )[branch]
        val initVal = intArrayOf(
            0xbbb5de72.toInt(),
            0xd4638d5b.toInt(),
            0x92a5f73b.toInt(),
            0x89f8a1c9.toInt(),
        )[branch]
        val mk = IntArray(48)
        for (j in 0 until 16) {
            mk[j] = key[j].u() xor ((initVal ushr ((j % 4) * 8)) and 255)
        }
        var r = 8
        for (j in 4 until 12) {
            var prev = intArrayOf(mk[j * 4 - 4], mk[j * 4 - 3], mk[j * 4 - 2], mk[j * 4 - 1])
            if (j % 4 == 0) {
                prev = intArrayOf(
                    ((initVal ushr (r and 24)) and 255) xor box[prev[1]],
                    box[prev[2]],
                    box[prev[3]],
                    box[prev[0]],
                )
            }
            r += 2
            for (k in 0 until 4) {
                mk[j * 4 + k] = prev[k] xor mk[j * 4 + k - 16]
            }
        }
        fun block(src: ByteArray): ByteArray {
            val b = IntArray(16) { src[it].u() }
            fun add(base: Int) {
                for (j in 0 until 16) {
                    b[j] = b[j] xor mk[base + (j / 4) * 4 + con[j % 4]]
                }
            }
            add(0)
            for (round in 1..2) {
                var prev = b.copyOf()
                for (j in 0 until 16) {
                    val idx = order[j]
                    b[j] = box[prev[con[idx / 4] * 4 + (idx % 4)]]
                }
                if (round == 1) {
                    prev = b.copyOf()
                    for (j in 0 until 16) {
                        b[j] = prev[(j / 4) * 4 + con[j % 4]]
                    }
                    fun xt(x: Int): Int = if ((x and 128) != 0) ((x shl 1) xor 0x1b) and 255 else (x shl 1) and 255
                    for (col in 0 until 4) {
                        val a = b[col]
                        val c = b[4 + col]
                        val d = b[8 + col]
                        val e = b[12 + col]
                        val t = a xor c xor d xor e
                        b[col] = b[col] xor t xor xt(a xor c)
                        b[4 + col] = b[4 + col] xor t xor xt(c xor d)
                        b[8 + col] = b[8 + col] xor t xor xt(d xor e)
                        b[12 + col] = b[12 + col] xor t xor xt(e xor a)
                    }
                }
                add(round * 16)
            }
            for (j in 0 until 16) {
                b[j] = b[j] xor mk[16 + j]
            }
            return ByteArray(16) { b[it].toByte() }
        }
        val wire = intArrayOf(6, 5, 3, 4, 2, 7, 1, 0)
        val compact = intArrayOf(1, 7, 3, 6, 2, 0, 4, 5)
        val plain = ByteArray(32)
        for (j in 0 until 31) {
            var acc = 0
            for (k in 0 until 8) {
                acc = acc or (((data[j * 8 + k].u() ushr wire[k]) and 1) shl compact[k])
            }
            plain[j] = acc.toByte()
        }
        plain[31] = 1
        var previous = iv.copyOf()
        val encrypted = ByteArray(32)
        for (j in 0 until 32 step 16) {
            for (k in 0 until 16) {
                plain[j + k] = (plain[j + k].u() xor previous[k].u()).toByte()
            }
            previous = block(plain.copyOfRange(j, j + 16))
            previous.copyInto(encrypted, j)
        }
        val out = byteArrayOf(encrypted[31]) + data
        for (j in 0 until 31) {
            val encByte = encrypted[j].u()
            for (k in 0 until 8) {
                val at = 1 + j * 8 + k
                val cleared = out[at].u() and (1 shl wire[k]).inv()
                val bit = ((encByte ushr compact[k]) and 1) shl wire[k]
                out[at] = (cleared or bit).toByte()
            }
        }
        return out
    }

    fun playbackV5Medusa(
        values: Map<String, String>,
        ts: Int,
        q: ByteArray,
        m: ByteArray,
        n0: Int = rand(),
        n1: Int = rand(),
        n2: Int = rand(),
    ): String {
        val f13 = playbackV5F13(q, m, ts)
        val message = playbackV5Proto(values, ts, n0, q, f13)
        val key = sm3(VendorConstants.playbackV5Key + le32(n1) + VendorConstants.playbackV5Key)
        val high = (n1 ushr 16) and 255
        val seed = le32((((high shl 11) or (n1 ushr 24)) xor (high ushr 5) xor high).inv())
        val p = (ByteArray(8) + xmxor(message, key)).reversedArray()
        for (i in p.indices) {
            p[i] = (p[i].u() xor seed[i.inv() and 3].u()).toByte()
        }
        val check = 0x18000001 or ((q[0].u() and 63) shl 14) or ((f13[0].u() and 63) shl 8)
        val n1Bytes = le32(n1)
        val packed = byteArrayOf(0xca.toByte()) + le32(n2) + le32(check) + p + n1Bytes.copyOfRange(2, 4)
        val aesKey = digest("MD5", VendorConstants.playbackV5Key.copyOfRange(0, 16))
        val aesIv = digest("MD5", VendorConstants.playbackV5Key.copyOfRange(16, 32))
        val encrypted = playbackV5AES(packed, ts, aesKey, aesIv)
        val tsBytes = le32(ts)
        val header = (le32(5) + VendorConstants.playbackV5Magic).apply {
            for (i in indices) {
                this[i] = (this[i].u() xor tsBytes[i and 3].u()).toByte()
            }
        }
        return (header + byteArrayOf(n1Bytes[0], n1Bytes[1], 0, 1) + encrypted).base64()
    }

    fun playbackV5Helios(ts: Int, nonce: Int = rand()): String {
        val seed = le32(nonce)
        val raw = digest("MD5", seed + "8662".toByteArray(Charsets.UTF_8)).hex().toByteArray(Charsets.US_ASCII)
        var k = ByteBuffer.wrap(raw, 0, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
        val pending = mutableListOf(
            ByteBuffer.wrap(raw, 8, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong(),
            ByteBuffer.wrap(raw, 16, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong(),
            ByteBuffer.wrap(raw, 24, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong(),
        )
        val rounds = ULongArray(34)
        for (i in 0 until 34) {
            rounds[i] = k
            val x = (pending[0].rotateRight(8) + k) xor i.toULong()
            pending[0] = pending[1]
            pending[1] = pending[2]
            pending[2] = x
            k = x xor k.rotateLeft(3)
        }
        val plain = playbackPad("$ts-${VendorConstants.mobileV5License}-8662".toByteArray(Charsets.UTF_8))
        for (at in plain.indices step 16) {
            var a = ByteBuffer.wrap(plain, at, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
            var b = ByteBuffer.wrap(plain, at + 8, 8).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
            for (i in rounds.indices) {
                b = rounds[i] xor (a + b.rotateRight(8))
                a = b xor a.rotateLeft(3)
            }
            ByteBuffer.wrap(plain, at, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(a.toLong())
            ByteBuffer.wrap(plain, at + 8, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(b.toLong())
        }
        return (seed + plain).base64()
    }

    /**
     * 100% 对齐 aston314/hongguo-tv v0.2.173 (playback_v5_sign.go -> signPlaybackV5):
     * 针对 /novel/player/multi_video_model/player/v1 移动端 v5 Gzip 请求体生成 F13 branch 12 + X-Medusa + X-Helios 签名。
     */
    fun signPlaybackV5(base: String, values: Map<String, String>, body: ByteArray): Request {
        val stamp = clock()
        val ts = (stamp / 1000).toInt()
        val orderedKeys = listOf(
            "aid", "app_name", "version_code", "version_name", "manifest_version_code",
            "channel", "device_platform", "device_type", "os_version", "update_version_code",
            "iid", "cdid", "device_id", "_rticket"
        )
        val bodyMd5 = digest("MD5", body)
        var query = ""
        var querySm3 = ByteArray(32)
        for (offset in 0 until 1024) {
            val ticket = (stamp + offset).toString()
            query = orderedKeys.joinToString("&") { k ->
                val v = if (k == "_rticket") ticket else (values[k] ?: "")
                "$k=${encode(v)}"
            }
            val qHash = sm3(query.toByteArray(Charsets.UTF_8))
            if ((iv(qHash, bodyMd5, ts) and 15) == (VendorConstants.mobileV5Branch and 15)) {
                querySm3 = qHash
                break
            }
        }
        val headers = linkedMapOf(
            "X-Khronos" to ts.toString(),
            "X-Helios" to playbackV5Helios(ts, rand()),
            "X-Medusa" to playbackV5Medusa(values, ts, querySm3, bodyMd5, rand(), rand(), rand()),
            "X-SS-STUB" to bodyMd5.hex().uppercase(),
        )
        return Request("$base?$query", headers, body)
    }

    companion object {
        fun encode(values: Map<String, String>): String =
            values.entries.joinToString("&") { (k, v) -> "${encode(k)}=${encode(v)}" }
        fun encode(value: String): String =
            URLEncoder.encode(value, "UTF-8").replace("+", "%20").replace("%7E", "~").replace("*", "%2A")
    }
}
