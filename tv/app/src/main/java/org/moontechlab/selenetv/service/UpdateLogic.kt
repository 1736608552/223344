package org.moontechlab.selenetv.service

import org.moontechlab.selenetv.model.GithubAsset
import org.moontechlab.selenetv.model.GithubRelease
import org.moontechlab.selenetv.model.UpdateInfo

/**
 * 更新相关的纯逻辑：无 Android 依赖，便于单元测试。
 * 负责版本比较、按设备 ABI 选包、以及是否弹窗的判定链。
 */
object UpdateLogic {

    /**
     * 解析版本号为数值段；去掉前导 v/V；任一段非纯数字返回 null。
     *
     * v2.8.4：必须容忍渠道后缀。车机包 `versionNameSuffix = "-car"`，本机 versionName 是
     * `2.8.4-car`；以前 `"4-car".toIntOrNull()` 得 null → 整串判为非法 → compareVersions 返回 0
     * → `<= 0` → 永远认为「已是最新」。这就是「车机版不能在线更新」的直接原因。
     * 现在先砍掉 `+build` / `-flavor` / 空格之后的部分再逐段解析。
     */
    fun parseVersion(raw: String): List<Int>? {
        val cleaned = raw.trim().removePrefix("v").removePrefix("V")
        if (cleaned.isEmpty()) return null
        val core = cleaned.substringBefore('+').substringBefore('-').substringBefore(' ').trim()
        if (core.isEmpty()) return null
        val parts = core.split('.')
        return parts.map { it.toIntOrNull() ?: return null }
    }

    /** 数值比较版本；a>b 返回正，a<b 返回负，相等或任一非法返回 0。 */
    fun compareVersions(a: String, b: String): Int {
        val pa = parseVersion(a) ?: return 0
        val pb = parseVersion(b) ?: return 0
        val n = maxOf(pa.size, pb.size)
        for (i in 0 until n) {
            val x = pa.getOrElse(i) { 0 }
            val y = pb.getOrElse(i) { 0 }
            if (x != y) return x.compareTo(y)
        }
        return 0
    }

    /**
     * 按设备 ABI 与「本包所属渠道」选匹配的 APK 资产。
     * 规则：
     * 0. 渠道优先、绝不跨渠道：车机包只认 `LunaTV-Car-*`；TV 包只认 `LunaTV-TV-*` / `SeleneTV` / `-TV-`。
     *    跨渠道装上去是**另一个包名**（车机是 `...selenetv.car`），等于并排出第二个 App，
     *    自己永远更新不掉自己 —— 这是「车机版不能在线更新」的第二个原因（原先只筛 TV 包，
     *    车机选不到资产 → null → 当作已是最新）。
     * 1. 若当前为海信设备 (isHisenseDevice=true)，优先命中包含 "hisense" 的专属包；
     * 2. 否则排除包含 "hisense" 的包，按 supportedAbis 优先级顺序命中第一个架构包；
     * 3. TV 渠道若 assets 中没有标注 TV 的包，则回退到按普通 apk 规则匹配（兼容老版本）。
     *    车机渠道**不回退**：宁可判定「无可用包」，也不能给车机装 TV/手机包。
     */
    fun selectAsset(
        supportedAbis: List<String>,
        assets: List<GithubAsset>,
        isHisenseDevice: Boolean = false,
        isCar: Boolean = false,
    ): Pair<String, GithubAsset>? {
        val allApks = assets.filter { it.name.endsWith(".apk", ignoreCase = true) }

        if (isCar) {
            val carApks = allApks.filter { it.name.contains("LunaTV-Car-", ignoreCase = true) }
            for (abi in supportedAbis) {
                val match = carApks.firstOrNull { it.name.contains(abi, ignoreCase = true) }
                if (match != null) return abi to match
            }
            return null
        }

        val tvApks = allApks.filter {
            it.name.contains("LunaTV-TV-", ignoreCase = true) ||
            it.name.contains("SeleneTV", ignoreCase = true) ||
            it.name.contains("-TV-", ignoreCase = true)
        }.ifEmpty { allApks }

        if (isHisenseDevice) {
            val hisenseMatch = tvApks.firstOrNull { it.name.contains("hisense", ignoreCase = true) }
            if (hisenseMatch != null) {
                return "hisense" to hisenseMatch
            }
        }

        // 普通设备排除海信专包，避免冲突
        val candidateApks = if (isHisenseDevice) tvApks else tvApks.filterNot { it.name.contains("hisense", ignoreCase = true) }

        for (abi in supportedAbis) {
            val match = candidateApks.firstOrNull { it.name.contains(abi, ignoreCase = true) }
            if (match != null) return abi to match
        }
        return null
    }

    /**
     * 组合判定：远端版本须严格高于本地，且能为当前设备选到 APK，才返回 UpdateInfo；
     * 否则（不高于本地 / CI 构建中无资产 / 无匹配架构）返回 null。
     */
    fun buildUpdateInfo(
        release: GithubRelease,
        currentVersion: String,
        supportedAbis: List<String>,
        isHisenseDevice: Boolean = false,
        isCar: Boolean = false,
    ): UpdateInfo? {
        if (compareVersions(release.tagName, currentVersion) <= 0) return null
        val (abi, asset) = selectAsset(supportedAbis, release.assets, isHisenseDevice, isCar) ?: return null
        val cleanVersion = release.tagName.trim().removePrefix("v").removePrefix("V")
        return UpdateInfo(
            version = cleanVersion,
            title = release.name.ifBlank { release.tagName },
            changelog = release.body,
            apkUrl = asset.browserDownloadUrl,
            apkSize = asset.size,
            abi = abi,
        )
    }

    /** 「稍后」冷却时长：6 小时。 */
    const val COOLDOWN_MILLIS = 6L * 60 * 60 * 1000

    /**
     * 是否应弹窗。手动检查（manual=true）绕过 skip 与冷却。
     * 自动检查：跳过了该版本、或仍在冷却期内 → 不弹。
     */
    fun shouldPrompt(
        info: UpdateInfo,
        skippedVersion: String?,
        postponedUntil: Long,
        now: Long,
        manual: Boolean,
    ): Boolean {
        if (manual) return true
        if (info.version == skippedVersion) return false
        if (now < postponedUntil) return false
        return true
    }
}
