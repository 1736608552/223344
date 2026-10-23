package org.moontechlab.selenetv.screen.tab

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.tooling.preview.Devices
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.moontechlab.selenetv.model.VideoInfo
import org.moontechlab.selenetv.model.toVideoInfo
import org.moontechlab.selenetv.data.Repositories
import org.moontechlab.selenetv.service.ApiResponse
import org.moontechlab.selenetv.service.ApiService
import org.moontechlab.selenetv.service.AppDataService
import org.moontechlab.selenetv.service.BangumiService
import org.moontechlab.selenetv.service.DoubanService
import org.moontechlab.selenetv.service.DoubanCacheService
import org.moontechlab.selenetv.service.ShortDramaService
import org.moontechlab.selenetv.service.TmdbService
import org.moontechlab.selenetv.ui.TvHeroBanner
import org.moontechlab.selenetv.ui.TvHeroItem
import org.moontechlab.selenetv.ui.CardContextMenu
import org.moontechlab.selenetv.ui.CardMenuItem
import org.moontechlab.selenetv.ui.ConfirmDialog
import org.moontechlab.selenetv.ui.RecommendSection
import org.moontechlab.selenetv.ui.VideoCardSource

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HomeTab(
    focusRequester: FocusRequester = remember { FocusRequester() },
    scrollState: ScrollState = rememberScrollState(),
    onVideoSelected: (VideoInfo) -> Unit = {},
    homeRefreshKey: Int = 0,
    onNavigateUpToHeader: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val doubanCacheService = remember { DoubanCacheService.getInstance(context) }
    val coroutineScope = rememberCoroutineScope()
    
    // 首屏焦点请求器（用于衔接 banner 与内容推荐横轴）
    val firstContentFocusRequester = remember { FocusRequester() }
    val bannerFocusRequester = remember { FocusRequester() }
    
    // 播放历史数据状态
    var playRecords by remember { mutableStateOf<List<VideoInfo>>(emptyList()) }
    var isLoadingPlayRecords by remember { mutableStateOf(true) }
    var errorPlayRecords by remember { mutableStateOf<String?>(null) }

    // 收藏夹数据状态
    var favorites by remember { mutableStateOf<List<VideoInfo>>(emptyList()) }
    var isLoadingFavorites by remember { mutableStateOf(true) }
    var errorFavorites by remember { mutableStateOf<String?>(null) }

    // 热门电影数据状态
    var hotMovies by remember { mutableStateOf<List<VideoInfo>>(emptyList()) }
    var isLoadingMovies by remember { mutableStateOf(true) }
    var errorMovies by remember { mutableStateOf<String?>(null) }

    // 热门短剧数据状态
    var hotShortDramas by remember { mutableStateOf<List<VideoInfo>>(emptyList()) }
    var isLoadingShortDramas by remember { mutableStateOf(true) }
    var errorShortDramas by remember { mutableStateOf<String?>(null) }

    // 热门剧集数据状态
    var hotTvShows by remember { mutableStateOf<List<VideoInfo>>(emptyList()) }
    var isLoadingTvShows by remember { mutableStateOf(true) }
    var errorTvShows by remember { mutableStateOf<String?>(null) }

    // 新番放送数据状态
    var bangumiCalendar by remember { mutableStateOf<List<VideoInfo>>(emptyList()) }
    var isLoadingBangumi by remember { mutableStateOf(true) }
    var errorBangumi by remember { mutableStateOf<String?>(null) }

    // 热门综艺数据状态
    var hotShows by remember { mutableStateOf<List<VideoInfo>>(emptyList()) }
    var isLoadingShows by remember { mutableStateOf(true) }
    var errorShows by remember { mutableStateOf<String?>(null) }

    val doubanService = remember { DoubanService.getInstance(context) }
    val bangumiService = remember { BangumiService.getInstance(context) }

    // 登录态：未登录时隐藏「继续观看」「我的收藏」并跳过其加载。
    // 随 homeRefreshKey 重新读取（登录后从其他页返回会刷新）。
    val isLoggedIn = remember(homeRefreshKey) { AppDataService.isLoggedInSync() || AppDataService.isLocalModeSync() }

    // 用于匹配的播放记录 Map（收藏夹需要）
    var playRecordsMap by remember { mutableStateOf<Map<String, org.moontechlab.selenetv.model.PlayRecord>>(emptyMap()) }

    // ===== 长按菜单 / 二次确认 状态 =====
    // 当前被长按的卡片及其来源；menuVisible 单独控制显隐，
    // 关闭动画期间需保持 target 不变（与 FilterDialog 一样常驻组合树）
    var menuVisible by remember { mutableStateOf(false) }
    var menuTarget by remember { mutableStateOf<VideoInfo?>(null) }
    var menuFrom by remember { mutableStateOf<VideoCardSource?>(null) }
    // 二次确认弹窗
    var confirmVisible by remember { mutableStateOf(false) }
    var confirmTitle by remember { mutableStateOf("") }
    var confirmMessage by remember { mutableStateOf("") }
    var confirmAction by remember { mutableStateOf<() -> Unit>({}) }

    // 当前收藏的 key 集合，用于判断「继续观看」卡片是否已收藏
    val favoriteKeys = remember(favorites) {
        favorites.map { "${it.source}+${it.id}" }.toSet()
    }

    // 删除播放记录：乐观移除 + 失败回滚
    fun deletePlayRecordAction(video: VideoInfo) {
        val prev = playRecords
        playRecords = playRecords.filterNot { it.source == video.source && it.id == video.id }
        coroutineScope.launch {
            try {
                withContext(Dispatchers.IO) { Repositories.userData().deletePlayRecord(video.source, video.id) }
            } catch (e: Exception) {
                playRecords = prev
                android.util.Log.e("HomeTab", "删除播放记录失败: ${e.message}")
            }
        }
    }

    // 添加收藏：乐观插入到收藏列表头部 + 失败回滚
    fun addFavoriteAction(video: VideoInfo) {
        val key = "${video.source}+${video.id}"
        if (favoriteKeys.contains(key)) return
        val prev = favorites
        favorites = listOf(video.copy(saveTime = System.currentTimeMillis())) + favorites
        coroutineScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    Repositories.userData().addFavorite(
                        video.source,
                        video.id,
                        mapOf(
                            "title" to video.title,
                            "source_name" to video.sourceName,
                            "year" to video.year,
                            "cover" to video.cover,
                            "total_episodes" to video.totalEpisodes,
                            "save_time" to System.currentTimeMillis(),
                        )
                    )
                }
            } catch (e: Exception) {
                favorites = prev
                android.util.Log.e("HomeTab", "添加收藏失败: ${e.message}")
            }
        }
    }

    // 取消收藏：乐观移除 + 失败回滚（favoriteKeys 随之更新，继续观看的收藏态自动同步）
    fun unfavoriteAction(video: VideoInfo) {
        val prev = favorites
        favorites = favorites.filterNot { it.source == video.source && it.id == video.id }
        coroutineScope.launch {
            try {
                withContext(Dispatchers.IO) { Repositories.userData().unfavorite(video.source, video.id) }
            } catch (e: Exception) {
                favorites = prev
                android.util.Log.e("HomeTab", "取消收藏失败: ${e.message}")
            }
        }
    }

    // 弹出二次确认弹窗
    fun requestConfirm(title: String, message: String, action: () -> Unit) {
        confirmTitle = title
        confirmMessage = message
        confirmAction = action
        confirmVisible = true
    }

    // 加载播放历史 + 收藏夹（收藏夹依赖播放历史的 index）
    fun loadPlayRecordsAndFavorites() {
        // 未登录：不请求（会抛「未登录」异常），直接清空并置为非加载态，区块由 isLoggedIn 隐藏
        if (!(AppDataService.isLoggedInSync() || AppDataService.isLocalModeSync())) {
            playRecords = emptyList()
            favorites = emptyList()
            isLoadingPlayRecords = false
            isLoadingFavorites = false
            errorPlayRecords = null
            errorFavorites = null
            return
        }
        coroutineScope.launch {
            // 刷新时若已有数据，保持现有卡片、静默原地刷新；不要切到骨架屏。
            // 否则会销毁正在聚焦的卡片，导致从详情返回时焦点被 focusRestorer 重置到第一个。
            if (playRecords.isEmpty()) isLoadingPlayRecords = true
            errorPlayRecords = null
            if (favorites.isEmpty()) isLoadingFavorites = true
            errorFavorites = null

            try {
                val records = withContext(Dispatchers.IO) {
                    Repositories.userData().getPlayRecords()
                }
                playRecordsMap = records
                val newRecords = records.values
                    .sortedByDescending { it.saveTime }
                    .map { it.toVideoInfo() }
                // 数据未变则不重新赋值，避免触发 LazyRow 的 focusRestorer 把焦点重置到第一个
                // （从详情返回时若 homeRefreshKey 刷新恰好在焦点恢复后完成，会抢走焦点）
                if (newRecords != playRecords) playRecords = newRecords
                errorPlayRecords = null
            } catch (e: Exception) {
                errorPlayRecords = e.message ?: "加载失败"
                android.util.Log.e("HomeTab", "加载播放历史失败: ${e.message}")
            }
            isLoadingPlayRecords = false

            try {
                val favList = withContext(Dispatchers.IO) {
                    Repositories.userData().getFavorites()
                }
                val newFavs = favList.map { fav ->
                    val key = "${fav.source}+${fav.id}"
                    val matchedRecord = playRecordsMap[key]
                    val videoInfo = fav.toVideoInfo()
                    if (matchedRecord != null) {
                        videoInfo.copy(index = matchedRecord.index)
                    } else {
                        videoInfo
                    }
                }
                // 同上：数据未变则不重新赋值，避免焦点被 focusRestorer 重置
                if (newFavs != favorites) favorites = newFavs
                errorFavorites = null
            } catch (e: Exception) {
                errorFavorites = e.message ?: "加载失败"
                android.util.Log.e("HomeTab", "加载收藏夹失败: ${e.message}")
            }
            isLoadingFavorites = false
        }
    }

    fun loadHotMovies() {
        coroutineScope.launch {
            isLoadingMovies = true
            errorMovies = null
            when (val response = doubanService.getHotMovies(pageLimit = 20, page = 0)) {
                is ApiResponse.Success -> {
                    hotMovies = response.data.map { it.toVideoInfo() }
                    errorMovies = null
                }
                is ApiResponse.Error -> {
                    errorMovies = response.message
                    android.util.Log.e("HomeTab", "加载热门电影失败: ${response.message}")
                }
            }
            isLoadingMovies = false
        }
    }

    fun loadHotTvShows() {
        coroutineScope.launch {
            isLoadingTvShows = true
            errorTvShows = null
            when (val response = doubanService.getHotTvShows(pageLimit = 20, page = 0)) {
                is ApiResponse.Success -> {
                    hotTvShows = response.data.map { it.toVideoInfo() }
                    errorTvShows = null
                }
                is ApiResponse.Error -> {
                    errorTvShows = response.message
                    android.util.Log.e("HomeTab", "加载热门剧集失败: ${response.message}")
                }
            }
            isLoadingTvShows = false
        }
    }

    fun loadBangumi() {
        coroutineScope.launch {
            isLoadingBangumi = true
            errorBangumi = null
            when (val response = bangumiService.getTodayCalendar()) {
                is ApiResponse.Success -> {
                    bangumiCalendar = response.data.map { it.toVideoInfo() }
                    errorBangumi = null
                }
                is ApiResponse.Error -> {
                    errorBangumi = response.message
                    android.util.Log.e("HomeTab", "加载新番放送失败: ${response.message}")
                }
            }
            isLoadingBangumi = false
        }
    }

    fun loadHotShows() {
        coroutineScope.launch {
            isLoadingShows = true
            errorShows = null
            when (val response = doubanService.getHotShows(pageLimit = 20, page = 0)) {
                is ApiResponse.Success -> {
                    hotShows = response.data.map { it.toVideoInfo() }
                    errorShows = null
                }
                is ApiResponse.Error -> {
                    errorShows = response.message
                    android.util.Log.e("HomeTab", "加载热门综艺失败: ${response.message}")
                }
            }
            isLoadingShows = false
        }
    }

    fun loadHotShortDramas() {
        coroutineScope.launch {
            isLoadingShortDramas = true
            errorShortDramas = null
            try {
                val list = ShortDramaService.getUnifiedList(genreKey = "all", rankKey = "rank_hot", page = 1, size = 20)
                hotShortDramas = list.map { it.toVideoInfo() }
            } catch (e: Exception) {
                errorShortDramas = e.message ?: "加载失败"
            } finally {
                isLoadingShortDramas = false
            }
        }
    }

    // 初始加载
    LaunchedEffect(Unit) {
        loadPlayRecordsAndFavorites()
        loadHotMovies()
        loadHotTvShows()
        loadHotShortDramas()
        loadBangumi()
        loadHotShows()
    }

    LaunchedEffect(homeRefreshKey) {
        if (homeRefreshKey > 0) {  // 跳过首次（已由 LaunchedEffect(Unit) 触发）
            loadPlayRecordsAndFavorites()
        }
    }

    // 聚合电影、剧集、短剧生成大屏沉浸幻灯片数据 (精选 6 部大作)
    val heroBannerItems = remember(hotMovies, hotTvShows, hotShortDramas) {
        val list = mutableListOf<TvHeroItem>()
        hotMovies.take(2).forEach { v ->
            val cachedIntro = if (!v.doubanId.isNullOrEmpty()) {
                doubanCacheService.get("${v.doubanId}_details") { raw ->
                    try {
                        kotlinx.serialization.json.Json { ignoreUnknownKeys = true }.decodeFromString<org.moontechlab.selenetv.model.DoubanMovieDetails>(raw).summary
                    } catch (_: Exception) { null }
                }?.trim()
            } else null

            list.add(
                TvHeroItem(
                    id = v.id,
                    title = v.title,
                    overview = cachedIntro.takeIf { !it.isNullOrEmpty() } ?: "豆瓣高分佳作 · ${v.year} 华语精选 · 超清大屏视界",
                    backdropUrl = v.cover,
                    posterUrl = v.cover,
                    typeLabel = "院线电影",
                    rate = v.rate ?: "9.5",
                    year = v.year,
                    videoInfo = v
                )
            )
        }
        hotShortDramas.take(2).forEach { v ->
            val cachedIntro = org.moontechlab.selenetv.hongguo.HongguoStreamResolver.getCachedSeriesIntro(v.id).trim()
            list.add(
                TvHeroItem(
                    id = v.id,
                    title = v.title,
                    overview = cachedIntro.takeIf { it.isNotEmpty() } ?: "爆款独家短剧 · 全${v.totalEpisodes}集爽剧连播 · 精彩反转",
                    backdropUrl = v.cover,
                    posterUrl = v.cover,
                    typeLabel = "热门短剧",
                    rate = v.rate ?: "9.8",
                    year = v.year,
                    videoInfo = v
                )
            )
        }
        hotTvShows.take(2).forEach { v ->
            val cachedIntro = if (!v.doubanId.isNullOrEmpty()) {
                doubanCacheService.get("${v.doubanId}_details") { raw ->
                    try {
                        kotlinx.serialization.json.Json { ignoreUnknownKeys = true }.decodeFromString<org.moontechlab.selenetv.model.DoubanMovieDetails>(raw).summary
                    } catch (_: Exception) { null }
                }?.trim()
            } else null

            list.add(
                TvHeroItem(
                    id = v.id,
                    title = v.title,
                    overview = cachedIntro.takeIf { !it.isNullOrEmpty() } ?: "全网热播黄金档 · 沉浸连播 · ${v.year} 必看佳作",
                    backdropUrl = v.cover,
                    posterUrl = v.cover,
                    typeLabel = "热门剧集",
                    rate = v.rate ?: "9.6",
                    year = v.year,
                    videoInfo = v
                )
            )
        }
        list
    }

    var enrichedBannerItems by remember { mutableStateOf<List<TvHeroItem>>(emptyList()) }

    // 异步拉取剧情简介 (电影、电视剧、短剧全覆盖) 与 TMDB 高清大剧照 (w1280)/海报 (w780)
    LaunchedEffect(heroBannerItems) {
        if (heroBannerItems.isEmpty()) {
            enrichedBannerItems = emptyList()
            return@LaunchedEffect
        }
        enrichedBannerItems = heroBannerItems

        withContext(Dispatchers.IO) {
            val tmdbKey = AppDataService.getTmdbKeySync()
            val updated = heroBannerItems.map { item ->
                val isDrama = item.videoInfo.source == "shortdrama" ||
                        item.videoInfo.source == "hongguo" ||
                        item.typeLabel.contains("短剧")

                // 1. 剧情简介异步补齐 (全品类支持：短剧调取短剧解析器，影视剧调取豆瓣详情)
                var realOverview = item.overview
                if (isDrama) {
                    val dramaIntro = runCatching {
                        org.moontechlab.selenetv.hongguo.HongguoStreamResolver.fetchSeriesIntro(item.videoInfo.id)
                    }.getOrNull()?.trim()
                    if (!dramaIntro.isNullOrEmpty()) {
                        realOverview = dramaIntro
                    }
                } else if (!item.videoInfo.doubanId.isNullOrEmpty()) {
                    val doubanResp = runCatching {
                        doubanService.getDoubanDetails(item.videoInfo.doubanId)
                    }.getOrNull()
                    if (doubanResp is ApiResponse.Success && doubanResp.data != null) {
                        val doubanSummary = doubanResp.data.summary?.trim()
                        if (!doubanSummary.isNullOrEmpty()) {
                            realOverview = doubanSummary
                        }
                    }
                }

                // 2. TMDB 高清大剧照与海报异步增强
                val newBackdrop: String
                val newPoster: String
                if (isDrama && item.backdropUrl.isNotEmpty()) {
                    newBackdrop = item.backdropUrl
                    newPoster = item.posterUrl
                } else {
                    val art = runCatching {
                        TmdbService.resolveArt(
                            originalTitle = item.title,
                            year = item.year,
                            apiKey = tmdbKey,
                            cache = doubanCacheService
                        )
                    }.getOrNull()

                    newBackdrop = art?.backdropUrl ?: item.backdropUrl
                    newPoster = art?.posterUrl ?: item.posterUrl
                }

                item.copy(
                    overview = realOverview,
                    backdropUrl = newBackdrop,
                    posterUrl = newPoster
                )
            }
            enrichedBannerItems = updated
        }
    }

    // 各推荐横轴专属 FocusRequester，构建无缝垂直焦点链路
    val playRecordsFocusRequester = remember { FocusRequester() }
    val favoritesFocusRequester = remember { FocusRequester() }
    val hotMoviesFocusRequester = remember { FocusRequester() }
    val hotShortDramasFocusRequester = remember { FocusRequester() }
    val hotTvShowsFocusRequester = remember { FocusRequester() }
    val bangumiFocusRequester = remember { FocusRequester() }
    val hotShowsFocusRequester = remember { FocusRequester() }

    // 智能平滑视口滚动规范：横向切卡片时视口稳如泰山，纵向换行时平滑将卡片带入最佳黄金浏览区
    val tvBringIntoViewSpec = remember {
        object : BringIntoViewSpec {
            override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
                val topThreshold = 68f
                val bottomThreshold = containerSize - 40f
                val itemTop = offset
                val itemBottom = offset + size

                // 若目标已经在舒适可视区内，禁止垂直滚动（彻底消解左右换卡片时的上下微晃）
                if (itemTop >= topThreshold && itemBottom <= bottomThreshold) {
                    return 0f
                }
                // 向下导航：平滑将下一行滚入视口中上方（约 32% 位置）
                if (itemBottom > bottomThreshold) {
                    return itemTop - (containerSize * 0.32f)
                }
                // 向上导航：平滑回滚至顶部边距
                if (itemTop < topThreshold) {
                    return itemTop - topThreshold
                }
                return 0f
            }
        }
    }

    CompositionLocalProvider(
        androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides tvBringIntoViewSpec
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .focusGroup()
        ) {
            // 顶部留出 TabSwitcher 的空间
            Spacer(modifier = Modifier.height(58.dp))

            // 全新设计的 TV 专属现代化沉浸视界幻灯片 (优先呈现 TMDB 超清大图)
            val displayBannerItems = if (enrichedBannerItems.isNotEmpty()) enrichedBannerItems else heroBannerItems
            val hasBanner = displayBannerItems.isNotEmpty()

            // 确定各区块的显隐与首个内容行焦点目标
            val showPlayRecords = isLoggedIn && (playRecords.isNotEmpty() || isLoadingPlayRecords || errorPlayRecords != null)
            val showFavorites = isLoggedIn && (favorites.isNotEmpty() || isLoadingFavorites || errorFavorites != null)
            val firstContentRequester = when {
                showPlayRecords -> playRecordsFocusRequester
                showFavorites -> favoritesFocusRequester
                else -> hotMoviesFocusRequester
            }

            // 向上直达 Banner 或顶部导航栏：联动平滑回滚至顶部 0 位置，完整展开巨幕 Banner 与顶部导航栏
            val navigateUpToBannerOrHeader: () -> Boolean = {
                coroutineScope.launch {
                    scrollState.animateScrollTo(0)
                }
                if (hasBanner && focusRequester.safeRequestFocus()) {
                    true
                } else if (onNavigateUpToHeader != null) {
                    onNavigateUpToHeader.invoke()
                    true
                } else {
                    false
                }
            }

            // 纵向安全向下导航：先平滑滚动视口，再尝试链式聚焦，杜绝因组件在视口外抛异常导致锁死
            val navigateDownWithScroll: (List<FocusRequester>) -> Boolean = { targets ->
                coroutineScope.launch {
                    scrollState.animateScrollBy(340f)
                }
                var handled = false
                for (target in targets) {
                    if (target.safeRequestFocus()) {
                        handled = true
                        break
                    }
                }
                handled
            }

            // 纵向安全向上导航：平滑回滚视口，并链式尝试聚焦上层组件
            val navigateUpWithScroll: (List<FocusRequester>, (() -> Boolean)?) -> Boolean = { targets, fallbackToTop ->
                coroutineScope.launch {
                    if (scrollState.value <= 340) {
                        scrollState.animateScrollTo(0)
                    } else {
                        scrollState.animateScrollBy(-340f)
                    }
                }
                var handled = false
                for (target in targets) {
                    if (target.safeRequestFocus()) {
                        handled = true
                        break
                    }
                }
                if (!handled && fallbackToTop != null) {
                    handled = fallbackToTop()
                }
                handled
            }

            if (hasBanner) {
                TvHeroBanner(
                    items = displayBannerItems,
                    onPlayClick = onVideoSelected,
                    onDetailClick = onVideoSelected,
                    bannerFocusRequester = focusRequester,
                    onNavigateUp = onNavigateUpToHeader,
                    onNavigateDown = {
                        navigateDownWithScroll(listOf(firstContentRequester, hotMoviesFocusRequester))
                    },
                    onBannerFocused = {
                        if (scrollState.value > 0) {
                            coroutineScope.launch {
                                scrollState.animateScrollTo(0)
                            }
                        }
                    },
                    modifier = Modifier.padding(bottom = 6.dp)
                )
            }
            
            // 播放历史 - 仅登录后、且有数据/加载中/有错误时显示
            if (showPlayRecords) {
                RecommendSection(
                    title = "继续观看",
                    videos = playRecords,
                    from = VideoCardSource.PLAYRECORD,
                    isLoading = isLoadingPlayRecords,
                    errorMessage = errorPlayRecords,
                    firstCardFocusRequester = playRecordsFocusRequester,
                    onNavigateUp = navigateUpToBannerOrHeader,
                    onNavigateDown = {
                        val targets = if (showFavorites && favorites.isNotEmpty()) {
                            listOf(favoritesFocusRequester, hotMoviesFocusRequester)
                        } else {
                            listOf(hotMoviesFocusRequester, hotShortDramasFocusRequester)
                        }
                        navigateDownWithScroll(targets)
                    },
                    onRetry = { loadPlayRecordsAndFavorites() },
                    onVideoClick = onVideoSelected,
                    onVideoLongClick = { video ->
                        menuTarget = video
                        menuFrom = VideoCardSource.PLAYRECORD
                        menuVisible = true
                    }
                )
            }

            // 收藏夹 - 仅登录后、且有数据/加载中/有错误时显示
            if (showFavorites) {
                RecommendSection(
                    title = "我的收藏",
                    videos = favorites,
                    from = VideoCardSource.FAVORITE,
                    isLoading = isLoadingFavorites,
                    errorMessage = errorFavorites,
                    firstCardFocusRequester = favoritesFocusRequester,
                    onNavigateUp = {
                        val targets = if (showPlayRecords) listOf(playRecordsFocusRequester) else emptyList()
                        navigateUpWithScroll(targets, navigateUpToBannerOrHeader)
                    },
                    onNavigateDown = {
                        navigateDownWithScroll(listOf(hotMoviesFocusRequester, hotShortDramasFocusRequester))
                    },
                    onRetry = { loadPlayRecordsAndFavorites() },
                    onVideoClick = onVideoSelected,
                    onVideoLongClick = { video ->
                        menuTarget = video
                        menuFrom = VideoCardSource.FAVORITE
                        menuVisible = true
                    }
                )
            }

            RecommendSection(
                title = "热门电影",
                videos = hotMovies,
                from = VideoCardSource.DOUBAN,
                isLoading = isLoadingMovies,
                errorMessage = errorMovies,
                firstCardFocusRequester = hotMoviesFocusRequester,
                onNavigateUp = {
                    val targets = buildList {
                        if (showFavorites && favorites.isNotEmpty()) add(favoritesFocusRequester)
                        if (showPlayRecords) add(playRecordsFocusRequester)
                    }
                    navigateUpWithScroll(targets, navigateUpToBannerOrHeader)
                },
                onNavigateDown = {
                    navigateDownWithScroll(listOf(hotShortDramasFocusRequester, hotTvShowsFocusRequester))
                },
                onRetry = { loadHotMovies() },
                onVideoClick = onVideoSelected
            )

            // 热门短剧推荐横轴
            RecommendSection(
                title = "热门短剧",
                videos = hotShortDramas,
                from = VideoCardSource.SHORTDRAMA,
                isLoading = isLoadingShortDramas,
                errorMessage = errorShortDramas,
                firstCardFocusRequester = hotShortDramasFocusRequester,
                onNavigateUp = {
                    navigateUpWithScroll(listOf(hotMoviesFocusRequester), null)
                },
                onNavigateDown = {
                    navigateDownWithScroll(listOf(hotTvShowsFocusRequester, bangumiFocusRequester))
                },
                onRetry = { loadHotShortDramas() },
                onVideoClick = onVideoSelected
            )

            RecommendSection(
                title = "热门剧集",
                videos = hotTvShows,
                from = VideoCardSource.DOUBAN,
                isLoading = isLoadingTvShows,
                errorMessage = errorTvShows,
                firstCardFocusRequester = hotTvShowsFocusRequester,
                onNavigateUp = {
                    navigateUpWithScroll(listOf(hotShortDramasFocusRequester, hotMoviesFocusRequester), null)
                },
                onNavigateDown = {
                    navigateDownWithScroll(listOf(bangumiFocusRequester, hotShowsFocusRequester))
                },
                onRetry = { loadHotTvShows() },
                onVideoClick = onVideoSelected
            )

            RecommendSection(
                title = "新番放送",
                videos = bangumiCalendar,
                from = VideoCardSource.BANGUMI,
                isLoading = isLoadingBangumi,
                errorMessage = errorBangumi,
                firstCardFocusRequester = bangumiFocusRequester,
                onNavigateUp = {
                    navigateUpWithScroll(listOf(hotTvShowsFocusRequester, hotShortDramasFocusRequester), null)
                },
                onNavigateDown = {
                    navigateDownWithScroll(listOf(hotShowsFocusRequester))
                },
                onRetry = { loadBangumi() },
                onVideoClick = onVideoSelected
            )

            RecommendSection(
                title = "热门综艺",
                videos = hotShows,
                from = VideoCardSource.DOUBAN,
                isLoading = isLoadingShows,
                errorMessage = errorShows,
                firstCardFocusRequester = hotShowsFocusRequester,
                onNavigateUp = {
                    navigateUpWithScroll(listOf(bangumiFocusRequester, hotTvShowsFocusRequester), null)
                },
                onNavigateDown = null,
                onRetry = { loadHotShows() },
                onVideoClick = onVideoSelected
            )
        }

        // ===== 长按上下文菜单（常驻组合树，由 menuVisible 控制显隐）=====
        val target = menuTarget
        val from = menuFrom
        val menuItems: List<CardMenuItem> = if (target != null && from != null) {
            val isFav = favoriteKeys.contains("${target.source}+${target.id}")
            buildList {
                when (from) {
                    VideoCardSource.PLAYRECORD -> {
                        if (isFav) {
                            add(CardMenuItem("取消收藏", isDestructive = true) {
                                requestConfirm("取消收藏", "确定取消收藏「${target.title}」吗？") {
                                    unfavoriteAction(target)
                                }
                            })
                        } else {
                            add(CardMenuItem("收藏") { addFavoriteAction(target) })
                        }
                        add(CardMenuItem("删除记录", isDestructive = true) {
                            requestConfirm("删除播放记录", "确定从「继续观看」中删除「${target.title}」吗？") {
                                deletePlayRecordAction(target)
                            }
                        })
                    }
                    VideoCardSource.FAVORITE -> {
                        add(CardMenuItem("取消收藏", isDestructive = true) {
                            requestConfirm("取消收藏", "确定取消收藏「${target.title}」吗？") {
                                unfavoriteAction(target)
                            }
                        })
                    }
                    else -> {}
                }
            }
        } else emptyList()

        CardContextMenu(
            visible = menuVisible,
            title = target?.title ?: "",
            items = menuItems,
            onClose = { menuVisible = false }
        )

        // ===== 二次确认弹窗 =====
        ConfirmDialog(
            visible = confirmVisible,
            title = confirmTitle,
            message = confirmMessage,
            onConfirm = confirmAction,
            onCancel = { confirmVisible = false }
        )
    }
}

@Preview(device = Devices.TV_1080p)
@Composable
fun HomeTabPreview() {
    HomeTab()
}

/**
 * 安全请求焦点扩展函数：若组件当前未挂载或不在视口内导致抛异常，安全捕获并返回 false，绝不抛出崩溃
 */
private fun FocusRequester.safeRequestFocus(): Boolean = try {
    requestFocus()
    true
} catch (_: Exception) {
    false
}
