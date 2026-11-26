package org.moontechlab.selenetv.screen.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import org.moontechlab.selenetv.ui.Surface
import androidx.tv.material3.Text

/**
 * v2.7.98: 短剧清晰度档位。
 *
 * 红果 video_tab 一次解析就把 360P~1080P 五档直链 + 各自 CENC 密钥一起带回来
 * （HongguoStreamResolver.doResolve 的 multiMap / keys / softDecMap），所以切档
 * 只需要换 URL + Key 重新 load，不用再走一遍 23 字段签名请求 —— 秒切、不耗配额。
 *
 * url/key 为空表示该档不可用（例如 bytevc2/VVC 编码档位已在上游被过滤掉）。
 */
data class QualityOption(
    val label: String,
    val url: String,
    val keyBytes: ByteArray?,
    val needsSoft: Boolean = false,
    val qualityPx: Int = 0,
) {
    override fun equals(other: Any?): Boolean = this === other || (other is QualityOption && other.label == label && other.url == url)
    override fun hashCode(): Int = label.hashCode() * 31 + url.hashCode()
}

/** 把 resolve 里 Map<String, Any?> 形态的字典安全转成 Map<String, String>（键值统一 toString）。 */
private fun toStringKeyMap(raw: Any?): Map<String, String>? {
    val m = raw as? Map<*, *> ?: return null
    if (m.isEmpty()) return emptyMap()
    return m.entries.associate { it.key?.toString().orEmpty() to it.value?.toString().orEmpty() }
}

/** 胶囊外显文案：有当前档位就显示档位（1080P），没有就显示功能名（清晰度）。 */
fun qualityPillLabel(current: String): String = current.ifBlank { "清晰度" }

/**
 * 把 [org.moontechlab.selenetv.hongguo.HongguoStreamResolver.resolve] 的返回值还原成可选档位列表。
 *
 * resolve 成功时带回来的字段：
 *   multiMap    -> 档位标签 -> 直链
 *   keys        -> 档位标签 -> 16 字节 CENC 密钥（hex）
 *   softDecMap  -> 档位标签 -> 是否需要 libmpv 软解（奇数分辨率流）
 * 「自动」是 resolve 额外塞的别名（指向 maxQuality 命中档），列表里要剔掉。
 */
fun qualityOptionsFromResolved(resolved: Map<String, Any?>?): List<QualityOption> {
    if (resolved == null) return emptyList()
    // resolve 返回的是 Map<String, String>，但签名是 Map<String, Any?>，
    // 这里统一规整成 String 键值，避免对 Map<*, *> 直接下标取值。
    val multiMap = toStringKeyMap(resolved["multiMap"]) ?: return emptyList()
    val keysMap = toStringKeyMap(resolved["keys"]) ?: emptyMap()
    val softMap = toStringKeyMap(resolved["softDecMap"]) ?: emptyMap()

    return multiMap.entries
        .mapNotNull { entry ->
            val label = entry.key?.toString().orEmpty()
            val url = entry.value?.toString().orEmpty()
            if (label.isEmpty() || label == "自动" || !url.startsWith("http")) return@mapNotNull null
            val keyHex = keysMap[label].orEmpty()
            val keyBytes = if (keyHex.length == 32) {
                keyHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            } else null
            QualityOption(
                label = label,
                url = url,
                keyBytes = keyBytes,
                needsSoft = softMap[label]?.toBoolean() == true,
                qualityPx = Regex("^(\\d{3,4})P").find(label)?.groupValues?.get(1)?.toIntOrNull()
                    ?: label.removeSuffix("P").toIntOrNull() ?: 0,
            )
        }
        .sortedByDescending { it.qualityPx }
}

/**
 * 控制条顶部的清晰度胶囊。文案 = 当前正在播的档位（如 1080P），未解析出来时显示「清晰度」。
 * 焦点模型镜像 [AspectRatioPill]：左交给画面比例、右交给倍速、下回进度条、上交给跳过或取消。
 */
