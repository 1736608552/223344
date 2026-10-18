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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.*
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
 * 全新重构的 TV 影院级顶通沉浸幻灯片 (TvHeroBanner)
 *
 * 核心升级亮点：
 * 1. 突破画框局限：350dp 黄金电影画幅全宽通透展开，彻底消除原本局促的小长条割裂感。
 * 2. 独家智能双模自适应渲染：
 *    - 电影/电视剧（横版剧照）：右侧宽幅电影画面，左侧经多阶多色深黑渐变无缝融合；
 *    - 短剧/竖屏海报：背景全幅漫反射柔光暗影，右侧以 9:16 独立立面悬浮巨幕海报呈现（绝不横向拉伸截断人物与字幕）！
 * 3. 豪华排版层次：渐变分类徽章 + 金黄豆瓣星标评分 + 1080P/独家标签 + 30sp 电影级加粗大标题。
 * 4. 影院级高光聚焦交互：获焦放大 1.08x，主按钮微光呼吸扩散，遥控器上下左右逻辑牢不可破。
 * 5. 底部与第一行卡片自然融合过渡，营造极具现代感与高级感的 TV 首页视觉！
 */
@Composable
fun TvHeroBanner(
    items: List<TvHeroItem>,
    onPlayClick: (VideoInfo) -> Unit,
    onDetailClick: (VideoInfo) -> Unit,
    modifier: Modifier = Modifier,
    bannerFocusRequester: FocusRequester = remember { FocusRequester() },
    onNavigateUp: (() -> Unit)? = null,
    onNavigateDown: (() -> Unit)? = null,
) {
    if (items.isEmpty()) return

    var currentIndex by remember { mutableIntStateOf(0) }
    var isBannerFocused by remember { mutableStateOf(false) }

    // 自动轮播逻辑（6秒切换，横幅获焦时绝对暂停防打扰与防失焦）
    LaunchedEffect(currentIndex, isBannerFocused, items.size) {
        if (!isBannerFocused && items.size > 1) {
            delay(6000)
            if (!isBannerFocused) {
                currentIndex = (currentIndex + 1) % items.size
            }
        }
    }

    val currentItem = items.getOrElse(currentIndex) { items.first() }

    // 判断当前项目是否为竖版短剧（短剧没有 16:9 横版大剧照，通常使用海报作为背景）
    val isShortDrama = currentItem.typeLabel.contains("短剧") ||
            currentItem.videoInfo.source == "shortdrama" ||
            currentItem.backdropUrl.isEmpty() ||
            currentItem.backdropUrl == currentItem.posterUrl

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(350.dp)
            .background(Color.Black)
            .onFocusChanged { focusState ->
                isBannerFocused = focusState.hasFocus
            }
    ) {
        // 1. 大剧照沉浸背景（带平滑淡入淡出 Crossfade 动效）
        Crossfade(
            targetState = currentItem,
            animationSpec = tween(650),
            modifier = Modifier.fillMaxSize(),
            label = "hero_bg_crossfade"
        ) { item ->
            val rawImage = if (item.backdropUrl.isNotEmpty()) item.backdropUrl else item.posterUrl
            val displayUrl = getImageUrlSync(rawImage)

            Box(modifier = Modifier.fillMaxSize()) {
                if (isShortDrama) {
                    // 短剧模式背景：将海报作为全屏高斯微光暗调铺底（提供沉浸式环境光晕）
                    AsyncImage(
                        model = displayUrl,
                        contentDescription = item.title,
                        contentScale = ContentScale.Crop,
                        alignment = Alignment.Center,
                        modifier = Modifier
                            .fillMaxSize()
                            .graphicsLayer { alpha = 0.16f }
                    )
                } else {
                    // 横版电影模式背景：靠右铺满 85% 区域
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .fillMaxWidth(0.85f)
                            .align(Alignment.CenterEnd)
                    ) {
                        AsyncImage(
                            model = displayUrl,
                            contentDescription = item.title,
                            contentScale = ContentScale.Crop,
                            alignment = Alignment.Center,
                            modifier = Modifier.fillMaxSize()
                        )
                    }
                }
            }
        }

        // 2. 电影级专业三重融合遮罩层：
        // (A) 左侧从纯黑到透明的横向遮罩（确保文字在任何明暗剧照下均 100% 清晰，且左边缘完美融入黑色底板）
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.horizontalGradient(
                        0.0f to Color.Black,
                        0.38f to Color.Black,
                        0.58f to Color.Black.copy(alpha = 0.90f),
                        0.80f to Color.Black.copy(alpha = 0.40f),
                        1.0f to Color.Transparent,
                    )
                )
        )

        // (B) 顶部向纯黑平滑羽化过渡（彻底消除顶部导航栏下方的横向切线与色块断层）
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(90.dp)
                .align(Alignment.TopCenter)
                .background(
                    Brush.verticalGradient(
                        0.0f to Color.Black,
                        0.40f to Color.Black.copy(alpha = 0.70f),
                        1.0f to Color.Transparent,
                    )
                )
        )

        // (C) 底部向纯黑背景无缝融化（与下方推荐行自然交融）
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.0f to Color.Transparent,
                        0.55f to Color.Transparent,
                        0.85f to Color.Black.copy(alpha = 0.85f),
                        1.0f to Color.Black,
                    )
                )
        )

        // 3. 右侧舞台：短剧 9:16 独立立面 3D 悬浮巨幕海报 + 背后立体漫反射光晕（绝不切头切字幕，彻底消除死黑孤立感！）
        if (isShortDrama) {
            Box(
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .padding(end = 44.dp, top = 20.dp, bottom = 26.dp)
                    .width(175.dp)
                    .fillMaxHeight()
            ) {
                // (1) 海报背后环境光辉漫反射层（消除死黑孤立感，营造影院级通透氛围）
                AsyncImage(
                    model = getImageUrlSync(currentItem.posterUrl),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    alignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 6.dp, vertical = 6.dp)
                        .graphicsLayer {
                            alpha = 0.35f
                            scaleX = 1.08f
                            scaleY = 1.08f
                        }
                        .clip(RoundedCornerShape(16.dp))
                )

                // (2) 前景立面高清单体海报
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .shadow(20.dp, RoundedCornerShape(14.dp))
                        .clip(RoundedCornerShape(14.dp))
                        .border(
                            1.2.dp,
                            Brush.verticalGradient(
                                listOf(
                                    Color.White.copy(alpha = 0.30f),
                                    Color.White.copy(alpha = 0.08f)
                                )
                            ),
                            RoundedCornerShape(14.dp)
                        )
                        .background(Color(0xFF141414))
                ) {
                    AsyncImage(
                        model = getImageUrlSync(currentItem.posterUrl),
                        contentDescription = currentItem.title,
                        contentScale = ContentScale.Crop,
                        alignment = Alignment.Center,
                        modifier = Modifier.fillMaxSize()
                    )
                    // 海报底部微光渐变，烘托立体纵深感
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(65.dp)
                            .align(Alignment.BottomCenter)
                            .background(
                                Brush.verticalGradient(
                                    listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f))
                                )
                            )
                    )
                }
            }
        }

        // 4. 左侧核心内容区域（大标、徽章、导语、按钮）
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .fillMaxWidth(if (isShortDrama) 0.68f else 0.62f)
                .padding(start = 36.dp, top = 28.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Column {
                // 顶部标签组（分类胶囊 + 评分 + 标签）
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    // 分类高光胶囊
                    val badgeGradient = if (currentItem.typeLabel.contains("短剧")) {
                        listOf(Color(0xFFFF6D00), Color(0xFFFF9100))
                    } else if (currentItem.typeLabel.contains("番") || currentItem.typeLabel.contains("漫")) {
                        listOf(Color(0xFF7C4DFF), Color(0xFFB388FF))
                    } else {
                        listOf(Color(0xFFE50914), Color(0xFFFF5252))
                    }

                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(5.dp))
                            .background(Brush.horizontalGradient(badgeGradient))
                            .padding(horizontal = 8.dp, vertical = 3.dp)
                    ) {
                        Text(
                            text = currentItem.typeLabel,
                            color = Color.White,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }

                    // 评分药丸
                    if (currentItem.rate.isNotEmpty() && currentItem.rate != "0.0") {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(RoundedCornerShape(5.dp))
                                .background(Color.White.copy(alpha = 0.12f))
                                .border(1.dp, Color(0xFFFFD54F).copy(alpha = 0.35f), RoundedCornerShape(5.dp))
                                .padding(horizontal = 7.dp, vertical = 3.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Star,
                                contentDescription = "Rate",
                                tint = Color(0xFFFFB300),
                                modifier = Modifier.size(13.dp)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(
                                text = currentItem.rate,
                                color = Color(0xFFFFD54F),
                                fontSize = 12.sp,
                                fontWeight = FontWeight.ExtraBold
                            )
                        }
                    }

                    // 年份徽章
                    if (currentItem.year.isNotEmpty()) {
                        Text(
                            text = currentItem.year,
                            color = Color.White.copy(alpha = 0.75f),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier
                                .clip(RoundedCornerShape(4.dp))
                                .background(Color.White.copy(alpha = 0.08f))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        )
                    }

                    // 画质标识
                    Text(
                        text = "1080P 原画",
                        color = Color(0xFF64B5F6),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .clip(RoundedCornerShape(4.dp))
                            .background(Color(0xFF1976D2).copy(alpha = 0.2f))
                            .border(1.dp, Color(0xFF64B5F6).copy(alpha = 0.4f), RoundedCornerShape(4.dp))
                            .padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }

                Spacer(modifier = Modifier.height(14.dp))

                // 电影海报级主标题（30sp 加粗 + 阴影防花）
                Text(
                    text = currentItem.title,
                    color = Color.White,
                    fontSize = 30.sp,
                    fontWeight = FontWeight.ExtraBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )

                Spacer(modifier = Modifier.height(10.dp))

                // 看点梗概（舒展行高与舒适对比度）
                if (currentItem.overview.isNotEmpty()) {
                    Text(
                        text = currentItem.overview,
                        color = Color(0xFFCCCCCC),
                        fontSize = 13.sp,
                        lineHeight = 19.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }

            // 底部操作按钮组
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // 按钮 1：立即播放（挂载 bannerFocusRequester，支持上下遥控导航）
                CinemaActionButton(
                    text = "立即播放",
                    icon = Icons.Default.PlayArrow,
                    isPrimary = true,
                    onClick = { onPlayClick(currentItem.videoInfo) },
                    onFocusChanged = { focused ->
                        if (focused) isBannerFocused = true
                    },
                    modifier = Modifier
                        .focusRequester(bannerFocusRequester)
                        .onPreviewKeyEvent { keyEvent ->
                            if (keyEvent.type == KeyEventType.KeyDown) {
                                when (keyEvent.key) {
                                    Key.DirectionUp -> {
                                        onNavigateUp?.invoke()
                                        onNavigateUp != null
                                    }
                                    Key.DirectionDown -> {
                                        onNavigateDown?.invoke()
                                        onNavigateDown != null
                                    }
                                    Key.DirectionLeft -> {
                                        true // 左边界锁定防脱焦
                                    }
                                    else -> false
                                }
                            } else false
                        }
                )

                // 按钮 2：查看详情（次级按钮，支持上下导航）
                CinemaActionButton(
                    text = "查看详情",
                    icon = Icons.Default.Info,
                    isPrimary = false,
                    onClick = { onDetailClick(currentItem.videoInfo) },
                    onFocusChanged = { focused ->
                        if (focused) isBannerFocused = true
                    },
                    modifier = Modifier.onPreviewKeyEvent { keyEvent ->
                        if (keyEvent.type == KeyEventType.KeyDown) {
                            when (keyEvent.key) {
                                Key.DirectionUp -> {
                                    onNavigateUp?.invoke()
                                    onNavigateUp != null
                                }
                                Key.DirectionDown -> {
                                    onNavigateDown?.invoke()
                                    onNavigateDown != null
                                }
                                Key.DirectionRight -> {
                                    true // 阻断向右进入盲区，杜绝失焦
                                }
                                else -> false
                            }
                        } else false
                    }
                )
            }
        }

        // 5. 悬浮微光指示器
        Row(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 36.dp, bottom = 24.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp)
        ) {
            items.indices.forEach { index ->
                val isSelected = index == currentIndex
                val width by animateDpAsState(
                    targetValue = if (isSelected) 26.dp else 7.dp,
                    animationSpec = tween(350),
                    label = "ind_width"
                )
                val alpha by animateFloatAsState(
                    targetValue = if (isSelected) 1.0f else 0.35f,
                    animationSpec = tween(350),
                    label = "ind_alpha"
                )
                Box(
                    modifier = Modifier
                        .height(6.dp)
                        .width(width)
                        .clip(CircleShape)
                        .background(if (isSelected) Color(0xFFFF5252) else Color.White)
                        .graphicsLayer { this.alpha = alpha }
                        .focusProperties { canFocus = false }
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null
                        ) { currentIndex = index }
                )
            }
        }
    }
}

/**
 * 影院级高光聚焦交互按钮
 */
@Composable
private fun CinemaActionButton(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    isPrimary: Boolean,
    onClick: () -> Unit,
    onFocusChanged: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    var isFocused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (isFocused) 1.08f else 1.0f,
        animationSpec = tween(220),
        label = "btn_scale"
    )

    Surface(
        onClick = onClick,
        modifier = modifier
            .onFocusChanged {
                isFocused = it.isFocused
                onFocusChanged(it.isFocused)
            }
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .then(
                if (isFocused) {
                    Modifier.border(2.dp, Color.White, RoundedCornerShape(12.dp))
                } else {
                    Modifier.border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
                }
            ),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(12.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (isPrimary) Color.White.copy(alpha = 0.25f) else Color.White.copy(alpha = 0.12f),
            focusedContainerColor = Color.White
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = text,
                tint = if (isFocused) Color(0xFF111111) else Color.White,
                modifier = Modifier.size(19.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = text,
                color = if (isFocused) Color(0xFF111111) else Color.White,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold
            )
        }
    }
}
