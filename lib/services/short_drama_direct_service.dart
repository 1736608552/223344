import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/raw_short_drama.dart';
import 'package:luna_tv/services/duanju_core_bridge.dart';

/// 短剧直连服务 (纯净官方原画架构: 100% 红果短剧原生/直连引擎驱动，已彻底移除第三方源).
///
/// 核心特性:
/// 1. **纯正红果官方原画**: 接入 libduanju_core 原生 Go 引擎与官方直连，1080p 超清原画秒开，零跑马灯广告。
/// 2. **AI 漫剧精选**: 首发支持爆款 AI 生成式短剧与动漫漫剧，专区置顶。
/// 3. **极速单源纯净**: 彻底剥离第三方低质采集源与星芽，专注超清水准。
class ShortDramaDirectService {
  /// 官方独家源配置 (100% 对齐红果鉴官方权威四大分类体系)
  static const List<_DirectSource> _sources = [
    _DirectSource(
      name: '红果短剧',
      apiUrl: 'https://hongguoduanju.com',
      srcKey: 'hongguo',
      pages: 3,
      categories: [
        _SourceCategory(1, '真人剧'),
        _SourceCategory(2, '漫剧'),
        _SourceCategory(3, 'AI剧'),
      ],
    ),
  ];

  static const List<String> SHORT_DRAMA_KEYWORDS = [
    '真人剧',
    '漫剧',
    'AI剧',
    '热播',
    '短剧',
  ];

  /// 红果短剧官方原生与真实分类全库拉取 (精准对齐红果鉴三大核心 genre: short_play, comic_series, ai_series)
  static Future<List<RawShortDrama>> _fetchHongguoPage(
    int typeId,
    int page, {
    String? categoryName,
  }) async {
    try {
      String catKey = 'all';
      String catName = '全部短剧';

      final String name = (categoryName ?? '').trim();
      if (name == '真人剧' || typeId == 1) {
        catKey = 'short_play';
        catName = '真人剧';
      } else if (name == '漫剧' || typeId == 2) {
        catKey = 'comic_series';
        catName = '漫剧';
      } else if (name == 'AI剧' || name == 'AI 剧' || typeId == 3) {
        catKey = 'ai_series';
        catName = 'AI剧';
      } else {
        catKey = 'all';
        catName = '全部短剧';
      }

      final items = await DuanjuCoreBridge.instance.fetchCatalog(
        category: catKey,
        page: page,
        size: 24,
      );

      if (items.isNotEmpty) {
        return items.map((m) {
          final idVal = m['id'] ?? m['drama_id'] ?? m['book_id'] ?? 0;
          final realDramaId = (m['drama_id'] ?? m['series_id'] ?? m['id'] ?? idVal).toString();
          final vodId = idVal is int
              ? idVal
              : (int.tryParse(idVal.toString()) ?? idVal.hashCode.abs());
          final name =
              (m['title'] ?? m['name'] ?? m['book_name'] ?? '').toString();
          final cover =
              (m['cover'] ?? m['cover_url'] ?? m['thumb_url'] ?? '').toString();
          final ep = m['episode_count'] ?? m['total_episodes'] ?? m['episodes'] ?? 80;
          final epCount = ep is int ? ep : (int.tryParse(ep.toString()) ?? 80);
          final desc =
              (m['intro'] ?? m['description'] ?? m['summary'] ?? '').toString();

          return RawShortDrama(
            vodId: vodId,
            dramaId: realDramaId,
            vodName: RawShortDrama.cleanVodName(name),
            vodPic: RawShortDrama.cleanVodPic(cover),
            vodPicSlide: '',
            vodTime: DateTime.now().toIso8601String(),
            vodScore: 9.6,
            vodRemarksEpisodeCount: epCount,
            vodContent: desc,
            vodBlurb: desc,
            vodActor: catName,
            typeId: typeId,
            typeName: catName,
          );
        }).where((r) => r.vodName.isNotEmpty).toList();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ShortDramaDirect] hongguo error: $e');
    }
    return <RawShortDrama>[];
  }

  /// 单页拉取分发
  static Future<List<RawShortDrama>> _fetchSinglePage(
    _DirectSource src,
    String typeId,
    int page,
  ) async {
    final tid = int.tryParse(typeId) ?? 102;
    return _fetchHongguoPage(tid, page);
  }

  /// 从源并发拉取
  static Future<List<RawShortDrama>> _fetchFromSource(
    _DirectSource src,
    int typeId, {
    int startPage = 1,
    int pages = 1,
  }) async {
    final futures = <Future<List<RawShortDrama>>>[];
    for (int p = startPage; p < startPage + pages; p++) {
      futures.add(_fetchSinglePage(src, typeId.toString(), p).catchError((e) {
        // ignore: avoid_print
        print('[ShortDramaDirect] source=${src.name} type=$typeId page=$p error=$e');
        return <RawShortDrama>[];
      }));
    }
    final results = await Future.wait(futures);
    final allRaw = <RawShortDrama>[];
    for (final r in results) {
      allRaw.addAll(r);
    }
    return allRaw;
  }

