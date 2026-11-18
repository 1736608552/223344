// Derived from drpys 22261ad; GPL-3.0.
package org.moontechlab.selenetv.hongguo

import android.content.Context
import android.content.SharedPreferences
import kotlin.random.Random

internal object VendorConstants {
    const val MOBILE_V5_UA = "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"
    const val VIDEO_UA = "com.phoenix.read/73532 (Linux; U; Android 14; zh_CN; 23049RAD8C; Build/UKQ1.230804.001; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
    const val APP_UA = "com.phoenix.read/73532 (Linux; U; Android 14; zh_CN; 23049RAD8C; Build/UKQ1.230804.001)"

    private const val PREFS_NAME = "hongguo_device_identity_v2"
    private const val KEY_INSTALL_IID = "key_install_iid"
    private const val KEY_DEVICE_ID = "key_device_id"
    private const val KEY_OPENUDID = "key_openudid"
    private const val KEY_CLIENTUDID = "key_clientudid"
    private const val KEY_CDID = "key_cdid"
    private const val KEY_OFFICIAL_REGISTERED = "key_official_registered"
    private const val KEY_OFFICIAL_COOKIE = "key_official_cookie"
    private const val KEY_BLACKLIST_IDS = "key_blacklist_device_ids"
    private val defaultBlacklist = setOf("3748291048294829104", "0")

    private fun getBlacklist(): MutableSet<String> {
        val sp = getPrefs()
        val saved = sp?.getStringSet(KEY_BLACKLIST_IDS, null) ?: emptySet()
        return (defaultBlacklist + saved).toMutableSet()
    }

    private fun getAppContext(): Context? {
        return try {
            val activityThreadClass = Class.forName("android.app.ActivityThread")
            val currentApplication = activityThreadClass.getMethod("currentApplication")
            (currentApplication.invoke(null) as? Context)?.applicationContext
        } catch (_: Exception) {
            null
        }
    }

    private fun getPrefs(): SharedPreferences? = getAppContext()?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // 专属设备身份与指纹本地持久化绑定：每台设备首次安装/升级自动分配专属唯一ID并持久化，彻底杜绝共用封禁
    var installIid: String = loadOrGenerateId(KEY_INSTALL_IID)
    var installDeviceId: String = loadOrGenerateId(KEY_DEVICE_ID)
    var openUdid: String = loadOrGenerateString(KEY_OPENUDID) { randomHex(16) }
    var clientUdid: String = loadOrGenerateString(KEY_CLIENTUDID) { java.util.UUID.randomUUID().toString() }
    var cdid: String = loadOrGenerateString(KEY_CDID) { java.util.UUID.randomUUID().toString() }

    var processNonce: String = randomNonce()
    var processStarted: Long = System.currentTimeMillis()

    private fun loadOrGenerateId(key: String): String {
        val sp = getPrefs()
        val blacklist = getBlacklist()
        var id = sp?.getString(key, null).orEmpty()
        if (id.isBlank() || id in blacklist) {
            id = randomInstallId()
            sp?.edit()?.putString(key, id)?.apply()
        }
        return id
    }

    private fun loadOrGenerateString(key: String, generator: () -> String): String {
        val sp = getPrefs()
        var str = sp?.getString(key, null).orEmpty()
        if (str.isBlank()) {
            str = generator()
            sp?.edit()?.putString(key, str)?.apply()
        }
        return str
    }

    fun isOfficialRegistered(): Boolean {
        val sp = getPrefs() ?: return false
        val blacklist = getBlacklist()
        return sp.getBoolean(KEY_OFFICIAL_REGISTERED, false) &&
            installDeviceId.isNotBlank() && installDeviceId !in blacklist &&
            installIid.isNotBlank() && installIid !in blacklist
    }

    fun getOfficialCookie(): String {
        val saved = getPrefs()?.getString(KEY_OFFICIAL_COOKIE, null).orEmpty()
        return saved.ifBlank { "install_id=$installIid; store-region=cn; store-region-src=did" }
    }

    fun saveOfficialIdentity(
        deviceId: String,
        iid: String,
        cdidVal: String = cdid,
        openUdidVal: String = openUdid,
        cookieVal: String = "",
    ) {
        val blacklist = getBlacklist()
        if (deviceId.isBlank() || deviceId == "0" || deviceId in blacklist || iid.isBlank() || iid == "0" || iid in blacklist) return
        installDeviceId = deviceId
        installIid = iid
        if (cdidVal.isNotBlank()) cdid = cdidVal
        if (openUdidVal.isNotBlank()) openUdid = openUdidVal
        val finalCookie = cookieVal.ifBlank { "install_id=$iid; store-region=cn; store-region-src=did" }
        getPrefs()?.edit()
            ?.putString(KEY_DEVICE_ID, installDeviceId)
            ?.putString(KEY_INSTALL_IID, installIid)
            ?.putString(KEY_CDID, cdid)
            ?.putString(KEY_OPENUDID, openUdid)
            ?.putBoolean(KEY_OFFICIAL_REGISTERED, true)
            ?.putString(KEY_OFFICIAL_COOKIE, finalCookie)
            ?.apply()
    }

    fun clearPersistedIdentity(failedDeviceId: String = "") {
        val sp = getPrefs()
        if (failedDeviceId.isNotBlank()) {
            val bl = getBlacklist()
            bl.add(failedDeviceId)
            sp?.edit()?.putStringSet(KEY_BLACKLIST_IDS, bl)?.apply()
        }
        regenerate()
    }

