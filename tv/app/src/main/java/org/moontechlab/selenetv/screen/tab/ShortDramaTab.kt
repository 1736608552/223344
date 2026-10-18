package org.moontechlab.selenetv.screen.tab

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.moontechlab.selenetv.model.ShortDrama
import org.moontechlab.selenetv.model.VideoInfo
import org.moontechlab.selenetv.model.toVideoInfo
import org.moontechlab.selenetv.service.ShortDramaService
import org.moontechlab.selenetv.ui.FilterOption
import org.moontechlab.selenetv.ui.FilterSelector
import org.moontechlab.selenetv.ui.VideoCardSource
import org.moontechlab.selenetv.ui.grid.GRID_CARD_WIDTH
import org.moontechlab.selenetv.ui.grid.GRID_COLUMNS
import org.moontechlab.selenetv.ui.grid.GridFilterRow
import org.moontechlab.selenetv.ui.grid.MediaGridScaffold

// 100% 对标手机端 short_drama_screen.dart 首行主分类 (真人剧、漫剧、AI剧)
private val GENRE_FILTER_OPTIONS = listOf(
    FilterOption("all", "全部"),
    FilterOption("short_play", "真人剧"),
    FilterOption("comic_series", "漫剧"),
    FilterOption("ai_series", "AI剧"),
)

// 100% 对标手机端 short_drama_screen.dart 次行排行榜单 (总热播榜、真人剧榜、漫剧榜、AI剧榜)
private val RANK_FILTER_OPTIONS = listOf(
    FilterOption("all", "全部"),
    FilterOption("rank_hot", "总热播榜"),
    FilterOption("rank_real", "真人剧榜"),
    FilterOption("rank_comic", "漫剧榜"),
    FilterOption("rank_ai", "AI剧榜"),
)

private const val HORIZONTAL_PADDING_DP = 58

/**
 * TV 端短剧专区页面 (100% 照搬手机端红果短剧双行分类与官方榜单联动体系)
 */
@Composable
fun ShortDramaTab(
    focusRequester: FocusRequester = remember { FocusRequester() },
    scrollState: ScrollState = rememberScrollState(),
    onVideoSelected: (VideoInfo) -> Unit = {},
) {
    val coroutineScope = rememberCoroutineScope()
    val configuration = LocalConfiguration.current
    val screenWidthDp = configuration.screenWidthDp.toFloat()

    // 计算网格布局间隙 (6 列适配电视横屏)
    val totalCardWidth = GRID_CARD_WIDTH * GRID_COLUMNS
    val totalPadding = HORIZONTAL_PADDING_DP * 2
    val availableForGaps = screenWidthDp - totalCardWidth - totalPadding
    val cardGap = (availableForGaps / (GRID_COLUMNS - 1)).coerceAtLeast(8f).dp
    val horizontalPadding = HORIZONTAL_PADDING_DP.dp

    // 首行主分类 & 次行榜单状态
    var selectedGenreKey by remember { mutableStateOf("all") }
    var selectedRankKey by remember { mutableStateOf("all") }

    var dramaList by remember { mutableStateOf<List<ShortDrama>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var currentPage by remember { mutableIntStateOf(1) }

    val genreFocusRequester = focusRequester
    val rankFocusRequester = remember { FocusRequester() }
    val contentFocusRequester = remember { FocusRequester() }

    fun loadData(isInitial: Boolean = false) {
        coroutineScope.launch {
            if (isInitial) {
                currentPage = 1
                isLoading = true
                errorMessage = null
            }
            try {
                val result = ShortDramaService.getUnifiedList(
                    genreKey = selectedGenreKey,
                    rankKey = selectedRankKey,
                    page = currentPage,
                    size = 24
                )
                dramaList = if (isInitial) result else (dramaList + result).distinctBy { it.id }
                errorMessage = null
                currentPage++
            } catch (e: Exception) {
                if (isInitial) errorMessage = e.message ?: "加载失败"
            } finally {
                isLoading = false
            }
        }
    }

    LaunchedEffect(selectedGenreKey, selectedRankKey) {
        loadData(isInitial = true)
    }

    Box(modifier = Modifier.fillMaxSize()) {
        MediaGridScaffold(
            items = dramaList,
            isLoading = isLoading,
            errorMessage = errorMessage,
            scrollState = scrollState,
            horizontalPadding = horizontalPadding,
            cardGap = cardGap,
            contentFocusRequester = contentFocusRequester,
            resetKey = "${selectedGenreKey}_${selectedRankKey}",
            itemToVideoInfo = { it.toVideoInfo() },
            itemToSource = { VideoCardSource.SHORTDRAMA },
            onItemClick = { drama -> onVideoSelected(drama.toVideoInfo()) },
            onRetry = { loadData(isInitial = true) },
            onLoadMore = { loadData(isInitial = false) },
            onContentNavigateUp = { rankFocusRequester.requestFocus() },
            filterSection = {
                Column(modifier = Modifier.fillMaxWidth()) {
                    // 首行主分类 (全部 / 真人剧 / 漫剧 / AI剧)
                    GridFilterRow(label = "分类") {
                        FilterSelector(
                            options = GENRE_FILTER_OPTIONS,
                            selectedKey = selectedGenreKey,
                            onSelect = { 
                                selectedGenreKey = it
                                // 切换主分类时若处于榜单模式，重置榜单为全部
                                if (selectedRankKey != "all") {
                                    selectedRankKey = "all"
                                }
                            },
                            focusRequester = genreFocusRequester,
                        )
                    }

                    Spacer(modifier = Modifier.height(4.dp))

                    // 次行排行榜单 (全部 / 总热播榜 / 真人剧榜 / 漫剧榜 / AI剧榜)
                    GridFilterRow(label = "排行") {
                        FilterSelector(
                            options = RANK_FILTER_OPTIONS,
                            selectedKey = selectedRankKey,
                            onSelect = { 
                                selectedRankKey = it
                            },
                            focusRequester = rankFocusRequester,
                        )
                    }
                }
            }
        )
    }
}
