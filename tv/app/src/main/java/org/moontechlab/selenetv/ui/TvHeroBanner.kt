package org.moontechlab.selenetv.ui

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Star
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import org.moontechlab.selenetv.model.VideoInfo
import org.moontechlab.selenetv.util.getImageUrlSync

/**
 * TV 端专属 Hero 幻灯片项目数据模型
 */
data class TvHeroItem(
    val id: String,
    val title: String,
    val overview: String,
    val backdropUrl: String,
    val posterUrl: String,
    val typeLabel: String,
    val rate: String = "9.6",
    val year: String = "2026",
    val videoInfo: VideoInfo,
)

/**
 * 全新设计的 TV 专属现代化沉浸视界幻灯片组件 (TvHeroBanner)
 *
 * 核心设计亮点：
 * 1. 沉浸式 16:9 横版大剧照全屏透视 + 左右轴柔和暗影双重渐变，彻底解决文字遮挡与边缘割裂
 * 2. 醒目视觉层次：流光类型胶囊 + 豆瓣高光金星评分 + 28sp 电影级巨幅主标题 + 两行看点摘要
 * 3. 遥控器与触屏双模按键：高光高斯毛玻璃「立即播放」与「详情」按钮，获焦呼吸光晕
 * 4. 动态胶囊呼吸指示器，获焦自动驻留防打扰，离开后 6 秒平滑淡入淡出（Crossfade）轮播
 */
