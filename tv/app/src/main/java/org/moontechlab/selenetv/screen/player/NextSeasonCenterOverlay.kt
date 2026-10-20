package org.moontechlab.selenetv.screen.player

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.PlayArrow
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
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import org.moontechlab.selenetv.service.NextSeasonCandidate

/**
 * TV 端全屏居中下一季/推荐内容自动连播大卡片浮层 (对齐 YouTube / Netflix 风格，专为 TV 遥控器打造)
 */
@Composable
fun NextSeasonCenterOverlay(
    candidate: NextSeasonCandidate,
    countdownSec: Int,
    playFocusRequester: FocusRequester,
    onPlayNow: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // 首次进入自动将遥控器焦点锁定在「立即播放」主按钮上
    LaunchedEffect(Unit) {
        kotlinx.coroutines.delay(120)
        try { playFocusRequester.requestFocus() } catch (_: Exception) {}
    }

    val progressAnim by animateFloatAsState(
        targetValue = (countdownSec / 5f).coerceIn(0f, 1f),
        animationSpec = tween(900),
        label = "overlay_countdown_progress"
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.82f)),
        contentAlignment = Alignment.Center
    ) {
        // 居中大卡片容器
        Surface(
            onClick = {},
            modifier = Modifier
                .width(580.dp)
                .clip(RoundedCornerShape(20.dp))
                .border(1.2.dp, Color(0x5538BDF8), RoundedCornerShape(20.dp)),
            shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(20.dp)),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = Color(0xF20F172A),
                focusedContainerColor = Color(0xF20F172A),
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = 1f)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp)
            ) {
                // 顶部状态条：小图标 + 醒目副标题
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(bottom = 16.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color(0x3338BDF8))
                            .padding(horizontal = 8.dp, vertical = 3.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.AutoAwesome,
                                contentDescription = null,
                                tint = Color(0xFF38BDF8),
                                modifier = Modifier.size(13.dp)
                            )
                            Text(
                                text = if (candidate.isNextSeason) "连播下一季" else "为你推荐",
                                color = Color(0xFF38BDF8),
                                fontSize = 11.5.sp,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }
                    Text(
                        text = candidate.bannerTitle,
                        color = Color.White.copy(alpha = 0.9f),
                        fontSize = 13.5.sp,
                        fontWeight = FontWeight.W600,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                // 中间主体：左侧海报 + 右侧详情
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // 左侧海报卡片
                    Box(
                        modifier = Modifier
                            .width(130.dp)
                            .height(180.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color(0xFF1E293B))
                    ) {
                        AsyncImage(
                            model = ImageRequest.Builder(LocalContext.current)
                                .data(candidate.poster)
                                .crossfade(true)
                                .build(),
                            contentDescription = candidate.title,
                            modifier = Modifier.fillMaxSize(),
                            contentScale = ContentScale.Crop,
                        )
                        // 海报角标
                        Box(
                            modifier = Modifier
                                .padding(6.dp)
                                .clip(RoundedCornerShape(4.dp))
                                .background(
                                    if (candidate.isNextSeason) Color(0xFF10B981)
                                    else Color(0xFFE11D48)
                                )
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                                .align(Alignment.TopStart)
                        ) {
                            Text(
                                text = if (candidate.isNextSeason) candidate.seasonLabel else "推荐",
                                color = Color.White,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }

                    Spacer(modifier = Modifier.width(20.dp))

                    // 右侧文本与按钮区
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .height(180.dp),
                        verticalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column {
                            Text(
                                text = candidate.title,
                                color = Color.White,
                                fontSize = 21.sp,
                                fontWeight = FontWeight.Bold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Spacer(modifier = Modifier.height(6.dp))
                            Text(
                                text = candidate.desc,
                                color = Color.White.copy(alpha = 0.72f),
                                fontSize = 12.5.sp,
                                lineHeight = 17.sp,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }

                        // 倒计时指示条
                        Column(modifier = Modifier.fillMaxWidth()) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = candidate.bannerSubtitle,
                                    color = Color(0xFF38BDF8),
                                    fontSize = 11.5.sp,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    text = "${countdownSec}s",
                                    color = Color.White.copy(alpha = 0.9f),
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            Spacer(modifier = Modifier.height(6.dp))
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(3.dp)
                                    .clip(RoundedCornerShape(1.5.dp))
                                    .background(Color.White.copy(alpha = 0.15f))
                            ) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxHeight()
                                        .fillMaxWidth(fraction = progressAnim)
                                        .background(Color(0xFF38BDF8))
                                )
                            }
                        }

                        // 操作按钮行（支持 TV 遥控器左右切焦）
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            // 主按钮：【立即播放 (5s)】
                            TvActionButton(
                                text = "立即播放 (${countdownSec}s)",
                                isPrimary = true,
                                onClick = onPlayNow,
                                modifier = Modifier
                                    .weight(1.3f)
                                    .focusRequester(playFocusRequester)
                            )
                            // 次按钮：【取消】
                            TvActionButton(
                                text = "取消",
                                isPrimary = false,
                                onClick = onDismiss,
                                modifier = Modifier.weight(0.7f)
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * TV 专用操作胶囊按钮 (黑白反色聚焦反馈)
 */
@Composable
private fun TvActionButton(
    text: String,
    isPrimary: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var isFocused by remember { mutableStateOf(false) }

    Surface(
        onClick = onClick,
        modifier = modifier
            .height(38.dp)
            .onFocusChanged { isFocused = it.isFocused },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(19.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (isPrimary) Color(0xFF0284C7) else Color.White.copy(alpha = 0.15f),
            focusedContainerColor = Color.White,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.04f)
    ) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = text,
                color = if (isFocused) Color(0xFF0F172A) else Color.White,
                fontSize = 13.5.sp,
                fontWeight = if (isFocused) FontWeight.Bold else FontWeight.W600
            )
        }
    }
}
