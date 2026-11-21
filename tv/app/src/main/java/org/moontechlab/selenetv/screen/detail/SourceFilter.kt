package org.moontechlab.selenetv.screen.detail

import org.moontechlab.selenetv.model.SearchResult
import org.moontechlab.selenetv.model.titlesMatch
import kotlin.math.abs

/**
 * 详情页源筛选规则（v2.7.77 全面对齐手机端精确度并修复 TV 端三大误杀根因）：
 * 1. 强匹配：result.doubanId(>0) == route.doubanId
 * 2. 弱匹配兜底：result 无 doubanId 或 vod_douban_id == 0（采集站常见默认值）时，按归一化标题与年份匹配
 * 3. 年份兼容：把 "unknown" / "0" / 空白视为缺省年份，并允许 ±1 年公差（防止豆瓣首播年与采集站建档年差 1 年误杀）
 * 4. 明确不匹配：result 带有效非 0 doubanId 且与 route 不等 → 拒绝（防串片）
 */
object SourceFilter {
    private val PUNCT_REGEX = Regex("""[\s\u3000:：·\-—_'"‘’“”()（）\[\]【】《》!！?？,，.。/\\~～]+""")
    private val YEAR_REGEX = Regex("""\d{4}""")
    private val VERSION_SUFFIX_REGEX = Regex(
        """^(第[\d零一二三四五六七八九十百千万]+[季部]|新版|重制版?|加长版?|未删减版?|完整版?|剧场版?|修复版?|高清版?|电影版?|电视剧|tv版?|tv|plus|\+|\d{4}|\d+|国语版?|粤语版?|中字|蓝光|4k|uhd|hd|tc|ts|bd)$""",
        RegexOption.IGNORE_CASE,
    )
    private val VERSION_PREFIX_REGEX = Regex(
        """^(剧场版|电影版?|电视剧|tv版?|tv|ova|plus)$""",
        RegexOption.IGNORE_CASE,
    )

    private fun normalizeTitle(raw: String): String =
        PUNCT_REGEX.replace(raw.trim().lowercase(), "")

    private fun isMissingYear(y: String): Boolean {
        val t = y.trim()
        return t.isEmpty() || t.equals("unknown", ignoreCase = true) || t == "0"
    }

    private fun yearsCompatible(resultYear: String, targetYear: String, allowTolerance: Boolean = true): Boolean {
        if (isMissingYear(targetYear) || isMissingYear(resultYear)) return true
        val ry = YEAR_REGEX.find(resultYear)?.value ?: return true
        val ty = YEAR_REGEX.find(targetYear)?.value ?: return true
        if (ry == ty) return true
        if (!allowTolerance) return false
        val rInt = ry.toIntOrNull() ?: return false
        val tInt = ty.toIntOrNull() ?: return false
        return abs(rInt - tInt) <= 1
    }

    private fun titlesEquivalent(resultTitle: String, targetTitle: String): Boolean {
        if (titlesMatch(resultTitle, targetTitle)) return true
        val nr = normalizeTitle(resultTitle)
        val nt = normalizeTitle(targetTitle)
        if (nr.isEmpty() || nt.isEmpty()) return false
        if (nr == nt) return true
        // 采集站标题 = 目标标题 + 合法版本/清晰度/季数后缀（如「两京十五日(2026)」「两京十五日第一季」「两京十五日HD」）
        if (nr.startsWith(nt)) {
            val rest = nr.substring(nt.length)
            if (VERSION_SUFFIX_REGEX.matches(rest)) return true
        }
        // 豆瓣标题带季数后缀而采集站省略（如豆瓣「庆余年 第一季」vs 采集站「庆余年」）
        if (nt.startsWith(nr)) {
            val rest = nt.substring(nr.length)
            if (VERSION_SUFFIX_REGEX.matches(rest)) return true
        }
        // 罕见前缀（如「剧场版 凡人修仙传」）
        if (nr.endsWith(nt)) {
            val prefix = nr.substring(0, nr.length - nt.length)
            if (VERSION_PREFIX_REGEX.matches(prefix)) return true
        }
        return false
    }

    private fun validDoubanIdOrNull(raw: Long?): String? =
        raw?.takeIf { it > 0L }?.toString()

    private fun validTargetDoubanIdOrNull(raw: String): String? =
        raw.trim().takeIf { it.isNotEmpty() && it != "0" }

    fun matchesContent(
        result: SearchResult,
        doubanId: String,
        title: String,
        year: String,
    ): Boolean = matchesContentInternal(result, doubanId, title, year, ignoreYear = false)

    /**
     * 放宽年份的豆瓣入口兜底匹配：当严格年份命中 0 源时使用（仍严格校验标题与非 0 豆瓣 ID 防串片）。
     */
    fun matchesContentRelaxedYear(
        result: SearchResult,
        doubanId: String,
        title: String,
    ): Boolean = matchesContentInternal(result, doubanId, title, year = "", ignoreYear = true)

    private fun matchesContentInternal(
        result: SearchResult,
        doubanId: String,
        title: String,
        year: String,
        ignoreYear: Boolean,
    ): Boolean {
        val resultDoubanId = validDoubanIdOrNull(result.doubanId)
        val targetDoubanId = validTargetDoubanIdOrNull(doubanId)
        return when {
            resultDoubanId != null && targetDoubanId != null && resultDoubanId == targetDoubanId -> {
                // 双重保险：doubanId 一致时仍需做标题宽松校验，防止采集站误填豆瓣 ID 导致串片
                val nr = normalizeTitle(result.title)
                val nt = normalizeTitle(title)
                titlesEquivalent(result.title, title) ||
                    (nr.isNotEmpty() && nt.isNotEmpty() && (nt.contains(nr) || nr.contains(nt)))
            }
            resultDoubanId == null || targetDoubanId == null -> {
                val titleOk = titlesEquivalent(result.title, title)
                val yearOk = if (ignoreYear) true else yearsCompatible(result.year, year, allowTolerance = true)
                titleOk && yearOk
            }
            else -> false
        }
    }

    /**
     * 仅按标题/年份匹配（忽略 doubanId）。用于 bangumi / 继续播放 / 收藏夹入口。
     */
    fun matchesByTitleYear(
        result: SearchResult,
        title: String,
        year: String,
    ): Boolean {
        val titleOk = titlesEquivalent(result.title, title)
        val yearOk = yearsCompatible(result.year, year, allowTolerance = true)
        return titleOk && yearOk
    }

    /**
     * 仅按归一化标题匹配（忽略年份与 doubanId），用于严格年份命中 0 源时的最后兜底。
     */
    fun matchesByTitleOnly(
        result: SearchResult,
        title: String,
    ): Boolean = titlesEquivalent(result.title, title)
}
