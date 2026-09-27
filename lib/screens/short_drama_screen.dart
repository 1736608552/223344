import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/screens/player_screen.dart';
import 'package:luna_tv/services/duanju_core_bridge.dart';
// v2.5.3: 列表/分类/图片走 ShortDramaDirectService (直连 3 源, 不依赖
//   serverUrl). 播放解析仍走 ShortDramaService.parseEpisode (serverUrl
//   后端代理, 含反爬/防盗链/CDN 缓存).
import 'package:cached_network_image/cached_network_image.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/luna_cache_manager.dart';
import 'package:luna_tv/services/short_drama_direct_service.dart';
import 'package:luna_tv/services/short_drama_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/widgets/short_drama_card.dart';
import 'package:luna_tv/widgets/pulsing_dots_indicator.dart';
import 'package:luna_tv/widgets/favorites_grid.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/widgets/capsule_tab_switcher.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/utils/device_utils.dart';

/// 短剧页面
class ShortDramaScreen extends StatefulWidget {
  const ShortDramaScreen({super.key});

  @override
  State<ShortDramaScreen> createState() => _ShortDramaScreenState();
}

class _ShortDramaScreenState extends State<ShortDramaScreen> {
  final ScrollController _scrollController = ScrollController();

  // 首行：主分类（全部、真人剧、漫剧、AI剧）
  static const List<String> _categoryTabs = ['全部', '真人剧', '漫剧', 'AI剧'];
  String _selectedCategoryTab = '全部';

  // 次行：排行（对标红果鉴官方四大榜单，与主分类双向联动）
  static const List<String> _rankTabs = ['全部', '总热播榜', '真人剧榜', '漫剧榜', 'AI剧榜'];
  String _selectedRankTab = '全部';

  // 题材分类列表（来自 API 的分类列表，用于映射及向后兼容）
  List<String> _typeTabs = const [];

  // 类型 -> 分类 typeId 的映射. 「全部」tab 不进 map, 走 _fetchDramaList 兜底逻辑.
  final Map<String, int> _typeToCategoryId = {};
  // 「全部」tab 的 key (selectedCategoryTab 用这个字符串表示「全部」)
  static const String _kAllTabKey = '全部';

