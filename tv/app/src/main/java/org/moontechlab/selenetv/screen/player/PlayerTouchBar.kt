package org.moontechlab.selenetv.screen.player

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import org.moontechlab.selenetv.ui.TouchMode
import org.moontechlab.selenetv.ui.tvTouchTap

/**
 * 车机触摸屏的「无遥控器兜底」按钮组（播放页右上角）：选集/频道 + 退出。
 *
 * 三条硬约束，都是为了「遥控器一点都不能受影响」：
 *  1. 只在 [TouchMode.active] 为真（车机声明了触摸屏 / 用户真的点过屏）时才进组合树——
 *     纯电视用户看不到、也没有这些节点。
 *  2. 故意**不挂 focusable / focusRequester**：它们不参与 D-pad 焦点搜索，
 *     遥控器的焦点顺序、焦点记忆、方向键落点与改动前完全一致。
 *  3. 点击只走 [tvTouchTap]（pointerInput），收不到 KeyEvent。
 */
@Composable
internal fun PlayerTouchBar(
    visible: Boolean,
    primaryLabel: String,
    onPrimary: () -> Unit,
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!TouchMode.active) return

    val alpha by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = tween(200),
        label = "player_touch_bar_alpha",
    )
    // 淡出到底就不再绘制：此时节点离开组合，绝不会在「看不见」的状态下被手指点到。
    if (alpha <= 0.01f) return

    Row(
        modifier = modifier.graphicsLayer { this.alpha = alpha },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TouchPill(label = primaryLabel, onClick = onPrimary)
        TouchPill(label = "退出", onClick = onExit)
    }
}

@Composable
private fun TouchPill(label: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(999.dp)
    Box(
        modifier = Modifier
            .clip(shape)
            .background(Color.Black.copy(alpha = 0.58f))
            .border(width = 1.dp, color = Color.White.copy(alpha = 0.22f), shape = shape)
            // 只挂触摸；不 focusable，遥控器按方向键永远不会停在这两个胶囊上。
            .tvTouchTap { onClick() }
            .padding(horizontal = 22.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            color = Color.White.copy(alpha = 0.95f),
            fontSize = 16.sp,
            fontWeight = FontWeight.W700,
        )
    }
}