@Composable
fun TvHeroBanner(
    items: List<TvHeroItem>,
    onPlayClick: (VideoInfo) -> Unit,
    onDetailClick: (VideoInfo) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (items.isEmpty()) return

    var currentIndex by remember { mutableIntStateOf(0) }
    var isUserInteracting by remember { mutableStateOf(false) }

    // 自动轮播逻辑（6秒切换，遥控器交互时暂停）
    LaunchedEffect(currentIndex, isUserInteracting, items.size) {
        if (!isUserInteracting && items.size > 1) {
            delay(6000)
            currentIndex = (currentIndex + 1) % items.size
        }
    }

    val currentItem = items.getOrElse(currentIndex) { items.first() }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(270.dp)
            .padding(horizontal = 24.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0xFF141414))
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(18.dp))
    ) {
        // 1. 大剧照沉浸背景（带平滑淡入淡出动效）
        Crossfade(
            targetState = currentItem,
            animationSpec = tween(700),
            modifier = Modifier.fillMaxSize(),
            label = "hero_crossfade"
        ) { item ->
            val rawImage = if (item.backdropUrl.isNotEmpty()) item.backdropUrl else item.posterUrl
            val displayUrl = getImageUrlSync(rawImage)
            AsyncImage(
                model = displayUrl,
                contentDescription = item.title,
                contentScale = ContentScale.Crop,
                alignment = Alignment.Center,
                modifier = Modifier.fillMaxSize()
            )
        }

        // 2. 双重渐变遮罩：左侧深暗衬底保护文字 + 底部柔和淡化融入背景
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.horizontalGradient(
                        0.0f to Color(0xF5080808),
                        0.45f to Color(0xD9080808),
                        0.75f to Color(0x66080808),
                        1.0f to Color.Transparent,
                    )
                )
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.0f to Color.Transparent,
                        0.65f to Color.Transparent,
                        1.0f to Color(0xEE080808),
                    )
                )
        )

        // 3. 核心内容区域（左对齐，占 62% 宽度）
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .fillMaxWidth(0.65f)
                .padding(start = 28.dp, top = 22.dp, bottom = 20.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Column {
                // 顶部标签组（类型胶囊 + 评分 + 年份）
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    // 类型微光胶囊
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(4.dp))
                            .background(
                                Brush.horizontalGradient(
                                    listOf(Color(0xFFE50914), Color(0xFFFF5252))
                                )
                            )
                            .padding(horizontal = 7.dp, vertical = 2.dp)
                    ) {
                        Text(
                            text = currentItem.typeLabel,
                            color = Color.White,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }

                    // 评分星标
                    if (currentItem.rate.isNotEmpty() && currentItem.rate != "0.0") {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(RoundedCornerShape(4.dp))
                                .background(Color.Black.copy(alpha = 0.55f))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Star,
                                contentDescription = "Star",
                                tint = Color(0xFFFFB300),
                                modifier = Modifier.size(12.dp)
                            )
                            Spacer(modifier = Modifier.width(3.dp))
                            Text(
                                text = currentItem.rate,
                                color = Color(0xFFFFD54F),
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }

                    // 年份标签
                    if (currentItem.year.isNotEmpty()) {
                        Text(
                            text = currentItem.year,
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }

                Spacer(modifier = Modifier.height(10.dp))

                // 巨幅标题
                Text(
                    text = currentItem.title,
                    color = Color.White,
                    fontSize = 26.sp,
                    fontWeight = FontWeight.ExtraBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )

                Spacer(modifier = Modifier.height(6.dp))

                // 看点梗概（两行优雅灰白）
                if (currentItem.overview.isNotEmpty()) {
                    Text(
                        text = currentItem.overview,
                        color = Color.White.copy(alpha = 0.72f),
                        fontSize = 12.sp,
                        lineHeight = 17.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }

            // 底部操作按钮组
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                // 按钮 1：立即播放
                HeroActionButton(
                    text = "立即播放",
                    icon = Icons.Default.PlayArrow,
                    isPrimary = true,
                    onClick = { onPlayClick(currentItem.videoInfo) },
                    onFocusChanged = { isUserInteracting = it }
                )

                // 按钮 2：详情信息
                HeroActionButton(
                    text = "查看详情",
                    icon = Icons.Default.Info,
                    isPrimary = false,
                    onClick = { onDetailClick(currentItem.videoInfo) },
                    onFocusChanged = { isUserInteracting = it }
                )
            }
        }

        // 4. 右下角动态胶囊呼吸指示器与触屏快速切换
        Row(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 24.dp, bottom = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            items.indices.forEach { index ->
                val isSelected = index == currentIndex
                val width by animateDpAsState(
                    targetValue = if (isSelected) 22.dp else 6.dp,
                    animationSpec = tween(350),
                    label = "indicator_width"
                )
                val alpha by animateFloatAsState(
                    targetValue = if (isSelected) 1.0f else 0.35f,
                    animationSpec = tween(350),
                    label = "indicator_alpha"
                )
                Box(
                    modifier = Modifier
                        .height(5.dp)
                        .width(width)
                        .clip(CircleShape)
                        .background(if (isSelected) Color(0xFFFF5252) else Color.White)
                        .graphicsLayer { this.alpha = alpha }
                        .clickable { currentIndex = index }
                )
            }
        }
    }
}

/**
 * 幻灯片专属 TV 交互按钮
 */
@Composable
private fun HeroActionButton(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    isPrimary: Boolean,
    onClick: () -> Unit,
    onFocusChanged: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    var isFocused by remember { mutableStateOf(false) }

    Surface(
        onClick = onClick,
        modifier = modifier
            .onFocusChanged {
                isFocused = it.isFocused
                onFocusChanged(it.isFocused)
            }
            .graphicsLayer {
                scaleX = if (isFocused) 1.06f else 1.0f
                scaleY = if (isFocused) 1.06f else 1.0f
            },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(8.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (isPrimary) Color.White.copy(alpha = 0.92f) else Color.White.copy(alpha = 0.15f),
            focusedContainerColor = if (isPrimary) Color.White else Color.White.copy(alpha = 0.3f)
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f)
    ) {
        Row(
            modifier = Modifier
                .padding(horizontal = 14.dp, vertical = 7.dp)
                .then(
                    if (isFocused) {
                        Modifier.border(2.dp, Color(0xFFFF5252), RoundedCornerShape(8.dp))
                    } else Modifier
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = text,
                tint = if (isPrimary) Color.Black else Color.White,
                modifier = Modifier.size(16.dp)
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = text,
                color = if (isPrimary) Color.Black else Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold
            )
        }
    }
}
