package org.moontechlab.selenetv.screen.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.moontechlab.selenetv.model.SearchResult

class PlayProgressTest {

    private fun source() = SearchResult(
        id = "42",
        title = "示例剧",
        poster = "http://h/p.jpg",
        episodes = listOf("http://h/1.m3u8", "http://h/2.m3u8"),
        episodesTitles = listOf("第一集", "第二集"),
        source = "qq",
        sourceName = "企鹅源",
        year = "2024",
    )

    @Test
    fun buildPlayUrl_noProxy_returnsRaw() {
        assertEquals("http://h/1.m3u8", PlayProgress.buildPlayUrl("http://h/1.m3u8", ""))
    }

    @Test
    fun buildPlayUrl_withProxy_encodesAndPrefixes() {
        val out = PlayProgress.buildPlayUrl("http://h/a b.m3u8", "http://proxy/?u=")
        assertEquals("http://proxy/?u=http%3A%2F%2Fh%2Fa+b.m3u8", out)
    }

    @Test
    fun buildRecord_mapsFieldsAndConvertsSeconds() {
        val r = PlayProgress.buildRecord(
            source = source(), title = "示例剧", episodeIndex = 1,
            positionMs = 65_000, durationMs = 2_700_000, nowMs = 1_700_000_000_000,
        )
        assertEquals("qq", r.source)
        assertEquals("42", r.id)
        assertEquals("企鹅源", r.sourceName)
        assertEquals("http://h/p.jpg", r.cover)
        assertEquals(2, r.index)              // 0 基 +1
        assertEquals(2, r.totalEpisodes)
        assertEquals(65L, r.playTime)         // ms→s
        assertEquals(2700L, r.totalTime)
        assertEquals(1_700_000_000_000, r.saveTime)
        assertEquals("示例剧", r.searchTitle)
    }

    @Test
    fun shouldSave_falseWhenUnderOneSecond() {
        assertFalse(PlayProgress.shouldSave(force = true, positionMs = 500, lastSavedPositionMs = -1, elapsedSinceLastSaveMs = 999_999))
    }

    @Test
    fun shouldSave_trueWhenForcedAndPastOneSecond() {
        assertTrue(PlayProgress.shouldSave(force = true, positionMs = 5_000, lastSavedPositionMs = 5_000, elapsedSinceLastSaveMs = 0))
    }

    @Test
    fun shouldSave_falseWhenWithinThrottleWindow() {
        assertFalse(PlayProgress.shouldSave(force = false, positionMs = 20_000, lastSavedPositionMs = 10_000, elapsedSinceLastSaveMs = 9_000))
    }

    @Test
    fun shouldSave_falseWhenPositionUnchanged() {
        assertFalse(PlayProgress.shouldSave(force = false, positionMs = 20_000, lastSavedPositionMs = 20_000, elapsedSinceLastSaveMs = 11_000))
    }

    @Test
    fun shouldSave_trueAfterWindowWithMovement() {
        assertTrue(PlayProgress.shouldSave(force = false, positionMs = 30_000, lastSavedPositionMs = 20_000, elapsedSinceLastSaveMs = 11_000))
    }

    @Test
    fun shouldSave_trueAtExactlyOneSecondWhenForced() {
        assertTrue(PlayProgress.shouldSave(force = true, positionMs = 1000, lastSavedPositionMs = -1, elapsedSinceLastSaveMs = 0))
    }

    @Test
    fun normalizePlayTimeMs_shortDrama_handlesMillisecondsFromMobile() {
        // 手机端上报 70 秒的短剧进度 (70,000 毫秒)
        val ms = PlayProgress.normalizePlayTimeMs(70_000L, isShortDrama = true)
        assertEquals(70_000L, ms) // 保持毫秒，不二次放大为 7000 万
    }

    @Test
    fun normalizePlayTimeMs_shortDrama_handlesSecondsFromLegacyTv() {
        // TV 端旧版存入秒 (70 秒)
        val ms = PlayProgress.normalizePlayTimeMs(70L, isShortDrama = true)
        assertEquals(70_000L, ms) // 正确转换为 70,000 毫秒
    }

    @Test
    fun normalizePlayTimeMs_shortDrama_capsExtremeValues() {
        // 极端脏数据超限
        val ms = PlayProgress.normalizePlayTimeMs(99_999_999L, isShortDrama = true)
        assertEquals(10 * 60 * 1000L, ms) // 限制在 10 分钟安全上限
    }

    @Test
    fun normalizePlayTimeMs_movie_handlesSecondsAndMilliseconds() {
        // 电影 1.5 小时 = 5400 秒
        val msFromSec = PlayProgress.normalizePlayTimeMs(5400L, isShortDrama = false)
        assertEquals(5_400_000L, msFromSec)

        // 电影从手机端传入 5,400,000 毫秒
        val msFromMs = PlayProgress.normalizePlayTimeMs(5_400_000L, isShortDrama = false)
        assertEquals(5_400_000L, msFromMs)
    }
}
