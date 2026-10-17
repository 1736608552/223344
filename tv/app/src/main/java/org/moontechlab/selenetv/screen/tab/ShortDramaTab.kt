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
import org.moontechlab.selenetv.ui.grid.GridFilterRow
import org.moontechlab.selenetv.ui.grid.MediaGridScaffold
import org.moontechlab.selenetv.ui.grid.rememberResponsiveGridLayout

private val SHORT_DRAMA_FILTER_OPTIONS = listOf(
    FilterOption("0", "全部短剧"),
    FilterOption("101", "爆款热播"),
    FilterOption("102", "战神逆袭"),
    FilterOption("103", "甜宠言情"),
    FilterOption("104", "都市职场"),
    FilterOption("105", "穿越重生"),
    FilterOption("106", "AI漫剧"),
)

/**
 * TV 端短剧专区页面
 */
@Composable
fun ShortDramaTab(
    focusRequester: FocusRequester = remember { FocusRequester() },
    scrollState: ScrollState = rememberScrollState(),
    onVideoSelected: (VideoInfo) -> Unit = {},
) {
    val coroutineScope = rememberCoroutineScope()
    val configuration = LocalConfiguration.current
    val gridLayout = rememberResponsiveGridLayout(configuration.screenWidthDp.dp)

    var selectedCategoryId by remember { mutableStateOf("0") }
    var dramaList by remember { mutableStateOf<List<ShortDrama>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var currentPage by remember { mutableIntStateOf(1) }

    val categoryFocusRequester = remember { FocusRequester() }
    val contentFocusRequester = remember { FocusRequester() }

    fun loadData(isInitial: Boolean = false) {
        coroutineScope.launch {
            if (isInitial) {
                currentPage = 1
                isLoading = true
                errorMessage = null
            }
            try {
                val catId = selectedCategoryId.toIntOrNull() ?: 0
                val result = ShortDramaService.getShortDramaList(
                    categoryId = catId,
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

    LaunchedEffect(selectedCategoryId) {
        loadData(isInitial = true)
    }

    Box(modifier = Modifier.fillMaxSize()) {
        MediaGridScaffold(
            items = dramaList,
            isLoading = isLoading,
            errorMessage = errorMessage,
            scrollState = scrollState,
            horizontalPadding = gridLayout.horizontalPadding,
            cardGap = gridLayout.cardGap,
            contentFocusRequester = contentFocusRequester,
            resetKey = selectedCategoryId,
            itemToVideoInfo = { it.toVideoInfo() },
            itemToSource = { VideoCardSource.SHORTDRAMA },
            onItemClick = { drama -> onVideoSelected(drama.toVideoInfo()) },
            onRetry = { loadData(isInitial = true) },
            onLoadMore = { loadData(isInitial = false) },
            onContentNavigateUp = { categoryFocusRequester.requestFocus() },
            filterSection = {
                GridFilterRow(onNavigateDown = { contentFocusRequester.requestFocus() }) {
                    FilterSelector(
                        title = "题材",
                        options = SHORT_DRAMA_FILTER_OPTIONS,
                        selectedValue = selectedCategoryId,
                        onSelect = { selectedCategoryId = it },
                        focusRequester = categoryFocusRequester,
                        onNavigateDown = { contentFocusRequester.requestFocus() },
                    )
                }
            }
        )
    }
}