  /// 关键字搜索 (纯红果全网检索)
  static Future<List<RawShortDrama>> search(String keyword) async {
    if (keyword.trim().isEmpty) return [];

    final cleanKw = keyword.trim();
    final allRaw = <RawShortDrama>[];

    try {
      final nativeItems = await DuanjuCoreBridge.instance.searchDramas(cleanKw);
      if (nativeItems.isNotEmpty) {
        final list = nativeItems.map((m) {
          final idVal = m['id'] ?? m['drama_id'] ?? m['series_id'] ?? 0;
          final realDramaId = (m['drama_id'] ?? m['series_id'] ?? m['id'] ?? idVal).toString();
          final vodId = idVal is int
              ? idVal
              : (int.tryParse(idVal.toString()) ?? idVal.hashCode.abs());
          final name = (m['title'] ?? m['name'] ?? '').toString();
          final cover = (m['cover'] ?? m['cover_url'] ?? '').toString();
          final ep = m['episode_count'] ?? m['total_episodes'] ?? 80;
          final epCount = ep is int ? ep : (int.tryParse(ep.toString()) ?? 80);
          final desc = (m['intro'] ?? m['description'] ?? '').toString();

          return RawShortDrama(
            vodId: vodId,
            dramaId: realDramaId,
            vodName: RawShortDrama.cleanVodName(name),
            vodPic: RawShortDrama.cleanVodPic(cover),
            vodPicSlide: '',
            vodTime: DateTime.now().toIso8601String(),
            vodScore: 9.6,
            vodRemarksEpisodeCount: epCount,
            vodContent: desc,
            vodBlurb: desc,
            vodActor: '红果短剧',
            typeId: 102,
            typeName: '红果精选',
          );
        }).where((r) => r.vodName.isNotEmpty).toList();
        allRaw.addAll(list);
      }
    } catch (_) {}

    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    return unique.values.toList();
  }

  /// 搜索短剧返回统一 ShortDrama 列表
  static Future<List<ShortDrama>> searchDramas(String keyword) async {
    final rawList = await search(keyword);
    return rawList.map(_toShortDrama).toList();
  }

  /// 首页"热门短剧"拉取：100% 对齐红果鉴总热播榜原生排序 (严格保留官方榜单 1~N 名真实顺序，绝不根据时间打乱)
  /// 首页"热门短剧"拉取：对齐红果鉴官方精选聚合流 (真人剧、漫剧、AI剧多样化呈现)
  static Future<List<ShortDrama>> getRecommend({int size = 60}) async {
    final allRaw = <RawShortDrama>[];

    final page1 = await _fetchHongguoPage(0, 1, categoryName: '全部');
    allRaw.addAll(page1);

    if (allRaw.length < size) {
      final page2 = await _fetchHongguoPage(0, 2, categoryName: '全部');
      allRaw.addAll(page2);
    }

    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      if (raw.vodName.isEmpty) continue;
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    final sliced = uniqueList.take(size).toList();
    return sliced.map(_toShortDrama).toList();
  }

  /// 短剧专区「全部」tab 分页形式：对齐红果鉴官方全题材聚合流 (真人剧、漫剧、AI剧交错融合，彻底杜绝内容雷同)
  static Future<ShortDramaListResponse> getRecommendResponse({
    int page = 1,
    int size = 40,
    Set<String>? excludeNames,
  }) async {
    final allRaw = await _fetchHongguoPage(0, page, categoryName: '全部');

    if (allRaw.isEmpty) {
      return const ShortDramaListResponse(list: [], hasMore: false);
    }

    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      if (raw.vodName.isEmpty) continue;
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    final filtered = excludeNames == null || excludeNames.isEmpty
        ? uniqueList
        : uniqueList.where((r) => !excludeNames.contains(r.vodName)).toList();

    return ShortDramaListResponse(
      list: filtered.map(_toShortDrama).toList(),
      hasMore: page < 50,
    );
  }

  /// 单个分类 tab 数据拉取 (真人剧、漫剧、AI剧 各自全库定向拉取，独立分页)
  static Future<ShortDramaListResponse> getListByTypeId({
    required int typeId,
    String? categoryName,
    int page = 1,
    int size = 20,
  }) async {
    final rawList = await _fetchHongguoPage(typeId, page, categoryName: categoryName);
    final hasMore = rawList.length >= 10 && page < 50;
    return ShortDramaListResponse(
      list: rawList.map(_toShortDrama).toList(),
      hasMore: hasMore,
    );
  }

  /// 红果鉴官方四大核心分类体系 (专区 Tab 第一位为「全部」，本方法返回其余官方三大核心题材)
  static Future<List<ShortDramaCategory>> getCategories() async {
    const priority = [
      ShortDramaCategory(typeId: 1, typeName: '真人剧'),
      ShortDramaCategory(typeId: 2, typeName: '漫剧'),
      ShortDramaCategory(typeId: 3, typeName: 'AI剧'),
    ];
    return priority;
  }

  /// RawShortDrama → ShortDrama 统一映射
  static ShortDrama _toShortDrama(RawShortDrama raw) {
    return ShortDrama(
      id: raw.vodId,
      dramaId: raw.dramaId.isNotEmpty ? raw.dramaId : raw.vodId.toString(),
      name: raw.vodName,
      cover: raw.vodPic,
      updateTime: raw.vodTime,
      score: raw.vodScore,
      episodeCount: raw.vodRemarksEpisodeCount,
      description: raw.vodContent.isNotEmpty ? raw.vodContent : raw.vodBlurb,
      author: raw.vodActor.isNotEmpty
          ? raw.vodActor
          : (raw.typeName.isNotEmpty ? raw.typeName : ''),
      backdrop: raw.vodPicSlide.isNotEmpty ? raw.vodPicSlide : raw.vodPic,
      voteAverage: raw.vodScore,
    );
  }
}

class _SourceCategory {
  final int typeId;
  final String typeName;
  const _SourceCategory(this.typeId, this.typeName);
}

class _DirectSource {
  final String name;
  final String apiUrl;
  final String srcKey;
  final int pages;
  final List<_SourceCategory> categories;

  const _DirectSource({
    required this.name,
    required this.apiUrl,
    required this.srcKey,
    this.pages = 3,
    required this.categories,
  });
}