    fun regenerate() {
        val blacklist = getBlacklist()
        var newDid: String
        var newIid: String
        do {
            newDid = randomInstallId()
        } while (newDid in blacklist)
        do {
            newIid = randomInstallId()
        } while (newIid in blacklist)

        installDeviceId = newDid
        installIid = newIid
        openUdid = randomHex(16)
        clientUdid = java.util.UUID.randomUUID().toString()
        cdid = java.util.UUID.randomUUID().toString()
        processNonce = randomNonce()
        processStarted = System.currentTimeMillis()

        getPrefs()?.edit()
            ?.putString(KEY_INSTALL_IID, installIid)
            ?.putString(KEY_DEVICE_ID, installDeviceId)
            ?.putString(KEY_OPENUDID, openUdid)
            ?.putString(KEY_CLIENTUDID, clientUdid)
            ?.putString(KEY_CDID, cdid)
            ?.putBoolean(KEY_OFFICIAL_REGISTERED, false)
            ?.remove(KEY_OFFICIAL_COOKIE)
            ?.apply()
    }

    private fun randomHex(len: Int): String {
        val hexChars = "0123456789abcdef"
        return buildString { repeat(len) { append(hexChars[Random.nextInt(16)]) } }
    }

    private fun randomInstallId(): String = buildString {
        append('2')
        repeat(15) { append(Random.nextInt(10)) }
    }

    private fun randomNonce(): String =
        android.util.Base64.encodeToString(
            Random.nextBytes(18),
            android.util.Base64.NO_WRAP or android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING
        )

    val device: java.util.LinkedHashMap<String, String>
        get() = linkedMapOf(
            "iid" to installIid,
            "device_id" to installDeviceId,
            "openudid" to openUdid,
            "clientudid" to clientUdid,
            "cdid" to cdid,
            "ac" to "wifi",
            "channel" to "update_64",
            "aid" to "8662",
            "app_name" to "novelread",
            "version_code" to "73532",
            "version_name" to "7.3.5.32",
            "device_platform" to "android",
            "os" to "android",
            "ssmix" to "a",
            "device_type" to "23049RAD8C",
            "device_brand" to "Redmi",
            "language" to "zh",
            "os_api" to "34",
            "os_version" to "14",
            "manifest_version_code" to "73532",
            "resolution" to "1080*2400",
            "dpi" to "440",
            "update_version_code" to "73532",
            "host_abi" to "arm64-v8a",
            "dragon_device_type" to "phone",
            "pv_player" to "73532",
            "compliance_status" to "0",
            "need_personal_recommend" to "1",
            "player_so_load" to "1",
            "is_android_pad_screen" to "0"
        )
    val playbackV5Magic = hex("2d4b4fca49750d433fb5ae2c226dcc56")
    val playbackV5Key = hex("b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d")
    val playbackV5SBox = hex("53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0df37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1dd12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe127400248591238922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c894545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dccd759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8de0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd288fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac91fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443fd830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f44591681335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e")
    val sbox = decode64("+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==")
    val hashTable = intArrayOf(0xebb64faf.toInt(),0x7aadcc2.toInt(),0xcf3187bf.toInt(),0xe01138ff.toInt(),0x6d0bfcff.toInt(),0x5a30a3be.toInt(),0xb41ad638.toInt(),0x34180eb8.toInt(),0xf233eb6f.toInt(),0xb1a584cc.toInt(),0xccc30dc7.toInt(),0x47d1db51.toInt(),0xd55653de.toInt(),0x70a84fa1.toInt(),0x57473c12.toInt(),0xf76f0288.toInt(),0x2c077f0a.toInt(),0xda0dcad0.toInt(),0xfbb86f6c.toInt(),0xfdc4cf00.toInt(),0x688a020d.toInt(),0xe676c6a6.toInt(),0x8cd6338b.toInt(),0x1a3c8d0e.toInt(),0xcce8b06b.toInt(),0x6ad0ed0b.toInt(),0xa0522717.toInt(),0xdc71ac83.toInt(),0x2285db71.toInt(),0xd5b4dda6.toInt(),0x736f8650.toInt(),0x6560306c.toInt(),0x617ce2a6.toInt(),0xe423417e.toInt(),0xa40e143.toInt(),0x544e4032.toInt(),0x88dffb2a.toInt(),0x716c1ae0.toInt(),0x4c467a88.toInt(),0x5b23bb3.toInt(),0xe1d0b866.toInt(),0xbaa3dcb8.toInt(),0xae3374d3.toInt(),0xc3381a50.toInt(),0x1702f75b.toInt(),0xfe6da368.toInt(),0xf0b4cf48.toInt(),0x4e0ffbb8.toInt(),0x72aad10d.toInt(),0x26c53a3d.toInt(),0xf2bce0f6.toInt(),0xb4557581.toInt(),0x4a257fdd.toInt(),0x8c3182a2.toInt(),0xab0b3b86.toInt(),0x3d5dfb14.toInt(),0x4f103634.toInt(),0xd37b52d7.toInt(),0x444eff16.toInt(),0xeb0a33d1.toInt(),0x6ca86f6e.toInt(),0x284ba7.toInt(),0x8387cfa.toInt(),0x5fb37586.toInt())
}
