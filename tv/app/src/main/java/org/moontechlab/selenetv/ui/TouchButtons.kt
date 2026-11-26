package org.moontechlab.selenetv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text

/**
 * 车机触摸屏的「返回」按钮（覆盖层页面用：详情页、登录页等）。
 *
 * 与遥控器的关系：**完全没有关系**。它不挂 focusable / focusRequester，
 * 不进 D-pad 焦点搜索、不抢焦点、不消费按键；只响应手指（pointerInput）。
 * 调用方负责用 [TouchMode] 判一次「是否触摸设备」，纯电视上不渲染。
 */
@Composable
fun TouchBackButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    label: String = "返回",
) {
    val shape = RoundedCornerShape(999.dp)
    Row(
        modifier = modifier
            .clip(shape)
            .background(Color.Black.copy(alpha = 0.55f))
            .border(width = 1.dp, color = Color.White.copy(alpha = 0.22f), shape = shape)
            .tvTouchTap { onClick() }
            .padding(horizontal = 18.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = "‹",
            color = Color.White,
            fontSize = 20.sp,
            fontWeight = FontWeight.W700,
        )
        Text(
            text = label,
            color = Color.White.copy(alpha = 0.95f),
            fontSize = 15.sp,
            fontWeight = FontWeight.W600,
        )
    }
}

/**
 * 触摸专用的圆形图标按钮（如「关闭」）。同样不参与焦点链。
 */
@Composable
fun TouchIconButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    sizeDp: androidx.compose.ui.unit.Dp = 44.dp,
    symbol: String = "✕",
) {
    androidx.compose.foundation.layout.Box(
        modifier = modifier
            .size(sizeDp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .border(width = 1.dp, color = Color.White.copy(alpha = 0.22f), shape = CircleShape)
            .tvTouchTap { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(text = symbol, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.W700)
    }
}