@Composable
fun QualityPill(
    currentLabel: String,
    onClick: () -> Unit,
    focusRequester: FocusRequester,
    scrubberFocus: FocusRequester,
    rightTarget: FocusRequester,
    leftTarget: FocusRequester? = null,
    upTarget: FocusRequester? = null,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (focused) 1.04f else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = 400f),
        label = "quality_pill_scale",
    )
    val shape = RoundedCornerShape(percent = 50)
    Surface(
        onClick = onClick,
        modifier = modifier
            .focusRequester(focusRequester)
            .onFocusChanged { focused = it.isFocused }
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .focusProperties {
                down = scrubberFocus
                up = upTarget ?: FocusRequester.Cancel
                left = leftTarget ?: FocusRequester.Cancel
                right = rightTarget
            },
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        shape = ClickableSurfaceDefaults.shape(shape = shape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            focusedContainerColor = Color.White,
        ),
        border = ClickableSurfaceDefaults.border(
            border = Border(
                border = BorderStroke(1.dp, Color.White.copy(alpha = 0.3f)),
                shape = shape,
            ),
            focusedBorder = Border(BorderStroke(0.dp, Color.Transparent), shape = shape),
        ),
    ) {
        Box(modifier = Modifier.padding(horizontal = 11.dp, vertical = 3.dp)) {
            Text(
                text = qualityPillLabel(currentLabel),
                color = if (focused) Color(0xFF0A0A0A) else Color.White.copy(alpha = 0.85f),
                fontSize = 13.sp,
                fontWeight = FontWeight.W600,
            )
        }
    }
}

/**
 * 清晰度选择 Popup：独立 Android window，自管焦点 + BACK。位置 = 胶囊上方 8dp，右端对齐胶囊右端。
 * 打开时焦点落到当前档位；按 OK 立即切流并关闭。镜像 [AspectRatioPopup]。
 */
@Composable
fun QualityPopup(
    open: Boolean,
    options: List<QualityOption>,
    currentLabel: String,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val transitionState = remember { MutableTransitionState(false) }
    transitionState.targetState = open

    if (transitionState.currentState || transitionState.targetState) {
        val density = LocalDensity.current
        val gapPx = with(density) { 8.dp.roundToPx() }
        val positionProvider = remember(gapPx) {
            object : PopupPositionProvider {
                override fun calculatePosition(
                    anchorBounds: IntRect,
                    windowSize: IntSize,
                    layoutDirection: LayoutDirection,
                    popupContentSize: IntSize,
                ): IntOffset {
                    val x = (anchorBounds.right - popupContentSize.width).coerceAtLeast(0)
                    val y = (anchorBounds.top - popupContentSize.height - gapPx).coerceAtLeast(0)
                    return IntOffset(x, y)
                }
            }
        }
        Popup(
            onDismissRequest = onDismiss,
            properties = PopupProperties(
                focusable = true,
                dismissOnBackPress = true,
                dismissOnClickOutside = true,
            ),
            popupPositionProvider = positionProvider,
        ) {
            val focusRequesters = remember(options) { options.map { FocusRequester() } }
            val currentIndex = remember(options, currentLabel) {
                options.indexOfFirst { it.label == currentLabel }.coerceAtLeast(0)
            }
            LaunchedEffect(Unit) {
                repeat(8) {
                    try {
                        focusRequesters[currentIndex].requestFocus()
                        return@LaunchedEffect
                    } catch (_: Exception) {
                        kotlinx.coroutines.delay(40)
                    }
                }
            }
            AnimatedVisibility(
                visibleState = transitionState,
                enter = fadeIn(animationSpec = tween(180)) +
                    scaleIn(
                        initialScale = 0.92f,
                        animationSpec = tween(220),
                        transformOrigin = TransformOrigin(1f, 1f),
                    ),
                exit = fadeOut(animationSpec = tween(140)) +
                    scaleOut(
                        targetScale = 0.95f,
                        animationSpec = tween(160),
                        transformOrigin = TransformOrigin(1f, 1f),
                    ),
            ) {
                Column(
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color(0xF20A0A0A))
                        .padding(vertical = 6.dp, horizontal = 6.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    options.forEachIndexed { index, opt ->
                        QualityPopupItem(
                            label = opt.label,
                            selected = opt.label == currentLabel,
                            onClick = { onSelect(opt.label) },
                            focusRequester = focusRequesters[index],
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun QualityPopupItem(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    focusRequester: FocusRequester,
) {
    var focused by remember { mutableStateOf(false) }
    Surface(
        onClick = onClick,
        modifier = Modifier
            .focusRequester(focusRequester)
            .onFocusChanged { focused = it.isFocused }
            .width(120.dp),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        shape = ClickableSurfaceDefaults.shape(shape = RoundedCornerShape(8.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            focusedContainerColor = Color.White,
        ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(
                        if (selected) {
                            if (focused) Color(0xFF0A0A0A) else Color(0xFF4CAF50)
                        } else Color.Transparent
                    ),
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                text = label,
                color = when {
                    focused -> Color(0xFF0A0A0A)
                    selected -> Color.White
                    else -> Color.White.copy(alpha = 0.65f)
                },
                fontSize = 15.sp,
                fontWeight = if (focused || selected) FontWeight.W700 else FontWeight.W500,
            )
        }
    }
}
