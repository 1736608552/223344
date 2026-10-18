package org.moontechlab.selenetv.screen.player

import org.junit.Assert.assertEquals
import org.junit.Test
import org.moontechlab.selenetv.service.AppDataService.PlayerType

class PlayerFactoryGateTest {
    @Test fun mpv_allowedOnApi21AndAbove() {
        assertEquals(PlayerType.MPV, resolveEffectivePlayerType(PlayerType.MPV, 21))
        assertEquals(PlayerType.MPV, resolveEffectivePlayerType(PlayerType.MPV, 25))
        assertEquals(PlayerType.MPV, resolveEffectivePlayerType(PlayerType.MPV, 26))
        assertEquals(PlayerType.MPV, resolveEffectivePlayerType(PlayerType.MPV, 34))
    }
    @Test fun mpv_downgradedBelowApi21() {
        assertEquals(PlayerType.EXOPLAYER, resolveEffectivePlayerType(PlayerType.MPV, 20))
        assertEquals(PlayerType.EXOPLAYER, resolveEffectivePlayerType(PlayerType.MPV, 19))
    }
    @Test fun exo_alwaysExo() {
        assertEquals(PlayerType.EXOPLAYER, resolveEffectivePlayerType(PlayerType.EXOPLAYER, 21))
        assertEquals(PlayerType.EXOPLAYER, resolveEffectivePlayerType(PlayerType.EXOPLAYER, 34))
    }
}