  // 列表数据
  final List<ShortDrama> _dramaList = [];
  int _page = 1;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _errorMessage;
  // v2.5.6: 「全部」tab 用的 page 状态 (跟子分类 tab 的 _page 共享).
  // 已展示的剧名集合, 翻页去重用.
  final Set<String> _shownNames = {};
  // v2.5.14: 切 tab 竞态保护 — generation 计数. 每次 _fetchDramaList /
  //   _loadMoreDramaList 启动前 +1, await 完成时若 generation 已不匹配
  //   (说明用户又切了 tab / 触发新的拉取), 就丢弃这次结果, 不 setState
  //   写入 _dramaList. 否则旧 tab 的请求会后到, 把新 tab 的列表覆盖
  //   掉 (用户反馈: 「在全部然后点到ai漫剧, 概率会显示全部分类内容」).
  int _fetchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// v2.5.5: 加载分类列表 — 走 ShortDramaDirectService (写死分类, 0 延迟).
  /// v2.5.5 起: 分类 tab 最前面插入「全部」tab, 点击走 3 源聚合 getRecommend.
  ///
  /// v2.5.15: 修复 `_loadCategories` 完成时强制 setState `_selectedTypeTab = '全部'`
  ///   会覆盖用户已切到「其他」tab 的选择 — 时序:
  ///     1. App 启动 → initState → `_loadCategories` 启动 (getCategories 异步, ~1-2s)
  ///     2. 用户**在 await 期间** 切到「ai 漫剧」→ `_onTypeTabChanged` → setState
  ///        `_selectedTypeTab = 'ai 漫剧'`, 调 `_fetchDramaList` (gen=1, typeId=52)
  ///     3. `_loadCategories` 完成 → setState `_selectedTypeTab = '全部'` (**覆盖了
  ///        用户选择**) → 调 `_fetchDramaList` (gen=2, typeId=null, 拉全部)
  ///     4. gen=1 (ai 漫剧) 完成 → myGen(1) != 2 → 丢弃
  ///     5. gen=2 (全部) 完成 → setState `_dramaList = 全部内容`
  ///     6. UI 高亮「全部」(被 step 3 改回), 内容「全部」
  ///   用户体验: 「我切到 ai 漫剧, 怎么变回全部 + 全部内容?」 — 表现为切 tab
  ///   后内容变成「全部分类」 (用户原话: 「切换到其他的分类会变成全部分类的内容」).
  ///   修法: `_loadCategories` 完成时只在 `_selectedTypeTab` 仍为空 (未初始化) 才
  ///   设回「全部」, 用户已选的 tab 不动. 同时只在 `_dramaList` 为空时调
  ///   `_fetchDramaList` (避免重复拉, 因为 _onTypeTabChanged 已拉过).
  Future<void> _loadCategories() async {
    final categories = await ShortDramaDirectService.getCategories();
    if (!mounted) return;

    // 过滤掉 "短剧" (被「全部」tab 替代, 「全部」走 3 源聚合)
    final typeTabs = <String>[_kAllTabKey]; // 「全部」永远排第一
    final typeToId = <String, int>{};
    for (final c in categories) {
      final name = c.typeName.trim();
      if (name.isEmpty) continue;
      if (name == '短剧') continue; // 主类被「全部」替代
      if (name == '全部') continue; // 不会出现在 getCategories 返回里, 兜底
      if (typeTabs.contains(name)) continue;
      typeTabs.add(name);
      typeToId[name] = c.typeId;
    }

    setState(() {
      _typeTabs = typeTabs;
      _typeToCategoryId
        ..clear()
        ..addAll(typeToId);
      // 只在未初始化时设回「全部」
      if (_selectedCategoryTab.isEmpty) {
        _selectedCategoryTab = _kAllTabKey;
      }
    });

    // v2.5.15: 只在 _dramaList 为空 (初次进入) 且没在 loading 时才自动拉.
    //   避免覆盖 _onTypeTabChanged 已发起的请求.
    if (_dramaList.isEmpty && !_isLoading) {
      _fetchDramaList(isRefresh: true);
    }
  }

  /// 处理滚动事件，上拉加载更多
  void _handleScroll() {
    if (!mounted) return;

    if (_scrollController.hasClients) {
      final position = _scrollController.position;

      if (position.maxScrollExtent <= 0) {
        if (_hasMore && !_isLoading && !_isLoadingMore && _dramaList.isNotEmpty) {
          _loadMoreDramaList();
        }
        return;
      }

      const double threshold = 100.0;
      if (position.pixels >= position.maxScrollExtent - threshold) {
        _loadMoreDramaList();
      }
    }
  }

  /// v2.5.6: 根据当前筛选拉取数据 — 走 ShortDramaDirectService.
  /// - 选中「全部」tab (selectedTypeTab == _kAllTabKey) → 3 源全聚合
  ///   + 去重 (getRecommendResponse, size=60 一次性, 但可翻页拉更多)
  /// - 选中具体子类 (typeId=64-69/62/63/52) → 该源按 type_id 拉 + 分页
  ///
  /// v2.5.14: 切 tab race condition 修复. 老逻辑: setState 改
  ///   _selectedTypeTab 后启动 await, 但若旧 tab 的请求后到, 会把
  ///   新 tab 的列表覆盖掉. 修法: 启动时 _fetchGeneration++, 记下
  ///   自己的 gen, await 完成后比对 — 不匹配就丢弃结果, 不 setState.
  Future<void> _fetchDramaList({bool isRefresh = false}) async {
    if (!mounted) return;

    // v2.5.14: 占一个 gen, 老请求会落在旧 gen 上被丢弃
    final myGen = ++_fetchGeneration;

    setState(() {
      _isLoading = true;
      if (isRefresh) {
        _dramaList.clear();
        _page = 1;
        _hasMore = true;
        _shownNames.clear(); // v2.5.6: 切 tab / 刷新时清空去重 set
      }
      _errorMessage = null;
    });

    final selectedTypeId = _currentSelectedTypeId();
    ShortDramaListResponse result;
    if (_selectedRankTab != '全部') {
      // 榜单/排行模式：加载红果官方四大榜单
      result = await ShortDramaDirectService.getRankingList(
        boardName: _selectedRankTab,
        page: _page,
      );
    } else if (selectedTypeId == null) {
      // 首行「全部」且次行「全部」: 3 源聚合推荐
      result = await ShortDramaDirectService.getRecommendResponse(
        page: 1,
        size: 60,
        excludeNames: isRefresh ? null : _shownNames,
      );
    } else {
      // 具体题材全库 (如真人剧全库、漫剧全库、AI剧全库)
      result = await ShortDramaDirectService.getListByTypeId(
        typeId: selectedTypeId,
        categoryName: _selectedCategoryTab,
        page: _page,
        size: 20,
      );
    }

    if (!mounted) return;
    // v2.5.14: 切 tab / 新的 _loadMore 启动后, 本次结果已过期, 丢弃
    if (myGen != _fetchGeneration) return;

    setState(() {
      _dramaList.addAll(result.list);
      // v2.5.6: 把新拉的剧名加入 _shownNames (下次翻页排除)
      for (final d in result.list) {
        if (d.name.isNotEmpty) _shownNames.add(d.name);
      }
      _hasMore = result.hasMore;
      _isLoading = false;
    });
  }

  /// 加载更多
  Future<void> _loadMoreDramaList() async {
    if (!mounted) return;
    if (_isLoading || _isLoadingMore || !_hasMore) return;

    // v2.5.14: 翻页也占 gen, 防止切 tab 时旧 page increment 撞上
    final myGen = ++_fetchGeneration;

    setState(() {
      _isLoadingMore = true;
    });

    _page++;

    final selectedTypeId = _currentSelectedTypeId();
    ShortDramaListResponse result;
    if (_selectedRankTab != '全部') {
      // 排行模式翻页
      result = await ShortDramaDirectService.getRankingList(
        boardName: _selectedRankTab,
        page: _page,
      );
    } else if (selectedTypeId == null) {
      // 「全部」tab 翻页: 拉下一页推荐
      result = await ShortDramaDirectService.getRecommendResponse(
        page: _page,
        size: 60,
        excludeNames: _shownNames,
      );
    } else {
      result = await ShortDramaDirectService.getListByTypeId(
        typeId: selectedTypeId,
        categoryName: _selectedCategoryTab,
        page: _page,
        size: 20,
      );
    }

    if (!mounted) return;
    // v2.5.14: 切 tab 后, 本次 page increment 已过期, 丢弃
    if (myGen != _fetchGeneration) {
      // 还原 _page, 不影响新 tab 的起始页 (新 tab 会自己 _page=1)
      _page--;
      return;
    }
    setState(() {
      _dramaList.addAll(result.list);
      for (final d in result.list) {
        if (d.name.isNotEmpty) _shownNames.add(d.name);
      }
      _hasMore = result.hasMore;
      _isLoadingMore = false;
    });
  }

  /// 当前选中主分类的 typeId. 返回 null 表示「全部」(走聚合).
  int? _currentSelectedTypeId() {
    if (_selectedCategoryTab == _kAllTabKey) return null;
    if (_selectedCategoryTab == '真人剧') return 1;
    if (_selectedCategoryTab == '漫剧') return 2;
    if (_selectedCategoryTab == 'AI剧' || _selectedCategoryTab == 'AI 剧') return 3;
    final id = _typeToCategoryId[_selectedCategoryTab];
    if (id == null || id <= 0) return null;
    return id;
  }

  /// 下拉刷新
  Future<void> _refreshDramaList() async {
    await _fetchDramaList(isRefresh: true);
  }

  /// 切换主分类（首行）并联动次行排行
  void _onCategoryChanged(String category) {
    if (_selectedCategoryTab == category && _selectedRankTab != '全部') return;
    setState(() {
      _selectedCategoryTab = category;
      _shownNames.clear();
      _page = 1;

      // 联动次行排行
      if (category == '全部') {
        if (_selectedRankTab != '总热播榜' && _selectedRankTab != '全部') {
          _selectedRankTab = '全部';
        }
      } else if (category == '真人剧') {
        _selectedRankTab = '真人剧榜';
      } else if (category == '漫剧') {
        _selectedRankTab = '漫剧榜';
      } else if (category == 'AI剧') {
        _selectedRankTab = 'AI剧榜';
      }
    });
    _fetchDramaList(isRefresh: true);
  }

  /// 切换排行（次行）并联动首行主分类
  void _onRankChanged(String rank) {
    if (_selectedRankTab == rank) return;
    setState(() {
      _selectedRankTab = rank;
      _shownNames.clear();
      _page = 1;

      // 联动首行主分类
      if (rank == '总热播榜') {
        _selectedCategoryTab = '全部';
      } else if (rank == '真人剧榜') {
        _selectedCategoryTab = '真人剧';
      } else if (rank == '漫剧榜') {
        _selectedCategoryTab = '漫剧';
      } else if (rank == 'AI剧榜') {
        _selectedCategoryTab = 'AI剧';
      } else if (rank == '全部') {
        // 次行选中「全部」表示退出榜单，查看首行当前选中的分类全库
      }
    });
    _fetchDramaList(isRefresh: true);
  }

  /// 点击短剧卡片 - 采用红果短剧 (官方原画) 观看源直出播放
  void _onDramaTap(ShortDrama drama) {
    final realId = drama.dramaId.isNotEmpty ? drama.dramaId : drama.id.toString();
    final cover = drama.backdrop.isNotEmpty ? drama.backdrop : drama.cover;
    final totalEps = drama.episodeCount > 0 ? drama.episodeCount : 80;
    final eps = List.generate(totalEps, (i) => (i + 1).toString());
    final epTitles = List.generate(totalEps, (i) => '第${i + 1}集');

    // 提前后台静默预拉取整剧 vid_list 与第 1 集播放计划，实现点击即秒开起播
    unawaited(DuanjuCoreBridge.instance.fetchEpisodeVidList(realId));
    unawaited(DuanjuCoreBridge.instance.prefetchEpisode(realId, 1));

    final initialDetail = SearchResult(
      id: realId,
      title: drama.name,
      poster: cover,
      episodes: eps,
      episodesTitles: epTitles,
      source: 'hongguo',
      sourceName: '红果短剧 (官方原画)',
      year: '2026',
      desc: drama.description,
      typeName: drama.author,
    );

    final videoInfo = VideoInfo(
      id: realId,
      source: 'hongguo',
      title: drama.name,
      sourceName: '红果短剧 (官方原画)',
      year: '2026',
      cover: cover,
      index: 0,
      totalEpisodes: totalEps,
      playTime: 0,
      totalTime: 0,
      saveTime: 0,
      searchTitle: drama.name,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PlayerScreen(
          videoInfo: videoInfo,
          preferredSource: 'hongguo',
          initialDetail: initialDetail,
        ),
      ),
    );
  }

  /// 显示短剧菜单 (长按) — 跟随主题亮色/暗色, 已收藏显示取消收藏
  void _showDramaMenu(ShortDrama drama) {
    HapticFeedback.mediumImpact();
    final themeService = Provider.of<ThemeService>(context, listen: false);
    final isDark = themeService.isDarkMode;
    final isFavorited = PageCacheService().isFavoritedSync('shortdrama', drama.id.toString());
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2C2C2C) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[600] : Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  drama.name,
                  style: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Divider(
                color: isDark ? const Color(0xFF3A3A3A) : Colors.grey[200],
                height: 1,
              ),
              ListTile(
                leading: const Icon(Icons.play_arrow, color: Color(0xFF22C55E)),
                title: Text('播放', style: TextStyle(color: isDark ? Colors.white : Colors.black87)),
                onTap: () {
                  Navigator.pop(ctx);
                  _onDramaTap(drama);
                },
              ),
              ListTile(
                leading: Icon(
                  isFavorited ? Icons.favorite : Icons.favorite_border,
                  color: const Color(0xFFE74C3C),
                ),
                title: Text(
                  isFavorited ? '取消收藏' : '收藏',
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _toggleFavorite(drama);
                },
              ),
              ListTile(
                leading: Icon(Icons.info_outline, color: isDark ? Colors.white70 : Colors.grey[600]),
                title: Text('查看详情', style: TextStyle(color: isDark ? Colors.white : Colors.black87)),
                onTap: () {
                  Navigator.pop(ctx);
                  _onDramaTap(drama);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 切换收藏
  Future<void> _toggleFavorite(ShortDrama drama) async {
    final videoInfo = VideoInfo(
      id: drama.id.toString(),
      source: 'shortdrama',
      title: drama.name,
      sourceName: '',
      year: '',
      cover: drama.cover,
      index: 0,
      totalEpisodes: drama.episodeCount,
      playTime: 0,
      totalTime: 0,
      saveTime: 0,
      searchTitle: drama.name,
    );
    try {
      final result = await PageCacheService().toggleFavorite(
        'shortdrama',
        drama.id.toString(),
        videoInfo.toJson(),
        context,
      );
      if (result.success) {
        await FavoritesGrid.refreshFavorites();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已加入收藏'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('收藏失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return RefreshIndicator(
          onRefresh: _refreshDramaList,
          color: const Color(0xFF22C55E),
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 顶部标题
              SliverToBoxAdapter(
                child: _buildHeader(themeService),
              ),
              // 筛选区（与电视剧页风格一致：白底圆角容器，双行标签）
              SliverToBoxAdapter(
                child: _buildFilterSection(themeService),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              // 内容区域
              if (_isLoading && _dramaList.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: PulsingDotsIndicator(),
                  ),
                )
              else if (_errorMessage != null && _dramaList.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildErrorState(themeService),
                )
              else if (_dramaList.isEmpty && !_isLoading)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyState(themeService),
                )
              else
                _buildDramaGrid(themeService),
              // 底部加载更多指示器
              if (_dramaList.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _buildBottomIndicator(themeService),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 构建顶部标题（带专属短剧搜索入口）
  Widget _buildHeader(ThemeService themeService) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '短剧',
                style: FontUtils.poppins(context,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 20, // 固定高度确保一致性
                child: Text(
                  '精彩短剧，一刷到底',
                  style: FontUtils.poppins(context,
                    fontSize: 14,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          InkWell(
            onTap: _openShortDramaSearch,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: themeService.isDarkMode
                    ? Colors.white.withOpacity(0.08)
                    : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: themeService.isDarkMode
                      ? Colors.white.withOpacity(0.12)
                      : const Color(0xFFE5E7EB),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: Color(0xFF22C55E),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '搜索短剧',
                    style: FontUtils.poppins(context,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: themeService.isDarkMode
                          ? Colors.white70
                          : const Color(0xFF4B5563),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 弹出专属短剧全网搜索弹窗
  void _openShortDramaSearch() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ShortDramaSearchModal(onDramaTap: _onDramaTap),
    );
  }

  /// 构建筛选区（与电视剧页风格一致：白底/半透明圆角卡片，首行主分类 + 次行排行，双向互动）
  Widget _buildFilterSection(ThemeService themeService) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: themeService.isDarkMode
            ? Colors.white.withOpacity(0.1)
            : Colors.white.withOpacity(0.8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 首行：主分类（全部、真人剧、漫剧、AI剧）
          _buildFilterRow(
            label: '分类',
            tabs: _categoryTabs,
            selectedTab: _selectedCategoryTab,
            onTabChanged: _onCategoryChanged,
          ),
          const SizedBox(height: 12),
          // 次行：排行（对标红果鉴官方四大榜单，与主分类双向联动）
          _buildFilterRow(
            label: '排行',
            tabs: _rankTabs,
            selectedTab: _selectedRankTab,
            onTabChanged: _onRankChanged,
          ),
        ],
      ),
    );
  }

  /// 构建单行筛选行（标题 + 横向胶囊标签）
  Widget _buildFilterRow({
    required String label,
    required List<String> tabs,
    required String selectedTab,
    required ValueChanged<String> onTabChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: FontUtils.poppins(context,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: CapsuleTabSwitcher(
            tabs: tabs,
            selectedTab: selectedTab,
            onTabChanged: onTabChanged,
          ),
        ),
      ],
    );
  }

  /// 构建短剧网格
  Widget _buildDramaGrid(ThemeService themeService) {
    final bool isPC = DeviceUtils.isPC();
    final double screenWidth = MediaQuery.of(context).size.width;

    int crossAxisCount;
    double horizontalPadding;

    if (isPC) {
      if (screenWidth > 1200) {
        crossAxisCount = 6;
      } else if (screenWidth > 900) {
        crossAxisCount = 5;
      } else {
        crossAxisCount = 4;
      }
      horizontalPadding = 24;
    } else if (DeviceUtils.isTablet(context)) {
      // 平板模式：根据屏幕宽度动态展示 6～8 列
      crossAxisCount = DeviceUtils.getTabletColumnCount(context);
      horizontalPadding = 16;
    } else {
      crossAxisCount = 3;
      horizontalPadding = 12;
    }

    final double gridWidth = screenWidth - horizontalPadding * 2;
    final double spacing = isPC ? 16.0 : 12.0;
    final double cardWidth = (gridWidth - spacing * (crossAxisCount - 1)) / crossAxisCount;
    // 平板 6~8 列下卡片更窄,行间距收紧 + 文字区按 cardWidth 缩放,避免海报视觉松散
    final double mainAxisSpacing = isPC ? 16.0 : 12.0;
    // PC 大卡文字区给 22,手机/平板窄卡统一给 16,与 ShortDramaCard 内部缩字号一致
    final double textAreaHeight = cardWidth < 200 ? 16.0 : 22.0;

    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: mainAxisSpacing,
          crossAxisSpacing: spacing,
          childAspectRatio: cardWidth / (cardWidth * 1.5 + textAreaHeight),
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final drama = _dramaList[index];
            return ShortDramaCard(
              drama: drama,
              cardWidth: cardWidth,
              onTap: () => _onDramaTap(drama),
              onLongPress: () => _showDramaMenu(drama),
            );
          },
          childCount: _dramaList.length,
        ),
      ),
    );
  }

  /// 构建空状态
  Widget _buildEmptyState(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.movie_filter_outlined,
            size: 64,
            color: themeService.isDarkMode
                ? Colors.white.withOpacity(0.3)
                : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '暂无短剧内容',
            style: FontUtils.poppins(context,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '下拉刷新试试',
            style: FontUtils.poppins(context,
              fontSize: 13,
              color: themeService.isDarkMode
                  ? Colors.white.withOpacity(0.4)
                  : Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建错误状态
  Widget _buildErrorState(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: themeService.isDarkMode
                ? Colors.white.withOpacity(0.3)
                : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            _errorMessage ?? '加载失败',
            style: FontUtils.poppins(context,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _refreshDramaList,
            child: Text(
              '重试',
              style: FontUtils.poppins(context,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF27ae60),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建底部指示器
  Widget _buildBottomIndicator(ThemeService themeService) {
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: PulsingDotsIndicator(),
      );
    }

    if (!_hasMore && _dramaList.isNotEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          children: [
            Container(
              width: 60,
              height: 2,
              decoration: BoxDecoration(
                color: themeService.isDarkMode
                    ? Colors.white.withOpacity(0.3)
                    : Colors.grey.withOpacity(0.4),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '已经到底啦~',
              style: FontUtils.poppins(context,
                fontSize: 14,
                color: themeService.isDarkMode
                    ? Colors.white.withOpacity(0.6)
                    : Colors.grey[600],
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '共 ${_dramaList.length} 部短剧',
              style: FontUtils.poppins(context,
                fontSize: 12,
                color: themeService.isDarkMode
                    ? Colors.white.withOpacity(0.4)
                    : Colors.grey[500],
                fontWeight: FontWeight.w300,
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox(height: 50);
  }
}

/// 专属短剧独立搜索面板
class _ShortDramaSearchModal extends StatefulWidget {
  final void Function(ShortDrama drama) onDramaTap;

  const _ShortDramaSearchModal({required this.onDramaTap});

  @override
  State<_ShortDramaSearchModal> createState() => _ShortDramaSearchModalState();
}

class _ShortDramaSearchModalState extends State<_ShortDramaSearchModal> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<ShortDrama> _searchResults = [];
  bool _isSearching = false;
  String? _searchError;
  bool _hasSearched = false;

  static const List<String> _hotKeywords = [
    '文盲修仙',
    '东北话事人',
    '我的婆婆',
    '天神殿',
    '凡人百世书',
    '重生富翁',
    '萌宝',
    '逆袭',
  ];

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    final cleanQ = query.trim();
    if (cleanQ.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchError = null;
      _hasSearched = true;
      _searchResults.clear();
    });

    try {
      final results = await ShortDramaDirectService.searchDramas(cleanQ);
      if (mounted) {
        setState(() {
          _searchResults.addAll(results);
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searchError = '搜索异常: $e';
          _isSearching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeService = Provider.of<ThemeService>(context);
    final isDark = themeService.isDarkMode;
    final bgColor = isDark ? const Color(0xFF1E1E24) : Colors.white;

    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // 顶部小横条
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),

          // 搜索栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withOpacity(0.08) : const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(21),
                      border: Border.all(
                        color: isDark ? Colors.white12 : const Color(0xFFE5E7EB),
                      ),
                    ),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      style: FontUtils.poppins(context,
                        fontSize: 14,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: _performSearch,
                      decoration: InputDecoration(
                        hintText: '搜索全网热门短剧...',
                        hintStyle: FontUtils.poppins(context,
                          fontSize: 14,
                          color: isDark ? Colors.white38 : Colors.grey[500],
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          size: 20,
                          color: Color(0xFF22C55E),
                        ),
                        suffixIcon: _controller.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _controller.clear();
                                  setState(() {});
                                },
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onChanged: (v) => setState(() {}),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _performSearch(_controller.text),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF22C55E),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: const Text('搜索', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 热词标签
          if (!_hasSearched) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '热门短剧推荐',
                  style: FontUtils.poppins(context,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _hotKeywords.map((kw) {
                  return ActionChip(
                    label: Text(kw, style: const TextStyle(fontSize: 12)),
                    backgroundColor: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFF3F4F6),
                    onPressed: () {
                      _controller.text = kw;
                      _performSearch(kw);
                    },
                  );
                }).toList(),
              ),
            ),
          ],

          // 搜索中或结果列表
          Expanded(
            child: _isSearching
                ? const Center(child: PulsingDotsIndicator())
                : _searchError != null
                    ? Center(child: Text(_searchError!, style: const TextStyle(color: Colors.redAccent)))
                    : _hasSearched && _searchResults.isEmpty
                        ? Center(
                            child: Text(
                              '未找到相关短剧，换个关键词试试',
                              style: TextStyle(color: isDark ? Colors.white38 : Colors.grey),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _searchResults.length,
                            separatorBuilder: (_, __) => const Divider(height: 16),
                            itemBuilder: (context, index) {
                              final d = _searchResults[index];
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: CachedNetworkImage(
                                    imageUrl: UserDataService.buildShortDramaImageUrl(d.cover),
                                    cacheManager: LunaCacheManager.instance,
                                    width: 48,
                                    height: 64,
                                    fit: BoxFit.cover,
                                    placeholder: (context, url) => Container(
                                      width: 48,
                                      height: 64,
                                      color: isDark ? Colors.white12 : Colors.grey[200],
                                    ),
                                    errorWidget: (context, url, error) => Container(
                                      width: 48,
                                      height: 64,
                                      color: isDark ? Colors.white12 : Colors.grey[200],
                                      child: const Icon(Icons.movie, size: 24),
                                    ),
                                  ),
                                ),
                                title: Text(
                                  d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 4),
                                    Text(
                                      '共 ${d.episodeCount} 集 · 官方原画',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: const Color(0xFF22C55E),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (d.description.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        d.description,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isDark ? Colors.white54 : Colors.black45,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                trailing: const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF22C55E), size: 30),
                                onTap: () {
                                  Navigator.pop(context);
                                  widget.onDramaTap(d);
                                },
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}